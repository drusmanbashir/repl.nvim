-- The `<M-h>` destination decision (lua/repl/focus_route.lua): given
-- what the router says about a buffer, where does the key go, and which handler
-- runs. No REPL, no Lab, no debug session -- the router and every handler's
-- collaborator are stubbed, so the rows are about the decision itself.
--
-- nvim --headless -n -i NONE -u NONE -l tests/repl_focus_route_contract.lua
-- exit 0 PASS, 1 FAIL.

dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/lib/private_state.lua').enter('repl_focus_route_contract') -- B7: private XDG state before any product module
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

require("repl.config").get().focus_lab = function() return true end

local route = require("repl.focus_route")

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

--- The router is the only thing `resolve` reads, so stubbing it is the whole
--- fixture.
local function router(live, backend, reason)
  package.loaded["repl.router"] = {
    dap_sidecar_live = function() return live end,
    resolve = function() return backend, reason end,
  }
end

local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end

-- ===== the decision =====

router(true, "slime", "connected")
check("live debug session takes alt+h", route.resolve(0).dest == "sidecar", route.resolve(0).dest)

router(false, "neopyter", "lab")
check("connected notebook routes to the browser", route.resolve(0).dest == "lab", route.resolve(0).dest)

router(false, "neopyter", "lab_pending")
check("managed ipynb with no Lab yet is pending", route.resolve(0).dest == "lab_pending", route.resolve(0).dest)

router(false, "slime", "connected")
check("python buffer routes to slime", route.resolve(0).dest == "slime", route.resolve(0).dest)

router(false, "iron", "connected")
check("iron buffer still reaches the slime gate", route.resolve(0).dest == "slime", route.resolve(0).dest)

router(false, "r_nvim", "connected")
check("r_nvim buffer still reaches the slime gate", route.resolve(0).dest == "slime", route.resolve(0).dest)

-- A resolver that may decline leaves the caller unable to tell "not mine" from
-- "I gave up", so every backend the router can name must produce a destination
-- that a handler answers.
do
  local handlers = route._test.handlers
  local total = true
  local missing
  for _, case in ipairs({
    { true, "slime", "connected" },
    { false, "neopyter", "lab" },
    { false, "neopyter", "lab_pending" },
    { false, "slime", "configured" },
    { false, "iron", "connected" },
    { false, "r_nvim", "connected" },
    { false, "dap", "sidecar" },
  }) do
    router(case[1], case[2], case[3])
    local answer = route.resolve(0)
    if type(answer) ~= "table" or not answer.dest or not handlers[answer.dest] then
      total = false
      missing = vim.inspect({ case, answer })
    end
  end
  check("every resolved destination has a handler", total, missing)
end

-- ===== dispatch =====

do
  local called = {}
  local handlers = route._test.handlers
  local real = { lab = handlers.lab, sidecar = handlers.sidecar, slime = handlers.slime }
  handlers.lab = function(bufnr) called[#called + 1] = "lab:" .. tostring(bufnr); return true end
  handlers.sidecar = function() called[#called + 1] = "sidecar"; return true end
  handlers.slime = function() called[#called + 1] = "slime"; return false end

  router(false, "neopyter", "lab")
  local focused, answer = route.focus(7)
  check("lab route runs the lab handler", called[#called] == "lab:7", vim.inspect(called))
  check("lab focus reports success", focused == true, focused)
  check("focus returns the route it took", answer.dest == "lab", vim.inspect(answer))

  router(true, "slime", "connected")
  route.focus(0)
  check("live session runs the sidecar handler", called[#called] == "sidecar", vim.inspect(called))

  router(false, "slime", "connected")
  check("a declined slime focus is reported false", route.focus(0) == false, "expected false")

  handlers.lab, handlers.sidecar, handlers.slime = real.lab, real.sidecar, real.slime
end

-- ===== messages =====

do
  notices = {}
  router(false, "neopyter", "lab_pending")
  local focused = route.focus(0)
  check("pending Lab does not claim focus", focused == false, focused)
  check("pending Lab names the start gate", (notices[1] or ""):find("<leader>ij", 1, true) ~= nil, vim.inspect(notices))
end

do
  notices = {}
  router(false, "neopyter", "lab")
  route.focus(0)
  check("a raised Lab says nothing", #notices == 0, vim.inspect(notices))
end

print(string.format("%d passed, %d failed", passes, #failures))
os.exit(#failures == 0 and 0 or 1)
