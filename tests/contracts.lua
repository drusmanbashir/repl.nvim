-- Run with nvim --headless -u NONE -l tests/contracts.lua from the plugin root.
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
local repl = require("repl")
repl.setup({ python_envs = vim.env.XDG_STATE_HOME .. "/envs.json" })
for _, path in ipairs(vim.fn.glob(root .. "/lua/repl/**/*.lua", false, true)) do
  local name = path:sub(#root + 6, -5):gsub("/", ".")
  assert(pcall(require, name), "standalone module failed: " .. name)
end
for name in pairs(package.loaded) do
  assert(not name:match("^user%."), "loaded host configuration: " .. name)
end
assert(require("repl.backend").current() == "slime")
local formatter = require("repl.python.slime_format")
local lines = { "if __name__ == '__main__':", "", "    x = 4", "# keep this comment" }
local text = table.concat(lines, "\n")
assert(formatter.ipython_text(text, "contract-target", true, false):find("# keep this comment", 1, true))
local router = require("repl.router")
package.loaded["dap-sidecar.host.sidecar"] = {
  session_live = function() return true end,
  session_adapter_type = function() return "python" end,
}
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b, "/contract/managed.ipynb")
vim.bo[b].filetype = "python"
vim.b[b].neopyter_managed_ipynb = true
assert(router.resolve({ bufnr = b, family = "python" }) == "neopyter", "managed notebook sent to DAP")
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, "/contract/ordinary.py")
vim.bo[source].filetype = "python"
assert(router.resolve({ bufnr = source, family = "python" }) == "dap", "ordinary source lost matching DAP route")
local command = "systemd-run --user --scope -p MemoryMax=100G -p MemorySwapMax=0 ipython"
require("repl.config").setup({ languages = { python = { command = command } } })
local spec = require("repl.specs").slime_kitty_spec("python")
assert(spec.start_command:find(command, 1, true), "custom command was dropped")
assert(spec.start_command:find("start-ipython", 1, true), "custom command bypassed inspection setup")
print("PASS standalone module, configuration, source, notebook/DAP and command contracts")
vim.cmd("qall!")
