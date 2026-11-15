-- Lab and kitty are MUTUALLY EXCLUSIVE paths, not a preference order. With a
-- kitty Slime REPL alive at the same time, a buffer whose REPL is a connected
-- JupyterLab must route every REPL key to Lab and must never reach the kitty
-- backend -- not for a send, not for alt+h.
--
-- No REPL, no Lab, no kitty: `neopyter.jupyter` and the slime config are
-- stubbed, so the rows are about the routing decision and the dispatch.
--
-- nvim --headless -n -i NONE -u NONE -l tests/repl_route_exclusivity_contract.lua
-- exit 0 PASS, 1 FAIL.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local failures = {}
local passes = 0

local function check(name, ok, detail)
  if ok then
    passes = passes + 1
    print("PASS " .. name)
  else
    failures[#failures + 1] = name
    print("FAIL " .. name .. ": " .. tostring(detail))
  end
end

-- A kitty Slime REPL is bound and alive for the whole of this file. Every row
-- below coexists with it; that is the point.
vim.g.slime_target = "kitty"
vim.g.slime_default_config = { listen_on = "unix:/tmp/kitty-test.sock", window_id = 3 }
vim.g.ub_repl_backend = "slime"

--- @param attached boolean  does JupyterLab hold a notebook for this buffer
local function lab(attached)
  package.loaded["neopyter.jupyter"] = {
    jupyterlab = {
      is_connecting = function() return true end,
      get_notebook = function() return attached and { remote_path = "/lab/nb.ipynb" } or nil end,
    },
  }
end

local function buffer(name, managed)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = "python"
  if managed then
    vim.b[bufnr].neopyter_managed_ipynb = true
  end
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local router = require("repl.router")

-- ===== the decision, with kitty alive alongside =====

do
  lab(true)
  local bufnr = buffer("/work/nb.ipynb", true)
  local backend, reason = router.resolve({ bufnr = bufnr })
  check("synced notebook routes to Lab, not the live kitty REPL", backend == "neopyter", backend .. "/" .. reason)
  check("slime is connected at the same time", router.slime_connected() == true, "slime not connected; row proves nothing")
end

do
  -- The dangerous case: Lab is NOT up, kitty IS. A managed notebook must still
  -- refuse rather than quietly execute its cells in the kitty REPL.
  lab(false)
  local bufnr = buffer("/work/pending.ipynb", true)
  local backend, reason = router.resolve({ bufnr = bufnr })
  check("managed notebook with no Lab never falls back to kitty", backend == "neopyter", backend .. "/" .. reason)
  check("and is reported as pending", reason == "lab_pending", reason)
end

do
  lab(true)
  local bufnr = buffer("/work/synced.py", false)
  check("an incidental .py Lab attachment stays on Kitty", router.resolve({ bufnr = bufnr }) == "slime", router.resolve({ bufnr = bufnr }))
  vim.b[bufnr].neopyter_explicit_percent_py = true
  check("an explicitly opened .py synced to Lab routes to Lab", router.resolve({ bufnr = bufnr }) == "neopyter", router.resolve({ bufnr = bufnr }))
end

do
  lab(false)
  local bufnr = buffer("/work/plain.py", false)
  check("an unsynced .py still routes to kitty", router.resolve({ bufnr = bufnr }) == "slime", router.resolve({ bufnr = bufnr }))
end

-- ===== dispatch cannot reach the other backend =====

do
  local reached = {}
  local actions = require("repl.actions")
  -- Readiness is a separate gate with its own failure message; this file is
  -- about which backend the action is handed to.
  require("repl").ensure_backend_ready = function() return true end
  actions.register_backend("neopyter", { send_selection = function() reached[#reached + 1] = "neopyter"; return true end })
  actions.register_backend("slime", { send_selection = function() reached[#reached + 1] = "slime"; return true end })

  lab(true)
  buffer("/work/dispatch.ipynb", true)
  actions.run("send_selection")
  check("a Lab buffer's send reaches neopyter", reached[1] == "neopyter", vim.inspect(reached))
  check("a Lab buffer's send never reaches slime", not vim.tbl_contains(reached, "slime"), vim.inspect(reached))

  reached = {}
  lab(false)
  buffer("/work/dispatch.py", false)
  actions.run("send_selection")
  check("an unsynced .py send still reaches slime", reached[1] == "slime", vim.inspect(reached))
end

-- ===== alt+h obeys the same split =====

do
  local route = require("repl.focus_route")
  lab(true)
  local bufnr = buffer("/work/focus.ipynb", true)
  check("alt+h in a Lab buffer targets the browser", route.resolve(bufnr).dest == "lab", route.resolve(bufnr).dest)

  lab(false)
  local plain = buffer("/work/focus.py", false)
  check("alt+h in a plain .py targets kitty", route.resolve(plain).dest == "slime", route.resolve(plain).dest)
end

print(string.format("%d passed, %d failed", passes, #failures))
os.exit(#failures == 0 and 0 or 1)
