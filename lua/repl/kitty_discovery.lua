local M = {}

local function window_process_matcher(matches_argv)
  local function matches_process(process)
    for _, key in ipairs({ "cmdline", "argv", "command", "cmd", "exe" }) do
      local value = process[key]
      local argv = type(value) == "table" and value
        or type(value) == "string" and vim.split(value, "%s+", { trimempty = true })
      if argv and argv[1] and matches_argv(vim.fs.basename(argv[1]), argv) then
        return true
      end
    end
    return false
  end

  return function(window)
    return matches_process(window) or vim.iter(window.foreground_processes or {}):any(matches_process)
  end
end

local sage_programs = { sage = true, ["sage-ipython"] = true }
local sage_modules = { sage = true, ["sage.cli"] = true, ["sage.cli.__main__"] = true }

M.window_process_matchers = {
  octave = window_process_matcher(function(name, argv)
    name = name:gsub("%-%d[%d.]*$", "")
    return name == "octave" or name == "octave-cli"
      or (name == "octave-gui" and vim.list_contains(argv, "--no-gui"))
  end),
  sage = window_process_matcher(function(name, argv)
    if sage_programs[name] then return true end
    if not name:match("^python[%d.]*$") or not argv[2] then return false end
    return sage_programs[vim.fs.basename(argv[2])] == true
      or (argv[2] == "-m" and sage_modules[argv[3]] == true)
  end),
}

