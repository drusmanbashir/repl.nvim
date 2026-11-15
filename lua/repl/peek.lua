--- REPL value peek: show what the LIVE REPL holds for the expression under the
--- cursor (or the visual selection), beside the code that names it.
---
--- Contract (REPL_ROUTING.md § `<M-k>` peek):
---  * Silent when the name is not defined in the REPL, when the probe raises,
---    and when the REPL never answers in time. A peek never launches a REPL,
---    never prompts, and never leaves a message behind for those three.
---    Everything else (no probe for this family, backend cannot peek) is
---    reported once, per the universal-REPL rule against silent no-ops.
---  * The answer travels through a run-dir file, not the terminal screen: a
---    busy scrollback, ANSI, and a prompt half-drawn by a still-running cell
---    are things a screen scrape has to guess about, and a wrong guess here
---    would put someone else's value next to this line.
---  * The probe runs `exec(<code>, globals(), dict(locals()))`: reads see the
---    frame (so a peek works stopped at a debug frame as well as at the
---    prompt), writes land in the copy, so the user namespace, `_` and the
---    `Out` history are untouched.
---
--- Style is `vim.g.ub_repl_peek_style`: "popup" (a float at the cursor, the
--- default) or "inline" (virtual text at end of the cursor line). `<leader>ip`
--- toggles.

local M = {}

local NS = vim.api.nvim_create_namespace("ub_repl_peek")
local AUGROUP = vim.api.nvim_create_augroup("ub_repl_peek", { clear = true })

local STYLES = { inline = true, popup = true }

local DEFAULTS = {
  style = "popup",
  timeout_ms = 2000,
  poll_ms = 25,
  max_chars = 4000,
  inline_chars = 120,
  popup_lines = 20,
  expr = "cexpr",
  server = true,
}

-- One peek at a time: the in-flight request and what is currently painted.
local pending = nil
local painted = nil

vim.api.nvim_set_hl(0, "ReplPeekValue", { link = "DiagnosticVirtualTextInfo", default = true })

-- ===== settings =====

local function setting(name)
  local value = vim.g["ub_repl_peek_" .. name]
  if value == nil or value == "" then
    value = vim.env["NVIM_REPL_PEEK_" .. name:upper()]
  end
  if value == nil or value == "" then
    return DEFAULTS[name]
  end
  if type(DEFAULTS[name]) == "number" then
    return tonumber(value) or DEFAULTS[name]
  end
  return value
end

function M.style()
  local style = tostring(setting("style")):lower()
  if not STYLES[style] then
    return DEFAULTS.style
  end
  return style
end

function M.set_style(style)
  style = type(style) == "string" and style:lower() or ""
  if style == "" or style == "toggle" then
    style = M.style() == "inline" and "popup" or "inline"
  end
  if not STYLES[style] then
    vim.notify("REPL peek style must be inline, popup or toggle", vim.log.levels.WARN)
    return false
  end
  vim.g.ub_repl_peek_style = style
  vim.notify("REPL peek style: " .. style, vim.log.levels.INFO)
  return true
end

function M.toggle_style()
  return M.set_style("toggle")
end

-- ===== probes =====

--- Escape for embedding in a double-quoted Python literal. Newlines become
--- `\n` ESCAPES, not line breaks: the whole probe has to stay ONE physical
--- line or the REPL executes half of it on the first newline it sees.
local function py_literal(text)
  local escaped = text:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. escaped .. '"'
end

