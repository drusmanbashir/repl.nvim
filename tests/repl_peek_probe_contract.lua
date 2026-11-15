-- Hh gate for the `<M-v>` REPL peek probe (lua/repl/peek.lua).
--
-- The probe is the part that runs inside someone's live session, so it is
-- tested by RUNNING it: python3 (and Rscript when present) execute the exact
-- text that would be pasted into the REPL, and the rows assert the answer file,
-- the silence contract for an undefined name, and that the probe left no name
-- of its own behind in the namespace it ran in.
--
-- nvim --headless -n -i NONE -u NONE -l tests/repl_peek_probe_contract.lua
-- exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local peek = require("repl.peek")

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

local function answer_path()
  return vim.fn.tempname() .. "-peek"
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

local function run(cmd)
  local out = vim.fn.system(cmd)
  return vim.v.shell_error, out
end

-- ===== python =====

if vim.fn.executable("python3") ~= 1 then
  print("INCONCLUSIVE: python3 not on PATH")
  os.exit(2)
end

local function python_peek(setup, expr)
  local path = answer_path()
  local probe = peek.probe("python", expr, path, 4000)
  local code, out = run({ "python3", "-c", setup .. "\n" .. probe })
  return { path = path, probe = probe, code = code, out = out, data = read(path) }
end

do
  local r = python_peek("x = 41 + 1", "x")
  check("probe_is_one_line", not r.probe:find("\n", 1, true), "probe spans lines: " .. r.probe)
  check("python_runs_clean", r.code == 0, "exit " .. tostring(r.code) .. " " .. tostring(r.out))
  check("defined_name_answers", r.data == "ok\n42", vim.inspect(r.data))
  check("value_parses", peek.parse(r.data or "") == "42", vim.inspect(r.data))
end

do
  local r = python_peek("pass", "not_defined_anywhere")
  check("undefined_name_answers_err", r.data == "err:NameError", vim.inspect(r.data))
  local value, reason = peek.parse(r.data or "")
  check("undefined_name_is_silent", value == nil and reason == "err:NameError", vim.inspect({ value, reason }))
end

do
  -- Quotes and backslashes have to survive two rounds of escaping (the probe
  -- embeds the expression in a string that is itself a string).
  local r = python_peek([==[d = {"a\\b": 'q"q'}]==], [==[d["a\\b"]]==])
  check("escaped_expression_answers", r.data == [==[ok
'q"q']==], vim.inspect(r.data))
end

do
  -- A repr that really spans lines keeps its line breaks: parse() strips the
  -- status line only.
  local setup = "class C:\n    def __repr__(self): return 'a\\nb'\nv = C()"
  local r = python_peek(setup, "v")
  check("multiline_value_kept", peek.parse(r.data or "") == "a\nb", vim.inspect(r.data))
end

do
  -- The namespace the probe ran in must look untouched afterwards.
  local path = answer_path()
  local probe = peek.probe("python", "leftovers", path, 4000)
  local script = table.concat({
    "leftovers = 1",
    probe,
    "print(sorted(k for k in list(globals()) if k in ('r','e','p','_v','_o','_p')))",
  }, "\n")
  local code, out = run({ "python3", "-c", script })
  check("probe_leaves_no_names", code == 0 and vim.trim(out) == "[]", tostring(out))
end

do
  -- A huge value must not paste a huge answer back.
  local path = answer_path()
  local probe = peek.probe("python", "big", path, 64)
  run({ "python3", "-c", "big = 'z' * 10000\n" .. probe })
  local data = read(path) or ""
  check("answer_is_clipped", #data == 64, "#answer=" .. #data)
end

-- ===== R (only when Rscript is installed) =====

if vim.fn.executable("Rscript") == 1 then
  local path = answer_path()
  local probe = peek.probe("r", "y", path, 4000)
  local code, out = run({ "Rscript", "-e", "y <- 42L\n" .. probe })
  check("r_defined_name_answers", code == 0 and (read(path) or ""):match("^ok\n%[1%] 42") ~= nil, tostring(out) .. vim.inspect(read(path)))

  local missing = answer_path()
  run({ "Rscript", "-e", peek.probe("r", "no_such_object", missing, 4000) })
  check("r_undefined_name_is_silent", peek.parse(read(missing) or "") == nil, vim.inspect(read(missing)))
else
  print("SKIP r rows: Rscript not on PATH")
end

print(string.format("%d passed, %d failed", passes, #failures))
os.exit(#failures == 0 and 0 or 1)
