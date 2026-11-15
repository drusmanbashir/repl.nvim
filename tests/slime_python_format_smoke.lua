local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function fail(message)
  error(message, 0)
end

local fmt = require("repl.python.slime_format")
local cr = string.char(13)

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end

  for i, line in ipairs(left) do
    if line ~= right[i] then
      return false
    end
  end

  return true
end

local function check(name, input, expected)
  local actual = fmt.ipython_lines(input)
  if not same_lines(actual, expected) then
    fail(
      name
        .. " failed\nexpected:\n"
        .. vim.inspect(expected)
        .. "\nactual:\n"
        .. vim.inspect(actual)
    )
  end
end

local function check_line_by_line(name, cases)
  for _, case in ipairs(cases) do
    check(name .. " / " .. case[1], { case[2] }, case[3])
  end
end

check("single top-level line", {
  'print("hello")',
}, {
  'print("hello")',
  "",
})

check("single indented line preserves indent", {
  '    print("hello")',
}, {
  '    print("hello")',
  cr,
})

check("nested multi-line block dedents common indent", {
  "    for i in range(2):",
  "        for j in range(2):",
  "            print(i, j)",
  '    print("done")',
}, {
  "for i in range(2):",
  "    for j in range(2):",
  "        print(i, j)",
  cr,
  'print("done")',
  "",
})

check_line_by_line("same nested loop sent line by line", {
  { "outer loop", "for i in range(2):", { "for i in range(2):", "" } },
  { "inner loop", "    for j in range(2):", { "    for j in range(2):", cr } },
  { "inner body", "        print(i, j)", { "        print(i, j)", cr } },
})

check("else closes indent without extra blank line", {
  "if value:",
  '    print("yes")',
  "else:",
  '    print("no")',
}, {
  "if value:",
  '    print("yes")',
  "else:",
  '    print("no")',
  cr,
})

-- VS Code Jupyter dedentCode: col-0 string body must not block outer strip.
check("indented assign + multiline string body at col 0", {
  '    SYSTEM_PROMPT = """You classify reports.',
  "Return JSON only.",
  '- "has_cancer": bool',
  '"""',
  "    x = 1",
}, {
  'SYSTEM_PROMPT = """You classify reports.',
  "Return JSON only.",
  '- "has_cancer": bool',
  '"""',
  "x = 1",
  "",
})

check("leading hash comment then indented code uses code indent", {
  "# note: setup",
  "    a = 1",
  "    b = 2",
}, {
  "# note: setup",
  "a = 1",
  "b = 2",
  "",
})

-- ===== `M-x` cell-send contract: `if __name__ == "__main__":` guard =====
-- See REPL_ROUTING.md § `M-x` cell-send contract (python). User code lines
-- are never omitted; payloads must self-execute (no manual Enter in IPython).

