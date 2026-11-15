local M = {}
function M.outer_dedent(lines)
  local prefix
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^#") then prefix = line:match("^(%s*)"); break end
  end
  if not prefix or prefix == "" then return lines, "" end
  local result, pattern = {}, "^" .. vim.pesc(prefix)
  for _, line in ipairs(lines) do result[#result + 1] = line:gsub(pattern, "", 1) end
  return result, prefix
end
return M
