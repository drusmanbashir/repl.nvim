--- Python REPL payload formatting for the slime send path
--- (`SlimeOverride_EscapeText_python`) and iron's python repl `format`.
--- Battery (run after every change here): bash tests/repl_send_battery.sh
--- Contract — see REPL_ROUTING.md § `M-x` cell-send contract (python).
---
--- Slime path, bracketed paste on (`ipython_text` -> `paste_lines`). Operator
--- rulings 2026-10-02: "DO NOT SKIP LINES TO PASS INTO REPL" -- every source
--- line of the block is sent, blank lines and a bare `if __name__ ==
--- "__main__":` included; <M-x> is a faithful pipe, so IPython ends up as if
--- the file ran top to bottom, blocks split across cells included.
--- * a multi-line body-only block is shifted left by its first code line
---   (outer_dedent); lines that lack that prefix, e.g. col-0 `# SECTION:`
---   comments and col-0 string text, are left alone; one line keeps its indent;
--- * a cell whose NEXT cell starts deeper than it does (repl_cell) is sent
---   without the execution CR: IPython holds the block, and the next payload
---   to the same REPL target continues it with the same shift, then executes;
--- * every other payload ends with the execution CR (self-executes; the CR is
---   a protocol character, never source). IPython judges what is complete.
--- Iron path, typed input without bracketed paste (`ipython_lines`): out of
--- scope for the no-skipped-lines rule (ruling 2026-10-02). It keeps the
--- line-lexical transform that drops blank lines, inserts CRs to close blocks
--- and drops a dangling guard header -- typed input cannot carry them.
--- Known limitation (iron path): line-lexical -- col-0 code-lookalikes inside
--- triple-quoted strings can be misread as guards or comments.
local M = {}

local cr = "\13"

