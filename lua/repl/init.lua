local backend = require("repl.backend")
local M = setmetatable({}, { __index = backend })

function M.setup(opts)
  require("repl.config").setup(opts)
  require("repl.python_env").setup()
  require("repl.slime").init()
  backend.setup_keymaps()
  require("repl.actions").setup_keymaps()
  return M
end

return M
