local M = {}
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local options = {
  languages = {
    python = { launcher = root .. "/bin/repl-launch" },
    r = { command = "R --quiet --no-save", launcher = root .. "/bin/repl-launch" },
    lua = { command = "lua", launcher = root .. "/bin/repl-launch" },
  },
  kitty_bin = "kitty",
  target = "kitty",
  python_envs = vim.fn.stdpath("data") .. "/repl/python-envs.json",
  backend_config = nil,
  python_paths = nil,
  focus_lab = nil,
  focus_target_helper = root .. "/bin/kitty-focus-slime-target",
  focus_source_helper = root .. "/bin/kitty-focus-slime-source",
  focus_back_helper = root .. "/bin/kitty-focus-back",
  repl_restart_helper = root .. "/bin/slime-repl-restart",
  callbacks = {},
}

function M.root() return root end
function M.get() return options end
function M.language(family) return options.languages[family] end

function M.setup(opts)
  opts = opts or {}
  for key, value in pairs(opts) do
    if key == "languages" then
      for family, language in pairs(value) do
        options.languages[family] = vim.tbl_deep_extend("force", options.languages[family] or {}, language)
      end
    else
      options[key] = value
    end
  end
end

function M.kitty_bin() return vim.env.NVIM_SLIME_KITTY_BIN or options.kitty_bin or "kitty" end
function M.host_script(name)
  local path = options.focus_target_helper
  if name == "kitty-focus-slime-source" then path = options.focus_source_helper end
  return vim.fn.executable(path) == 1 and path or name
end
function M.focus_back_bin()
  local path = options.focus_back_helper
  if type(path) == "function" then path = path() end
  return type(path) == "string" and vim.fn.executable(path) == 1 and path or nil
end

return M
