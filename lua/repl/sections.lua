local M = {}

local section_marker_vim_regex = [[\c^\s*#\s*\*\?\s*SECTION\>\s*:]]

local function section_matcher()
  local ok, matcher = pcall(vim.regex, section_marker_vim_regex)
  if not ok then
    return nil
  end
  return matcher
end

function M.section_marker_vim_regex()
  return section_marker_vim_regex
end

function M.current_section_range(bufnr, cursor_line)
  bufnr = bufnr or 0
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if total_lines < 1 then
    return nil
  end

  local matcher = section_matcher()
  if matcher == nil then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  cursor_line = math.max(1, math.min(cursor_line or vim.api.nvim_win_get_cursor(0)[1], total_lines))

  local function is_marker(lnum)
    return lnum >= 1 and lnum <= total_lines and matcher:match_str(lines[lnum]) ~= nil
  end

  local prev_marker = nil
  local next_marker = nil
  local has_marker = false

  for lnum = cursor_line, 1, -1 do
    if is_marker(lnum) then
      prev_marker = lnum
      has_marker = true
      break
    end
  end

  local next_search_start = prev_marker and (prev_marker + 1) or 1
  for lnum = next_search_start, total_lines do
    if is_marker(lnum) then
      has_marker = true
      if prev_marker == nil or lnum > prev_marker then
        next_marker = lnum
        break
      end
    end
  end

  if not has_marker then
    return {
      has_marker = false,
      start_line = 1,
      finish_line = total_lines,
      move_line = total_lines,
    }
  end

  local start_line = prev_marker and (prev_marker + 1) or 1
  local finish_line = next_marker and (next_marker - 1) or total_lines
  local move_line = next_marker and math.min(next_marker + 1, total_lines) or total_lines

  return {
    has_marker = true,
    start_line = start_line,
    finish_line = finish_line,
    move_line = move_line,
    marker_line = prev_marker,
    next_marker_line = next_marker,
  }
end

function M.current_section_lines(bufnr, cursor_line)
  local range = M.current_section_range(bufnr, cursor_line)
  if range == nil then
    return nil
  end

  if range.finish_line < range.start_line then
    return {
      has_marker = range.has_marker,
      lines = {},
      range = range,
    }
  end

  return {
    has_marker = range.has_marker,
    lines = vim.api.nvim_buf_get_lines(bufnr or 0, range.start_line - 1, range.finish_line, false),
    range = range,
  }
end

---@param bufnr number|nil
---@param cursor_line number|nil
---@param direction "next"|"prev"
---@return number|nil marker line, or nil when none
function M.find_section_marker(bufnr, cursor_line, direction)
  bufnr = bufnr or 0
  local matcher = section_matcher()
  if matcher == nil then
    return nil
  end

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  if total_lines < 1 then
    return nil
  end

  cursor_line = math.max(1, math.min(cursor_line or vim.api.nvim_win_get_cursor(0)[1], total_lines))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local function is_marker(lnum)
    return lnum >= 1 and lnum <= total_lines and matcher:match_str(lines[lnum]) ~= nil
  end

  if direction == "next" then
    for lnum = cursor_line + 1, total_lines do
      if is_marker(lnum) then
        return lnum
      end
    end
    return nil
  end

  for lnum = cursor_line - 1, 1, -1 do
    if is_marker(lnum) then
      return lnum
    end
  end
  return nil
end

---@param direction "next"|"prev"
function M.jump_section(direction)
  local cur = vim.fn.line(".")
  local target = M.find_section_marker(0, cur, direction)
  if target == nil then
    vim.notify("No more SECTION markers", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
end

return M
