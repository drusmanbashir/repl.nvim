-- Cache by socket so send and focus share a single window-tree query.
-- Invalidate on mutations and refresh before reporting a missing child.
local kitty_rpc = require("repl.kitty_rpc")
local uv = vim.uv

local M = {}

-- Long enough that one user action pays a single round trip, short enough that
-- a window closed by hand outside Neovim cannot linger.
M.ttl_ms = 2000

local cache = {}
local stats = { hits = 0, misses = 0, refreshes = 0, socket = 0, cli = 0 }

local function now_ms()
  return uv.hrtime() / 1e6
end

local function fetch(listen_on)
  local data, err = kitty_rpc.request(listen_on, "ls")
  if not data then return nil, err end
  local ok, tree = pcall(vim.json.decode, data)
  if not ok or type(tree) ~= "table" then
    return nil, "invalid Kitty ls payload"
  end
  stats.socket = stats.socket + 1
  return tree
end

--- Drop the cached tree for one socket. Call after ANY kitty command that
--- changes a window's title, existence, or tab.
function M.invalidate(listen_on)
  if listen_on == nil then
    cache = {}
    return
  end
  cache[listen_on] = nil
end

function M.invalidate_all()
  cache = {}
end

--- Uncached read. For poll loops that are waiting for the tree to change.
function M.fresh(listen_on)
  local tree, err = fetch(listen_on)
  cache[listen_on] = tree and { tree = tree, stamp = now_ms() } or nil
  return tree, err
end

--- Cached read.
function M.get(listen_on, opts)
  opts = opts or {}
  if type(listen_on) ~= "string" or listen_on == "" or listen_on == "?" then
    return nil, "no kitty socket"
  end
  local entry = cache[listen_on]
  local ttl = opts.ttl_ms or M.ttl_ms
  if not opts.force and entry and (now_ms() - entry.stamp) < ttl then
    stats.hits = stats.hits + 1
    return entry.tree
  end
  stats.misses = stats.misses + 1
  return M.fresh(listen_on)
end

--- Every window on this socket, flattened out of the OS-window/tab nesting.
function M.windows(tree)
  local out = {}
  for _, os_window in ipairs(tree or {}) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        out[#out + 1] = window
      end
    end
  end
  return out
end

local function find(tree, window_id)
  for _, window in ipairs(M.windows(tree)) do
    if tonumber(window.id) == window_id then
      return window
    end
  end
end

--- Look one window up by id. A miss forces exactly one refresh before
--- reporting the window gone: a REPL launched by <leader>in seconds ago is
--- absent from a stale tree, and treating that as "no such window" is what
--- would break launching.
function M.window(listen_on, window_id)
  window_id = tonumber(window_id)
  if not window_id then
    return nil, "no window id"
  end
  local tree, err = M.get(listen_on)
  if not tree then
    return nil, err
  end
  local window = find(tree, window_id)
  if window then
    return window
  end
  if cache[listen_on] then
    stats.refreshes = stats.refreshes + 1
    tree, err = M.fresh(listen_on)
    if not tree then
      return nil, err
    end
    window = find(tree, window_id)
    if window then
      return window
    end
  end
  return nil, string.format("kitty window %d not found on %s", window_id, tostring(listen_on))
end

--- Test seam: tests/kitty_tree_cache_smoke.sh asserts on these counters.
function M._test_stats()
  return vim.deepcopy(stats)
end

function M._test_reset()
  cache = {}
  stats = { hits = 0, misses = 0, refreshes = 0, socket = 0, cli = 0 }
end

return M
