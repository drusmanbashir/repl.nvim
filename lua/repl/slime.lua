local M = {}

function M.init()
    local target = vim.env.NVIM_SLIME_TARGET or require("repl.config").get().target or "kitty"
    local tmux_repl_target = vim.env.NVIM_SLIME_TMUX_REPL_TARGET or "dlmain:1"
    vim.g.slime_target = target
    vim.g.slime_no_mappings = 1
    vim.g.slime_bracketed_paste = 1
    vim.g.slime_preserve_curpos = 1
    -- IPython needs bracketed paste, otherwise pasted blocks get auto-indented line by line.
    vim.g.slime_python_ipython = 0
    -- Ruling 2026-10-02: an indented `# %%` splits cells too (repl.cell).
    vim.g.slime_cell_delimiter = [[^\s*#\s*%%]]
    vim.g.slime_tmux_repl_target = vim.g.slime_tmux_repl_target or tmux_repl_target
    if target == "kitty" then
      vim.g.slime_default_config = {
        window_id = tonumber(vim.env.NVIM_SLIME_KITTY_WINDOW_ID) or 1,
        listen_on = vim.env.NVIM_SLIME_KITTY_LISTEN_ON or vim.env.KITTY_LISTEN_ON or "",
      }
    else
      vim.g.slime_default_config = {
        socket_name = "default",
        target_pane = "{last}",
      }
    end
    vim.g.slime_dont_ask_default = 1
    -- Where alt+h goes is decided in one place (repl.focus_route): debug
    -- sidecar while a session is live, the JupyterLab browser window for a
    -- connected Neopyter notebook, otherwise the bound Slime REPL. This keymap
    -- owns none of that -- it presses the key.
    vim.keymap.set({ "n", "i", "v", "s" }, "<M-h>", function()
      require("repl.focus_route").focus()
    end, { silent = true, desc = "Focus this buffer's REPL (debug sidecar / JupyterLab / Slime)" })
end

function M.setup()
    if M._setup then return true end
    local keymap = vim.keymap.set
    local discovery = require("repl.kitty_discovery").new()
    local repl_title_matches = discovery.repl_title_matches
    local filter_windows_matching_env = discovery.filter_windows_matching_env
    local window_matches_env = discovery.window_matches_env
    local repl_kitty_windows = discovery.repl_kitty_windows
    local ipython_sessions = discovery.ipython_sessions
    local r_sessions = discovery.r_sessions
    local repl_actions = require("repl.actions")
    local repl_backend = require("repl")
    local repl_focus = require("repl.focus")
    local repl_sections = require("repl.sections")
    local tmux_pane_format = "#{pane_id}\t#{pane_current_command}\t#{pane_start_command}"
    local host_paths = require("repl.config")
    local kitty_bin = host_paths.kitty_bin()
    local repl_restart_helper = vim.env.NVIM_SLIME_REPL_RESTART_HELPER
      or host_paths.get().repl_restart_helper
    local ipython_start_command = vim.env.NVIM_SLIME_IPYTHON_START_COMMAND
      or require("repl.specs").slime_kitty_spec("python").start_command

    local slime_format = require("repl.python.slime_format")
    -- Set by send_cell for the one payload slime#send_cell is about to make:
    -- the next cell continues this cell's block (repl_cell.next_cell_continues).
    local cell_continues_next = false
    -- REPL_ROUTING.md § `M-x` cell-send contract: a block a payload leaves open
    -- is continued by the next payload to the SAME REPL, so the formatter is
    -- told which REPL this buffer's payload goes to (vim-slime calls this after
    -- resolving b:slime_config).
    _G.ub_slime_escape_python = function(text)
      local config = vim.b.slime_config or {}
      local target = tostring(config.listen_on or config.socket_name or "")
        .. "#" .. tostring(config.window_id or config.target_pane or "")
      local bracketed = (vim.b.slime_bracketed_paste or vim.g.slime_bracketed_paste or 0) ~= 0
      return slime_format.ipython_text(text, target, bracketed, cell_continues_next)
    end

    _G.ub_slime_send = function(config, text)
      local target = vim.fn["slime#config#resolve"]("target")
      local send = vim.fn["slime#targets#" .. target .. "#send"]
      if vim.bo.filetype ~= "python" or not cell_continues_next
        or vim.fn["slime#config#resolve"]("bracketed_paste") == 0 then
        return send(config, text)
      end
      -- vim-slime converts a trailing LF into Enter even without a CR.
      -- Keep every held newline inside one paste; let the target send it raw.
      local bracketed = vim.b.slime_bracketed_paste
      vim.b.slime_bracketed_paste = 0
      local ok, err = pcall(send, config, "\27[200~" .. text .. "\27[201~")
      vim.b.slime_bracketed_paste = bracketed
      if not ok then
        error(err, 0)
      end
    end

    vim.cmd([[
      function! SlimeOverride_EscapeText_python(text) abort
        return v:lua.ub_slime_escape_python(a:text)
      endfunction
      function! SlimeOverrideSend(config, text) abort
        call v:lua.ub_slime_send(a:config, a:text)
      endfunction
    ]])

    local function focus_dap_repl()
      local ok_dapui, dapui = pcall(require, "dapui")
      if ok_dapui then
        dapui.open()
      end

      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "dap-repl" then
          vim.api.nvim_set_current_win(win)
          return true
        end
      end

      return false
    end

    local function send_to_dap_repl(text, focus)
      local ok_console, console = pcall(require, "dap-sidecar.extensions.python.console")
      local console_ok, available = false, false
      if ok_console then console_ok, available = pcall(console.available) end
      if console_ok and available then
        console.send_text(text)
        if focus then
          console.open()
        end
        return true
      end

      local ok_dap, dap = pcall(require, "dap")
      if not ok_dap or dap.session() == nil then
        return false
      end

      dap.repl.execute(text)
      if focus then
        focus_dap_repl()
      end

      return true
    end

    -- R-SEND-03, shared source-send contract: one shared, MODE-aware
    -- reader (charwise, linewise and blockwise) so the debug console and the
    -- kitty REPL are handed the same characters. The hand-rolled charwise trim
    -- this replaced sent a <C-v> rectangle as whole first/last lines.
    local function get_visual_selection()
      return require("repl.send_context").visual_selection()
    end

    local function current_cell_delimiter()
      return vim.b.slime_cell_delimiter or vim.g.slime_cell_delimiter
    end

    local function current_slime_family()
      return repl_backend.family_for_filetype(vim.bo.filetype or "")
    end

    local function slime_state_name(suffix, family)
      return "ub_slime_kitty_" .. suffix .. "_" .. family
    end

    local function read_slime_family_state(family)
      return {
        listen_on = vim.g[slime_state_name("listen_on", family)],
        registered = vim.g[slime_state_name("registered", family)],
        window_id = tonumber(vim.g[slime_state_name("window_id", family)] or ""),
      }
    end

    local function clear_slime_family_state(family)
      vim.g[slime_state_name("window_id", family)] = nil
      vim.g[slime_state_name("listen_on", family)] = nil
      vim.g[slime_state_name("registered", family)] = false
    end

    local function parse_pane_line(line)
      return (line or ""):match("^([^\t]+)\t([^\t]*)\t(.*)$")
    end

    local function is_ipython_pane(text)
      return text:find("ipython", 1, true) ~= nil
    end

    local function find_ipython_pane(target)
      local lines = vim.fn.systemlist({ "tmux", "list-panes", "-t", target, "-F", tmux_pane_format })
      for _, line in ipairs(lines) do
        local pane_id, cmd, start = parse_pane_line(line)
        if pane_id and is_ipython_pane(line) then
          return pane_id, cmd, start
        end
      end
    end

    local function pane_info(target)
      local lines = vim.fn.systemlist({ "tmux", "display-message", "-p", "-t", target, tmux_pane_format })
      if vim.v.shell_error ~= 0 then
        return nil
      end
      return parse_pane_line(lines[1])
    end

    local function resolve_tmux_repl_pane()
      local target = vim.g.slime_tmux_repl_target or vim.env.NVIM_SLIME_TMUX_REPL_TARGET or "dlmain:1"
      local pane_id, cmd, start = find_ipython_pane(target)
      if pane_id then
        return pane_id, cmd, start
      end
      pane_id, cmd, start = pane_info(target)
      if pane_id then
        return pane_id, cmd, start
      end
      pane_id, cmd, start = find_ipython_pane(":repl")
      if pane_id then
        return pane_id, cmd, start
      end
      return pane_info(":repl")
    end

    local function ensure_tmux_repl_pane()
      local pane_id = resolve_tmux_repl_pane()

      if not pane_id or pane_id == "" then
        vim.notify("Could not find tmux repl pane for vim-slime", vim.log.levels.WARN)
        return false
      end

      vim.b.slime_config = {
        socket_name = "default",
        target_pane = pane_id,
      }

      return true
    end

    local function kitty_rpc(listen_on, args, input)
      local cmd = { kitty_bin, "@", "--to", listen_on }
      vim.list_extend(cmd, args)
      local output = vim.fn.system(cmd, input)
      if vim.v.shell_error ~= 0 then
        return nil, output
      end
      return output
    end

    -- Last reason a `kitty @ ls` failed, kept so a failed RPC can never be
    -- reported as "no REPL window". A whole session was lost to that
    -- confusion: Neovim had run out of file descriptors (a plugin leaking one
    -- unix socket per request), so every shell-out and every job spawn failed
    -- process-wide, and the only symptom the user saw was this file claiming
    -- the live `agent-repl-1` window did not exist.
    local last_kitty_rpc_error = nil

    -- Neovim cannot spawn anything once its fd table is full, so name that
    -- directly rather than leaving the operator to guess from a kitty error.
    local function fd_pressure()
      local fd_dir = "/proc/self/fd"
      if vim.fn.isdirectory(fd_dir) ~= 1 then
        return nil
      end
      local open = 0
      local ok = pcall(function()
        for _ in vim.fs.dir(fd_dir) do
          open = open + 1
        end
      end)
      if not ok then
        return nil
      end
      local limit = nil
      local handle = io.open("/proc/self/limits", "r")
      if handle then
        for line in handle:lines() do
          limit = tonumber(line:match("^Max open files%s+(%d+)")) or limit
        end
        handle:close()
      end
      if not limit or open < limit - 32 then
        return nil
      end
      return string.format("this Neovim is out of file descriptors (%d/%d open); restart it", open, limit)
    end

    local kitty_cache = require("repl.kitty_tree")

    -- Cached; repl/focus.lua reads the same cache, so a send no longer asks
    -- kitty the same question twice. Any mutation below calls
    -- kitty_cache.invalidate(), and the poll loops call fresh().
    local function kitty_tree(listen_on, opts)
      local tree, rpc_error = kitty_cache.get(listen_on, opts)
      if not tree then
        last_kitty_rpc_error = string.format(
          "kitty @ --to %s ls failed: %s",
          tostring(listen_on),
          tostring(rpc_error or ""):gsub("%s+", " ")
        )
        return nil
      end
      last_kitty_rpc_error = nil
      return tree
    end

    local function kitty_tree_fresh(listen_on)
      return kitty_tree(listen_on, { force = true })
    end

    local function kitty_window_by_id(tree, id)
      id = tonumber(id)
      if not id then
        return nil
      end
      for _, os_window in ipairs(tree or {}) do
        for _, tab in ipairs(os_window.tabs or {}) do
          for _, window in ipairs(tab.windows or {}) do
            if tonumber(window.id) == id then
              return window
            end
          end
        end
      end
    end

    local function write_slime_focus_target(listen_on, window_id, family)
      repl_focus.publish_target({
        backend = require("repl").current(),
        family = family,
        listen_on = listen_on,
        window_id = window_id,
      })
    end

    local function should_publish_slime_focus_target()
      if vim.g.slime_target ~= "kitty" then
        return false
      end
      if vim.bo.buftype ~= "" then
        return false
      end
      if not require("repl.registry").is_repl_filetype(vim.bo.filetype or "") then
        return false
      end
      -- A buffer whose REPL is a connected JupyterLab has no kitty target, and
      -- must not publish the family's as if it had one. Managed `.ipynb`
      -- buffers are already excluded by their `acwrite` buftype above; a `.py`
      -- synced to Lab is not, and used to advertise a kitty REPL that its own
      -- sends never go to -- two answers on disk to "what is this buffer's
      -- REPL". The published target then fed OS-level `alt+h` and `dl-repl`.
      -- The paths are mutually exclusive, not merely preferred:
      -- REPL_ROUTING.md § `<M-h>` destinations.
      if require("repl.router").neopyter_buffer(vim.api.nvim_get_current_buf()) then
        return false
      end
      return true
    end

    local function bind_kitty_repl(listen_on, window_id, family)
      window_id = tonumber(window_id)
      if not window_id then
        return false
      end

      local current = vim.b.slime_config
      if type(current) == "table"
        and current.family == family
        and current.listen_on == listen_on
        and tonumber(current.window_id or "") == window_id then
        local target = {
          backend = "slime",
          family = family,
          target = "kitty",
          listen_on = listen_on,
          window_id = window_id,
        }
        repl_focus.claim_route(repl_focus.resolve_target(target) or target)
        return true
      end

      vim.b.slime_config = {
        family = family,
        window_id = window_id,
        listen_on = listen_on,
      }
      vim.g[slime_state_name("window_id", family)] = window_id
      vim.g[slime_state_name("listen_on", family)] = listen_on
      vim.g[slime_state_name("registered", family)] = true
      write_slime_focus_target(listen_on, window_id, family)
      repl_focus.emit_changed({
        backend = "slime",
        family = family,
        target = "kitty",
        listen_on = listen_on,
        window_id = window_id,
      })
      return true
    end

    local current_kitty_target
    local repl_kitty_windows_for

    local function publish_active_slime_focus_target()
      if vim.g.slime_target ~= "kitty" then
        return
      end
      if vim.bo.buftype ~= "" then
        return
      end

      local family = current_slime_family()
      -- Always publish family so OS M-h / dl-repl focus can no-op on non-python
      -- buffers (previously non-repl BufEnter left stale family=python).
      if not should_publish_slime_focus_target() or repl_backend.current() ~= "slime" then
        write_slime_focus_target(nil, nil, family)
        return
      end

      local buffer_config = vim.b.slime_config or {}
      if buffer_config.family == family and buffer_config.listen_on and buffer_config.window_id then
        write_slime_focus_target(buffer_config.listen_on, buffer_config.window_id, family)
        return
      end

      local family_state = read_slime_family_state(family)
      if family_state.listen_on and family_state.window_id then
        write_slime_focus_target(family_state.listen_on, family_state.window_id, family)
        return
      end

      write_slime_focus_target(nil, nil, family)
    end

    local function send_kitty_text(listen_on, window_id, text)
      return kitty_rpc(listen_on, { "send-text", "--match", "id:" .. tostring(window_id), "--stdin" }, text) ~= nil
    end

    local family_session_label = {
      python = "IPython",
      r = "R",
    }

    local function select_session(family, sessions)
      local label = family_session_label[family] or family
      local choices = { "Select " .. label .. " session:" }
      for i, session in ipairs(sessions) do
        table.insert(choices, string.format("%d. %s", i, session.label))
      end

      local choice = vim.fn.inputlist(choices)
      return sessions[choice]
    end

    local function generic_sessions(windows, family)
      local sessions = {}
      for _, window in ipairs(windows or {}) do
        local context = window._ub_repl_context or {}
        table.insert(sessions, {
          window_id = window.id,
          listen_on = context.listen_on,
          label = (context.os_window_name or context.window_title or "kitty window") .. " " .. family,
        })
      end
      return sessions
    end

    local function family_sessions(family, windows)
      if family == "python" then return ipython_sessions(windows) end
      if family == "r" then return r_sessions(windows) end
      return generic_sessions(windows, family)
    end

    local function next_repl_window_title(base_title, windows)
      local max_suffix = 0
      local escaped = vim.pesc(base_title)

      for _, window in ipairs(windows or {}) do
        local context = window._ub_repl_context or {}
        for _, candidate in ipairs({ context.os_window_name, context.window_title }) do
          if candidate == base_title then
            max_suffix = math.max(max_suffix, 1)
          else
            local suffix = candidate and (candidate:match("^" .. escaped .. "%-(%d+)$") or candidate:match("^" .. escaped .. "%s+(%d+)$"))
            if suffix then
              max_suffix = math.max(max_suffix, tonumber(suffix) or 0)
            end
          end
        end
      end

      return string.format("%s-%d", base_title, max_suffix + 1)
    end

    -- The OS-title fixups below are X11/GNOME-specific. macOS has no
    -- _NET_WM_NAME and ships neither tool, so calling them raised
    -- "E475: 'xdotool' is not executable" out of vim.fn.system and aborted
    -- <leader>it / REPL registration on Mac. Capability check, not host check:
    -- a Linux box without xdotool degrades the same way instead of erroring.
    local x11_title_tools_ok = nil
    local function x11_title_tools_available()
      if x11_title_tools_ok == nil then
        x11_title_tools_ok = vim.fn.executable("xdotool") == 1 and vim.fn.executable("xprop") == 1
      end
      return x11_title_tools_ok
    end

    local function net_wm_name_is_utf8(xid, window_title)
      local out = vim.fn.system({ "xprop", "-id", tostring(xid), "_NET_WM_NAME" })
      return type(out) == "string"
        and out:find("UTF8_STRING", 1, true)
        and out:find('"' .. window_title .. '"', 1, true)
    end

    local function set_os_window_title(platform_window_id, window_title)
      -- GNOME white SSD bar paints UTF8_STRING _NET_WM_NAME only.
      -- kitty @ set-window-title often leaves STRING (blank bar); xprop -set won't change type.
      -- Remove → 8u set, retry until UTF8 value sticks (deterministic; no OCR).
      local xid = tostring(platform_window_id)
      for _ = 1, 8 do
        -- xdotool --name writes STRING _NET_WM_NAME and blanks GNOME bar if it runs last.
        vim.fn.system({ "xdotool", "set_window", "--name", window_title, xid })
        vim.fn.system({ "xprop", "-id", xid, "-f", "WM_NAME", "8s", "-set", "WM_NAME", window_title })
        vim.fn.system({ "xprop", "-id", xid, "-remove", "_NET_WM_NAME" })
        vim.fn.system({
          "xprop",
          "-id",
          xid,
          "-f",
          "_NET_WM_NAME",
          "8u",
          "-set",
          "_NET_WM_NAME",
          window_title,
        })
        vim.fn.system({ "xprop", "-id", xid, "-f", "_NET_WM_ICON_NAME", "8u", "-set", "_NET_WM_ICON_NAME", window_title })
        if net_wm_name_is_utf8(xid, window_title) then
          return true
        end
        vim.wait(100)
      end
      vim.notify(
        "OS title UTF8 set failed for xid=" .. xid .. " title=" .. window_title,
        vim.log.levels.WARN
      )
      return false
    end

    local function platform_window_id_for(listen_on, window_id)
      local tree = kitty_tree(listen_on)
      for _, os_window in ipairs(tree or {}) do
        for _, tab in ipairs(os_window.tabs or {}) do
          for _, window in ipairs(tab.windows or {}) do
            if tonumber(window.id) == tonumber(window_id) and os_window.platform_window_id then
              return os_window.platform_window_id
            end
          end
        end
      end
      return nil
    end

    local function set_kitty_repl_titles(listen_on, window_id, window_title)
      if not listen_on or listen_on == "" or not window_id or not window_title or window_title == "" then
        return
      end
      kitty_rpc(listen_on, { "set-window-title", "--match", "id:" .. tostring(window_id), window_title })
      kitty_rpc(listen_on, { "set-tab-title", "--match", "window_id:" .. tostring(window_id), window_title })
      -- The send path reads window.title back to compute the next title, so a
      -- cached pre-rename tree here would re-apply the old name forever.
      kitty_cache.invalidate(listen_on)
      if not x11_title_tools_available() then
        -- kitty's own RPC titles are the whole story off X11; skipping also
        -- avoids a 1.5s platform_window_id wait on every registration.
        return
      end
      local xid = nil
      vim.wait(1500, function()
        xid = platform_window_id_for(listen_on, window_id)
        return xid ~= nil
      end, 50)
      if not xid then
        return
      end
      -- After kitty RPC (often STRING), force UTF8 OS title until it sticks.
      vim.wait(150)
      set_os_window_title(xid, window_title)
    end

    function current_kitty_target()
      local family = repl_backend.family_for_filetype(vim.bo.filetype or "")
      local spec = require("repl.specs").slime_kitty_spec(family)
      local listen_on = spec.listen_on or vim.env.KITTY_LISTEN_ON
      return spec.family, listen_on, spec.title, spec.window_class or spec.title, spec.launcher, spec.start_command
    end

    local function known_kitty_listen_ons(primary)
      local seen = {}
      local listen_ons = {}

      local function add(listen_on)
        if not listen_on or listen_on == "" or seen[listen_on] then
          return
        end
        seen[listen_on] = true
        table.insert(listen_ons, listen_on)
      end

      add(primary)

      -- Broader than repl_paths.socket_globs() on purpose: this list also has to
      -- find the startup kitty instance and scrollback sockets, which are not
      -- dl-prefixed. Safe against CCC's control sockets because those are named
      -- `kitty-focus.sock-<pid>` and this pattern anchors on a `.sock` suffix.
      local runtime = require("repl.paths").runtime_dir()
      for _, pattern in ipairs({ "/*kitty*.sock", "/kitty-scrollback.sock-*" }) do
        for _, socket in ipairs(vim.fn.glob(runtime .. pattern, false, true) or {}) do
          add("unix:" .. socket)
        end
      end

      return listen_ons
    end

    -- Discovery for <leader>it and <leader>in: uncached on purpose. A REPL that
    -- another Neovim (or the launcher) created seconds ago must show up in the
    -- picker, and this path is not on the send hot path.
    function repl_kitty_windows_for(listen_on, title, window_class)
      local tree = kitty_tree_fresh(listen_on)
      return repl_kitty_windows(tree, title, listen_on, window_class)
    end

    if vim.g.slime_target == "kitty" then
      publish_active_slime_focus_target()
    end

    local function repl_kitty_windows_from_sources(listen_ons, title, window_class)
      local windows = {}
      for _, listen_on in ipairs(listen_ons or {}) do
        vim.list_extend(windows, repl_kitty_windows_for(listen_on, title, window_class))
      end
      return windows
    end

    local function repl_launch_env(window_title, window_class)
      -- Copy then mutate: must drop a stale NVIM_SLIME_IPYTHON_EXECUTABLE so the
      -- helper cannot inherit agent from a prior buffer when resolve is empty.
      local env = vim.fn.environ()
      local spec = require("repl.specs").slime_kitty_spec(current_slime_family())
      env.DL_REPL_COMMAND = spec.start_command
      local python_command = host_paths.language("python").command
      env.NVIM_REPL_COMMAND = current_slime_family() == "python" and python_command and python_command ~= "" and python_command or nil
      env.NVIM_REPL_ENVS_CONFIG = host_paths.get().python_envs
      env.DL_REPL_SOCKET = spec.listen_on
      env.DL_REPL_WINDOW_TITLE = window_title
      env.DL_REPL_WINDOW_CLASS = window_class
      -- The user is typing in nvim; a REPL that appears as a side effect of
      -- <M-x> must not take the keyboard. Manual launcher runs leave this unset.
      env.DL_REPL_NO_FOCUS = "1"
      local ok, repl_env = pcall(require, "repl.python_env")
      local ipython = ok and repl_env.ipython_cmd() or nil
      local pythonpath = nil
      local ok_paths, project_paths = pcall(require, "repl.python.project_paths")
      if ok_paths then
        local root = (ok and repl_env.context_root and repl_env.context_root(0)) or vim.fn.getcwd()
        pythonpath = project_paths.prepend_for(root, env.PYTHONPATH)
      end
      -- Pin absolute ipython from buffer resolve. Title alone must not drift
      -- from the process: helper otherwise resolves via shell cwd and can
      -- start agent under a dl-repl title (or the reverse).
      if ipython and ipython ~= "" then
        env.NVIM_SLIME_IPYTHON_EXECUTABLE = ipython
      else
        env.NVIM_SLIME_IPYTHON_EXECUTABLE = nil
      end
      env.PYTHONPATH = pythonpath or env.PYTHONPATH
      return env
    end

    -- A cold `kitty --detach` + login shell + conda activate takes ~3s on this
    -- Mac before the launcher can title the window, so the old flat 3000ms
    -- budget expired on the very launch it was waiting for. The budget is wide
    -- now because a *broken* launcher no longer has to burn it: the wait aborts
    -- as soon as the launcher process itself exits non-zero (see repl_launch).
    local REPL_LAUNCH_TIMEOUT_MS = 15000

    local function wait_for_env_kitty_windows(listen_on, title, window_class, launch)
      local windows = {}
      vim.wait(REPL_LAUNCH_TIMEOUT_MS, function()
        windows = filter_windows_matching_env(
          repl_kitty_windows_for(listen_on, title, window_class),
          title
        )
        if #windows > 0 then
          return true
        end
        return launch ~= nil and launch.exit_code ~= nil and launch.exit_code ~= 0
      end, 100)
      return windows
    end

    local function wait_for_kitty_window_title(listen_on, base_title, window_class, window_title, launch)
      local matched = nil
      vim.wait(REPL_LAUNCH_TIMEOUT_MS, function()
        if launch ~= nil and launch.exit_code ~= nil and launch.exit_code ~= 0 then
          return true
        end
        local windows = filter_windows_matching_env(
          repl_kitty_windows_for(listen_on, base_title, window_class),
          base_title
        )
        for _, window in ipairs(windows) do
          local context = window._ub_repl_context or {}
          local candidates = {
            context.window_title,
            context.os_window_name,
            window.title,
          }
          for _, candidate in ipairs(candidates) do
            if candidate == window_title then
              matched = window
              return true
            end
          end
        end
        return false
      end, 100)
      return matched
    end

    -- Durable trace of every REPL launch and every launch failure. vim.notify is
    -- routed to Noice and vanishes, so <M-x> used to leave nothing readable
    -- afterwards -- which is why the launcher's `Unknown flag: --class` death
    -- surfaced to the user only as "Could not find kitty REPL window".
    -- Survives an nvim restart, unlike the runtime dir, and is where a user
    -- already looks for nvim logs. Not a repl_paths entry: that dict is pinned
    -- byte-for-byte to bin/dl_repl_paths.py by repl_paths_parity_smoke.sh.
    local LAUNCH_LOG = vim.env.DL_REPL_LOG_FILE
      or (vim.fn.stdpath("log") .. "/dl-repl.log")

    local function launch_log(line)
      pcall(function()
        vim.fn.mkdir(vim.fn.fnamemodify(LAUNCH_LOG, ":h"), "p")
        local handle = io.open(LAUNCH_LOG, "a")
        if not handle then
          return
        end
        handle:write(os.date("%Y-%m-%dT%H:%M:%S") .. " " .. line:gsub("%s+", " ") .. "\n")
        handle:close()
      end)
    end

    -- Notify AND log: a launch is never silent, and a failure is never lost.
    local function notify_launch(message, level)
      vim.notify(message, level)
      local line = message:gsub("%s+", " ")
      if #line > 200 then
        line = line:sub(1, 197) .. "..."
      end
      -- history=true keeps it in `:messages` even when Noice swallows the popup.
      pcall(vim.api.nvim_echo, {
        { "[slime] " .. line, level == vim.log.levels.INFO and "MoreMsg" or "WarningMsg" },
      }, true, {})
    end

    local function notify_launch_failure(message)
      notify_launch(message, vim.log.levels.WARN)
      launch_log("failure " .. message)
    end

    -- Launcher failure used to be indistinguishable from "no REPL window":
    -- `mac/dl-repl-window` died instantly on kitty 0.45's removed --class flag
    -- and <M-x> still reported only "Could not find kitty REPL window ...".
    -- Capture the launcher's own stderr/exit status so the message names it.
    local function repl_launch(launcher, window_title, window_class)
      if not launcher or launcher == "" or vim.fn.executable(launcher) ~= 1 then
        return nil, "REPL launcher not found: " .. tostring(launcher)
      end
      local bufname = vim.api.nvim_buf_get_name(0)
      notify_launch("Launching " .. window_title .. " for " .. bufname, vim.log.levels.INFO)
      launch_log(string.format(
        "launch %s slot=%s buf=%s launcher=%s",
        window_title, window_title:match("%-(%d+)$") or "?", bufname, launcher
      ))
      local launch = { launcher = launcher, stderr = {} }
      vim.fn.jobstart({ launcher }, {
        detach = true,
        env = repl_launch_env(window_title, window_class),
        on_stderr = function(_, data)
          for _, line in ipairs(data or {}) do
            if line ~= "" then
              table.insert(launch.stderr, line)
            end
          end
        end,
        on_exit = function(_, code)
          launch.exit_code = code
        end,
      })
      return launch
    end

    local function repl_launch_error(launch)
      local parts = {}
      if launch.exit_code and launch.exit_code ~= 0 then
        table.insert(parts, string.format("%s exited %d", launch.launcher, launch.exit_code))
      end
      if #launch.stderr > 0 then
        table.insert(parts, table.concat(launch.stderr, " | "))
      end
      if #parts == 0 then
        return string.format("%s produced no REPL window in %dms", launch.launcher, REPL_LAUNCH_TIMEOUT_MS)
      end
      return table.concat(parts, ": ")
    end

    local function ensure_repl_kitty_window(listen_on, title, launcher, window_class)
      local windows = filter_windows_matching_env(
        repl_kitty_windows_for(listen_on, title, window_class),
        title
      )
      if #windows > 0 then
        return windows, false
      end

      local window_title = next_repl_window_title(title, windows)
      local launch, launch_error = repl_launch(launcher, window_title, window_class)
      if not launch then
        return {}, true, launch_error
      end
      windows = wait_for_env_kitty_windows(listen_on, title, window_class, launch)
      if #windows > 0 then
        set_kitty_repl_titles(listen_on, windows[1].id, window_title)
        return windows, true
      end
      return {}, true, repl_launch_error(launch)
    end

    local function wait_for_ipython_session(listen_on, title, window_id)
      local sessions = {}
      vim.wait(3000, function()
        local tree = kitty_tree_fresh(listen_on)
        local window = kitty_window_by_id(tree, window_id)
        sessions = ipython_sessions(window and { window } or repl_kitty_windows(tree, title, listen_on))
        return #sessions > 0
      end, 100)
      return sessions[1]
    end

    -- A REPL window this send has just launched is listed by kitty, and passes
    -- the session check through its own launch command (`slime-repl-restart
    -- start-ipython`), seconds before IPython reads its terminal. A payload sent
    -- then is echoed raw by the terminal (`^[[200~` ... `^[[201~`) above the
    -- IPython banner (oracle slime S03 on `rig-slow`). prompt_toolkit enters raw
    -- mode before it draws `In [N]:`, so a drawn prompt is the first moment a
    -- paste reaches IPython itself. On timeout the send goes ahead as before and
    -- the launch log says so. REPL_ROUTING.md § `M-x` cell-send contract item 8.
    local function wait_for_ipython_prompt(listen_on, window_id)
      local ready = vim.wait(REPL_LAUNCH_TIMEOUT_MS, function()
        local text = kitty_rpc(listen_on, { "get-text", "--match", "id:" .. tostring(window_id) })
        return text ~= nil and text:find("In %[%d+%]:") ~= nil
      end, 100)
      if not ready then
        launch_log(string.format(
          "window %s drew no IPython prompt in %dms; sending anyway", tostring(window_id), REPL_LAUNCH_TIMEOUT_MS
        ))
      end
      return ready
    end

    local function wait_for_r_session(listen_on, title, window_id)
      local sessions = {}
      vim.wait(3000, function()
        local tree = kitty_tree_fresh(listen_on)
        local window = kitty_window_by_id(tree, window_id)
        sessions = r_sessions(window and { window } or repl_kitty_windows(tree, title, listen_on))
        return #sessions > 0
      end, 100)
      return sessions[1]
    end

    local function wait_for_family_session(family, listen_on, title, window_id)
      if family == "python" then return wait_for_ipython_session(listen_on, title, window_id) end
      if family == "r" then return wait_for_r_session(listen_on, title, window_id) end
      return nil
    end

    local function register_kitty_repl(force_select)
      local family, listen_on, title, window_class, launcher, start_command = current_kitty_target()
      if not listen_on or listen_on == "" then
        vim.notify("Could not find kitty listen socket for vim-slime", vim.log.levels.WARN)
        return false
      end

      local windows, launched_window, launch_error = nil, false, nil
      if force_select then
        windows = filter_windows_matching_env(
          repl_kitty_windows_from_sources(known_kitty_listen_ons(listen_on), title, window_class),
          title
        )
      else
        windows, launched_window, launch_error =
          ensure_repl_kitty_window(listen_on, title, launcher, window_class)
      end
      if #windows == 0 then
        notify_launch_failure(
          launch_error
            and ("Could not start kitty REPL for " .. family .. " (" .. tostring(title) .. "): " .. launch_error)
            or ("Could not find kitty REPL window for " .. family .. " matching " .. tostring(title)
              .. (fd_pressure() and (" -- " .. fd_pressure()) or "")
              .. (last_kitty_rpc_error and (" -- " .. last_kitty_rpc_error) or ""))
        )
        return false
      end

      if launched_window and family == "python" then
        wait_for_ipython_prompt(listen_on, windows[1].id)
      end

      local sessions = family_sessions(family, windows)
      if #sessions == 0 and not force_select then
        local window = windows[1]
        if not send_kitty_text(listen_on, window.id, start_command .. "\n") then
          vim.notify("Could not start " .. family .. " in kitty slime target", vim.log.levels.WARN)
          return false
        end
        local started = wait_for_family_session(family, listen_on, title, window.id)
        if started then
          sessions = { started }
        else
          sessions = generic_sessions({ window }, family)
        end
      end

      if #sessions == 0 then
        vim.notify("No " .. family .. " sessions found", vim.log.levels.WARN)
        return false
      end

      local selected = nil
      if #sessions == 1 and not force_select then
        selected = sessions[1]
      else
        selected = select_session(family, sessions)
        if not selected then return false end
      end

      local bound_listen = selected.listen_on or listen_on
      if bind_kitty_repl(bound_listen, selected.window_id, family) then
        -- Always force UTF8 OS title for python (reuse path otherwise leaves STRING / blank bar).
        -- Never rewrite env prefix (agent-repl ↔ dl-repl): title must match the
        -- process that was already filtered; only normalize slot numbering.
        if family == "python" then
          local tree = kitty_tree_fresh(bound_listen)
          local window = kitty_window_by_id(tree, selected.window_id)
          local current_title = window and window.title or ""
          local base_title = require("repl.python_env").repl_title_base()
          if repl_title_matches(current_title, base_title) then
            local slot = tonumber(current_title:match("%-repl%-(%d+)$")) or 1
            local new_title = base_title .. "-" .. slot
            set_kitty_repl_titles(bound_listen, selected.window_id, new_title)
            vim.g[slime_state_name("title", family)] = new_title
          elseif current_title ~= "" then
            vim.g[slime_state_name("title", family)] = current_title
          end
        end
        if selected.label then
          vim.notify("Slime target: " .. selected.label, vim.log.levels.INFO)
        end
        return true
      end

      return false
    end

    local function launch_new_repl()
      local family, listen_on, title, window_class, launcher = current_kitty_target()
      if not listen_on or listen_on == "" then
        vim.notify("Could not find kitty listen socket for " .. family, vim.log.levels.WARN)
        return false
      end
      if not launcher or launcher == "" or vim.fn.executable(launcher) ~= 1 then
        notify_launch_failure("REPL launcher not found: " .. tostring(launcher))
        return false
      end
      local existing = filter_windows_matching_env(
        repl_kitty_windows_for(listen_on, title, window_class),
        title
      )
      local window_title = next_repl_window_title(title, existing)

      local launch, launch_error = repl_launch(launcher, window_title, window_class)
      if not launch then
        notify_launch_failure(launch_error)
        return false
      end
      local window = wait_for_kitty_window_title(listen_on, title, window_class, window_title, launch)
      if not window then
        notify_launch_failure(
          launch_error
            or ("Could not start " .. family .. " kitty REPL: " .. repl_launch_error(launch))
        )
        return false
      end

      set_kitty_repl_titles(listen_on, window.id, window_title)

      if bind_kitty_repl(listen_on, window.id, family) then
        vim.notify(string.format("New %s REPL bound (window %d)", family, window.id), vim.log.levels.INFO)
        return true
      end
      return false
    end

    local function ensure_kitty_repl_window()
      local family, listen_on, title, window_class = current_kitty_target()
      local buffer_config = vim.b.slime_config or {}
      local family_state = read_slime_family_state(family)
      local window_id = nil
      local registered_listen_on = nil

      if buffer_config.family == family then
        window_id = tonumber(buffer_config.window_id or "")
        registered_listen_on = buffer_config.listen_on
      end

      if not window_id then
        window_id = family_state.window_id
      end
      if not registered_listen_on or registered_listen_on == "" then
        registered_listen_on = family_state.listen_on or listen_on
      end

      if window_id and registered_listen_on and registered_listen_on ~= "" then
        local tree = kitty_tree(registered_listen_on)
        local window = kitty_window_by_id(tree, window_id)
        if window and (family ~= "python" or window_matches_env(window, title)) then
          return bind_kitty_repl(registered_listen_on, window_id, family)
        end
        clear_slime_family_state(family)
        vim.b.slime_config = nil
      end

      return register_kitty_repl(false)
    end

    local function ensure_slime_target()
      if vim.g.slime_target == "kitty" then
        return ensure_kitty_repl_window()
      end
      return ensure_tmux_repl_pane()
    end

    local function feed(keys)
      vim.api.nvim_feedkeys(vim.keycode(keys), "m", false)
    end

    local function send_slime_text(text)
      if ensure_slime_target() then
        vim.fn["slime#send"](text)
        return true
      end
      return false
    end

    local function ensure_then(action)
      return function()
        if ensure_slime_target() then
          action()
        end
      end
    end

    local function send_plug(keys)
      return ensure_then(function()
        feed(keys)
      end)
    end

    local function send_selection()
      local repl_send_motion = require("repl.send_motion")
      local selection = get_visual_selection()
      if selection ~= "" and send_to_dap_repl(selection, false) then
        repl_send_motion.move_below_visual_selection()
        return
      end

      if ensure_slime_target() then
        feed("<Plug>SlimeRegionSend")
        repl_send_motion.move_below_visual_selection()
      end
    end

    local function move_cursor_down_after_send()
      local current = vim.fn.line(".")
      local target = math.min(current + 1, vim.fn.line("$"))
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      vim.cmd("normal! zz")
    end

    local function send_motion()
      if not ensure_slime_target() then
        return ""
      end
      vim.o.operatorfunc = "v:lua.require'repl.send_motion'.slime_send_op"
      return "g@"
    end

    local function send_import_for_symbol()
      if vim.bo.filetype ~= "python" then
        vim.notify("Auto-import send only works in python buffers", vim.log.levels.WARN)
        return
      end

      local symbol = vim.fn.expand("<cword>")
      local import_block = require("repl.send_context").import_block(symbol)
      if import_block == nil or #import_block == 0 then
        vim.notify("Import statement not found for " .. symbol, vim.log.levels.WARN)
        return
      end

      if send_slime_text(table.concat(import_block, "\n") .. "\r") then
        move_cursor_down_after_send()
        vim.cmd("normal! ^")
      end
    end

    local function send_current_line_and_move()
      local line = vim.api.nvim_get_current_line()

      if send_to_dap_repl(line, true) then
        move_cursor_down_after_send()
        return
      end

      if send_slime_text(line .. "\r") then
        move_cursor_down_after_send()
      end
    end

    local function send_text_snippet(text)
      if text == nil or text == "" then
        vim.notify("Nothing to send at cursor", vim.log.levels.WARN)
        return
      end

      if send_to_dap_repl(text, false) then
        return
      end

      send_slime_text(text .. "\r")
    end

    local function send_word_under_cursor()
      local repl_send_context = require("repl.send_context")
      send_text_snippet(repl_send_context.word_under_cursor())
    end

    local function send_rest_of_line_from_cursor()
      local repl_send_context = require("repl.send_context")
      send_text_snippet(repl_send_context.rest_of_line_from_cursor())
    end

    local repl_cell = require("repl.cell")

    local function send_cell(move_after_send)
      -- Same gate as send_line / send_selection while a debug console is bound.
      local cell_lines = repl_cell.current_lines()
      local cell_text = table.concat(cell_lines, "\n")
      if cell_text ~= "" and send_to_dap_repl(cell_text, false) then
        if move_after_send then
          repl_cell.move_below_next_delimiter()
        end
        return
      end

      if not ensure_slime_target() then
        return
      end

      cell_continues_next = vim.bo.filetype == "python" and repl_cell.next_cell_continues()
      local ok, err = pcall(vim.fn["slime#send_cell"])
      cell_continues_next = false
      if not ok then
        error(err, 0)
      end
      if move_after_send then
        repl_cell.move_below_next_delimiter()
      end
    end

    local function send_cell_and_move()
      send_cell(true)
    end

    local function send_until_cursor()
      if not ensure_slime_target() then
        return
      end

      vim.cmd(("1,%dSlimeSend"):format(vim.fn.line(".")))
    end

    local function move_to_section_line(line)
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.cmd("normal! zz")
    end

    local function send_current_section(move_after_send)
      local payload = repl_sections.current_section_lines(0)
      if payload == nil then
        vim.notify("Could not resolve current SECTION block", vim.log.levels.WARN)
        return
      end
      if not payload.has_marker then
        vim.notify("No SECTION markers found in current buffer", vim.log.levels.WARN)
        return
      end
      if #payload.lines == 0 then
        vim.notify("Current SECTION block is empty", vim.log.levels.WARN)
        return
      end

      if send_slime_text(table.concat(payload.lines, "\n") .. "\r") and move_after_send then
        move_to_section_line(payload.range.move_line)
      end
    end

    local function use_repl_target()
      ensure_slime_target()
    end

    -- Bind existing env-matching kitty session only. No launch, no start_command.
    -- Used by traceback consumers (`\aP` / `\j` / C-S-y) after nvim restart.
    local function discover_kitty_repl_target()
      if vim.g.slime_target ~= "kitty" then
        return false
      end
      local family, listen_on, title, window_class = current_kitty_target()
      if not listen_on or listen_on == "" then
        return false
      end

      local windows = filter_windows_matching_env(
        repl_kitty_windows_from_sources(known_kitty_listen_ons(listen_on), title, window_class),
        title
      )
      if #windows == 0 then
        return false
      end

      local sessions = family_sessions(family, windows)
      if #sessions == 0 then
        return false
      end

      local selected
      if #sessions == 1 then
        selected = sessions[1]
      else
        selected = select_session(family, sessions)
        if not selected then
          return false
        end
      end

      local bound_listen = selected.listen_on or listen_on
      return bind_kitty_repl(bound_listen, selected.window_id, family)
    end

    local function select_kitty_repl_target()
      if vim.g.slime_target ~= "kitty" then
        vim.notify("REPL target selection is only available for kitty Slime targets", vim.log.levels.WARN)
        return
      end
      register_kitty_repl(true)
    end

    local function slime_ipython_env()
      local ok, repl_env = pcall(require, "repl.python_env")
      if not ok then
        return nil
      end
      return repl_env.ipython_cmd()
    end

    local function with_slime_ipython_env(fn)
      local ipython = slime_ipython_env()
      local previous = vim.env.NVIM_SLIME_IPYTHON_EXECUTABLE
      local previous_pythonpath = vim.env.PYTHONPATH
      local previous_repl_command = vim.env.NVIM_REPL_COMMAND
      local previous_envs_config = vim.env.NVIM_REPL_ENVS_CONFIG
      local previous_kitty_bin = vim.env.NVIM_SLIME_KITTY_BIN
      vim.env.NVIM_SLIME_KITTY_BIN = host_paths.kitty_bin()
      local configured_command = host_paths.language("python").command
      vim.env.NVIM_REPL_COMMAND = configured_command and configured_command ~= "" and configured_command or nil
      vim.env.NVIM_REPL_ENVS_CONFIG = host_paths.get().python_envs
      local pythonpath = nil
      local ok, project_paths = pcall(require, "repl.python.project_paths")
      if ok then
        local repl_ok, repl_env = pcall(require, "repl.python_env")
        local root = (repl_ok and repl_env.context_root and repl_env.context_root(0)) or vim.fn.getcwd()
        pythonpath = project_paths.prepend_for(root, vim.env.PYTHONPATH)
      end
      -- Always override: a stale agent pin must not survive into a dl buffer restart.
      if ipython and ipython ~= "" then
        vim.env.NVIM_SLIME_IPYTHON_EXECUTABLE = ipython
      else
        vim.env.NVIM_SLIME_IPYTHON_EXECUTABLE = nil
      end
      if pythonpath and pythonpath ~= "" then
        vim.env.PYTHONPATH = pythonpath
      end
      fn()
      if previous == nil then
        vim.env.NVIM_SLIME_IPYTHON_EXECUTABLE = nil
      else
        vim.env.NVIM_SLIME_IPYTHON_EXECUTABLE = previous
      end
      vim.env.PYTHONPATH = previous_pythonpath
      vim.env.NVIM_REPL_COMMAND = previous_repl_command
      vim.env.NVIM_REPL_ENVS_CONFIG = previous_envs_config
      vim.env.NVIM_SLIME_KITTY_BIN = previous_kitty_bin
    end

    local function restart_tmux_python_process()
      local pane_id, cmd, start = resolve_tmux_repl_pane()
      if not pane_id or pane_id == "" then
        vim.notify("Could not find tmux repl pane for vim-slime", vim.log.levels.WARN)
        return
      end

      vim.b.slime_config = {
        socket_name = "default",
        target_pane = pane_id,
      }

      with_slime_ipython_env(function()
        local output = vim.fn.system({ repl_restart_helper, "tmux", pane_id })
        if vim.v.shell_error ~= 0 then
          vim.notify(output, vim.log.levels.ERROR)
          return
        end
        vim.notify(vim.trim(output), vim.log.levels.INFO)
      end)
    end

    local function parse_repl_slot_from_title(title)
      if type(title) ~= "string" or title == "" then
        return 1
      end
      return tonumber(title:match("%-repl%-(%d+)$")) or 1
    end

    local function restart_kitty_python_process()
      if not ensure_kitty_repl_window() then
        return
      end

      local family = current_slime_family()
      local listen_on = vim.b.slime_config.listen_on
      local window_id = vim.b.slime_config.window_id
      local tree = kitty_tree(listen_on)
      local window = kitty_window_by_id(tree, window_id)
      local current_title = window and window.title or ""
      local base_title = require("repl.python_env").repl_title_base()
      local slot = parse_repl_slot_from_title(current_title)
      -- Keep existing env title if bind somehow points at a foreign pane; do not
      -- paint dl-repl over an agent process (or the reverse).
      local new_title = repl_title_matches(current_title, base_title)
          and (base_title .. "-" .. slot)
        or (current_title ~= "" and current_title or (base_title .. "-" .. slot))

      local restarted = false
      with_slime_ipython_env(function()
        local output = vim.fn.system({ repl_restart_helper, "kitty", listen_on, tostring(window_id) })
        kitty_cache.invalidate(listen_on)
        if vim.v.shell_error ~= 0 then
          vim.notify(output, vim.log.levels.ERROR)
          return
        end
        restarted = true
        vim.notify(vim.trim(output), vim.log.levels.INFO)
      end)
      if not restarted then
        return
      end

      -- Title match may be stale/empty after restart; wait by window_id.
      wait_for_ipython_session(listen_on, new_title, window_id)
      set_kitty_repl_titles(listen_on, window_id, new_title)
      vim.g[slime_state_name("title", family)] = new_title
      repl_focus.emit_changed({
        backend = "slime",
        family = family,
        target = "kitty",
        listen_on = listen_on,
        window_id = window_id,
        title = new_title,
      })
    end

    local function restart_slime_process()
      -- A block a payload left open lived in the REPL being replaced.
      slime_format.forget()
      if current_slime_family() == "r" then
        vim.notify("Slime R restart is not implemented yet", vim.log.levels.WARN)
        return
      end
      if vim.g.slime_target == "kitty" then
        restart_kitty_python_process()
        return
      end
      restart_tmux_python_process()
    end

    local function quit_slime_repl()
      if current_slime_family() == "r" then
        send_slime_text('quit(save = "no")\r')
        return
      end
      send_slime_text("quit()\r")
    end

    local function send_file()
      vim.cmd("%SlimeSend")
    end

    local slime_group = vim.api.nvim_create_augroup("ub_slime", { clear = true })

    local function configure_slime_buffer(buf)
      vim.b[buf].slime_cell_delimiter = vim.b[buf].slime_cell_delimiter or vim.g.slime_cell_delimiter
      if vim.bo[buf].filetype == "python" then
        vim.b[buf].slime_python_ipython = 0
        vim.b[buf].slime_bracketed_paste = 1
      end
    end

    configure_slime_buffer(0)

    vim.api.nvim_create_autocmd("FileType", {
      group = slime_group,
      pattern = { "python", "sh", "zsh", "bash", "r", "rmd", "quarto", "rnoweb" },
      callback = function(args)
        configure_slime_buffer(args.buf)
      end,
    })

    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
      group = slime_group,
      callback = function()
        publish_active_slime_focus_target()
      end,
    })

    --- A bound target, or nil. Kitty may bind an EXISTING window (discovery
    --- never launches and never types a start_command); tmux is taken as bound
    --- only once a real send has resolved its pane, because the tmux resolver
    --- falls back to the `:repl` window whether or not IPython is running there
    --- and a peek must never paste a probe into a shell.
    local function peek_target_bound()
      local function complete(config)
        if type(config) ~= "table" then
          return false
        end
        if config.listen_on and config.listen_on ~= "" and tonumber(config.window_id or "") then
          return true
        end
        return config.target_pane ~= nil and config.target_pane ~= ""
      end

      if complete(vim.b.slime_config) then
        return true
      end
      if vim.g.slime_target == "kitty" then
        pcall(discover_kitty_repl_target)
      end
      return complete(vim.b.slime_config)
    end

    --- REPL_ROUTING.md § `<M-k>` peek. The probe text is built by
    --- repl.peek; all this backend owns is putting it on the wire.
    local function peek_value(context)
      local text = context and context.text
      if type(text) ~= "string" or text == "" then
        return false
      end
      if not peek_target_bound() then
        vim.notify(
          "REPL peek: no REPL bound for this buffer; use <M-x> to bind or <leader>in to launch",
          vim.log.levels.WARN
        )
        return false
      end
      vim.fn["slime#send"](text .. "\r")
      return true
    end

    repl_actions.register_backend("slime", {
      send_selection = send_selection,
      peek_value = peek_value,
      send_line = send_current_line_and_move,
      send_word = send_word_under_cursor,
      send_rest_of_line = send_rest_of_line_from_cursor,
      send_import = send_import_for_symbol,
      send_motion = send_motion,
      send_cell = function()
        send_cell(false)
      end,
      send_cell_and_move = send_cell_and_move,
      send_block_and_move = send_cell_and_move,
      use_repl_target = use_repl_target,
      restart_repl = restart_slime_process,
      quit_repl = quit_slime_repl,
      send_paragraph = send_plug("<Plug>SlimeParagraphSend"),
      send_section = function()
        send_current_section(false)
      end,
      send_section_and_move = function()
        send_current_section(true)
      end,
      send_file = ensure_then(send_file),
      send_until_cursor = send_until_cursor,
    })

    _G.ub_slime_use_repl_target = use_repl_target
    _G.ub_slime_select_repl_target = select_kitty_repl_target
    _G.ub_slime_discover_repl_target = discover_kitty_repl_target
    _G.ub_slime_launch_new_repl = launch_new_repl
    _G.ub_slime_publish_focus_target = publish_active_slime_focus_target

    keymap("n", "<leader>rc", "<cmd>SlimeConfig<CR>", { silent = true, desc = "Slime Config" })
    M._setup = true
    return true
end

return M
