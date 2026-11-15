local M = {}

local repl_registry = require("repl.registry")
local repl_specs = require("repl.specs")

local family_defaults = {
  python = "slime",
  r = "slime",
  lua = "slime",
  other = "slime",
}

local family_backends = {
  python = {
    iron = true,
    slime = true,
    neopyter = true,
  },
  r = {
    r_nvim = true,
    slime = true,
    neopyter = true,
  },
  lua = {
    slime = true,
  },
  other = {
    iron = true,
    slime = true,
  },
}

local function normalize_backend(value)
  if type(value) ~= "string" then
    return nil
  end

  local normalized = value:lower()
  if normalized == "iron" or normalized == "slime" or normalized == "r_nvim" or normalized == "neopyter" then
    return normalized
  end

  return nil
end

local function normalize_bool(value)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) ~= "string" then
    return nil
  end

  local normalized = value:lower()
  if normalized == "1" or normalized == "true" or normalized == "on" or normalized == "yes" then
    return true
  end
  if normalized == "0" or normalized == "false" or normalized == "off" or normalized == "no" then
    return false
  end

  return nil
end

local function in_tmux()
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

function M.family_for_filetype(filetype)
  return repl_registry.family_for_filetype(filetype)
end

local function current_filetype()
  return vim.bo.filetype or ""
end

local function current_family()
  return M.family_for_filetype(current_filetype())
end

local function sync_python_focus_publish()
  if current_family() ~= "python" then
    return
  end
  if type(_G.ub_slime_publish_focus_target) == "function" then
    _G.ub_slime_publish_focus_target()
    return
  end
  require("repl.focus").publish_target({
    backend = M.current(),
    family = "python",
  })
end

local function family_backend_var(family)
  return "ub_repl_backend_" .. family
end

local function family_backend_env(family)
  return "NVIM_REPL_BACKEND_" .. string.upper(family)
end

local function backend_allowed_for_family(backend, family)
  return backend ~= nil and family_backends[family] ~= nil and family_backends[family][backend] == true
end

local function backend_for_family(family, filetype)
  local override = normalize_backend(vim.g[family_backend_var(family)])
    or normalize_backend(vim.env[family_backend_env(family)])

  if family == "python" then
    override = override
      or normalize_backend(vim.g.ub_repl_backend)
      or normalize_backend(vim.env.NVIM_REPL_BACKEND)
  end

  if backend_allowed_for_family(override, family) then
    return override
  end

  local normalized_filetype = type(filetype) == "string" and filetype:lower() or nil
  local registry_backend = normalized_filetype and repl_registry.backend_for_filetype(normalized_filetype)
    or repl_registry.default_backend_for_family(family)
  if backend_allowed_for_family(registry_backend, family) then
    return registry_backend
  end

  return family_defaults[family] or family_defaults.other
end

local function configure_slime_env(family)
  local spec = repl_specs.slime_kitty_spec(family)
  vim.env.NVIM_SLIME_TARGET = vim.env.NVIM_SLIME_TARGET or "kitty"
  vim.env.NVIM_SLIME_KITTY_LISTEN_ON = spec.listen_on
  vim.env.NVIM_SLIME_KITTY_TITLE = spec.title
end

function M.registry_default_backend(family)
  local registry_default = require("repl.registry").default_backend_for_family(family)
  if registry_default then
    return registry_default
  end
  return family_defaults[family] or family_defaults.other
end

function M.current()
  local filetype = current_filetype()
  local family = M.family_for_filetype(filetype)
  local backend = backend_for_family(family, filetype)

  if backend == "slime" then
    configure_slime_env(family)
  end

  vim.g.ub_repl_backend_resolved = backend
  vim.g["ub_repl_backend_resolved_" .. family] = backend
  return backend
end

function M.tmux_enabled()
  local override = normalize_bool(vim.g.ub_repl_tmux)
  if override == nil then
    override = normalize_bool(vim.env.NVIM_REPL_TMUX)
  end
  local enabled = override
  if enabled == nil then
    enabled = in_tmux()
  end

  vim.g.ub_repl_tmux_resolved = enabled
  return enabled
end

