-- The plugin can switch to an available Iron backend without loading dapui.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

package.preload["dapui"] = function()
  error("simulated dapui poison")
end
package.loaded["dapui"] = nil
package.preload["lazy"] = function()
  return { load = function() end }
end
package.preload["lazy.core.config"] = function()
  return { plugins = {} }
end
package.preload["iron.core"] = function()
  return {}
end

local repl = require("repl")
repl.setup({ callbacks = { ensure_iron = function()
  require("repl.actions").register_backend("iron", { send_selection = function() return true end })
  return true
end } })
vim.bo.filetype = "python"

assert(repl.current() == "slime", "default must be slime")
assert(repl.use_iron() == true, "Iron backend should be available")
assert(repl.current() == "iron", "current backend should be Iron")
assert(require("repl.actions").backend_registered("iron"), "Iron backend must be registered")
assert(package.loaded["dapui"] == nil, "switching backend must not load dapui")

print("PASS iron backend does not load dapui")
