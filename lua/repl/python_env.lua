local M = {}

local CONFIG_PATH = vim.fn.stdpath("data") .. "/repl/python-envs.json"
local cache = {}
local FALLBACK_ENV = "dl"
local pending_prompt = {}
local declined_prompt = {}

local function config_path()
  if type(vim.g.ub_repl_python_envs_path) == "string" and vim.g.ub_repl_python_envs_path ~= "" then
    return vim.g.ub_repl_python_envs_path
  end
  local configured = require("repl.config").get().python_envs
  return configured or CONFIG_PATH
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok then
    return data
  end
  return nil
end

local function conda_base()
  -- Build without nil holes: ipairs stops at the first nil, so a missing
  -- CONDA_EXE used to skip ~/mambaforge entirely (oracle/kitty launches).
  local candidates = {}
  if vim.env.CONDA_EXE and vim.env.CONDA_EXE ~= "" then
    candidates[#candidates + 1] = vim.fn.fnamemodify(vim.env.CONDA_EXE, ":h:h")
  end
  for _, base in ipairs({
    vim.fn.expand("~/mambaforge"),
    vim.fn.expand("~/miniconda3"),
    vim.fn.expand("~/miniforge3"),
  }) do
    candidates[#candidates + 1] = base
  end
  for _, base in ipairs(candidates) do
    if base and base ~= "" and vim.fn.isdirectory(base) == 1 then
      return base
    end
  end
  return nil
end

local function project_root(path)
  if not path or path == "" then
    return nil
  end
  return vim.fs.root(path, { "pyproject.toml", "setup.py", "setup.cfg", ".git" })
end

local function context_root(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = project_root(path)
  if root then
    return root
  end
  local cwd = vim.fn.getcwd()
  if cwd and cwd ~= "" then
    return project_root(cwd) or cwd
  end
  return nil
end

function M.context_root(bufnr)
  return context_root(bufnr)
end

local function load_config()
  if cache.config then
    return cache.config
  end
  cache.config = read_json(config_path()) or { default_env = FALLBACK_ENV, projects = {} }
  return cache.config
end

local function write_config(cfg)
  local lines = {
    "{",
    string.format('  "default_env": %s,', vim.json.encode(cfg.default_env or FALLBACK_ENV)),
    '  "projects": [',
  }
  local projects = cfg.projects or {}
  for i, entry in ipairs(projects) do
    local comma = i < #projects and "," or ""
    lines[#lines + 1] = string.format(
      '    { "match": %s, "conda_env": %s }%s',
      vim.json.encode(entry.match),
      vim.json.encode(entry.conda_env),
      comma
    )
  end
  lines[#lines + 1] = "  ]"
  lines[#lines + 1] = "}"
  vim.fn.writefile(lines, config_path())
end

-- nvim/configs/repl-python-envs.json is written with Sinclair's absolute paths. Rather
-- than fork a second Mac config (two sources of truth for which conda env a
-- project uses), translate the code-root prefix to this host's. Exact no-op on
-- Sinclair, where the two roots are the same string -- and without it every Mac
-- buffer fell through to default_env, so `{env}-repl` titles collapsed to
-- `dl-repl` and the env filter could never tell an agent REPL from a dl one.
local CONFIG_CODE_ROOT = "/home/ub/code"

local function local_code_root()
  if vim.env.NVIM_CODE_ROOT and vim.env.NVIM_CODE_ROOT ~= "" then
    return vim.env.NVIM_CODE_ROOT
  end
  return vim.fn.expand("~/code")
end

--- Every prefix a config entry should match against on this host.
function M.match_prefixes(match)
  if type(match) ~= "string" or match == "" then
    return {}
  end
  local prefixes = { match }
  local root = local_code_root()
  if root ~= CONFIG_CODE_ROOT and vim.startswith(match, CONFIG_CODE_ROOT .. "/") then
    table.insert(prefixes, root .. match:sub(#CONFIG_CODE_ROOT + 1))
  end
  return prefixes
end

local function match_project(root)
  local cfg = load_config()
  if not root then
    return nil
  end
  local best, best_len = nil, -1
  for _, entry in ipairs(cfg.projects or {}) do
    for _, prefix in ipairs(M.match_prefixes(entry.match)) do
      if vim.startswith(root, prefix) then
        if #prefix > best_len then
          best, best_len = entry, #prefix
        end
        break
      end
    end
  end
  return best
end

--- Pairing key = first-level folder under ~/code/ only.
--- Rule: every repo lives directly under ~/code/; never scope to nested
--- .git / pyproject roots (e.g. ~/code/llm/rag-from-scratch → ~/code/llm).
function M.pairing_scope(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  local code = local_code_root()
  if not vim.startswith(path, code .. "/") then
    return nil
  end
  local rest = path:sub(#code + 2)
  local first = rest:match("^[^/]+")
  if not first or first == "" then
    return nil
  end
  return code .. "/" .. first
end

local function configured_env_name(root)
  local entry = match_project(root)
  if entry and entry.conda_env and entry.conda_env ~= "" then
    return entry.conda_env
  end
  local cfg = load_config()
  local default_env = cfg.default_env
  if type(default_env) == "string" and default_env ~= "" then
    return default_env
  end
  return FALLBACK_ENV
end

--- The conda env EXPLICITLY mapped to a file path, or nil when nothing matches.
---
--- `resolve` folds "unmapped" into `default_env`, which a caller holding no
--- source buffer (the DAP sidecar) cannot tell from a real mapping; it also
--- refuses to answer at all when the env's python is missing. This accessor
--- answers the mapping question only, so the caller can decide between falling
--- back and refusing.
function M.env_for_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local entry = match_project(vim.fs.normalize(path))
  if not entry or type(entry.conda_env) ~= "string" or entry.conda_env == "" then
    return nil
  end
  local base = conda_base()
  if not base then
    return nil
  end
  local prefix = base .. "/envs/" .. entry.conda_env
  return {
    env_name = entry.conda_env,
    prefix = prefix,
    python = prefix .. "/bin/python",
    ipython = prefix .. "/bin/ipython",
  }
end

function M.resolve(root)
  root = root or context_root(0)
  if not root then
    return nil
  end
  if cache[root] then
    return cache[root]
  end
  local env_name = configured_env_name(root)
  local base = conda_base()
  if not base then
    return nil
  end
  local prefix = base .. "/envs/" .. env_name
  local python = prefix .. "/bin/python"
  local ipython = prefix .. "/bin/ipython"
  -- Prefer filereadable: some headless/oracle launches report executable()==0
  -- for conda bins even when the path is present and runnable.
  if vim.fn.filereadable(python) ~= 1 and vim.fn.executable(python) ~= 1 then
    return nil
  end
  if vim.fn.filereadable(ipython) ~= 1 and vim.fn.executable(ipython) ~= 1 then
    ipython = python
  end
  local resolved = {
    env_name = env_name,
    prefix = prefix,
    python = python,
    ipython = ipython,
    root = root,
  }
  cache[root] = resolved
  return resolved
end

function M.resolve_for_buffer(bufnr)
  return M.resolve(context_root(bufnr))
end

function M.python_path(root)
  local r = M.resolve(root)
  if r then
    return r.python
  end
  return nil
end

function M.ipython_cmd(root)
  local r = M.resolve(root)
  if r then
    return r.ipython
  end
  return nil
end

function M.env_name(root)
  root = root or context_root(0)
  if not root then
    return FALLBACK_ENV
  end
  return configured_env_name(root)
end

function M.repl_title_base(root)
  return M.env_name(root) .. "-repl"
end

function M.list_conda_envs()
  local base = conda_base()
  if not base then
    return {}
  end
  local envs_dir = base .. "/envs"
  if vim.fn.isdirectory(envs_dir) ~= 1 then
    return {}
  end
  local out = {}
  for _, name in ipairs(vim.fn.readdir(envs_dir) or {}) do
    if vim.fn.isdirectory(envs_dir .. "/" .. name) == 1 then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

function M.add_pairing(match, conda_env)
  assert(type(match) == "string" and match ~= "", "match required")
  assert(type(conda_env) == "string" and conda_env ~= "", "conda_env required")
  local cfg = load_config()
  for _, entry in ipairs(cfg.projects or {}) do
    if entry.match == match then
      entry.conda_env = conda_env
      write_config(cfg)
      M.reload()
      return
    end
  end
  table.insert(cfg.projects, 1, { match = match, conda_env = conda_env })
  write_config(cfg)
  M.reload()
end

local function prompt_disabled()
  if vim.g.ub_repl_env_no_prompt then
    return true
  end
  if vim.env.LIVE_ORACLE_LUA or vim.env.LIVE_HARNESS_LUA then
    return true
  end
  if #vim.api.nvim_list_uis() == 0 then
    return true
  end
  return false
end

--- Ask which conda env to permanently pair with this ~/code root when unmapped.
function M.maybe_prompt_pairing(bufnr)
  if prompt_disabled() then
    return
  end
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or path:match("^%w+://") then
    return
  end
  local scope = M.pairing_scope(path)
  if not scope then
    return
  end
  if match_project(scope) then
    return
  end
  if pending_prompt[scope] or declined_prompt[scope] then
    return
  end
  pending_prompt[scope] = true
  vim.schedule(function()
    local envs = M.list_conda_envs()
    if #envs == 0 then
      pending_prompt[scope] = nil
      vim.notify("No conda envs found to pair with " .. scope, vim.log.levels.WARN)
      return
    end
    vim.ui.select(envs, { prompt = "Conda env for " .. scope }, function(choice)
      pending_prompt[scope] = nil
      if not choice then
        declined_prompt[scope] = true
        return
      end
      M.add_pairing(scope, choice)
      vim.notify(string.format("Paired %s → %s", scope, choice), vim.log.levels.INFO)
    end)
  end)
end

function M.setup()
  if vim.g.ub_repl_python_env_setup then
    return
  end
  vim.g.ub_repl_python_env_setup = true
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("ub_repl_python_env_pairing", { clear = true }),
    pattern = { "*.py", "*.ipynb", "*.pyi" },
    callback = function(ev)
      M.maybe_prompt_pairing(ev.buf)
    end,
  })
end

function M.reload()
  cache = {}
end

return M