--- Each CR-separated segment executes as its own IPython input, so every
--- segment must compile alone (catches premature CR splitting a block) and
--- the joined payload must compile as a whole.
local function check_compiles(name, input)
  local payload_lines = fmt.ipython_lines(input)
  local segments = {}
  local current = {}
  for _, line in ipairs(payload_lines) do
    if line == cr then
      segments[#segments + 1] = table.concat(current, "\n")
      current = {}
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    segments[#segments + 1] = table.concat(current, "\n")
  end
  segments[#segments + 1] = table.concat(payload_lines, "\n"):gsub(cr, "\n")

  for i, segment in ipairs(segments) do
    if segment:gsub("%s", "") ~= "" then
      local out = vim.fn.system(
        { "python3", "-c", "import sys; compile(sys.stdin.read(), '<payload>', 'exec')" },
        segment
      )
      if vim.v.shell_error ~= 0 then
        fail(name .. " segment " .. i .. " does not compile:\n" .. out .. "\nsegment:\n" .. segment)
      end
    end
  end
end

--- Every non-blank input line must appear verbatim in the payload (fidelity:
--- the transform may add lines, never drop or rewrite user lines).
local function check_fidelity(name, input)
  local actual = fmt.ipython_lines(input)
  local pos = 1
  for _, line in ipairs(input) do
    if line:gsub("[ \t]", "") ~= "" then
      local found = nil
      for i = pos, #actual do
        if actual[i] == line then
          found = i
          break
        end
      end
      if found == nil then
        fail(name .. " dropped or rewrote user line: " .. vim.inspect(line))
      end
      pos = found + 1
    end
  end
end

check("dangling guard is dropped, not invented or refused", {
  "class A:",
  "    x = 1",
  "",
  'if __name__ == "__main__":',
  "#SECTION:---- setup ----",
  "",
}, {
  "class A:",
  "    x = 1",
  "#SECTION:---- setup ----",
  cr,
})

check("single-quote dangling guard", {
  "if __name__ == '__main__':",
  "# %%",
}, {
  "# %%",
  "",
})

check("one-line guard untouched", {
  'if __name__ == "__main__": main()',
}, {
  'if __name__ == "__main__": main()',
  "",
})

check("indented guard is not treated as the module guard", {
  "class A:",
  '    if __name__ == "__main__":',
}, {
  "class A:",
  '    if __name__ == "__main__":',
  cr,
})

check("body-only indented cell still dedents (no guard in chunk)", {
  "    frame = 1",
  "    print(frame)",
  "#SECTION:---- next ----",
}, {
  "frame = 1",
  "print(frame)",
  "#SECTION:---- next ----",
  cr,
})

check("trailing col-0 comment after indented block still executes", {
  "for i in range(2):",
  "    print(i)",
  "#SECTION:---- tail ----",
}, {
  "for i in range(2):",
  "    print(i)",
  "#SECTION:---- tail ----",
  cr,
})

check("indented prefix before dangling guard invents no body", {
  "    previous_guard_body()",
  'if __name__ == "__main__":',
  "#SECTION: next",
}, {
  "previous_guard_body()",
  "#SECTION: next",
  cr,
})

check("second dangling guard after guard-with-body invents no body", {
  'if __name__ == "__main__":',
  "    x = 1",
  'if __name__ == "__main__":',
  "#SECTION: tail",
}, {
  'if __name__ == "__main__":',
  "    x = 1",
  "#SECTION: tail",
  cr,
})

local function check_no_invented_pass(name, input)
  for _, line in ipairs(fmt.ipython_lines(input)) do
    if line == "    pass" then
      fail(name .. " synthesized pass")
    end
  end
end

check_no_invented_pass("bare guard", { 'if __name__ == "__main__":' })
check_no_invented_pass("guard after indented block", {
  "    previous_guard_body()",
  'if __name__ == "__main__":',
})

check("multi-line parenthesized import gets no premature CR", {
  "from episode import (",
  "    ReportExtract,",
  "    build_user_prompt,",
  ")",
  "CT_SPLIT = 1",
}, {
  "from episode import (",
  "    ReportExtract,",
  "    build_user_prompt,",
  ")",
  cr,
  "CT_SPLIT = 1",
  "",
})

check("except* chain gets no premature CR", {
  "try:",
  "    work()",
  "except* ValueError:",
  "    recover()",
}, {
  "try:",
  "    work()",
  "except* ValueError:",
  "    recover()",
  cr,
})

check("comment-only chunk sends without executing CR", {
  "# %%",
  "#SECTION:---- empty ----",
}, {
  "# %%",
  "#SECTION:---- empty ----",
  "",
})

-- ===== regression: regex1 p2/base.py guard cells =====
-- Verbatim snapshot of /home/ub/code/regex1/p2/base.py (the file whose M-x
-- sends produced "IndentationError: expected an indented block after 'if'
-- statement on line 28" and a wedged In[] buffer). Copied, not read at
-- runtime: the original lives outside this repo and may change.
local base_py = {
  '"""p2 scratch: regex + pydantic tool-call starter on your CT batch split."""',
  "",
  "from __future__ import annotations",
  "",
  "import json",
  "import re",
  "import sys",
  "from pathlib import Path",
  "from typing import Any, Literal",
  "",
  "import pandas as pd",
  "from pydantic import BaseModel, Field",
  "",
  'REPO_ROOT = Path("/home/ub/code/regex1")',
  "if str(REPO_ROOT) not in sys.path:",
  "    sys.path.insert(0, str(REPO_ROOT))",
  "from tutorial.common.llm import DEFAULT_MODEL, complete, structured",
  "from tutorial.episodes.ep01_structured_output.episode import (",
  "    ReportExtract,",
  "    SYSTEM_PROMPT_CANCER,",
  "    build_user_prompt,",
  ")",
  "",
  "",
  'CT_SPLIT = REPO_ROOT / "files/batch/202526/splits/split_001.xlsx"',
  'NORMAL_RE = re.compile(r"no acute cardiopulmonary|\\bnormal\\b", re.I)',
  "",
  "",
  "class ToolCall(BaseModel):",
  '    """One agent turn: invoke a tool or return a final answer."""',
  "",
  '    tool: Literal["grep_report", "final_answer"]',
  "    args: dict[str, Any] = Field(default_factory=dict)",
  "",
  "",
  'if __name__ == "__main__":',
  "#SECTION:-------------------- setup --------------------------------------------------------------------------------------",
  "# %%",
  '    frame = pd.read_excel(CT_SPLIT).fillna("")',
  '    print(f"rows={len(frame)}  cols={list(frame.columns)}")',
  "",
  "    row = frame.iloc[0]",
  '    report_text = str(row["report_text"])',
  "    match = NORMAL_RE.search(report_text)",
  "    print(f\"patient_id={row['patient_id']}  regex_hit={match.group(0) if match else None}\")",
  "",
  "    # pydantic: parse one tool JSON string (same shape ep03 agents use)",
  '    raw = json.dumps({"tool": "grep_report", "args": {"pattern": "pleural effusion"}})',
  "    call = ToolCall.model_validate_json(raw)",
  "    print(call)",
  "",
  "    model = DEFAULT_MODEL",
  "#SECTION:-------------------- crossover: episode 01 on CT data ----------------------------------------------------------",
  "# %%",
  "    report_id = f\"{row['patient_id']}|{row['examination_date']}\"",
  "    clinical = f\"{row['clinical_details']}\\n{row['referral']}\".strip()",
  "    user_prompt = build_user_prompt(report_id, clinical, report_text)",
  "    print(user_prompt[:400])",
}

-- Preamble cell: file top → line before the first `# %%` (dangling guard).
local base_py_preamble = {}
for i = 1, 38 do
  base_py_preamble[i] = base_py[i]
end

do
  local actual = fmt.ipython_lines(base_py_preamble)
  for _, line in ipairs(actual) do
    if line:match("^if __name__") then
      fail("regression base.py preamble: dangling guard header must be dropped")
    end
  end
  if actual[#actual] ~= cr then
    fail("regression base.py preamble must end with executing CR")
  end
  check_no_invented_pass("regression base.py preamble", base_py_preamble)
end

check_fidelity("regression base.py whole-file fidelity", base_py)
check_compiles("regression base.py whole-file", base_py)
do
  local actual = fmt.ipython_lines(base_py)
  if actual[#actual] ~= cr then
    fail("regression base.py whole-file must end with executing CR")
  end
end

print("slime python format smoke ok")
