-- Single source of truth for REPL runtime paths (sockets, focus state, tmux
-- target) across Mac and Sinclair.
--
-- Before this module the rule was restated in seven places (three Lua, four
-- shell) and they had already drifted: Neovim resolved
-- `unix:/tmp/dl-repl-kitty.sock` on Mac while the launcher created
-- `/tmp/dl-repl-kitty-501.sock`, and focus state was split between `/tmp` and
-- `$TMPDIR`. Every consumer must call this module; the shell side calls the
-- byte-identical port in `bin/dl_repl_paths.py`, pinned by
-- `nvim/tests/repl_paths_parity_smoke.sh`.
--
-- Invariant: on Linux every value here is byte-identical to what the old
-- inline expressions produced, so Sinclair is unaffected.

local M = {}

-- Socket basename per family. Kept as data so the Python port can mirror it.
local FAMILY_BASE = {
	python = "dl-repl",
	r = "dl-r-repl",
	lua = "dl-lua-repl",
}

-- Per-family user override. Distinct from DL_REPL_SOCKET, which dl-session-env
-- *exports* — a variable the tooling writes cannot also mean "the user pinned
-- this", so the override gets its own name.
local FAMILY_OVERRIDE = {
	python = "DL_REPL_SOCKET_OVERRIDE",
	r = "DL_R_REPL_SOCKET_OVERRIDE",
	lua = "DL_LUA_REPL_SOCKET_OVERRIDE",
}

-- Session-scoped socket exported by mac/dl-session-env, consumed but never
-- written here.
local FAMILY_SESSION = {
	python = "DL_REPL_SOCKET",
	r = "DL_R_REPL_SOCKET",
	lua = "DL_LUA_REPL_SOCKET",
}

M.families = { "python", "r", "lua" }

local function env(name)
	local value = vim.env[name]
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function M.sysname()
	-- DL_REPL_PATHS_SYSNAME lets one host exercise the other's branch in tests.
	return env("DL_REPL_PATHS_SYSNAME") or (vim.uv or vim.loop).os_uname().sysname
end

function M.is_darwin()
	return M.sysname() == "Darwin"
end

--- Runtime directory for sockets and focus state.
---
--- Deliberately does NOT consult TMPDIR. On macOS TMPDIR is per-login-session
--- (`/var/folders/<hash>/T/`), so a launchd, cron or ssh context resolves a
--- different directory than the GUI session and silently stops seeing its
--- sockets. `/tmp` is stable across all of them; uid qualification (below)
--- covers the multi-user case that XDG_RUNTIME_DIR handles on Linux.
function M.runtime_dir()
	return env("DL_RUNTIME_DIR") or env("XDG_RUNTIME_DIR") or "/tmp"
end

function M.uid()
	local override = env("DL_REPL_PATHS_UID")
	if override then
		return tonumber(override) or 0
	end
	return (vim.uv or vim.loop).getuid()
end

--- Sanitised session namespace, or nil.
--- Mirrors mac/dl-session-env: `tr -cs 'A-Za-z0-9._-' '-'` then strip edges.
--- Sinclair has no dl-session-env, so namespaces are Darwin-only and Linux
--- socket names are unchanged by this feature.
function M.namespace()
	local raw = env("DL_SESSION_NAMESPACE")
	if not raw or not M.is_darwin() then
		return nil
	end
	local safe = raw:gsub("[^A-Za-z0-9._-]+", "-")
	safe = safe:gsub("^%-+", ""):gsub("%-+$", "")
	if safe == "" then
		return nil
	end
	return safe
end

local function socket_for(base, family)
	local override = family and env(FAMILY_OVERRIDE[family] or "")
	if override then
		return override
	end
	local session = family and env(FAMILY_SESSION[family] or "")
	if session then
		return session
	end

	local runtime = M.runtime_dir()
	if not M.is_darwin() then
		-- Byte-identical to the pre-resolver expression on Sinclair.
		return "unix:" .. runtime .. "/" .. base .. "-kitty.sock"
	end

	-- /tmp is shared between users on macOS, so qualify by uid; the namespace
	-- suffix keeps `dl2`/`dl3` sessions from binding each other's REPLs.
	local name = base .. "-kitty-" .. tostring(M.uid())
	local namespace = M.namespace()
	if namespace then
		name = name .. "-" .. namespace
	end
	return "unix:" .. runtime .. "/" .. name .. ".sock"
end

function M.socket(family)
	local base = FAMILY_BASE[family]
	if not base then
		return nil
	end
	return socket_for(base, family)
end

function M.edit_socket()
	local override = env("DL_EDIT_SOCKET_OVERRIDE")
	if override then
		return override
	end
	local session = env("DL_EDIT_SOCKET")
	if session then
		return session
	end
	return socket_for("dl-edit", nil)
end

function M.state_file()
	return env("DL_FOCUS_SLIME_STATE_FILE") or (M.runtime_dir() .. "/kitty-focus-slime-target.json")
end

function M.registry_file()
	return env("DL_FOCUS_SLIME_REGISTRY_FILE")
		or env("DL_FOCUS_SLIME_PAIR_FILE")
		or (M.runtime_dir() .. "/kitty-focus-slime-pair.json")
end

-- CCC gives every kitty OS window its own control socket (kitty.conf
-- `listen_on unix:/tmp/kitty-focus.sock` -> `kitty-focus.sock-<pid>`). Probing
-- those lets a REPL pair itself to an agent pane, so they are excluded by name
-- -- not by requiring a `dl-` prefix, because focus resolution must still find
-- non-canonical kitty instances (a plain `regular-r-kitty.sock` holding an R
-- session), which is how a focused non-dl REPL overrides stale family state.
M.socket_excludes = { "kitty-focus.sock" }

--- Glob patterns for "other kitty sockets worth probing".
function M.socket_globs()
	return { "/*kitty*.sock", "/*kitty*.sock-*" }
end

--- True for sockets that must never be probed.
function M.socket_excluded(path)
	local name = vim.fn.fnamemodify(path, ":t")
	for _, prefix in ipairs(M.socket_excludes) do
		if name:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

function M.tmux_target()
	local explicit = env("NVIM_SLIME_TMUX_REPL_TARGET")
	if explicit then
		return explicit
	end
	local namespace = M.namespace()
	if namespace then
		return "dlmain-" .. namespace .. ":1"
	end
	return "dlmain:1"
end

--- Everything the parity test compares against bin/dl_repl_paths.py.
function M.dump()
	local sockets = {}
	for _, family in ipairs(M.families) do
		sockets[family] = M.socket(family)
	end
	return {
		sysname = M.sysname(),
		runtime_dir = M.runtime_dir(),
		namespace = M.namespace() or "",
		sockets = sockets,
		edit_socket = M.edit_socket(),
		state_file = M.state_file(),
		registry_file = M.registry_file(),
		socket_globs = M.socket_globs(),
		tmux_target = M.tmux_target(),
	}
end

return M
