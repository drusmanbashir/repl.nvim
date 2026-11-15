-- One cached view of `kitty @ ls`, shared by every REPL consumer.
--
-- Why this exists: a single `send_cell` asked kitty for its whole window tree
-- TWICE -- once from repl_focus.publish_target and once from
-- slime.ensure_slime_target -- through two separate, uncached copies of the
-- same function. Measured 2026-09-01: 50ms per call, and that is not payload
-- (12.6KB; `ls --match id:N` measures the same) but the kitty command-line
-- client's own Python startup. Talking to the socket directly costs 23ms.
--
-- What the cache may NOT break: the operator runs a variable number of python
-- buffers, each bound to its own kitty window running its own conda env, with
-- <leader>it to rebind and <leader>in to launch a new one. So:
--   * a window id that is absent from the cached tree forces ONE refresh
--     before anyone concludes the window is gone -- otherwise <leader>in would
--     launch a REPL that the very next lookup denies exists;
--   * every kitty call that MUTATES the tree (title, launch, close, restart)
--     invalidates it, because the send path reads back the title it just wrote;
--   * the poll loops that watch for a REPL to appear must call fresh(), since
--     a cache is precisely what they are polling to defeat.
--
-- The tree is cached per socket, not per window: one socket hosts one window
-- per conda env (`dl-repl-1` and `agent-repl-1` share
-- unix:/run/user/1000/dl-repl-kitty.sock), and a single `ls` already answers
-- for all of them.

local uv = vim.uv or vim.loop

local M = {}

-- Long enough that one user action pays a single round trip, short enough that
-- a window closed by hand outside Neovim cannot linger.
M.ttl_ms = 2000

local cache = {}
local stats = { hits = 0, misses = 0, refreshes = 0, socket = 0, cli = 0 }

local function now_ms()
  return uv.hrtime() / 1e6
end

--- `unix:/run/user/1000/x.sock` -> a path; `unix:@name` -> Linux abstract
--- socket, whose name is a NUL byte followed by the label.
local function socket_path(listen_on)
  if type(listen_on) ~= "string" then
    return nil
  end
  local path = listen_on:match("^unix:(.+)$")
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 1) == "@" then
    return "\0" .. path:sub(2)
  end
  return path
end

--- kitty answers a DCS-wrapped envelope whose `data` is itself a JSON string.
local function decode_envelope(raw)
  local body = raw:match("\27P@kitty%-cmd(.-)\27\\")
  if not body then
    return nil, "no kitty-cmd envelope in reply"
  end
  local ok, envelope = pcall(vim.json.decode, body)
  if not ok or type(envelope) ~= "table" then
    return nil, "unparseable kitty envelope"
  end
  if not envelope.ok then
    return nil, tostring(envelope.error or "kitty reported failure")
  end
  local data = envelope.data
  if type(data) == "string" then
    local decoded_ok, decoded = pcall(vim.json.decode, data)
    if not decoded_ok then
      return nil, "unparseable kitty ls payload"
    end
    return decoded
  end
  return data
end

--- Preferred transport: 23ms, no process spawn.
local function rpc_socket(listen_on, timeout_ms)
  local path = socket_path(listen_on)
  if not path then
    return nil, "not a unix socket"
  end
  local pipe = uv.new_pipe(false)
  if not pipe then
    return nil, "could not create pipe"
  end

  local chunks, finished, failure = {}, false, nil
  local function close_pipe()
    if pipe and not pipe:is_closing() then
      pcall(function()
        pipe:read_stop()
      end)
      pcall(function()
        pipe:close()
      end)
    end
  end
  local function finish(err)
    if finished then
      return
    end
    finished, failure = true, err
    close_pipe()
  end

  pipe:connect(path, function(connect_error)
    if connect_error then
      finish(tostring(connect_error))
      return
    end
    pipe:read_start(function(read_error, chunk)
      if read_error then
        finish(tostring(read_error))
        return
      end
      if not chunk then
        finish("kitty closed the socket before replying")
        return
      end
      chunks[#chunks + 1] = chunk
      -- The terminator can straddle two chunks, so test the joined buffer.
      if table.concat(chunks):find("\27\\", 1, true) then
        finish(nil)
      end
    end)
    local request = "\27P@kitty-cmd"
      .. vim.json.encode({ cmd = "ls", version = { 0, 14, 0 }, no_response = false })
      .. "\27\\"
    pipe:write(request, function(write_error)
      if write_error then
        finish(tostring(write_error))
      end
    end)
  end)

  local completed = vim.wait(timeout_ms or 2000, function()
    return finished
  end, 5)
  close_pipe()

  if not completed then
    return nil, "timed out waiting for " .. listen_on
  end
  if failure then
    return nil, failure
  end
  return decode_envelope(table.concat(chunks))
end

--- Fallback for anything the socket cannot serve (a kitty too old to answer
--- unauthenticated, a socket path this Neovim cannot open). Costs 50ms.
local function rpc_cli(listen_on)
  local kitty_bin = require("repl.config").kitty_bin()
  local output = vim.fn.system({ kitty_bin, "@", "--to", listen_on, "ls" })
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output or "")
  end
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return nil, "kitty @ ls returned unparseable output for " .. tostring(listen_on)
  end
  return decoded