function M.set_current(backend, family)
  local normalized = normalize_backend(backend)
  if not normalized then
    return false
  end

  family = family or current_family()
  if not backend_allowed_for_family(normalized, family) then
    return false
  end

  vim.g[family_backend_var(family)] = normalized
  vim.g["ub_repl_backend_resolved_" .. family] = normalized
  vim.env[family_backend_env(family)] = normalized
  if family == "python" then
    vim.g.ub_repl_backend = normalized
    vim.g.ub_repl_backend_resolved = normalized
    vim.env.NVIM_REPL_BACKEND = normalized
  end
  return true
end

function M.set_tmux_enabled(enabled)
  local normalized = normalize_bool(enabled)
  if normalized == nil then
    return false
  end

  vim.g.ub_repl_tmux = normalized
  vim.g.ub_repl_tmux_resolved = normalized
  vim.env.NVIM_REPL_TMUX = normalized and "1" or "0"
  return true
end

local function lazy_plugin_loaded(name)
  local ok_config, config = pcall(require, "lazy.core.config")
  if not ok_config then
    return false
  end

  local plugin = config.plugins[name]
  return plugin ~= nil and plugin._ ~= nil and plugin._.loaded ~= nil
end

local function load_lazy_plugin(name)
  local ok_lazy, lazy = pcall(require, "lazy")
  if not ok_lazy then
    vim.notify("Could not switch REPL backend: lazy.nvim is not loaded", vim.log.levels.ERROR)
    return false, false
  end

  local was_loaded = lazy_plugin_loaded(name)
  local ok_load, err = pcall(lazy.load, { plugins = { name } })
  if not ok_load then
    vim.notify("Could not load " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
    return false, was_loaded
  end

  return true, was_loaded
end

local function sync_slime_editor_title()
  local callback = require("repl.config").get().callbacks.sync_editor_title
  if type(callback) == "function" then callback() end
end

local function ensure_slime_runtime()
  local slime = require("repl.slime")
  slime.init()
  local installed = #vim.api.nvim_get_runtime_file("autoload/slime.vim", false) > 0
  if not installed then
    local ok_load = load_lazy_plugin("vim-slime")
    if not ok_load then return false end
  end
  local ok, err = pcall(slime.setup)
  if not ok then
    vim.notify("Could not configure REPL Slime integration: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return type(_G.ub_slime_use_repl_target) == "function"
end

function M.ensure_iron_runtime()
  local family = current_family()
  if family == "r" then
    return false
  end

  local ok_load = load_lazy_plugin("iron.nvim")
  if not ok_load then
    return false
  end

  local callback = require("repl.config").get().callbacks.ensure_iron
  return type(callback) == "function" and callback() == true and pcall(require, "iron.core")
end

function M.ensure_backend_ready(backend)
  -- R-SEND-03: the "dap" backend sends over the debug sidecar socket, so it
  -- needs no REPL plugin at all -- registering it IS its readiness, and in
  -- particular it must not drag vim-slime in.
  if backend == "dap" then
    local callback = require("repl.config").get().callbacks.ensure_dap
    if type(callback) == "function" then return callback() == true end
    local ok, sidecar = pcall(require, "repl.dap_sidecar_backend")
    return ok and sidecar.ensure() == true
  end
  if backend == "iron" then
    return M.ensure_iron_runtime()
  end
  if backend == "slime" then
    return ensure_slime_runtime()
  end
  if backend == "r_nvim" then
    local ok_load = load_lazy_plugin("R.nvim")
    return ok_load and pcall(require, "r")
  end
  if backend == "neopyter" then
    return pcall(require, "neopyter")
  end
  return false
end

function M.use_iron()
  local family = current_family()
  if family == "r" then
    vim.notify("Iron is not available for R buffers", vim.log.levels.WARN)
    return false
  end

  if not M.ensure_iron_runtime() then
    vim.notify("Could not switch REPL backend: iron.nvim is unavailable", vim.log.levels.ERROR)
    return false
  end

  M.set_current("iron", family)
  vim.env.NVIM_SLIME_TARGET = nil
  vim.env.NVIM_SLIME_KITTY_LISTEN_ON = nil
  vim.env.NVIM_SLIME_KITTY_TITLE = nil
  vim.env.NVIM_SLIME_KITTY_WINDOW_ID = nil
  require("repl.actions").setup_keymaps()
  sync_slime_editor_title()
  sync_python_focus_publish()

  vim.notify("REPL backend switched to iron", vim.log.levels.INFO)
  return true
end

function M.use_slime()
  local family = current_family()
  M.set_current("slime", family)
  configure_slime_env(family)
  vim.env.NVIM_SLIME_KITTY_WINDOW_ID = nil

  if not ensure_slime_runtime() then return false end

  require("repl.actions").setup_keymaps()
  sync_slime_editor_title()
  sync_python_focus_publish()
  vim.notify("REPL backend switched to slime", vim.log.levels.INFO)
  return true
end

function M.use_r_nvim()
  if current_family() ~= "r" then
    vim.notify("R.nvim is only available for R buffers", vim.log.levels.WARN)
    return false
  end

  local ok_load = load_lazy_plugin("R.nvim")
  if not ok_load then
    return false
  end

  if not pcall(require, "r") then
    vim.notify("Could not switch REPL backend: R.nvim is unavailable", vim.log.levels.ERROR)
    return false
  end

  M.set_current("r_nvim", "r")
  require("repl.actions").setup_keymaps()
  sync_slime_editor_title()
  vim.notify("REPL backend switched to R.nvim", vim.log.levels.INFO)
  return true
end

function M.select_slime_target()
  if not M.use_slime() then
    return false
  end

  if type(_G.ub_slime_select_repl_target) ~= "function" then
    vim.notify("Could not open Slime target selector", vim.log.levels.WARN)
    return false
  end

  _G.ub_slime_select_repl_target()
  return true
end

function M.use_slime_target()
  if not ensure_slime_runtime() then
    vim.notify("Could not open Slime target", vim.log.levels.WARN)
    return false
  end

  _G.ub_slime_use_repl_target()
  return true
end

--- Discover+bind an existing env-matching kitty REPL. No launch / no start_command.
--- Success = bind state readable after call (do not trust return alone from callers that mutate).
function M.discover_slime_target()
  if not ensure_slime_runtime() then
    return false
  end
  if type(_G.ub_slime_discover_repl_target) ~= "function" then
    return false
  end
  return _G.ub_slime_discover_repl_target() == true
end

function M.toggle()
  local family = current_family()
  local backend = M.current()

  if family == "r" then
    if backend == "r_nvim" then
      return M.use_slime()
    end
    return M.use_r_nvim()
  end

  if backend == "iron" then
    return M.use_slime()
  end

  return M.use_iron()
end

function M.setup_keymaps()
  if M._keymaps_installed then return end
  M._keymaps_installed = true
  require("repl.actions").setup_keymaps()

  vim.keymap.set("n", "<leader>ii", M.toggle, {
    silent = true,
    desc = "REPL toggle backend (Slime/Iron or Slime/R.nvim)",
  })
  vim.keymap.set("n", "<leader>it", M.select_slime_target, {
    silent = true,
    desc = "REPL select Slime kitty target",
  })
  -- Admin key, not a send key: it picks how `<M-k>` SHOWS a value, so it is
  -- backend-independent and lives with the other <leader>i… admin controls.
  vim.keymap.set("n", "<leader>ip", function()
    require("repl.peek").toggle_style()
  end, {
    silent = true,
    desc = "REPL peek style (inline/popup)",
  })
  vim.api.nvim_create_user_command("ReplPeekStyle", function(args)
    require("repl.peek").set_style(args.args)
  end, {
    nargs = "?",
    complete = function()
      return { "inline", "popup", "toggle" }
    end,
    desc = "Set the REPL peek style (inline/popup/toggle)",
  })
  vim.keymap.set("n", "<leader>in", function()
    if vim.bo.filetype ~= "python" then
      return
    end
    if type(_G.ub_slime_launch_new_repl) == "function" then
      _G.ub_slime_launch_new_repl()
      return
    end
    vim.notify("Slime new REPL unavailable (plugin not loaded)", vim.log.levels.WARN)
  end, {
    silent = true,
    desc = "REPL launch new Slime kitty window (python only)",
  })
  -- Neopyter <leader>ij / ic / ie are buffer-local (REPL_ROUTING.md matrix);
  -- installed by the host Neopyter integration on BufEnter.

  vim.keymap.set("n", "<leader>rp", M.use_slime_target, {
    silent = true,
    desc = "Use configured Slime REPL target",
  })
end

return M
