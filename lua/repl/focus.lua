local M = {}

local host_paths = require("repl.config")
local focus_state = require("repl.focus_state")
local kitty_bin = host_paths.kitty_bin()
local slime_focus_target_helper = vim.env.NVIM_SLIME_FOCUS_TARGET_HELPER
  or host_paths.get().focus_target_helper
local uv = vim.uv
local kitty_rpc = require("repl.kitty_rpc")

function M.read_state()
  return focus_state.read_state()
end

function M.read_same_source_target(family)
  return focus_state.read_same_source_target(family)
end

-- Shared with slime.lua through repl.kitty_tree; this used to be a second,
-- uncached copy, so one send_cell paid for `kitty @ ls` twice.
local function kitty_tree(listen_on)
  return (require("repl.kitty_tree").get(listen_on))
end

local function process_text(process)
  if type(process) ~= "table" then
    return tostring(process or "")
  end

  local parts = {}
  for _, key in ipairs({ "cmdline", "argv", "command", "cmd", "exe" }) do
    local value = process[key]
    if type(value) == "table" then
      table.insert(parts, table.concat(value, " "))
    elseif value ~= nil then
      table.insert(parts, tostring(value))
    end
  end
  return table.concat(parts, " ")
end

local function contains_word(text, word)
  return text:match("%f[%w]" .. vim.pesc(word) .. "%f[^%w]") ~= nil
end

local function process_matches_family(process, family)
  local text = process_text(process)
  if family == "python" then
    return text:find("ipython", 1, true) ~= nil
  end
  if family == "r" then
    return contains_word(text, "R") or contains_word(text, "arf") or contains_word(text, "radian")
  end
  if family == "lua" then
    return contains_word(text, "lua") or contains_word(text, "luajit")
  end
  return false
end

local function window_matches_family(window, family)
  local matchers = require("repl.kitty_discovery").window_process_matchers
  local matches_process = matchers[family]
  if matches_process then return matches_process(window) end
  if family == "python" and matchers.sage(window) then return false end
  if process_matches_family(window, family) then
    return true
  end
  for _, process in ipairs(window.foreground_processes or {}) do
    if process_matches_family(process, family) then
      return true
    end
  end
  return false
end

local function find_window_by_id(tree, wanted_window_id)
  wanted_window_id = tonumber(wanted_window_id)
  if not wanted_window_id then
    return nil
  end

  for _, os_window in ipairs(tree or {}) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        if tonumber(window.id) == wanted_window_id then
          return {
            platform_window_id = os_window.platform_window_id,
            window_id = wanted_window_id,
          }
        end
      end
    end
  end
  return nil
end

local function find_family_window(tree, family)
  for _, os_window in ipairs(tree or {}) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        if window.id and window_matches_family(window, family) then
          return {
            platform_window_id = os_window.platform_window_id,
            window_id = tonumber(window.id),
          }
        end
      end
    end
  end
  return nil
end

function M.resolve_target(target)
  target = vim.tbl_extend("force", {}, target or {})
  local listen_on = target.listen_on
  if type(listen_on) ~= "string" or listen_on == "" then
    return nil
  end

  local tree = kitty_tree(listen_on)
  if not tree then
    return nil
  end

  local requested_window_id = tonumber(target.window_id)
  local resolved = find_window_by_id(tree, requested_window_id)
  if not resolved and not requested_window_id then
    resolved = find_family_window(tree, target.family)
  end
  if not resolved then
    return nil
  end

  target.window_id = resolved.window_id
  target.platform_window_id = resolved.platform_window_id
  target.target = target.target or "kitty"
  return target
end

function M.publish_target(target)
  return focus_state.publish_target(target, M.resolve_target)
end

function M.claim_route(target)
  return focus_state.claim_route(target)
end

local function mark_binding_stale(bufnr, detail)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      local context = vim.b[bufnr].ub_repl_context
      if type(context) == "table" and type(context.binding) == "table" then
        context.binding.status = "stale"
        vim.b[bufnr].ub_repl_context = context
      end
    end
    if detail and detail ~= "" then
      vim.notify("REPL focus failed: " .. detail .. "; use the explicit bind command", vim.log.levels.WARN)
    end
  end)
end

local function focus_kitty_child(binding, callback)
  kitty_rpc.send_async(binding.listen_on, "focus-window", { match = "id:" .. tostring(binding.window_id) },
    function(_, err) callback(err) end)
end