end

local function fetch(listen_on)
  local tree, socket_error = rpc_socket(listen_on)
  if tree then
    stats.socket = stats.socket + 1
    return tree
  end
  local cli_tree, cli_error = rpc_cli(listen_on)
  if cli_tree then
    stats.cli = stats.cli + 1
    return cli_tree
  end
  return nil, string.format("socket: %s; cli: %s", tostring(socket_error), tostring(cli_error))
end

--- Drop the cached tree for one socket. Call after ANY kitty command that
--- changes a window's title, existence, or tab.
function M.invalidate(listen_on)
  if listen_on == nil then
    cache = {}
    return
  end
  cache[listen_on] = nil
end

function M.invalidate_all()
  cache = {}
end

--- Uncached read. For poll loops that are waiting for the tree to change.
function M.fresh(listen_on)
  local tree, err = fetch(listen_on)
  cache[listen_on] = tree and { tree = tree, stamp = now_ms() } or nil
  return tree, err
end

--- Cached read.
function M.get(listen_on, opts)
  opts = opts or {}
  if type(listen_on) ~= "string" or listen_on == "" or listen_on == "?" then
    return nil, "no kitty socket"
  end
  local entry = cache[listen_on]
  local ttl = opts.ttl_ms or M.ttl_ms
  if not opts.force and entry and (now_ms() - entry.stamp) < ttl then
    stats.hits = stats.hits + 1
    return entry.tree
  end
  stats.misses = stats.misses + 1
  return M.fresh(listen_on)
end

--- Every window on this socket, flattened out of the OS-window/tab nesting.
function M.windows(tree)
  local out = {}
  for _, os_window in ipairs(tree or {}) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        out[#out + 1] = window
      end
    end
  end
  return out
end

local function find(tree, window_id)
  for _, window in ipairs(M.windows(tree)) do
    if tonumber(window.id) == window_id then
      return window
    end
  end
end

--- Look one window up by id. A miss forces exactly one refresh before
--- reporting the window gone: a REPL launched by <leader>in seconds ago is
--- absent from a stale tree, and treating that as "no such window" is what
--- would break launching.
function M.window(listen_on, window_id)
  window_id = tonumber(window_id)
  if not window_id then
    return nil, "no window id"
  end
  local tree, err = M.get(listen_on)
  if not tree then
    return nil, err
  end
  local window = find(tree, window_id)
  if window then
    return window
  end
  if cache[listen_on] then
    stats.refreshes = stats.refreshes + 1
    tree, err = M.fresh(listen_on)
    if not tree then
      return nil, err
    end
    window = find(tree, window_id)
    if window then
      return window
    end
  end
  return nil, string.format("kitty window %d not found on %s", window_id, tostring(listen_on))
end

--- Test seam: tests/kitty_tree_cache_smoke.sh asserts on these counters.
function M._test_stats()
  return vim.deepcopy(stats)
end

function M._test_reset()
  cache = {}
  stats = { hits = 0, misses = 0, refreshes = 0, socket = 0, cli = 0 }
end

return M
