local M = {}

function M.word_under_cursor()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

function M.rest_of_line_from_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".")
  if col < 1 or col > #line then
    return nil
  end
  local rest = line:sub(col)
  if rest == "" then
    return nil
  end
  return rest
end

--- R-SEND-03, shared source-send contract: region and import-block
--- extraction, shared by every REPL backend.
---
--- These moved here out of repl.slime's `config()` closure so the "dap" backend
--- (DAP sidecar backend) can reach them without vim-slime being loaded, and
--- so both backends extract IDENTICAL text: what the debugger runs and what the
--- kitty REPL runs must be the same characters, or a debug send silently means
--- something else than the same keystroke outside a session.
---
--- This module deliberately depends on nothing but the Neovim API.

local VISUAL_MODES = { v = true, V = true, ["\22"] = true }

--- `g@` motion kind -> the register type describing the same shape.
local MOTION_MODE = { char = "v", line = "V", block = "\22" }

--- Text between two positions, honouring the SHAPE of the region.
---
--- getregion() is the only reader that gets blockwise right: a rectangle is not
--- "the first line from its start column to the last line's end column", which
--- is what a hand-rolled charwise trim produces, and for a `<C-v>` selection that
--- difference is code the operator did not select being executed.
local function region_text(pos1, pos2, mode)
  local ok, lines = pcall(vim.fn.getregion, pos1, pos2, { type = mode })
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--- Text of the visual selection, in every visual MODE.
---
--- While visual mode is still active (an `x` mapping run from a Lua callback) the
--- `'<` / `'>` marks still describe the PREVIOUS selection, so the live ends
--- (`v` and `.`) are read instead; once it has ended, the marks are the record.
function M.visual_selection()
  local mode = vim.fn.mode()
  if VISUAL_MODES[mode] then
    return region_text(vim.fn.getpos("v"), vim.fn.getpos("."), mode) or ""
  end
  local last = vim.fn.visualmode()
  if not VISUAL_MODES[last] then
    last = "v"
  end
  return region_text(vim.fn.getpos("'<"), vim.fn.getpos("'>"), last) or ""
end

--- Text an operator (`g@`) just covered, honouring the motion's shape.
function M.operator_region(motion_type)
  return region_text(vim.fn.getpos("'["), vim.fn.getpos("']"), MOTION_MODE[motion_type] or "v") or ""
end

local function line_contains_import_symbol(line, symbol)
  if not line or line == "" then
    return false
  end

  local escaped = "%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]"
  return (
    line:match("^%s*import%s+") ~= nil
    or line:match("^%s*from%s+") ~= nil
  ) and line:match(escaped) ~= nil
end

local function collect_import_block(lines, start_idx)
  local block = {}
  local paren_depth = 0
  local started = false

  for i = start_idx, #lines do
    local line = lines[i]
    if line == nil or line == "" then
      if started and paren_depth <= 0 then
        break
      end
    end

    table.insert(block, line)
    started = true

    local opens = select(2, line:gsub("%(", ""))
    local closes = select(2, line:gsub("%)", ""))
    paren_depth = paren_depth + opens - closes

    local continued = line:match("\\%s*$") ~= nil
    if paren_depth <= 0 and not continued then
      break
    end
  end

  return block
end

--- The import statement (with its parenthesised / backslash continuation) that
--- brings `symbol` into the buffer, as a list of lines, or nil.
function M.import_block(symbol, bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)
  local i = 1

  while i <= #lines do
    local line = lines[i]
    if line and (line:match("^%s*import%s+") or line:match("^%s*from%s+")) then
      local block = collect_import_block(lines, i)
      local text = table.concat(block, "\n")
      if text:match("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]") then
        return block
      end
      i = i + math.max(#block, 1)
    elseif line_contains_import_symbol(line, symbol) then
      return collect_import_block(lines, i)
    else
      i = i + 1
    end
  end
end

return M