--- Front the OS window holding the bound REPL.
---
--- On X11 the preferred command is the compiled helper's `--raise`, which sends
--- the window manager an _NET_ACTIVE_WINDOW message in-process and waits at
--- 0.5ms granularity. `xdotool windowactivate --sync` reaches the same end
--- state but waits in 30ms sleeps, so it bills a full 30ms even when the raise
--- completed in one, and misses several ticks on a real cross-window switch.
--- Measured on Sinclair: ~52ms through the helper against ~115ms through
--- xdotool for the same switch. xdotool stays as the fallback for a host that
--- never built the helper.
local function activate_os_window(binding, callback)
  local sysname = uv.os_uname().sysname
  local command
  if sysname == "Darwin" then
    command = { "osascript", "-e", 'tell application "kitty" to activate' }
  else
    local focus_back = host_paths.focus_back_bin()
    if focus_back then
      command = { focus_back, "--raise", tostring(binding.platform_window_id) }
    else
      command = { "xdotool", "windowactivate", "--sync", tostring(binding.platform_window_id) }
    end
  end
  if vim.fn.executable(command[1]) ~= 1 then
    callback(command[1] .. " is not executable")
    return
  end
  local ok, error_message = pcall(vim.system, command, { text = true }, function(result)
    if result.code == 0 then
      callback(nil)
    else
      callback(vim.trim(result.stderr or ("exit " .. tostring(result.code))))
    end
  end)
  if not ok then
    callback(tostring(error_message))
  end
end

--- Focus only the binding already published for the current buffer.
--- No path resolution, target discovery, launch, transcript read, or state-file
--- read is permitted here: this function is the latency-sensitive <M-h> path.
function M.focus_ready_target()
  local bufnr = vim.api.nvim_get_current_buf()
  local context = vim.b[bufnr].ub_repl_context
  local binding = type(context) == "table" and context.binding or nil
  local spec = type(context) == "table" and context.repl_spec or nil
  if type(binding) ~= "table"
    or type(spec) ~= "table"
    or spec.backend ~= "slime"
    or binding.status ~= "ready"
    or binding.fingerprint ~= spec.fingerprint
    or not binding.listen_on
    or not binding.window_id
    or not binding.platform_window_id
  then
    return false
  end

  local function fail(detail)
    if detail then
      mark_binding_stale(bufnr, detail)
    end
  end

  local function finish(final_error)
    if final_error then
      fail(final_error)
      return
    end
    vim.schedule(function()
      M.claim_route({
        backend = "slime",
        family = spec.family,
        listen_on = binding.listen_on,
        platform_window_id = binding.platform_window_id,
        window_id = binding.window_id,
      })
    end)
  end

  if uv.os_uname().sysname == "Darwin" then
    -- Kitty can own several OS windows. Select the child before application
    -- activation, then reassert it after macOS raises kitty.
    focus_kitty_child(binding, function(first_error)
      if first_error then
        fail(first_error)
        return
      end
      activate_os_window(binding, function(activation_error)
        if activation_error then
          fail(activation_error)
          return
        end
        focus_kitty_child(binding, finish)
      end)
    end)
  else
    -- X11 can raise the exact stored OS-window id. One child selection after
    -- the raise is sufficient; Oracle verifies both the OS window and latency.
    activate_os_window(binding, function(activation_error)
      if activation_error then
        fail(activation_error)
        return
      end
      focus_kitty_child(binding, finish)
    end)
  end
  return true
end

local function register_pair(target)
  target = M.resolve_target(target) or target or {}
  local family = target.family
  local target_kind = target.target
  local listen_on = target.listen_on
  local window_id = tonumber(target.window_id or "")
  if target_kind ~= "kitty" or not family or not listen_on or listen_on == "" or not window_id then
    return false
  end
  if vim.fn.executable(slime_focus_target_helper) ~= 1 then
    return false
  end

  local entry = {
    family = family,
    source = {
      listen_on = vim.env.KITTY_LISTEN_ON,
      window_id = tonumber(vim.env.KITTY_WINDOW_ID),
      platform_window_id = tonumber(vim.env.WINDOWID),
    },
    target = {
      family = family,
      listen_on = listen_on,
      window_id = window_id,
      platform_window_id = target.platform_window_id,
    },
  }
  local output = vim.fn.system({ slime_focus_target_helper, "--register" }, vim.json.encode(entry))
  if vim.v.shell_error == 0 then
    return true
  end

  local detail = vim.trim(output or "")
  vim.notify("Could not register slime source focus pair: " .. (detail ~= "" and detail or ("exit " .. tostring(vim.v.shell_error))), vim.log.levels.WARN)
  return false
end

function M.emit_changed(target)
  target = target or {}
  local resolved = M.resolve_target(target) or target
  register_pair(resolved)
  M.claim_route(resolved)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ReplChanged",
    modeline = false,
    data = target,
  })
end

function M.publish_and_emit(target)
  M.publish_target(target)
  M.emit_changed(target)
end

function M.publish_backend_target(target)
  local resolved = M.resolve_target(target)
  if not resolved then
    return false
  end
  M.publish_and_emit(resolved)
  return true
end

return M
