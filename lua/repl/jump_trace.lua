local M = {}
local kitty_rpc = require("repl.kitty_rpc")
local uv = vim.uv
local active_slime_kitty_target = nil

vim.api.nvim_create_autocmd("User", {
  pattern = "ReplChanged",
  callback = function(args)
    local data = args.data or {}
    if data.backend == "slime" and data.target == "kitty" and data.family == "python" then
      active_slime_kitty_target = {
        listen_on = data.listen_on,
        window_id = tonumber(data.window_id),
      }
    elseif data.backend ~= "slime" or data.family == "python" then
      active_slime_kitty_target = nil
    end
  end,
})

-- ===== utils =====
local function strip_ansi(s) return (s:gsub("\27%[[0-9;]*m", "")) end
local function fs_exists(p) return p and uv.fs_stat(p) ~= nil end
local function expand_home(p) if p and p:sub(1,2) == "~/" then return vim.fn.expand("~") .. p:sub(2) end return p end
local function get_git_root()
  local ok,out=pcall(function() return vim.fn.systemlist({ "git","rev-parse","--show-toplevel"}) end)
  if ok and out and out[1] and out[1]~="" then return out[1] end
  return nil
end
local function resolve_path(path)
  path = expand_home(path)
  if fs_exists(path) then return path end
  if path:match("^/") then return path end
  local cwd = uv.cwd(); if cwd then local p=cwd.."/"..path; if fs_exists(p) then return p end end
  local root = get_git_root(); if root then local p=root.."/"..path; if fs_exists(p) then return p end end
  return path
end

local function current_backend()
  local ok, repl_backend = pcall(require, "repl")
  if ok and type(repl_backend.current) == "function" then
    return repl_backend.current()
  end
  return "slime"
end

local function tmux_repl_target()
  return vim.g.slime_tmux_repl_target or vim.env.NVIM_SLIME_TMUX_REPL_TARGET or "dlmain:1"
end

local function capture_tmux_repl_lines()
  if vim.fn.executable("tmux") ~= 1 then return nil end
  local function ipython_pane(target)
    local lines = vim.fn.systemlist({ "tmux", "list-panes", "-t", target, "-F", "#{pane_id}\t#{pane_current_command}\t#{pane_start_command}" })
    for _, line in ipairs(lines) do
      local pane, cmd, start = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
      start = start or ""
      if cmd == "ipython" or start:match("/ipython\\") or start:match('/ipython["%s]') or start:match("/ipython$") then return pane end
    end
  end

  local pane = ipython_pane(tmux_repl_target()) or ipython_pane(":repl")
  if not pane then return nil end
  local lines = vim.fn.systemlist({ "tmux", "capture-pane", "-t", pane, "-p", "-S", "-5000" })
  if vim.v.shell_error == 0 and #lines > 0 then return lines end
  return nil
end

--- Bound slime kitty pair only (active / family g: / env / buffer). No KITTY_LISTEN_ON —
--- that is the editor socket and must not mix with a post-discover window_id.
local function slime_kitty_bind_pair(family)
  local slime_config = vim.b.slime_config or {}
  local target = active_slime_kitty_target or {}
  local listen_on = target.listen_on
    or vim.g["ub_slime_kitty_listen_on_" .. family]
    or vim.env.NVIM_SLIME_KITTY_LISTEN_ON
    or slime_config.listen_on
  local window_id = tonumber(
    target.window_id
      or vim.g["ub_slime_kitty_window_id_" .. family]
      or vim.env.NVIM_SLIME_KITTY_WINDOW_ID
      or slime_config.window_id
      or ""
  )
  return listen_on, window_id
end

local function capture_kitty_repl_lines()
  local family = (function()
    local ok, repl_backend = pcall(require, "repl")
    if ok and type(repl_backend.family_for_filetype) == "function" then
      return repl_backend.family_for_filetype(vim.bo.filetype or "")
    end
    return "python"
  end)()

  local listen_on, window_id = slime_kitty_bind_pair(family)
  if not window_id then
    -- Discover-only: bind existing env-matching REPL. Never launch / type start_command.
    local ok, repl_backend = pcall(require, "repl")
    if ok and type(repl_backend.discover_slime_target) == "function" then
      pcall(repl_backend.discover_slime_target)
    end
    listen_on, window_id = slime_kitty_bind_pair(family)
  end

  if not listen_on or listen_on == "" then
    error("Cannot jump from slime kitty traceback: missing kitty listen socket. Select a slime kitty target first.")
  end
  if not window_id then
    error("Cannot jump from slime kitty traceback: missing slime kitty window id. Select a slime kitty target first.")
  end

  local text, err = kitty_rpc.get_text(listen_on, window_id, "all")
  if not text then
    error(("Cannot jump from slime kitty traceback: kitty get-text failed for window id %s on %s: %s"):format(window_id, listen_on, err))
  end
  if text == "" then
    error(("Cannot jump from slime kitty traceback: kitty window id %s on %s returned no text."):format(window_id, listen_on))
  end
  return vim.split(text, "\n", { plain = true })
