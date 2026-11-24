local M = {}

function M.lab_buffer(path, bufnr)
  if type(path) ~= "string" then
    return false
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if path:match("%.py$") then
    return vim.api.nvim_buf_is_valid(bufnr)
      and vim.b[bufnr].neopyter_explicit_percent_py == true
  end
  return path:match("%.ipynb$") ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr].neopyter_managed_ipynb == true
end

local lab_buffer = M.lab_buffer

function M.neopyter_connected()
  local ok, jupyter = pcall(require, "neopyter.jupyter")
  if not ok or not jupyter.jupyterlab then
    return false
  end
  return jupyter.jupyterlab:is_connecting()
end

--- True only if neopyter is connected AND this buffer has a synced notebook,
--- so unrelated .py buffers don't get their cells routed to JupyterLab.
function M.neopyter_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.lab_buffer(vim.api.nvim_buf_get_name(bufnr), bufnr) then
    return false
  end
  if not M.neopyter_connected() then
    return false
  end
  local ok, jupyter = pcall(require, "neopyter.jupyter")
  if not ok or not jupyter.jupyterlab then
    return false
  end
  return jupyter.jupyterlab:get_notebook(bufnr) ~= nil
end

function M.iron_connected(filetype)
  local ok_ll, ll = pcall(require, "iron.lowlevel")
  if not ok_ll then
    return false
  end
  local meta = ll.get(filetype or vim.bo.filetype)
  return meta ~= nil and ll.repl_exists(meta)
end

function M.slime_connected()
  if vim.g.slime_target == "kitty" then
    local cfg = vim.b.slime_config or vim.g.slime_default_config
    if type(cfg) == "table" then
      if cfg.listen_on and cfg.listen_on ~= "" then
        return true
      end
      if cfg.window_id and tonumber(cfg.window_id) and tonumber(cfg.window_id) > 0 then
        return true
      end
    end
    return false
  end

  local target = vim.g.slime_tmux_repl_target or vim.env.NVIM_SLIME_TMUX_REPL_TARGET
  return type(target) == "string" and target ~= ""
end

function M.r_nvim_connected()
  return (tonumber(vim.g.R_Nvim_status or 0) or 0) >= 7
end

function M.is_connected(backend, context)
  context = context or {}
  local filetype = context.filetype or vim.bo.filetype or ""

  if backend == "neopyter" then
    return lab_buffer(context.path, context.bufnr) and M.neopyter_buffer(context.bufnr)
  end
  if backend == "iron" then
    return M.iron_connected(filetype)
  end
  if backend == "slime" then
    return M.slime_connected()
  end
  if backend == "r_nvim" then
    return M.r_nvim_connected()
  end

  return false
end

local function fallback_order(family)
  if family == "r" then
    return { "r_nvim", "slime" }
  end
  if family == "python" or family == "lua" or family == "other" then
    return { "iron", "slime", "neopyter" }
  end
  return { "slime" }
end

--- Managed `.ipynb` only (not plain `.py`). Never fall through to slime/iron.
local function managed_ipynb_buffer(path, bufnr)
  bufnr = bufnr or 0
  return type(path) == "string"
    and path:match("%.ipynb$") ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr].neopyter_managed_ipynb == true
end

--- R-SEND-03, shared source-send contract: is the debug sidecar the
--- REPL for this buffer right now?
---
--- In production the DAP session and the `[dap-ipython]` console live in a
--- SEPARATE sidecar nvim, so nothing the editor can ask about its OWN dap state
--- answers this; `sidecar.session_live()` is the predicate `<M-h>` already uses
--- for the same question. Binding granularity is one editor nvim <-> its sidecar
--- (the socket path derives from v:servername), which is exactly the granularity
--- slime uses for its kitty REPL: per-nvim, per-family. `package.loaded` rather
--- than `require` so no debug module is pulled in when nobody is debugging.
function M.dap_sidecar_live()
  local sidecar = package.loaded["dap-sidecar.host.sidecar"]
  if type(sidecar) ~= "table" or type(sidecar.session_live) ~= "function" then
    return false
  end
  local ok, live = pcall(sidecar.session_live)
  return ok and live == true
end

--- The live session's adapter type, or nil when there is none or it is not yet
--- known. Same `package.loaded` rule as above, so asking costs nothing when
--- nobody is debugging.
---@return string|nil
function M.dap_sidecar_adapter()
  local sidecar = package.loaded["dap-sidecar.host.sidecar"]
  if type(sidecar) ~= "table" or type(sidecar.session_adapter_type) ~= "function" then
    return nil
  end
  local ok, kind = pcall(sidecar.session_adapter_type)
  if not ok or type(kind) ~= "string" or kind == "" then
    return nil
  end
  return kind
end

