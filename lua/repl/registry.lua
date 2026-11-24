local M = {}

M.default_config_path = vim.fn.stdpath("data") .. "/repl/backends.json"

M.filetype_family = {
  python = "python",
  r = "r",
  rmd = "r",
  quarto = "r",
  rnoweb = "r",
  rhelp = "r",
  rout = "r",
  lua = "lua",
  octave = "octave",
  sage = "sage",
}

local function config_path()
  local config = require("repl.config").get()
  return config.backend_config or vim.env.NVIM_REPL_BACKEND_CONFIG or vim.g.ub_repl_backend_config or M.default_config_path
end

local function normalize_family(value)
  if type(value) ~= "string" then
    return nil
  end

  local normalized = value:lower()
  if normalized == "r" or normalized == "python" or normalized == "lua" or normalized == "octave" or normalized == "sage" or normalized == "other" then
    return normalized
  end

  return nil
end

local function normalize_engine(value)
  if type(value) ~= "string" then
    return nil
  end

  local normalized = value:lower()
  if normalized == "iron" or normalized == "slime" or normalized == "r_nvim" or normalized == "neopyter" then
    return normalized
  end

  return nil
end

local function decode_json_file(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local raw = table.concat(vim.fn.readfile(path), "\n")
  if raw == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    vim.notify("Could not read REPL backend config: " .. tostring(path), vim.log.levels.WARN)
    return nil
  end

  return decoded
end

local function config_entries(config)
  if type(config) ~= "table" then
    return {}
  end

  if vim.islist(config) then
    return config
  end

  if type(config.filetypes) == "table" then
    return config.filetypes
  end

  return {}
end

function M.load()
  local config = decode_json_file(config_path())
  local registry = {
    family_defaults = {},
    filetype_backend = {},
    filetype_family = vim.deepcopy(M.filetype_family),
  }

  for family, engine in pairs((type(config) == "table" and config.families) or {}) do
    local normalized_family = normalize_family(family)
    local normalized_engine = normalize_engine(type(engine) == "table" and engine.engine or engine)
    if normalized_family and normalized_engine then
      registry.family_defaults[normalized_family] = normalized_engine
    end
  end

  for family, backend in pairs({ python = "slime", r = "slime", lua = "slime", octave = "slime", sage = "slime", other = "slime" }) do
    registry.family_defaults[family] = registry.family_defaults[family] or backend
  end

  for _, entry in ipairs(config_entries(config)) do
    if type(entry) == "table" and type(entry.filetype) == "string" then
      local filetype = entry.filetype:lower()
      local family = normalize_family(entry.family) or registry.filetype_family[filetype] or normalize_family(filetype) or "other"
      local engine = normalize_engine(entry.engine or entry.backend)

      registry.filetype_family[filetype] = family
      if engine then
        registry.filetype_backend[filetype] = engine
        registry.family_defaults[family] = registry.family_defaults[family] or engine
      end
    end
  end

  return registry
end

function M.family_for_filetype(filetype)
  local normalized = type(filetype) == "string" and filetype:lower() or ""
  return M.load().filetype_family[normalized] or "other"
end

function M.backend_for_filetype(filetype)
  local normalized = type(filetype) == "string" and filetype:lower() or ""
  return M.load().filetype_backend[normalized]
end

function M.default_backend_for_family(family)
  return M.load().family_defaults[family]
end

function M.is_repl_filetype(filetype)
  return M.family_for_filetype(filetype) ~= "other"
end

return M
