local M = {}

local repl_paths = require("repl.paths")
local uv = vim.uv or vim.loop

local function focus_state_path()
  return repl_paths.state_file()
end

local function source_key(family)
  local listen_on = vim.env.KITTY_LISTEN_ON
  if type(listen_on) ~= "string" or listen_on == "" then
    return nil
  end
  local window_id = tonumber(vim.env.KITTY_WINDOW_ID or "") or 0
  local platform_window_id = tonumber(vim.env.WINDOWID or "") or 0
  return table.concat({ family or "", listen_on, tostring(window_id), tostring(platform_window_id) }, "::")
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  if not lines or not lines[1] or lines[1] == "" then
    return nil
  end
  local ok, decoded = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  return ok and type(decoded) == "table" and decoded or nil
end

local function atomic_write_json(path, value)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok_write = pcall(vim.fn.writefile, { vim.fn.json_encode(value) }, temporary)
  if not ok_write then
    return false
  end
  local ok_rename, renamed = pcall(uv.fs_rename, temporary, path)
  if not ok_rename or not renamed then
    pcall(os.remove, temporary)
    return false
  end
  return true
end

local function editor_source()
  local listen_on = vim.env.KITTY_LISTEN_ON
  local platform_window_id = tonumber(vim.env.WINDOWID or "")
  local window_id = tonumber(vim.env.KITTY_WINDOW_ID or "")
  if type(listen_on) ~= "string" or listen_on == "" or not platform_window_id or not window_id then
    return nil
  end
  return {
    listen_on = listen_on,
    platform_window_id = platform_window_id,
    window_id = window_id,
  }
end

local function route_path(target)
  local platform_window_id = tonumber(target.platform_window_id or "")
  local window_id = tonumber(target.window_id or "")
  if not platform_window_id or not window_id then
    return nil
  end
  return string.format("%s.routes/%d.%d.json", focus_state_path(), platform_window_id, window_id)
end

--- True when this Neovim is the kitty-scrollback pager rather than an editor.
--- Guarded at both durable-state chokepoints: slime and r-nvim publish, and
--- binds, sends, and successful focus actions claim routes, so per-caller
--- checks would miss a path. A pager must stamp neither focus state nor route;
--- doing so repoints M-h / dl-repl at whatever family the scrollback buffer
--- happens to have.
---
--- The marker is the env var the kitty_scrollback_nvim kitten exports into the
--- pager it launches, never the control socket's name. The socket name is a
--- per-host kitty.conf setting, not a pager property: Sinclair's kitty.conf sets
--- `listen_on unix:/run/user/1000/kitty-scrollback.sock` for EVERY kitty window,
--- so a name test classified every editor on that host as a pager and silently
--- disabled focus publishing there -- M-h / dl-repl never saw a target, and the
--- python-buffer gate read a backend-less state and fail-opened under iron.
--- (On this Mac the same test was inert: kitty.conf uses kitty-focus.sock, so it
--- never fired, which is why only the live Sinclair oracle caught it.)
local function is_scrollback_pager()
  local marker = vim.env.KITTY_SCROLLBACK_NVIM
  return type(marker) == "string" and marker ~= "" and marker ~= "0"
end

function M.claim_route(target)
  if is_scrollback_pager() then
    return false
  end
  local path = route_path(target)
  local source = editor_source()
  if target.backend ~= "slime" or not path or not source then
    return false
  end
  return atomic_write_json(path, {
    family = target.family,
    nvim_pid = vim.fn.getpid(),
    schema_version = 1,
    source = source,
    updated_at = os.time(),
  })
end

--- The way back from a raised JupyterLab browser window.
---
--- Same registry, same `source` shape, and therefore the same reader
--- (`bin/kitty_focus_slime_source.py` hands both kinds to one `focus_entry`):
--- reverse routes keep ONE writer, which is this module. Only the key differs,
--- because a browser window is an X11 window with no kitty child behind it --
--- `lab.<x11-window-id>.json` beside the kitty `<platform>.<child>.json`.
---
--- Written only by a `<M-h>` raise that succeeded; `cleanup_routes` sweeps it
--- with the rest when this editor exits.
---@param lab_window_id string|number  the raised browser window's X11 id
---@return boolean claimed
function M.claim_lab_route(lab_window_id)
  if is_scrollback_pager() then
    return false
  end
  local window_id = tonumber(lab_window_id or "")
  local source = editor_source()
  if not window_id or not source then
    return false
  end
  return atomic_write_json(string.format("%s.routes/lab.%d.json", focus_state_path(), window_id), {
    backend = "neopyter",
    nvim_pid = vim.fn.getpid(),
    schema_version = 1,
    source = source,
    updated_at = os.time(),
  })
end

local function cleanup_routes()
  local source = editor_source()
  if not source then
    return
  end
  for _, path in ipairs(vim.fn.glob(focus_state_path() .. ".routes/*.json", false, true)) do
    local route = read_json(path)
    local candidate = route and route.source or nil
    if type(candidate) == "table"
      and tonumber(route.nvim_pid or "") == vim.fn.getpid()
      and candidate.listen_on == source.listen_on
      and tonumber(candidate.platform_window_id or "") == source.platform_window_id
      and tonumber(candidate.window_id or "") == source.window_id
    then
      pcall(os.remove, path)
    end
  end
end

function M.read_state()
  return read_json(focus_state_path()) or {}
end

function M.read_same_source_target(family)
  local state = M.read_state()
  local source_targets = state._source_targets
  local key = source_key(family)
  if type(source_targets) ~= "table" or not key then
    return nil
  end

  local entry = source_targets[key]
  local window_id = type(entry) == "table" and tonumber(entry.window_id or "") or nil
  if type(entry) ~= "table" or entry.family ~= family or not entry.listen_on or not window_id then
    return nil
  end

  return {
    family = family,
    listen_on = entry.listen_on,
    window_id = window_id,
  }