local function r_literal(text)
  local escaped = text:gsub("[\\']", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return "'" .. escaped .. "'"
end

--- family -> (expr, path, limit) -> one line of source the REPL can run.
--- The answer file is written under a `.part` name and renamed, so the poller
--- can never read a half-written value.
local PROBES = {}

--- Kept as short as it can be: the REPL echoes whatever is pasted into it, so
--- every character here is scrollback the operator has to read past. The names
--- it binds (`r`, `e`, `p`) are common ones deliberately -- they are bound in
--- the throwaway copy, never the session, and each is read before it is
--- rebound, so peeking `r`, `e` or `p` itself still answers with the session's.
PROBES.python = function(expr, path, limit)
  local code = table.concat({
    "try:",
    " r='ok\\n'+repr((" .. expr .. "))",
    "except BaseException as e:",
    " r='err:'+type(e).__name__",
    "p=__import__('pathlib').Path(" .. py_literal(path .. ".part") .. ")",
    "p.write_text(r[:" .. limit .. "],errors='replace')",
    "p.rename(" .. py_literal(path) .. ")",
  }, "\n")
  return "exec(" .. py_literal(code) .. ",globals(),dict(locals()))"
end

PROBES.r = function(expr, path, limit)
  local p = r_literal(path)
  return table.concat({
    "local({p<-",
    p,
    ";r<-tryCatch(paste0('ok\\n',paste(utils::capture.output(print(",
    expr,
    ")),collapse='\\n')),error=function(e) paste0('err:',class(e)[1]));",
    "cat(substr(r,1,",
    tostring(limit),
    "),file=paste0(p,'.part'));file.rename(paste0(p,'.part'),p)})",
  }, "")
end

function M.probe(family, expr, path, limit)
  local build = PROBES[family]
  if not build then
    return nil
  end
  return build(expr, path, limit or DEFAULTS.max_chars)
end

--- Probe answer -> value, or nil plus the reason it has none.
function M.parse(data)
  if type(data) ~= "string" or data == "" then
    return nil, "empty"
  end
  local head, body = data:match("^([^\n]*)\n?(.*)$")
  if head == "ok" then
    return body
  end
  return nil, head
end

-- ===== answer file =====

local seq = 0

local function peek_dir()
  local dir = require("repl.paths").runtime_dir() .. "/nvim-peek"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Drop answers a dead nvim (or a REPL that replied long after we gave up)
--- left behind. Cheap: the directory holds one file per live peek.
local function sweep(dir)
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  local now = os.time()
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      return
    end
    local path = dir .. "/" .. name
    local stat = uv.fs_stat(path)
    if stat and stat.mtime and (now - stat.mtime.sec) > 600 then
      os.remove(path)
    end
  end
end

local function next_path()
  local dir = peek_dir()
  sweep(dir)
  seq = seq + 1
  return string.format("%s/p%d-%d", dir, vim.fn.getpid(), seq)
end

-- ===== painting =====

local function clear()
  if not painted then
    return
  end
  if painted.win and vim.api.nvim_win_is_valid(painted.win) then
    vim.api.nvim_win_close(painted.win, true)
  end
  if painted.buf and vim.api.nvim_buf_is_valid(painted.buf) then
    vim.api.nvim_buf_clear_namespace(painted.buf, NS, 0, -1)
  end
  vim.api.nvim_clear_autocmds({ group = AUGROUP })
  painted = nil
end

M.clear = clear

local function arm_clear()
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" }, {
    group = AUGROUP,
    once = true,
    callback = clear,
  })
end

