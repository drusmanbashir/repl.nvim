local uv = vim.uv
local M = {}

local prefix, suffix = "\27P@kitty-cmd", "\27\\"
local version = { 0, 14, 2 }
local timeout_ms = 2000
local max_reply_bytes = 16 * 1024 * 1024

local function frame(command, payload, no_response)
  return prefix .. vim.json.encode({
    cmd = command,
    version = version,
    payload = payload,
    no_response = no_response,
  }) .. suffix
end

local function decode(raw)
  local first = raw:find(prefix, 1, true)
  local last = first and raw:find(suffix, first + #prefix, true)
  if not last then return nil, "missing Kitty response frame" end
  local ok, reply = pcall(vim.json.decode, raw:sub(first + #prefix, last - 1))
  if not ok or type(reply) ~= "table" or type(reply.ok) ~= "boolean" then
    return nil, "invalid Kitty response"
  end
  if not reply.ok then return nil, tostring(reply.error or "Kitty rejected the request") end
  if reply.data == nil then return true end
  return reply.data
end

local function exchange(listen_on, frames, expect_reply, callback)
  local path = type(listen_on) == "string" and listen_on:match("^unix:(.+)$")
  if not path then
    callback(nil, "a Kitty Unix socket is required")
    return
  end
  if path:sub(1, 1) == "@" then path = "\0" .. path:sub(2) end

  local pipe, pipe_error = uv.new_pipe(false)
  if not pipe then
    callback(nil, pipe_error)
    return
  end
  local timer, timer_error = uv.new_timer()
  if not timer then
    pipe:close()
    callback(nil, timer_error)
    return
  end

  local chunks, bytes, finished = {}, 0, false
  local function finish(data, err)
    if finished then return end
    finished = true
    timer:close()
    pipe:close()
    callback(data, err)
  end

  local function read(err, chunk)
    if finished then return end
    if err or not chunk then
      finish(nil, err or "Kitty closed the socket before replying")
      return
    end
    bytes = bytes + #chunk
    if bytes > max_reply_bytes then
      finish(nil, "Kitty response exceeded 16 MiB")
      return
    end
    local previous = chunks[#chunks]
    chunks[#chunks + 1] = chunk
    if chunk:find(suffix, 1, true) or (previous and previous:sub(-1) .. chunk:sub(1, 1) == suffix) then
      finish(decode(table.concat(chunks)))
    end
  end

  local function connected(err)
    if finished then return end
    if err then
      finish(nil, err)
      return
    end
    if expect_reply then
      local started, read_error = pipe:read_start(read)
      if not started then
        finish(nil, read_error)
        return
      end
    end
    local write, write_error = pipe:write(frames, function(err)
      if err or not expect_reply then finish(not err or nil, err) end
    end)
    if not write then finish(nil, write_error) end
  end

  local started, timer_start_error = timer:start(timeout_ms, 0, function()
    finish(nil, "timed out on " .. listen_on)
  end)
  if not started then
    finish(nil, timer_start_error)
    return
  end
  local connecting, connect_error = pipe:connect2(path, { no_truncate = true }, connected)
  if not connecting then finish(nil, connect_error) end
  return finish
end

local function await(listen_on, frames, expect_reply)
  assert(not vim.in_fast_event(), "Kitty RPC requires the editor event loop")
  local finished, data, failure
  local finish = exchange(listen_on, frames, expect_reply, function(reply, err)
    finished, data, failure = true, reply, err
  end)
  if not finished then
    local ok, reason = vim.wait(timeout_ms, function() return finished end, timeout_ms, true)
    if not ok then
      finish(nil, reason == -2 and "Kitty request interrupted" or "timed out on " .. listen_on)
    end
  end
  return data, failure
end

function M.request(listen_on, command, payload)
  return await(listen_on, frame(command, payload, false), true)
end

function M.request_async(listen_on, command, payload, callback)
  exchange(listen_on, frame(command, payload, false), true, vim.schedule_wrap(callback))
end

function M.get_text(listen_on, window_id, extent)
  local text, err = M.request(listen_on, "get-text", { match = "id:" .. tostring(window_id), extent = extent })
  if type(text) ~= "string" then return nil, err or "missing Kitty get-text payload" end
  return text
end

function M.send_text(listen_on, window_id, ...)
  local id = tonumber(window_id)
  if not id then return nil, "a Kitty window ID is required" end
  local match = "id:" .. tostring(id)
  local frames = {}
  -- Kitty's CLI uses 1024-byte chunks. Base64 preserves bytes across chunk
  -- boundaries, and every fragment shares one socket to preserve ordering.
  for _, fragment in ipairs({ ... }) do
    for i = 1, #fragment, 1024 do
      frames[#frames + 1] = frame("send-text", {
        match = match,
        data = "base64:" .. vim.base64.encode(fragment:sub(i, i + 1023)),
      }, true)
    end
  end
  if #frames == 0 then return true end
  return await(listen_on, frames, false)
end

return M