--- Drop whitespace-only lines so IPython does not end a block early.
local function remove_empty_lines(lines)
  local newlines = {}
  for _, line in ipairs(lines) do
    if line:gsub("[ \t]", "") ~= "" then
      newlines[#newlines + 1] = line
    end
  end
  return newlines
end

--- VS Code Jupyter `dedentCode`: strip leading whitespace of the first
--- non-empty, non-`#` line from every line that still has that prefix.
--- String/body lines at column 0 are left alone (unlike textwrap.dedent).
--- Returns the shifted lines and the prefix removed ("" when none).
local function outer_dedent(lines)
  local prefix
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^#") then
      prefix = line:match("^(%s*)")
      break
    end
  end
  if not prefix or prefix == "" then return lines, "" end
  local out, pat = {}, "^" .. vim.pesc(prefix)
  for _, line in ipairs(lines) do out[#out + 1] = line:gsub(pat, "", 1) end
  return out, prefix
end

local function closes_indent(line)
  -- Any comment (incl. `#SECTION:`/`#%%` markers) must not flush the open
  -- block early — a premature CR mid-guard-body would execute half a suite.
  if line:match("^#") then
    return true
  end
  if line:match("^except%*") then
    return true
  end
  -- A col-0 closing bracket continues an open expression (multi-line import
  -- or call) — a CR before it would split the expression across inputs.
  if line:match("^[%)%]%}]") then
    return true
  end
  local exceptions = { "elif", "else", "except", "finally" }
  for _, exception in ipairs(exceptions) do
    if line == exception or line:match("^" .. exception .. "[%s:]") then
      return true
    end
  end
  return false
end

local MAIN_GUARD_PATTERNS = {
  '^if%s+__name__%s*==%s*"__main__"%s*:%s*$',
  "^if%s+__name__%s*==%s*'__main__'%s*:%s*$",
  '^if%s+__name__%s*==%s*"__main__"%s*:%s*#.*$',
  "^if%s+__name__%s*==%s*'__main__'%s*:%s*#.*$",
}

local function is_main_guard_line(line)
  for _, pattern in ipairs(MAIN_GUARD_PATTERNS) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

local function is_code_line(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  return trimmed ~= "" and not trimmed:match("^#")
end

local function dangling_main_guard_index(lines)
  -- Last guard wins: an earlier guard with a body must not hide a later
  -- dangling one.
  local guard_idx = nil
  for i, line in ipairs(lines) do
    if is_main_guard_line(line) then
      guard_idx = i
    end
  end

  if guard_idx == nil then
    return nil
  end

  for i = guard_idx + 1, #lines do
    if is_code_line(lines[i]) then
      return nil
    end
  end

  return guard_idx
end

local function is_comment_line(line)
  return line:match("^%s*#") ~= nil
end

function M.ipython_lines(lines)
  local result = {}
  local indent_open = false

  lines = remove_empty_lines(lines)
  -- A guard header whose body lives in a later cell is dropped, never refused:
  -- everything above it still runs (the body cells send dedented on their own).
  local dangling = dangling_main_guard_index(lines)
  if dangling then
    table.remove(lines, dangling)
  end
  if #lines > 1 then
    lines = outer_dedent(lines)
  end

  local has_code_line = false
  for _, line in ipairs(lines) do
    if is_code_line(line) then
      has_code_line = true
      break
    end
  end

  for i, line in ipairs(lines) do
    if line:match("^%s") then
      indent_open = true
    end

    result[#result + 1] = line

    if i < #lines and indent_open and not lines[i + 1]:match("^%s") and not closes_indent(lines[i + 1]) then
      indent_open = false
      result[#result + 1] = cr
    end
  end

  -- The payload must self-execute in the REPL (no manual Enter): whenever a
  -- code line was sent, end with the executing CR unless the last line is
  -- already a bare top-level code statement (which auto-runs on its own
  -- newline). Covers both an indented block still open at the end AND
  -- trailing col-0 comment lines (`#SECTION:` tails) following code, since
  -- closes_indent's comment exception otherwise leaves such trailing
  -- comments (and the tracked indent_open state) looking "closed" without
  -- ever emitting the CR that flushes the preceding block.
  if #result == 0 then
    result[1] = cr
  elseif has_code_line and (indent_open or is_comment_line(lines[#lines])) then
    result[#result + 1] = cr
  else
    result[#result + 1] = ""
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Slime path: bracketed paste (rulings 2026-10-02). <M-x> is a faithful pipe:
-- IPython should end up as if the file ran top to bottom, blocks split across
-- cells included. Every source line is sent, shifted only as much as IPython
-- needs; IPython judges completeness and errors. vim-slime wraps the payload
-- in ESC[200~ .. ESC[201~ and sends the final newline as a separate Enter.

-- REPL target -> the shift (prefix) of a payload whose block the next payload
-- continues. One writer: paste_lines; forget() when that REPL is replaced.
local held = {}

local function strip_prefix(lines, prefix)
  if prefix == "" then
    return lines
  end
  local pat = "^" .. vim.pesc(prefix)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = (line:gsub(pat, "", 1))
  end
  return out
end

--- Bracketed-paste payload for `lines` (every one of them, in order) sent to
--- REPL `target`. `continued` = the next cell starts deeper than this one
--- (repl.cell.next_cell_continues): the block goes on there, so the
--- payload is sent without the execution CR and the next payload to `target`
--- continues it with the same shift. Otherwise a multi-line block is
--- outer-dedented (a single line keeps its indent; IPython strips it), and
--- the payload ends with the execution CR.
function M.paste_lines(lines, target, continued)
  local shift = target and held[target]
  local out
  if shift then
    out = strip_prefix(lines, shift)
  elseif #lines > 1 then
    out, shift = outer_dedent(lines)
  else
    out, shift = lines, ""
  end
  if target then
    held[target] = continued and shift or nil
  end

  local payload = vim.list_extend({}, out)
  payload[#payload + 1] = continued and "" or cr
  return payload
end

--- Drop the held block of `target` (every target when nil).
function M.forget(target)
  if target == nil then
    held = {}
  else
    held[target] = nil
  end
end

--- vim-slime EscapeText for python. `bracketed == false` keeps the typed-input
--- transform (ipython_lines); otherwise the bracketed-paste payload.
function M.ipython_text(text, target, bracketed, continued)
  if bracketed == false then
    local typed = vim.split(text, "\n", { plain = true, trimempty = false })
    return table.concat(M.ipython_lines(typed), "\n")
  end
  -- One terminator -- the linewise yank's final newline, or the CR a line or
  -- SECTION send appends -- ends the text; it is not a source line.
  local tail = text:sub(-1)
  if tail == "\n" or tail == "\r" then
    text = text:sub(1, -2)
  end
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  return table.concat(M.paste_lines(lines, target, continued == true), "\n")
end

return M
