local M = {}

function M.below_sent_line(bufnr)
  bufnr = bufnr or 0
  local end_pos = vim.fn.getpos("']")
  if type(end_pos) ~= "table" or end_pos[2] == nil or end_pos[2] <= 0 then
    return nil
  end
  return math.min(end_pos[2] + 1, vim.api.nvim_buf_line_count(bufnr))
end

function M.below_visual_selection_line(bufnr)
  bufnr = bufnr or 0
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if type(start_pos) ~= "table" or type(end_pos) ~= "table" then
    return nil
  end
  if start_pos[2] == nil or end_pos[2] == nil or start_pos[2] <= 0 or end_pos[2] <= 0 then
    return nil
  end
  local last_line = math.max(start_pos[2], end_pos[2])
  return math.min(last_line + 1, vim.api.nvim_buf_line_count(bufnr))
end

local function move_cursor_to_line(winid, line)
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd("normal! zz")
  end)
end

function M.move_below_sent_block(winid, bufnr)
  winid = winid or vim.api.nvim_get_current_win()
  bufnr = bufnr or vim.api.nvim_win_get_buf(winid)
  local line = M.below_sent_line(bufnr)
  if line == nil then
    return
  end
  move_cursor_to_line(winid, line)
end

function M.move_below_visual_selection(winid, bufnr)
  winid = winid or vim.api.nvim_get_current_win()
  bufnr = bufnr or vim.api.nvim_win_get_buf(winid)
  local line = M.below_visual_selection_line(bufnr)
  if line == nil then
    return
  end
  move_cursor_to_line(winid, line)
end

function M.slime_send_op(type)
  local saved_global = vim.g.slime_preserve_curpos
  local saved_buf = vim.b.slime_preserve_curpos
  vim.g.slime_preserve_curpos = 0
  vim.b.slime_preserve_curpos = 0
  vim.fn["slime#send_op"](type)
  vim.g.slime_preserve_curpos = saved_global
  if saved_buf == nil then
    vim.b.slime_preserve_curpos = nil
  else
    vim.b.slime_preserve_curpos = saved_buf
  end
  M.move_below_sent_block()
end

function M.iron_send_motion(mtype)
  require("iron.core").send_motion(mtype)
  M.move_below_sent_block()
end

return M
