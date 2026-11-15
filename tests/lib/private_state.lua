-- B7: every sidecar test runs under a private XDG state/cache/runtime dir and the
-- harness refuses the operator's real one. Product modules (diagnostics.lua) write
-- a log group under stdpath('state') and prune older groups; a test that loads them
-- with the inherited environment destroys the operator's real groups.
--
--   dofile(<script dir>/../lib/private_state.lua).enter('name')   -- first code line
--   dofile(<lib dir>/private_state.lua).guard('name')             -- harness: refuse real
--
-- enter(): an inherited environment is reused ONLY when the runner that allocated
-- it says so: DAP_TEST_PRIVATE_STATE=<dir> (set by run_p5.py, the rigs and this
-- helper when they allocate) AND XDG_STATE_HOME lies under <dir>; XDG_CACHE_HOME
-- and XDG_RUNTIME_DIR not under <dir> are allocated as <dir>/cache and <dir>/run.
-- Anything else, default or non-default root alike (XDG_STATE_HOME=$HOME/my-state
-- is the user's), is replaced by a fresh state/cache/run under DAP_TEST_STATE_ROOT
-- (default /s/agent_rw/tmp/dap-test-state). Dirs this helper created are removed on
-- every exit (VimLeavePre, which `qa!` runs, and os.exit); dirs of dead owners are
-- pruned on entry as crash recovery. Shell twin: private_state.sh.
--
-- Boundary: dap_plugins.bootstrap calls guard(), so its callers fail loudly when they
-- forgot enter(); a test that bypasses bootstrap is protected only by its own first
-- enter() call (private_state_coverage.sh lists entries without it).
local M = {}

local ROOT = os.getenv('DAP_TEST_STATE_ROOT') or '/s/agent_rw/tmp/dap-test-state'

local function norm(p)
  return vim.fn.resolve(vim.fn.fnamemodify(p, ':p')):gsub('/+$', '')
end

--- The directories that count as the operator's real state dir.
function M.real_dirs()
  local out = {}
  local home = os.getenv('HOME')
  if home and home ~= '' then out[#out + 1] = norm(home .. '/.local/state') end
  local pw = vim.uv.os_get_passwd()
  if pw and pw.homedir then out[#out + 1] = norm(pw.homedir .. '/.local/state') end
  return out
end

local function under(p, dir)
  if not p or p == '' or not dir or dir == '' then return false end
  p, dir = norm(p), norm(dir)
  return p == dir or p:sub(1, #dir + 1) == dir .. '/'
end

--- True when the runner's marker proves XDG_STATE_HOME is its own allocation.
function M.owned()
  local m = os.getenv('DAP_TEST_PRIVATE_STATE')
  return m ~= nil and m:sub(1, 1) == '/' and under(os.getenv('XDG_STATE_HOME'), m)
end

--- True when the effective state dir is a real one (or falls back to it).
function M.is_real()
  local s = os.getenv('XDG_STATE_HOME')
  if not s or s == '' then return true, '$HOME/.local/state' end
  for _, r in ipairs(M.real_dirs()) do
    if norm(s) == r then return true, s end
  end
  return false, s
end

--- Refuse to continue when the effective state dir is the real one.
function M.guard(name)
  local real, where = M.is_real()
  -- Owned, or inside the agent scratch area (rigs that allocate their own), passes.
  if not M.owned() and (real or not (under(where, '/s/agent_rw/tmp') or under(where, '/tmp'))) then
    io.stderr:write(('FAIL %s: B7: effective state dir is the real one (%s); call lib/private_state.lua enter() first\n')
      :format(name or 'test', where))
    os.exit(1)
  end
end

local function prune()
  for entry, kind in vim.fs.dir(ROOT) do
    local pid = entry:match('^(%d+)%-')
    if kind == 'directory' and pid and not vim.uv.fs_stat('/proc/' .. pid) then
      vim.fn.delete(ROOT .. '/' .. entry, 'rf')
    end
  end
end

local cleanups, hooked = {}, false

local function run_cleanups()
  for i = #cleanups, 1, -1 do
    local f = table.remove(cleanups, i)
    pcall(f)
  end
end

local function hook()
  if hooked then return end
  hooked = true
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = run_cleanups })
  local real_exit = os.exit
  os.exit = function(...) run_cleanups(); return real_exit(...) end
end

function M.enter(name)
  if M.owned() then
    local m = os.getenv('DAP_TEST_PRIVATE_STATE')
    for _, kv in ipairs({ { 'XDG_CACHE_HOME', 'cache' }, { 'XDG_RUNTIME_DIR', 'run' } }) do
      if not under(os.getenv(kv[1]), m) then
        vim.fn.mkdir(m .. '/' .. kv[2], 'p', tonumber('700', 8))
        vim.env[kv[1]] = m .. '/' .. kv[2]
      end
    end
    return function() end
  end
  vim.fn.mkdir(ROOT, 'p')
  prune()
  local scratch = ('%s/%d-%04x'):format(ROOT, vim.fn.getpid(), math.random(0, 0xffff))
  for _, d in ipairs({ 'state', 'cache', 'run' }) do vim.fn.mkdir(scratch .. '/' .. d, 'p', tonumber('700', 8)) end
  vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME, vim.env.XDG_RUNTIME_DIR =
    scratch .. '/state', scratch .. '/cache', scratch .. '/run'
  vim.env.DAP_TEST_PRIVATE_STATE = scratch
  M.guard(name)
  local done = false
  local function cleanup()
    if done then return end
    done = true
    vim.fn.delete(scratch, 'rf')
  end
  cleanups[#cleanups + 1] = cleanup
  hook()
  return cleanup
end

return M
