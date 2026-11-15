-- REPL send battery, capture half (REPL_ROUTING.md § `M-x` cell-send contract).
--
-- PURPOSE: hands the IPython judge exactly the bytes the editor's real send
-- route gives kitty for one fixture case -- the standalone plugin's direct setup, the real keymaps (<M-x>, <M-X>, visual <M-e>), the
-- real router, cell/section readers, formatter and vim-slime kitty target. The
-- route stops at the `kitty` CLI (fake_kitty.py), which records send-text stdin.
--
-- Arranged, not exercised: the REPL binding is pre-set (b:slime_config naming a
-- fake window) so no window discovery or launch runs. Keys are fed through the
-- mapping table, not typed in a terminal: key delivery is out of scope here.
--
-- Env: BATTERY_PLUGIN_ROOT (plugin under test), BATTERY_VIM_SLIME_ROOT (installed
-- vim-slime, read-only), BATTERY_CASES (cases.json), BATTERY_CASE_ID,
-- BATTERY_FIXTURE (private copy of the fixture), BATTERY_CAPTURE_DIR,
-- BATTERY_FAKE_TREE, BATTERY_WORK.
local env = function(name)
  local value = os.getenv(name)
  assert(value and value ~= "", "capture.lua: missing env " .. name)
  return value
end

local PLUGIN_ROOT = env("BATTERY_PLUGIN_ROOT")
local VIM_SLIME_ROOT = env("BATTERY_VIM_SLIME_ROOT")
local CAPTURE_DIR = env("BATTERY_CAPTURE_DIR")
local WORK = env("BATTERY_WORK")
local manifest = { case = env("BATTERY_CASE_ID"), steps = {}, notifications = {} }

local function write_manifest()
  local fh = assert(io.open(CAPTURE_DIR .. "/manifest.json", "w"))
  fh:write(vim.json.encode(manifest))
  fh:close()
end

local function send_files()
  local out = {}
  for _, name in ipairs(vim.fn.readdir(CAPTURE_DIR)) do
    if name:match("^send%-%d+%.bin$") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function find_case()
  local fh = assert(io.open(env("BATTERY_CASES"), "r"))
  local cases = vim.json.decode(fh:read("*a"))
  fh:close()
  for _, case in ipairs(cases.cases) do
    if case.id == manifest.case then
      return case
    end
  end
  error("capture.lua: no case " .. manifest.case .. " in cases.json")
end

local function load_route()
  vim.opt.rtp:prepend(PLUGIN_ROOT)
  vim.opt.rtp:prepend(VIM_SLIME_ROOT)
  vim.cmd.runtime("plugin/slime.vim")
  require("repl").setup()
  require("repl.slime").setup()
end

local function bind_fake_repl()
  -- Pre-bound REPL: the window the binding names exists in the fake tree and
  -- carries the env title, so ensure_kitty_repl_window takes its bound path.
  local spec = require("repl.specs").slime_kitty_spec("python")
  local tree = {
    {
      id = 1,
      platform_window_id = 4242,
      wm_name = spec.title .. "-1",
      wm_class = spec.window_class,
      tabs = {
        {
          title = spec.title .. "-1",
          windows = { { id = 7, title = spec.title .. "-1", pid = 1, foreground_processes = {} } },
        },
      },
    },
  }
  local fh = assert(io.open(env("BATTERY_FAKE_TREE"), "w"))
  fh:write(vim.json.encode(tree))
  fh:close()
  vim.b.slime_config = { family = "python", window_id = 7, listen_on = spec.listen_on }
  manifest.binding = { title = spec.title, listen_on = spec.listen_on }
end

local function run_step(index, step)
  if step.cursor then
    vim.api.nvim_win_set_cursor(0, { step.cursor[1], step.cursor[2] or 0 })
  end
  local before_files = send_files()
  local before_cursor = vim.api.nvim_win_get_cursor(0)
  vim.v.errmsg = ""
  vim.api.nvim_feedkeys(vim.keycode(step.keys), "mtx", false)
  local after_files = send_files()
  local sends = {}
  for i = #before_files + 1, #after_files do
    sends[#sends + 1] = after_files[i]
  end
  manifest.steps[index] = {
    keys = step.keys,
    cursor_before = before_cursor,
    cursor_after = vim.api.nvim_win_get_cursor(0),
    sends = sends,
    errmsg = vim.v.errmsg,
  }
end

local function main()
  local default_notify = vim.notify
  vim.notify = function(msg, level, opts)
    manifest.notifications[#manifest.notifications + 1] = { msg = tostring(msg), level = level }
    return default_notify(msg, level, opts)
  end
  load_route()
  local case = find_case()
  vim.cmd.edit(vim.fn.fnameescape(env("BATTERY_FIXTURE")))
  vim.bo.filetype = "python"
  bind_fake_repl()
  for index, step in ipairs(case.steps) do
    run_step(index, step)
  end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  manifest.error = tostring(err)
end
write_manifest()
vim.cmd(ok and "qall!" or "cquit 1")
