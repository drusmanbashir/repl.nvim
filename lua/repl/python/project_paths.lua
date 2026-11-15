local M = {}

local CONFIG_PATH = vim.fn.stdpath("data") .. "/repl/python-paths.json"
local MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", ".git" }
local cache

local function read_config()
  if cache then
    return cache
  end
  local path = require("repl.config").get().project_paths or CONFIG_PATH
  local fh = io.open(path, "r")
  if not fh then
    cache = { core = {}, projects = {} }
    return cache
  end
  local content = fh:read("*a")
  fh:close()
  local ok, parsed = pcall(vim.json.decode, content)
  if not ok or type(parsed) ~= "table" then
    cache = { core = {}, projects = {} }
    return cache
  end
  cache = {
    core = type(parsed.core) == "table" and parsed.core or {},
    projects = type(parsed.projects) == "table" and parsed.projects or {},
  }
  return cache
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function resolve_dir(dir)
  if type(dir) == "string" and dir ~= "" then
    local root = vim.fs.root(dir, MARKERS)
    return normalize(root or dir)
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    local root = vim.fs.root(name, MARKERS)
    return normalize(root or name)
  end
  return normalize(vim.fn.getcwd())
end

function M.extras_for(dir)
  local cfg = read_config()
  local target = resolve_dir(dir)
  if not target then
    return {}
  end
  local best_key = nil
  local best_len = -1
  for key, _ in pairs(cfg.projects) do
    local key_norm = normalize(key)
    if key_norm and (target == key_norm or vim.startswith(target, key_norm .. "/")) then
      if #key_norm > best_len then
        best_key = key
        best_len = #key_norm
      end
    end
  end
  if not best_key then
    return {}
  end
  local out = {}
  for _, path in ipairs(cfg.projects[best_key]) do
    local normalized = normalize(path)
    if normalized then
      table.insert(out, normalized)
    end
  end
  return out
end

function M.lsp_paths_for(dir)
  local cfg = read_config()
  local extras = M.extras_for(dir)
  local out = {}
  local seen = {}

  local function append_unique(path)
    local normalized = normalize(path)
    if normalized and not seen[normalized] then
      seen[normalized] = true
      table.insert(out, normalized)
    end
  end

  for _, path in ipairs(cfg.core or {}) do
    append_unique(path)
  end
  for _, path in ipairs(extras) do
    append_unique(path)
  end
  return out
end

function M.prepend_for(dir, current)
  local extras = M.extras_for(dir)
  if #extras == 0 then
    return current
  end
  local prefix = table.concat(extras, ":")
  if type(current) == "string" and current ~= "" then
    return prefix .. ":" .. current
  end
  return prefix
end

function M.reload()
  cache = nil
end

return M
