-- Hh gate for the QUIET peek route: python/repl_peek_server.py (the half
-- that runs inside the REPL) answering the editor's own socket client
-- (repl.peek `ask_server`).
--
-- The server is booted under plain `python3` with a namespace of known values,
-- exactly as `ipython -i` boots it, so the rows are about the wire: a defined
-- name, an undefined one, an expression that raises, the socket the REPL picks
-- for its window, and a dead socket answering nil so the caller can fall back
-- to the pasted probe.
--
-- nvim --headless -n -i NONE -u NONE -l tests/repl_peek_server_contract.lua
-- exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local peek = require("repl.peek")
local server_py = root .. "/python/repl_peek_server.py"

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

if vim.fn.executable("python3") ~= 1 then
  print("INCONCLUSIVE: python3 not on PATH")
  os.exit(2)
end

local runtime = vim.fn.tempname()
vim.fn.mkdir(runtime, "p")
local window_id = 424242
local socket = runtime .. "/nvim-peek/k" .. window_id .. ".sock"

local boot = table.concat({
  "exec(open(" .. string.format("%q", server_py) .. ").read())",
  "alpha = 41 + 1",
  "class Boom:",
  "    def __repr__(self): raise ValueError('nope')",
  "boom = Boom()",
  "import time; time.sleep(30)",
}, "\n")

local job = vim.fn.jobstart({ "python3", "-c", boot }, {
  env = { XDG_RUNTIME_DIR = runtime, KITTY_WINDOW_ID = tostring(window_id), TMUX_PANE = "" },
})
local function stop()
  pcall(vim.fn.jobstop, job)
end

if not vim.wait(5000, function()
  local stat = (vim.uv or vim.loop).fs_stat(socket)
  return stat ~= nil and stat.type == "socket"
end, 50) then
  stop()
  print("INCONCLUSIVE: server never bound " .. socket)
  os.exit(2)
end
check("server_binds_its_window_socket", true)

local function ask(expr, path)
  local answer, answered = nil, false
  peek._test.ask_server(path or socket, expr, function(data)
    answer, answered = data, true
  end)
  vim.wait(3000, function()
    return answered
  end, 10)
  return answer
end

check("defined_name_answers", peek.parse(ask("alpha") or "") == "42", vim.inspect(ask("alpha")))
check("undefined_name_is_silent", peek.parse(ask("not_a_name") or "") == nil, vim.inspect(ask("not_a_name")))
check("raising_repr_is_silent", select(2, peek.parse(ask("boom") or "")) == "err:ValueError", vim.inspect(ask("boom")))
check("expression_not_just_name", peek.parse(ask("alpha * 2") or "") == "84", vim.inspect(ask("alpha * 2")))

-- The editor's side of the same route: the binding names the socket.
vim.env.DL_RUNTIME_DIR = runtime
vim.b.slime_config = { family = "python", window_id = window_id, listen_on = "unix:/x" }
vim.g.ub_repl_backend_python = "slime"
vim.bo.filetype = "python"
local resolved = peek._test.server_socket({ family = "python", backend = "slime", bufnr = 0 })
check("binding_names_the_socket", resolved == socket, tostring(resolved))
check(
  "tmux_binding_names_the_pane_socket",
  (function()
    vim.b.slime_config = { socket_name = "default", target_pane = "%7" }
    return peek._test.server_socket({ family = "python", backend = "slime", bufnr = 0 })
  end)() == nil,
  "a pane with no server answered a path"
)
vim.b.slime_config = { family = "python", window_id = window_id, listen_on = "unix:/x" }

stop()
vim.wait(2000, function()
  return (vim.uv or vim.loop).fs_stat(socket) == nil
end, 50)
check("dead_server_answers_nil", ask("alpha", socket) == nil, "a dead socket answered")

vim.fn.delete(runtime, "rf")
print(string.format("%d passed, %d failed", passes, #failures))
os.exit(#failures == 0 and 0 or 1)