local function render_inline(value, anchor)
  local lines = vim.split(value, "\n", { plain = true })
  -- The value alone: the expression is already under the cursor, and repeating
  -- it pushes the part being read off the right of the line.
  local text = lines[1] or ""
  if #lines > 1 then
    text = text .. " ..."
  end
  local limit = setting("inline_chars")
  if #text > limit then
    text = text:sub(1, limit - 1) .. "…"
  end

  painted = { buf = anchor.buf }
  vim.api.nvim_buf_set_extmark(anchor.buf, NS, anchor.row, 0, {
    virt_text = { { "  " .. text, "ReplPeekValue" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
  arm_clear()
end

local function render_popup(value, anchor)
  local lines = vim.split(value, "\n", { plain = true })
  local max_lines = setting("popup_lines")
  if #lines > max_lines then
    lines = vim.list_slice(lines, 1, max_lines)
    lines[#lines + 1] = "..."
  end

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, math.max(20, math.floor(vim.o.columns * 0.6)))
  local height = math.min(#lines, math.max(1, math.floor(vim.o.lines * 0.4)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. anchor.expr .. " ",
    title_pos = "left",
    focusable = false,
    noautocmd = true,
  })
  vim.wo[win].wrap = false

  painted = { win = win }
  arm_clear()
end

local function render(value, anchor)
  clear()
  if M.style() == "popup" then
    render_popup(value, anchor)
  else
    render_inline(value, anchor)
  end
end

-- ===== the peek itself =====

local function stop_pending()
  if not pending then
    return
  end
  if not pending.timer:is_closing() then
    pending.timer:stop()
    pending.timer:close()
  end
  pending = nil
end

local function read_answer(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  os.remove(path)
  return data
end

local function deliver(data, anchor)
  local value, reason = M.parse(data)
  if value == nil then
    -- Silence is the contract: the name is not defined in the REPL yet.
    if vim.g.ub_repl_peek_debug then
      vim.notify("REPL peek: " .. anchor.expr .. " -> " .. tostring(reason), vim.log.levels.INFO)
    end
    return
  end
  if not vim.api.nvim_buf_is_valid(anchor.buf) or vim.api.nvim_get_current_buf() ~= anchor.buf then
    return
  end
  render(value, anchor)
end

--- Poll the answer file. The REPL may be mid-cell, so not answering in time is
--- normal and says nothing; the file is swept later if it lands after that.
local function await(path, anchor)
  local uv = vim.uv or vim.loop
  local poll = setting("poll_ms")
  local ticks_left = math.max(1, math.ceil(setting("timeout_ms") / poll))
  local timer = uv.new_timer()
  pending = { timer = timer, path = path }

  timer:start(poll, poll, function()
    if uv.fs_stat(path) then
      local data = read_answer(path)
      vim.schedule(function()
        stop_pending()
        deliver(data, anchor)
      end)
      return
    end
    ticks_left = ticks_left - 1
    if ticks_left <= 0 then
      vim.schedule(function()
        stop_pending()
        if vim.g.ub_repl_peek_debug then
          vim.notify("REPL peek: no answer for " .. anchor.expr, vim.log.levels.WARN)
        end
      end)
    end
  end)
end

local function expression_under_cursor()
  local how = tostring(setting("expr")):lower()
  local expr = how == "cword" and vim.fn.expand("<cword>") or vim.fn.expand("<cexpr>")
  if expr == nil or expr == "" then
    expr = vim.fn.expand("<cword>")
  end
  return expr
end

--- The fallback route: paste a probe at the prompt and poll the file it
--- writes. Costs one line of the REPL's scrollback, which is why the socket
--- above is tried first.
local function paste_probe(context, expr, anchor)
  local path = next_path()
  context.text = M.probe(context.family, expr, path, setting("max_chars"))
  context.peek_expr = expr
  if require("repl.actions").run("peek_value", context) ~= true then
    return false
  end
  await(path, anchor)
  return true
end

-- ===== in-REPL server (the quiet route) =====

--- The REPL's own socket, or nil. `python/repl_peek_server.py` names it
--- after the kitty window / tmux pane the REPL runs in -- the two things the
--- slime binding already holds -- so no handshake is needed to find it.
---
--- Only the slime route: while a debug session owns the sends the value being
--- asked about is the sidecar frame's, and that is not this kitty REPL's to
--- answer.
local function server_socket(context)
  if setting("server") == false or setting("server") == "0" then
    return nil
  end
  if context.family ~= "python" then
    return nil
  end
  local repl_actions = require("repl.actions")
  if select(1, repl_actions.resolve_backend(context)) ~= "slime" then
    return nil
  end

  local config = vim.b.slime_config
  if type(config) ~= "table" then
    return nil
  end
  local name
  if tonumber(config.window_id or "") then
    name = "k" .. tostring(tonumber(config.window_id))
  elseif type(config.target_pane) == "string" and config.target_pane ~= "" then
    name = "t" .. config.target_pane:gsub("^%%", "")
  end
  if not name then
    return nil
  end

  local path = require("repl.paths").runtime_dir() .. "/nvim-peek/" .. name .. ".sock"
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat or stat.type ~= "socket" then
    return nil
  end
  return path
end

--- Ask the REPL's socket. `on_answer(nil)` means there was nobody home (dead
--- REPL, older REPL started without the server, a peek that outlived its
--- timeout) -- the caller falls back to pasting a probe at the prompt.
local function ask_server(path, expr, on_answer)
  local uv = vim.uv or vim.loop
  local pipe = uv.new_pipe(false)
  local timer = uv.new_timer()
  local chunks = {}
  local done = false

  local function finish(data)
    if done then
      return
    end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if not pipe:is_closing() then
      pipe:close()
    end
    on_answer(data)
  end

  timer:start(setting("timeout_ms"), 0, function()
    finish(nil)
  end)

  pipe:connect(path, function(err)
    if err then
      return finish(nil)
    end
    pipe:write(expr .. "\n")
    pipe:read_start(function(read_err, chunk)
      if read_err then
        return finish(nil)
      end
      if chunk then
        chunks[#chunks + 1] = chunk
        return
      end
      finish(table.concat(chunks))
    end)
  end)
end

--- Peek `opts.expr`, the visual selection (`opts.visual`), or the expression
--- under the cursor.
function M.peek(opts)
  opts = opts or {}
  clear()
  stop_pending()

  local expr = opts.expr
  if expr == nil and opts.visual then
    expr = require("repl.send_context").visual_selection()
  end
  expr = vim.trim(expr or expression_under_cursor() or "")
  if expr == "" then
    return false
  end

  local repl_actions = require("repl.actions")
  local context = repl_actions.current_context()
  if not PROBES[context.family] then
    vim.notify("REPL peek is not available for " .. context.family .. " buffers", vim.log.levels.WARN)
    return false
  end

  local anchor = {
    buf = context.bufnr,
    row = vim.api.nvim_win_get_cursor(0)[1] - 1,
    expr = expr,
  }

  local socket = server_socket(context)
  if socket then
    ask_server(socket, expr, function(data)
      vim.schedule(function()
        if data and data ~= "" then
          deliver(data, anchor)
        else
          paste_probe(context, expr, anchor)
        end
      end)
    end)
    return true
  end

  return paste_probe(context, expr, anchor)
end

function M.peek_visual()
  -- '< / '> still describe the PREVIOUS selection while visual mode is live,
  -- the same reason repl_actions leaves visual mode before every x-mode send.
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return M.peek({ visual = true })
end

M._test = {
  probes = PROBES,
  ask_server = function(path, expr, on_answer)
    return ask_server(path, expr, on_answer)
  end,
  server_socket = function(context)
    return server_socket(context)
  end,
  py_literal = py_literal,
  r_literal = r_literal,
  -- The answer half, so the async + paint path can be gated without a REPL:
  -- the test writes the answer file the REPL would have written.
  await = function(path, anchor)
    return await(path, anchor)
  end,
  pending = function()
    return pending
  end,
  painted = function()
    return painted
  end,
  namespace = NS,
}

return M