--- Which families a live sidecar may take a send from, and on what terms.
---
--- EVERY family here names the adapter it needs, and the symmetry is the point:
--- the sidecar has two consoles and `sidecar_repl.select` picks between them
--- from the SESSION, never from the filetype that was sent. Its `auto` branch
--- answers `ipython` for a live Python session and `lua` for a live Lua one,
--- both before reading `args.filetype`. So a buffer handed to the wrong session
--- does not get refused -- it gets EXECUTED in the wrong language. Lua code
--- evaluated as Python, or Python evaluated as Lua.
---
--- The adapter strings are `sidecar_repl`'s own (`is_python` accepts `python`
--- and `debugpy`; `is_lua` is `nlua`), so the two modules cannot disagree about
--- what a language is.
---
--- An UNKNOWN adapter refuses for both. Between a launch being accepted and its
--- `event_initialized`, and on a reused sidecar whose previous run was another
--- language, there is no sound answer -- and the cost of guessing is running
--- code in the wrong interpreter, while the cost of refusing is the ordinary
--- REPL the operator already had.
---
--- `r` is absent: the sidecar has no R console, so an R buffer is never taken
--- from R.nvim or Slime.
local SIDECAR_FAMILY_ADAPTERS = {
  python = { python = true, debugpy = true },
  lua = { nlua = true },
}

--- May a live sidecar take this buffer's sends? Only when it is running the
--- language this buffer is written in.
---@param family string|nil
---@return boolean
function M.dap_sidecar_owns(family)
  local accepts = SIDECAR_FAMILY_ADAPTERS[family]
  if not accepts then
    return false
  end
  if not M.dap_sidecar_live() then
    return false
  end
  local kind = M.dap_sidecar_adapter()
  return kind ~= nil and accepts[kind] == true
end

---@param context table|nil
---@return string backend
---@return string reason configured|connected|lab|lab_pending|sidecar
function M.resolve(context)
  local repl_backend = require("repl")
  context = context or {}
  local bufnr = context.bufnr or 0
  local path = context.path or vim.api.nvim_buf_get_name(bufnr)
  local family = context.family
    or repl_backend.family_for_filetype(context.filetype or vim.bo.filetype or "")

  -- Managed notebooks and explicitly attached percent files belong only to
  -- their Jupyter kernel, even while a matching debug sidecar is live.
  if managed_ipynb_buffer(path, bufnr) then
    if M.neopyter_buffer(bufnr) then return "neopyter", "lab" end
    return "neopyter", "lab_pending"
  end
  if lab_buffer(path, bufnr) and M.neopyter_buffer(bufnr) then
    return "neopyter", "lab"
  end

  if context.dap_route ~= false and M.dap_sidecar_owns(family) then
    return "dap", "sidecar"
  end

  local preferred = context.backend or repl_backend.current()
  local resolve_context = vim.tbl_extend("force", context, { family = family, path = path })

  if M.is_connected(preferred, resolve_context) then
    return preferred, "connected"
  end

  local registry_default = repl_backend.registry_default_backend(family)
  if preferred ~= registry_default then
    return preferred, "configured"
  end

  local seen = {}
  local candidates = {}

  local function add(name)
    if name and not seen[name] then
      seen[name] = true
      candidates[#candidates + 1] = name
    end
  end

  for _, name in ipairs(fallback_order(family)) do
    add(name)
  end

  for _, backend in ipairs(candidates) do
    if backend ~= preferred and M.is_connected(backend, resolve_context) then
      return backend, "connected"
    end
  end

  return preferred, "configured"
end

--- Restart must follow the configured provider, not a stale kitty bind.
---
--- R-SEND-03: nor a live debug sidecar. "Restart the REPL" means the kitty
--- process the operator owns; the sidecar console is restarted by the debug
--- session, not by <M-R>. `dap_route = false` is what keeps M.resolve's sidecar
--- rule out of every path this function falls through to (R2').
---@param context table|nil
---@return string backend
---@return string reason
function M.resolve_restart(context)
  local repl_backend = require("repl")
  context = vim.tbl_extend("force", context or {}, { dap_route = false })
  local bufnr = context.bufnr or vim.api.nvim_get_current_buf()
  local filetype = context.filetype or vim.bo.filetype or ""
  local configured = context.backend or repl_backend.current()
  local family = context.family or repl_backend.family_for_filetype(filetype)
  if family == "octave" or family == "sage" then
    return "slime", "configured"
  end

  if configured == "iron" then
    return "iron", "configured"
  end
  if configured == "r_nvim" then
    return "r_nvim", "configured"
  end
  if configured == "neopyter" then
    return M.resolve(context)
  end

  local ok_ll, ll = pcall(require, "iron.lowlevel")
  if ok_ll and type(ll.get_repl_ft_for_bufnr) == "function" and ll.get_repl_ft_for_bufnr(bufnr) then
    return "iron", "repl_buffer"
  end

  if M.iron_connected(filetype) and not M.slime_connected() then
    return "iron", "connected"
  end

  return M.resolve(context)
end

function M.describe(context)
  local backend, reason = M.resolve(context)
  return string.format("%s (%s)", backend, reason)
end

return M