end

local function in_tmux()
  local ok, repl_backend = pcall(require, "repl")
  if ok and type(repl_backend.tmux_enabled) == "function" then
    return repl_backend.tmux_enabled()
  end
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

-- ===== parsing =====
local function is_valid_source_file(path)
  if not path then return false end
  if path:match("^Cell%s+In%[") or path:match("^%d%d:%d%d$") then return false end
  return path:match("%.py[iw]?$") ~= nil
end

-- file-based frame
local function parse_file_frame(line)
  line = strip_ansi(line)
  local p,n = line:match([[File%s+"([^"]+)",%s*line%s+(%d+)]])
  if p and n and is_valid_source_file(p) then return resolve_path(p), tonumber(n) end
  p,n = line:match([[([%w%._~/%-%+\\]+%.py[iw]?):(%d+)]])
  if p and n and is_valid_source_file(p) then return resolve_path(p), tonumber(n) end
end

local function is_trace_header(s)
  s = strip_ansi(s); if s:match("^%s*-+$") then return false end
  return s:find("Traceback", 1, true) ~= nil
end

local function is_error_footer(s)
  s = strip_ansi(s)
  return s:match("^%s*%u[%w%.]*Error[:%s]") ~= nil or s:match("^%s*Exception[:%s]") ~= nil
end

local function is_ipython_prompt(s)
  -- vi-mode IPython prefixes the prompt with [ins] / [nav].
  s = strip_ansi(s):gsub("^%[%a+%]%s*", "")
  return s:match("^In %[[0-9]+%]:") ~= nil or s:match("^Out%s*%[[0-9]+%]:") ~= nil
end

-- cell-only frame: also grab the arrow-code line for exact matching
local function clean_cell_func(func)
  if not func then return nil end
  func = func:gsub("%(.*$", "")
  if func == "" then return nil end
  return func
end

local function parse_cell_frame_with_snippet(lines, i)
  local line = strip_ansi(lines[i])
  local cell_id, n, func = line:match([[Cell%s+In%[(%d+)%],%s*line%s+(%d+),%s*in%s+(.+)$]])
  if not cell_id then
    cell_id, n = line:match([[Cell%s+In%[(%d+)%],%s*line%s+(%d+)]])
  end
  if not n then return nil end
  n = tonumber(n)
  cell_id = tonumber(cell_id)
  local snippet = nil
  for k = i+1, math.min(i+5, #lines) do
    local l = strip_ansi(lines[k])
    local num, code = l:match("^%-+>%s*(%d+)%s*(.*)$")
    if num and tonumber(num) == n then
      snippet = code:gsub("%s+", " "):sub(1, 200)
      break
    end
  end
  -- Real IPython SyntaxError: no ----> arrow; indented source then caret line.
  if not snippet then
    for k = i + 1, math.min(i + 4, #lines) do
      local l = strip_ansi(lines[k])
      if is_error_footer(l) then break end
      local nxt = lines[k + 1] and strip_ansi(lines[k + 1]) or ""
      if nxt:match("^%s*%^+%s*$") and l:match("%S") then
        snippet = l:gsub("^%s+", ""):gsub("%s+", " "):sub(1, 200)
        break
      end
    end
  end
  func = clean_cell_func(func)
  return { lnum = n, func = func, snippet = snippet, cell_id = cell_id }
end

-- ===== REPL output source (tmux when attached, otherwise native buffers) =====
local function capture_window_repl_lines()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local iron = nil
  local best = { buf=nil, row=1e9, matches=0 }
  for _, w in ipairs(wins) do
    if w ~= vim.api.nvim_get_current_win() then
      local cfg = vim.api.nvim_win_get_config(w); if cfg.relative and cfg.relative ~= "" then goto cont end
      local b = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(b)
      if name:match("^iron://") then iron = b end
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local m=0; for _,l in ipairs(lines) do local p,n = parse_file_frame(l); if p and n and fs_exists(p) then m=m+1 end end
      local row = vim.api.nvim_win_get_position(w)[1]
      if m > best.matches or (m==best.matches and row < best.row) then best={buf=b,row=row,matches=m} end
      ::cont::
    end
  end
  if iron then return vim.api.nvim_buf_get_lines(iron, 0, -1, false) end
  if best.buf and best.matches > 0 then return vim.api.nvim_buf_get_lines(best.buf, 0, -1, false) end
  -- fallback: top-most other window
  local top, top_row = nil, math.huge
  for _, w in ipairs(wins) do
    if w ~= vim.api.nvim_get_current_win() then
      local cfg = vim.api.nvim_win_get_config(w); if cfg.relative and cfg.relative ~= "" then goto c2 end
      local row = vim.api.nvim_win_get_position(w)[1]
      if row < top_row then top, top_row = vim.api.nvim_win_get_buf(w), row end
      ::c2::
    end
  end
  if top then return vim.api.nvim_buf_get_lines(top, 0, -1, false) end
  return nil
end

local function find_best_repl_source()
  local backend = current_backend()

  if backend == "slime" then
    local target = vim.g.slime_target or vim.env.NVIM_SLIME_TARGET or "tmux"
    if target == "kitty" then
      return capture_kitty_repl_lines()
    end
    if in_tmux() then
      return capture_tmux_repl_lines() or capture_window_repl_lines()
    end
    return capture_window_repl_lines()
  end

  return capture_window_repl_lines() or (in_tmux() and capture_tmux_repl_lines() or nil)
end

-- ===== newest error =====
-- An error is an error: whatever its form (Traceback, caret SyntaxError,
-- frameless UsageError), only the newest one in scrollback is ever used.
-- Scanning up, the first footer or Traceback header met belongs to it. A footer
-- block starts at its header, else at its first frame line, bounded by the
-- previous prompt or footer. A header met first means an unrecognised footer:
-- the block runs to the next prompt.
local function is_frame_line(s)
  s = strip_ansi(s)
  return s:match("^%s*File%s") ~= nil or s:match("Cell%s+In%[%d+%],%s*line%s+%d+") ~= nil
end

local function newest_error_range(lines)
  for i = #lines, 1, -1 do
    if is_trace_header(lines[i]) then
      local last = i
      for k = i + 1, #lines do
        if is_ipython_prompt(lines[k]) then break end
        last = k
      end
      return i, last
    end
    if is_error_footer(lines[i]) then
      local first = i
      for k = i - 1, 1, -1 do
        local s = lines[k]
        if is_ipython_prompt(s) or is_error_footer(s) then break end
        if is_trace_header(s) then first = k; break end
        if is_frame_line(s) then first = k end
      end
      return first, i
    end
  end
  return nil
end

local function newest_error_frames(lines)
  local first, last = newest_error_range(lines)
  if not first then return {} end
  local out = {}
  for i = first, last do
    local p, n = parse_file_frame(lines[i])
    if p and n and fs_exists(p) then
      out[#out + 1] = { path = p, lnum = n, line = i, kind = "file" }
    end
    local hit = parse_cell_frame_with_snippet(lines, i)
    if hit then
      out[#out + 1] = {
        path = nil,
        lnum = hit.lnum,
        line = i,
        kind = "cell",
        func = hit.func,
        snippet = hit.snippet,
        cell_id = hit.cell_id,
      }
    end
  end
  return out
end

-- ===== find exact line for cell frames =====
-- Scratch under `if __name__ == "__main__":` is excluded from snippet scans.
local function main_guard_line(lines)
  for i, l in ipairs(lines) do
    if l:match("^%s*if%s+__name__%s*==%s*[\"']__main__[\"']%s*:") then
      return i
    end
  end
  return nil
end

local function scan_limit(lines)
  local guard = main_guard_line(lines)
  if guard then return guard - 1 end
  return #lines
end

local function find_method_line_in_current_buffer(func_name)
  if not func_name or func_name == "<module>" then return nil end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last = scan_limit(lines)
  local class, meth = func_name:match("^([%w_]+)%.([%w_]+)$")
  if class and meth then
    local class_ln
    for i = 1, last do
      if lines[i]:match("^%s*class%s+" .. vim.pesc(class) .. "%s*[%(:]") then
        class_ln = i
        break
      end
    end
    if class_ln then
      for j = class_ln, last do
        if lines[j]:match("^%s*def%s+" .. vim.pesc(meth) .. "%s*%(") then return j end
        if j > class_ln and lines[j]:match("^%s*class%s+") then break end
      end
    end
  end
  for i = 1, last do
    if lines[i]:match("^%s*def%s+" .. vim.pesc(func_name) .. "%s*%(") then return i end
  end
  return nil
end

local function normalize_ws(s) return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")) end
local function normalize_code_for_match(s)
  s = normalize_ws(s)
  s = s:gsub("#.*$", "")
  s = s:gsub("[^%w_]+", "")
  return s:lower()
end

local function tokenize_code(s)
  local tokens = {}
  for t in normalize_code_for_match(s):gmatch("[%a_][%w_]*") do
    tokens[#tokens + 1] = t
  end
  return tokens
end

local SNIPPET_SKIP_CALLEE = {
  print = true,
  len = true,
  range = true,
  str = true,
  int = true,
  float = true,
  list = true,
  dict = true,
  set = true,
  tuple = true,
  type = true,
  isinstance = true,
  getattr = true,
  setattr = true,
  super = true,
}

local function primary_callee(snippet)
  local last = nil
  for name in snippet:gmatch("([%w_]+)%s*%(") do
    if not SNIPPET_SKIP_CALLEE[name] then last = name end
  end
  return last
end

local function token_overlap_score(snippet, line)
  local a = tokenize_code(snippet)
  local b = tokenize_code(line)
  if #a == 0 or #b == 0 then return 0 end
  local setb = {}
  for _, t in ipairs(b) do setb[t] = true end
  local hit = 0
  for _, t in ipairs(a) do
    if setb[t] then hit = hit + 1 end
  end
  return hit / #a
end

local function line_match_quality(line, norm, relaxed)
  local ws = normalize_ws(line)
  -- Exact line match first (indent-insensitive via normalize_ws).
  if ws == norm then return 4 end
  local relaxed_line = normalize_code_for_match(line)
  if relaxed ~= "" and relaxed_line == relaxed then return 3 end
  -- def/class lines must not substring-match call snippets like "boom()"
  -- (that false offset vote lands \jj on the def instead of the call site).
  if ws:match("^async%s+def%s+") or ws:match("^def%s+") or ws:match("^class%s+") then
    return 0
  end
  if ws:find(norm, 1, true) then return 2 end
  -- Source line may contain a truncated traceback snippet (forward only).
  -- Never reverse-match snippet:contains(line): short normalized decoys like
  -- "    ][-1]" → "1" false-hit inside "ifjj_case_001" and steal cell offset votes.
  if relaxed ~= "" and relaxed_line:find(relaxed, 1, true) then return 1 end
  return 0
end

local function line_matches_snippet(line, norm, relaxed)
  return line_match_quality(line, norm, relaxed) > 0
end

local function find_snippet_in_range(lines, snippet, start_ln, end_ln, stop_at_outdent)
  if not snippet or snippet == "" or end_ln < start_ln then return nil end
  local norm = normalize_ws(snippet)
  local relaxed = normalize_code_for_match(snippet)
  local base = lines[start_ln] or ""
  local indent_len = #(base:match("^%s*") or "")
  for i = start_ln, end_ln do
    local l = lines[i]
    if stop_at_outdent and i > start_ln then
      local cur_indent = #(l:match("^%s*") or "")
      if cur_indent <= indent_len and l:match("^%s*[%w_]+") then break end
    end
    if line_matches_snippet(l, norm, relaxed) then return i end
  end
  return nil
end

local function find_snippet_by_callee(lines, snippet, start_ln, end_ln)
  local callee = primary_callee(snippet)
  if not callee or end_ln < start_ln then return nil end
  local call_pat = vim.pesc(callee) .. "%s*%("
  local class_pat = "^%s*class%s+" .. vim.pesc(callee) .. "%s*[%(:]"
  local best_i, best_score = nil, 0
  for i = start_ln, end_ln do
    local l = lines[i]
    local is_class = l:match(class_pat)
    local is_call = l:match(call_pat)
    if is_class or is_call then
      local score = token_overlap_score(snippet, l)
      -- Constructor-like cell → prefer class signature over internal call sites.
      if is_class then
        score = score + 0.35
      elseif l:match("^%s*def%s+") then
        score = score + 0.05
      end
      if score > best_score then
        best_score = score
        best_i = i
      end
    end
  end
  if best_i and best_score > 0 then return best_i end
  return nil
end

local function find_cell_line_in_current_buffer(func_name, snippet)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last = scan_limit(lines)
  if last < 1 then return nil end

  local def_ln = find_method_line_in_current_buffer(func_name)
  if def_ln and snippet then
    local found = find_snippet_in_range(lines, snippet, def_ln, last, true)
    if found then return found end
    return def_ln
  end

  -- Module-level cell (no func): scan library body only (above __name__), not scratch.
  if snippet then
    local found = find_snippet_in_range(lines, snippet, 1, last, false)
    if found then return found end
    found = find_snippet_by_callee(lines, snippet, 1, last)
    if found then return found end
  end
  return def_ln
end

-- ===== cell-frame offset (whole buffer, including under __main__) =====
local function find_all_snippet_lines(lines, snippet)
  if not snippet or snippet == "" then return {} end
  local norm = normalize_ws(snippet)
  local relaxed = normalize_code_for_match(snippet)
  local hits = {}
  local best_quality = 0
  for i = 1, #lines do
    local quality = line_match_quality(lines[i], norm, relaxed)
    if quality > best_quality then
      hits = { { lnum = i, quality = quality } }
      best_quality = quality
    elseif quality > 0 and quality == best_quality then
      hits[#hits + 1] = { lnum = i, quality = quality }
    end
  end
  return hits
end

--- Annotate cell matches with resolved_lnum via consistent offset voting.
--- offset = buf_line - cell_lnum; map frame → offset + cell_lnum.
local function annotate_cell_offsets(matches)
  local has_cell = false
  for _, m in ipairs(matches) do
    if m.kind == "cell" then
      has_cell = true
      break
    end
  end
  if not has_cell then return end

  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #buf_lines == 0 then return end
  local by_cell = {}
  for _, m in ipairs(matches) do
    if m.kind == "cell" then
      local id = m.cell_id or 0
      by_cell[id] = by_cell[id] or {}
      by_cell[id][#by_cell[id] + 1] = m
    end
  end

  for _, frames in pairs(by_cell) do
    local votes = {}
    for _, m in ipairs(frames) do
      for _, hit in ipairs(find_all_snippet_lines(buf_lines, m.snippet)) do
        local off = hit.lnum - m.lnum
        local v = votes[off]
        if not v then
          v = { count = 0 }
          votes[off] = v
        end
        v.count = v.count + 1
      end
    end

    local best_off, best_count = nil, 0
    for off, v in pairs(votes) do
      -- Do not use the editor cursor: the result must be invariant to where
      -- the operator started. Stable smallest-offset tie-break handles truly
      -- identical duplicate snippets without Lua table-order dependence.
      if v.count > best_count or (v.count == best_count and (best_off == nil or off < best_off)) then
        best_off, best_count = off, v.count
      end
    end

    if best_off then
      for _, m in ipairs(frames) do
        local ln = best_off + m.lnum
        if ln < 1 then ln = 1 end
        if ln > #buf_lines then ln = #buf_lines end
        m.resolved_lnum = ln
      end
    end
  end
end

-- ===== jump helpers =====
local function jump_same_file(lnum)
  lnum = math.max(1, tonumber(lnum) or 1)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local max = vim.api.nvim_buf_line_count(buf)
  if lnum > max then lnum = max end
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  pcall(vim.cmd, "normal! zvzz")
end

local function find_bufnr_by_realpath(path)
  local target = uv.fs_realpath(resolve_path(path)) or resolve_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local real = uv.fs_realpath(name) or name
        if real == target then return bufnr, target end
      end
    end
  end
  return nil, target
end

local function jump_to(match)
  if not match.path or match.kind == "cell" then
    if match.resolved_lnum then
      jump_same_file(match.resolved_lnum)
      return
    end
    local found = find_cell_line_in_current_buffer(match.func, match.snippet)
    if found then jump_same_file(found); return end
    jump_same_file(1)
    return
  end

  local bufnr = select(1, find_bufnr_by_realpath(match.path))
  if bufnr and bufnr == vim.api.nvim_get_current_buf() then
    jump_same_file(match.lnum)
    return
  end
  if bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  else
    local path = resolve_path(match.path)
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
  end
  jump_same_file(match.lnum)
end

-- 0-based: \jj/\j0 deepest, \j1 one up; \JJ/\J0 top, \J1 second from top.
local function choose_nth(matches, from_top, n)
  if #matches == 0 then return nil end
  n = tonumber(n) or 0
  if n < 0 then n = 0 end
  if n > #matches - 1 then n = #matches - 1 end
  return from_top and matches[n + 1] or matches[#matches - n]
end

-- ===== postfix count reader (supports \jj / \JJ and \j[n] / \J[n]; 0-based) =====
local function read_postfix_count(confirm_char)
  -- Blocks for ONE key; then greedily eats queued digits.
  -- Confirm char (\jj / \JJ) is alias for index 0.
  local first = vim.fn.getcharstr()
  if first == confirm_char then return 0 end
  if not first:match("%d") then
    -- push it back so it still gets typed
    vim.api.nvim_feedkeys(first, "n", false)
    return 0
  end
  local num = first
  while true do
    local nxt = vim.fn.getchar(0)
    if nxt == 0 or nxt == nil then break end
    local ch = type(nxt) == "number" and vim.fn.nr2char(nxt) or nxt
    if ch:match("%d") then
      num = num .. ch
    else
      vim.api.nvim_feedkeys(ch, "n", false)
      break
    end
  end
  return tonumber(num) or 0
end

-- ===== commands =====
function M.jump_from_bottom_with_prompt()
  local lines = find_best_repl_source(); if not lines then vim.notify("No REPL/output window found.", vim.log.levels.WARN); return end
  local matches = newest_error_frames(lines); if #matches == 0 then vim.notify("No valid file/cell frames.", vim.log.levels.WARN); return end
  annotate_cell_offsets(matches)
  local n = read_postfix_count("j")
  local m = choose_nth(matches, false, n); jump_to(m)
end

function M.jump_from_top_with_prompt()
  local lines = find_best_repl_source(); if not lines then vim.notify("No REPL/output window found.", vim.log.levels.WARN); return end
  local matches = newest_error_frames(lines); if #matches == 0 then vim.notify("No valid file/cell frames.", vim.log.levels.WARN); return end
  annotate_cell_offsets(matches)
  local n = read_postfix_count("J")
  local m = choose_nth(matches, true, n); jump_to(m)
end

-- ===== last traceback text (Yana \aP / \aN) =====
--- Slice last Traceback..Error block from already-captured REPL lines.
--- @return string|nil text
--- @return string|nil err
function M.last_traceback_from_lines(lines)
  if not lines or #lines == 0 then
    return nil, "No REPL/output window found."
  end
  local first, last = newest_error_range(lines)
  if not first then
    return nil, "No traceback in REPL."
  end
  local out = {}
  for i = first, last do
    out[#out + 1] = strip_ansi(lines[i])
  end
  return table.concat(out, "\n"), nil
end

--- Capture sister REPL scrollback and return the last traceback block.
--- @return string|nil text
--- @return string|nil err
function M.last_traceback_text()
  local ok, lines = pcall(find_best_repl_source)
  if not ok then
    return nil, tostring(lines)
  end
  return M.last_traceback_from_lines(lines)
end

--- Slice the last n REPL lines (from the bottom) from already-captured lines.
--- @return string|nil text
--- @return string|nil err
function M.last_repl_tail_from_lines(lines, n)
  if not lines or #lines == 0 then
    return nil, "No REPL/output window found."
  end
  n = tonumber(n) or 0
  if n <= 0 then
    return nil, "Line count must be positive."
  end
  -- kitty --extent all / tmux capture-pane pad to the bottom of the screen;
  -- that padding must not eat the N-line budget.
  local last = #lines
  while last > 0 and strip_ansi(lines[last]):match("^%s*$") do
    last = last - 1
  end
  if last == 0 then
    return nil, "No REPL output to attach."
  end
  local start = math.max(1, last - n + 1)
  local out = {}
  for i = start, last do
    out[#out + 1] = strip_ansi(lines[i])
  end
  return table.concat(out, "\n"), nil
end

--- Capture sister REPL scrollback and return the last n lines from the bottom.
--- @return string|nil text
--- @return string|nil err
function M.last_repl_tail_text(n)
  local ok, lines = pcall(find_best_repl_source)
  if not ok then
    return nil, tostring(lines)
  end
  return M.last_repl_tail_from_lines(lines, n)
end

-- Debug
function M._list()
  local lines = find_best_repl_source(); if not lines then print("no REPL"); return end
  local m = newest_error_frames(lines); print("#matches:", #m)
  for i,x in ipairs(m) do print(i, (x.path or "<current>")..":"..x.lnum, x.kind or "", x.func or "", x.snippet or "") end
end

return M