end

function M.publish_target(target, resolve_target)
  if is_scrollback_pager() then
    return
  end
  local requested_target = target or {}
  target = resolve_target(requested_target) or requested_target
  local family = target.family
  local listen_on = target.listen_on
  local window_id = tonumber(target.window_id or "")
  local backend = target.backend
  local state_path = focus_state_path()

  vim.fn.mkdir(vim.fn.fnamemodify(state_path, ":h"), "p")
  local existing = M.read_state()
  local resolved_env
  local spec = {}
  local ok_env, repl_env = pcall(require, "repl.python_env")
  if ok_env and family ~= "octave" and family ~= "sage" then
    resolved_env = repl_env.resolve_for_buffer(0)
  end
  local ok_specs, repl_specs = pcall(require, "repl.specs")
  if ok_specs and family then
    spec = repl_specs.slime_kitty_spec(family)
  end
  local repl_spec = {
    backend = backend,
    env_name = resolved_env and resolved_env.env_name or nil,
    env_prefix = resolved_env and resolved_env.prefix or nil,
    executable = resolved_env and resolved_env.ipython or nil,
    family = family,
    launcher = spec.launcher,
    namespace = repl_paths.namespace() or "",
    socket = spec.listen_on,
    start_command = spec.start_command,
    title_base = spec.title,
    window_class = spec.window_class,
  }
  repl_spec.fingerprint = vim.fn.sha256(vim.json.encode({
    repl_spec.family,
    repl_spec.backend,
    repl_spec.namespace,
    repl_spec.env_name,
    repl_spec.socket,
    repl_spec.title_base,
  }))
  local ready = backend == "slime"
    and type(listen_on) == "string"
    and listen_on ~= ""
    and window_id ~= nil
    and target.platform_window_id ~= nil
  local previous_binding = type(existing.binding) == "table" and existing.binding or {}
  local binding = {
    bound_at = ready and (previous_binding.fingerprint == repl_spec.fingerprint and previous_binding.bound_at or os.time()) or nil,
    fingerprint = ready and repl_spec.fingerprint or nil,
    listen_on = ready and listen_on or nil,
    platform_window_id = ready and target.platform_window_id or nil,
    status = ready and "ready" or "unbound",
    window_id = ready and window_id or nil,
  }
  local source = {
    nvim_server = vim.v.servername,
    buffer_id = vim.api.nvim_get_current_buf(),
    filetype = vim.bo.filetype,
    kitty_listen_on = vim.env.KITTY_LISTEN_ON,
    kitty_window_id = tonumber(vim.env.KITTY_WINDOW_ID or ""),
    nvim_pid = vim.fn.getpid(),
    path = vim.api.nvim_buf_get_name(0),
    platform_window_id = tonumber(vim.env.WINDOWID or ""),
    project_root = resolved_env and resolved_env.root or nil,
  }
  local state = vim.tbl_extend("force", existing, {
    binding = binding,
    family = family,
    -- Published so the Mac focus helpers can recover the session namespace
    -- without asking System Events for the frontmost window's AXTitle, which
    -- needs a GUI plus an Accessibility grant and returns "" headlessly (a
    -- named session would then silently retarget the default REPL).
    namespace = repl_paths.namespace() or "",
    sender_listen_on = vim.env.KITTY_LISTEN_ON,
    sender_platform_window_id = tonumber(vim.env.WINDOWID or ""),
    sender_window_id = tonumber(vim.env.KITTY_WINDOW_ID or ""),
    publisher = "nvim",
    nvim_pid = vim.fn.getpid(),
    generation = tonumber(existing.generation or 0) + 1,
    repl_spec = repl_spec,
    schema_version = 2,
    source = source,
    updated_at = os.time(),
  })

  state._source_targets = type(existing._source_targets) == "table" and existing._source_targets or {}
  if family and listen_on and listen_on ~= "" and window_id then
    state.backend = backend
    state.target = "kitty"
    state.listen_on = listen_on
    state.platform_window_id = target.platform_window_id
    state.window_id = window_id
    local key = source_key(family)
    if key then
      state._source_targets[key] = {
        backend = backend,
        family = family,
        listen_on = listen_on,
        platform_window_id = target.platform_window_id,
        updated_at = state.updated_at,
        window_id = window_id,
      }
    end
  else
    state.backend = backend
    if backend == "iron" then
      state.target = nil
      state.listen_on = nil
      state.platform_window_id = nil
      state.window_id = nil
    elseif backend == "slime" then
      -- Backend-only publish: preserve a bound kitty target (iron -> slime toggle).
      if not (listen_on and listen_on ~= "" and window_id) then
        if existing.target then
          state.target = existing.target
        end
        if existing.listen_on then
          state.listen_on = existing.listen_on
        end
        if existing.window_id then
          state.window_id = existing.window_id
        end
        if existing.platform_window_id then
          state.platform_window_id = existing.platform_window_id
        end
      end
    else
      state.target = nil
      state.listen_on = nil
      state.platform_window_id = nil
      state.window_id = nil
    end
  end

  vim.b.ub_repl_context = {
    binding = binding,
    generation = state.generation,
    repl_spec = repl_spec,
    schema_version = state.schema_version,
    source = source,
    updated_at = state.updated_at,
  }

  atomic_write_json(state_path, state)
end

local focus_group = vim.api.nvim_create_augroup("ub_repl_focus_state", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = focus_group,
  callback = cleanup_routes,
})

return M
