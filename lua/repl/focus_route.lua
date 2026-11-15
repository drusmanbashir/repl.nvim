--- Where `<M-h>` goes from this buffer, and nothing else.
---
--- This used to be answered inline in the `<M-h>` keymap (slime.lua): a
--- `package.loaded` probe for a live debug sidecar, then a slime-only focus
--- call, then a slime-only warning string. That duplicated the decision
--- `repl.router.resolve` already makes for every send key, and left no
--- room for a third destination without a third bolted-on `if`. Routing is one
--- question, so it gets one owner.
---
--- `resolve` is TOTAL: it always names a destination, and every destination it
--- names is a key of `HANDLERS`. There is no "not mine" return, because a
--- caller cannot tell that from "I tried and gave up" and the two need
--- different messages. Whether the destination can actually be reached is the
--- handler's answer, not the route's.
---
--- Contracts: REPL_ROUTING.md § `<M-h>` destinations.

local M = {}

---@alias ReplFocusDest "sidecar"|"lab"|"lab_pending"|"slime"

--- Read live, never cached: a debug session starting or a Lab connecting
--- between two keypresses must change where the second one lands.
---@param bufnr integer|nil
---@return { dest: ReplFocusDest, reason: string }
function M.resolve(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local router = require("repl.router")

  -- A live debug sidecar owns alt+h before anything else does: the kitty REPL
  -- is not where a stopped frame's names live. Asked through the router's
  -- `package.loaded` probe, so no debug module is pulled in when nobody is
  -- debugging. Deliberately broader than `dap_sidecar_owns(family)` used by the
  -- send keys -- alt+h is "show me the thing I am debugging in", whatever the
  -- buffer under the cursor happens to be.
  if router.dap_sidecar_live() then
    return { dest = "sidecar", reason = "session_live" }
  end

  local backend, reason = router.resolve({ bufnr = bufnr })
  if backend == "neopyter" then
    -- `lab` means a synced notebook exists in a connected JupyterLab;
    -- `lab_pending` is a managed .ipynb whose Lab is not up yet.
    return { dest = reason == "lab" and "lab" or "lab_pending", reason = reason }
  end

  -- Everything else keeps the pre-existing path byte for byte: the slime fast
  -- path applies its own ready/fingerprint gate and declines for iron, R.nvim,
  -- unbound and non-REPL buffers exactly as it did before.
  return { dest = "slime", reason = reason }
end

--- One handler per destination. Each returns whether focus actually moved, and
--- each owns the message for its own failure -- the single slime-worded notice
--- this replaced was wrong for two of the four destinations.
local HANDLERS = {
  sidecar = function()
    require("dap-sidecar.engine.dap2").focus_debug_window()
    return true
  end,

  lab = function(bufnr)
    local focus_lab = require("repl.config").get().focus_lab
    if type(focus_lab) == "function" then return focus_lab(bufnr) end
    vim.notify("No focus_lab callback is configured", vim.log.levels.WARN)
    return false
  end,

  lab_pending = function()
    vim.notify("Neopyter is not connected for this notebook; press <leader>ij", vim.log.levels.WARN)
    return false
  end,

  slime = function()
    if require("repl.focus").focus_ready_target() then
      return true
    end
    vim.notify(
      "No ready Slime REPL binding for this buffer; use <M-x> to bind or <leader>in to launch",
      vim.log.levels.WARN
    )
    return false
  end,
}

--- Resolve, then act. The `<M-h>` keymap is this call and nothing else.
---@param bufnr integer|nil
---@return boolean focused
---@return { dest: ReplFocusDest, reason: string } route
function M.focus(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local route = M.resolve(bufnr)
  return HANDLERS[route.dest](bufnr) == true, route
end

M._test = { handlers = HANDLERS }

return M
