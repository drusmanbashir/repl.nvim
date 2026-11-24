local M = {}
local function quote(value)
  return vim.fn.shellescape(tostring(value))
end

function M.slime_kitty_spec(family)
  local config = require("repl.config")
  local language = config.language(family) or config.language("python")
  local python = family == "python"
  local command = language.command
  if python then
    local helper = vim.env.NVIM_SLIME_REPL_RESTART_HELPER or config.get().repl_restart_helper
    command = ""
    if type(language.command) == "string" and language.command ~= "" then
      command = "NVIM_REPL_COMMAND=" .. quote(language.command) .. " "
    end
    local executable = require("repl.python_env").ipython_cmd()
    if executable then command = command .. "NVIM_SLIME_IPYTHON_EXECUTABLE=" .. quote(executable) .. " " end
    command = command .. quote(helper) .. " start-ipython"
  end
  return {
    family = family,
    launcher = language.launcher or config.root() .. "/bin/repl-launch",
    listen_on = language.listen_on or require("repl.paths").socket(family),
    start_command = command,
    title = language.title or (python and require("repl.python_env").repl_title_base() or ({ r = "dl-r-repl", lua = "dl-lua-repl", octave = "dl-octave-repl", sage = "dl-sage-repl" })[family] or ("repl-" .. family)),
    window_class = language.window_class or (python and "ipython-repl" or nil),
  }
end
return M