function M.new()
    local function process_text(process)
      if type(process) ~= "table" then
        return tostring(process or "")
      end

      local parts = {}
      for _, key in ipairs({ "cmdline", "argv", "command", "cmd", "exe", "pid", "cwd" }) do
        local value = process[key]
        if type(value) == "table" then
          table.insert(parts, table.concat(value, " "))
        elseif value ~= nil then
          table.insert(parts, tostring(value))
        end
      end

      return table.concat(parts, " ")
    end

    local function is_ipython_process(process)
      return process_text(process):find("ipython", 1, true) ~= nil
    end

    local function is_r_process(process)
      local text = process_text(process)
      return text:match("%f[%w]R%f[^%w]") ~= nil
        or text:match("%f[%w]arf%f[^%w]") ~= nil
        or text:match("%f[%w]radian%f[^%w]") ~= nil
    end

    local function process_parent_pid(pid)
      pid = tonumber(pid)
      if not pid then
        return nil
      end

      local ok, lines = pcall(vim.fn.readfile, "/proc/" .. tostring(pid) .. "/stat", "", 1)
      if not ok or not lines or not lines[1] then
        return nil
      end

      local after_name = lines[1]:match("%) (.+)$")
      if not after_name then
        return nil
      end

      local fields = vim.split(after_name, " ")
      return tonumber(fields[2])
    end

    local function nonempty(value)
      if type(value) == "string" and value ~= "" then
        return value
      end
      return nil
    end


    local function repl_title_matches(candidate, base_title)
      if type(candidate) ~= "string" or candidate == "" then
        return false
      end
      if candidate == base_title then
        return true
      end
      local escaped = vim.pesc(base_title)
      return candidate:match("^" .. escaped .. "%-%d+$") ~= nil
        or candidate:match("^" .. escaped .. "%s+%d+$") ~= nil
    end

    -- Class match finds every ipython-repl; keep only titles for current env (`{env}-repl`).
    local function filter_windows_matching_env(windows, base_title, sage_socket, sage_class)
      local out = {}
      for _, window in ipairs(windows or {}) do
        local context = window._ub_repl_context or {}
        if repl_title_matches(context.window_title, base_title)
          or repl_title_matches(context.os_window_name, base_title)
          or (sage_socket and context.listen_on == sage_socket and context.os_window_class == sage_class
            and M.window_process_matchers.sage(window)) then
          table.insert(out, window)
        end
      end
      return out
    end

    local function window_matches_env(window, base_title)
      if not window then
        return false
      end
      return repl_title_matches(window.title, base_title)
    end

    local function repl_kitty_windows(tree, title, listen_on, window_class)
      local matches = {}
      local fallback = {}

      for os_index, os_window in ipairs(tree or {}) do
        local os_window_matches = repl_title_matches(os_window.wm_name, title)
          or (window_class and os_window.wm_class == window_class)
          or (not window_class and repl_title_matches(os_window.wm_class, title))
        local os_window_name = nonempty(os_window.wm_name) or nonempty(os_window.wm_class)
        for tab_index, tab in ipairs(os_window.tabs or {}) do
          local tab_matches = repl_title_matches(tab.title, title)
          for window_index, window in ipairs(tab.windows or {}) do
            local window_matches = repl_title_matches(window.title, title)
            if window.id then
              window._ub_repl_sort = {
                os_window_matches or tab_matches or window_matches,
                tab_index,
                os_index,
                window_index,
              }
              window._ub_repl_context = {
                tab_index = tab_index,
                window_id = window.id,
                window_title = nonempty(window.title),
                os_window_name = os_window_name,
                os_window_class = os_window.wm_class,
                listen_on = listen_on,
              }
              if window._ub_repl_sort[1] then
                table.insert(matches, window)
              else
                table.insert(fallback, window)
              end
            end
          end
        end
      end

      table.sort(matches, function(a, b)
        local left = a._ub_repl_sort
        local right = b._ub_repl_sort
        if left[2] ~= right[2] then
          return left[2] < right[2]
        end
        if left[3] ~= right[3] then
          return left[3] < right[3]
        end
        return left[4] < right[4]
      end)

      table.sort(fallback, function(a, b)
        local left = a._ub_repl_sort
        local right = b._ub_repl_sort
        if left[2] ~= right[2] then
          return left[2] < right[2]
        end
        if left[3] ~= right[3] then
          return left[3] < right[3]
        end
        return left[4] < right[4]
      end)

      vim.list_extend(matches, fallback)
      return matches
    end

    local function main_ipython_process(window)
      if M.window_process_matchers.sage(window) then
        return nil
      end
      if is_ipython_process(window) then
        return window
      end

      local window_pid = tonumber(window.pid)
      local fallback = nil
      for _, process in ipairs(window.foreground_processes or {}) do
        if is_ipython_process(process) then
          if tonumber(process.pid) == window_pid then
            return process
          end
          if window_pid and process_parent_pid(process.pid) == window_pid then
            return process
          end
          fallback = fallback or process
        end
      end

      return fallback
    end

    local function main_r_process(window)
      if is_r_process(window) then
        return window
      end

      local window_pid = tonumber(window.pid)
      local fallback = nil
      for _, process in ipairs(window.foreground_processes or {}) do
        if is_r_process(process) then
          if tonumber(process.pid) == window_pid then
            return process
          end
          if window_pid and process_parent_pid(process.pid) == window_pid then
            return process
          end
          fallback = fallback or process
        end
      end

      return fallback
    end

    local function session_label(session)
      local parts = {}
      if session.os_window_name then
        table.insert(parts, session.os_window_name)
      end
      if session.tab_index then
        table.insert(parts, "tab " .. tostring(session.tab_index))
      end
      if session.window_title and not session.window_title:find("IPython", 1, true) then
        table.insert(parts, session.window_title)
      end

      local prefix = table.concat(parts, " - ")
      if prefix == "" then
        return "IPython"
      end
      return prefix .. " IPython"
    end

    local function ipython_sessions(windows)
      local sessions = {}

      for _, window in ipairs(windows or {}) do
        local process = main_ipython_process(window)
        if process then
          local context = window._ub_repl_context or {}
          table.insert(sessions, {
            window_id = window.id,
            pid = process.pid,
            listen_on = context.listen_on,
            tab_index = context.tab_index,
            window_title = context.window_title,
            os_window_name = context.os_window_name,
          })
        end
      end

      for _, session in ipairs(sessions) do
        session.label = session_label(session)
      end

      return sessions
    end

    local function r_sessions(windows)
      local sessions = {}

      for _, window in ipairs(windows or {}) do
        local process = main_r_process(window)
        if process then
          local context = window._ub_repl_context or {}
          table.insert(sessions, {
            window_id = window.id,
            pid = process.pid,
            listen_on = context.listen_on,
            tab_index = context.tab_index,
            window_title = context.window_title,
            os_window_name = context.os_window_name,
            label = ((context.os_window_name or context.window_title or "kitty window") .. " R"),
          })
        end
      end

      return sessions
    end


    return {
      repl_title_matches = repl_title_matches,
      filter_windows_matching_env = filter_windows_matching_env,
      window_matches_env = window_matches_env,
      repl_kitty_windows = repl_kitty_windows,
      ipython_sessions = ipython_sessions,
      r_sessions = r_sessions,
    }
end

return M
