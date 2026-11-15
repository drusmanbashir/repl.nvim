local M = {}

-- REPL_ROUTING.md § `M-x` cell-send contract, ruling 2026-10-02: an indented
-- `    # %%` splits cells too, so <M-x> inside a guard body sends only the
-- sub-cell around the cursor. slime.lua sets the same pattern for vim-slime.
local DEFAULT_DELIMITER = [[^\s*#\s*%%]]

function M.delimiter_pattern()
  local d = vim.b.slime_cell_delimiter or vim.g.slime_cell_delimiter
  if d and d ~= vim.NIL then
    return d
  end
  return DEFAULT_DELIMITER
end

function M.current_lines(bufnr, winid)
  bufnr = bufnr or 0
  winid = winid or vim.api.nvim_get_current_win()
  local first, last
  vim.api.nvim_win_call(winid, function()
    local previous = vim.fn.search(M.delimiter_pattern(), "bcnW")
    local following = vim.fn.search(M.delimiter_pattern(), "nW")
    first = previous > 0 and previous + 1 or 1
    last = following > 0 and following - 1 or vim.api.nvim_buf_line_count(bufnr)
  end)
  if first > last then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
end

--- Indent width of the first code line (not blank, not a comment), or nil.
local function code_indent(lines)
  for _, line in ipairs(lines) do
    if line:match("%S") and not line:match("^%s*#") then
      return #line:match("^(%s*)")
    end
  end
  return nil
end

--- True when the cell after the current one begins deeper than the current
--- cell's first code line: a block this cell opened goes on in the next cell
--- (as the file reads), so the payload must leave it open for that cell.
--- Ruling 2026-10-02 (REPL_ROUTING.md § `M-x` cell-send contract, item 4).
function M.next_cell_continues(bufnr, winid)
  bufnr = bufnr or 0
  winid = winid or vim.api.nvim_get_current_win()
  local first, following
  vim.api.nvim_win_call(winid, function()
    local previous = vim.fn.search(M.delimiter_pattern(), "bcnW")
    following = vim.fn.search(M.delimiter_pattern(), "nW")
    first = previous > 0 and previous + 1 or 1
  end)
  if following == 0 then
    return false
  end
  local base = code_indent(vim.api.nvim_buf_get_lines(bufnr, first - 1, following - 1, false))
  if base == nil then
    return false
  end
  local matcher = vim.regex(M.delimiter_pattern())
  local next_cell = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, following, -1, false)) do
    if matcher:match_str(line) then
      break
    end
    next_cell[#next_cell + 1] = line
  end
  local deeper = code_indent(next_cell)
  return deeper ~= nil and deeper > base
end

function M.move_below_next_delimiter(bufnr, winid)
  bufnr = bufnr or 0
  winid = winid or vim.api.nvim_get_current_win()
  local pat = M.delimiter_pattern()
  local cur = vim.api.nvim_win_get_cursor(winid)[1]
  vim.api.nvim_win_set_cursor(winid, { cur, 0 })
  local next_delim = vim.fn.search(pat, "nW")
  local line
  if next_delim > 0 then
    line = math.min(next_delim + 1, vim.api.nvim_buf_line_count(bufnr))
  else
    line = vim.api.nvim_buf_line_count(bufnr)
  end
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd("normal! zz")
  end)
end

return M
