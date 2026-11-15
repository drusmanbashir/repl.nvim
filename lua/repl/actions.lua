local M = {}

M.index = {
  { id = "send_selection", mode = "x", lhs = "<M-e>", desc = "REPL Send Selection" },
  { id = "send_line", mode = "n", lhs = "<M-e>", desc = "REPL Send Line" },
  { id = "send_word", mode = "n", lhs = "<M-w>", desc = "REPL Send Word" },
  { id = "send_rest_of_line", mode = "n", lhs = "<M-y>", desc = "REPL Send Rest Of Line" },
  { id = "send_import", mode = "n", lhs = "<M-i>", desc = "REPL Send Import" },
  { id = "send_motion", mode = "n", lhs = "<M-c>", desc = "REPL Send Motion", expr = true },
  { id = "send_block_and_move", mode = "n", lhs = "<M-x>", desc = "REPL Send Cell And Move" },
  { id = "send_section_and_move", mode = "n", lhs = "<M-X>", desc = "REPL Send SECTION And Move" },
  { id = "send_paragraph", mode = "n", lhs = "<M-P>", desc = "REPL Send Paragraph" },
  { id = "restart_repl", mode = "n", lhs = "<M-R>", desc = "REPL Restart" },
  {
    mode = "n",
    lhs = "<M-k>",
    desc = "REPL Peek Value Under Cursor",
    direct = function()
      require("repl.peek").peek()
    end,
  },
  {
    mode = "x",
    lhs = "<M-k>",
    desc = "REPL Peek Value Of Selection",
    direct = function()
      require("repl.peek").peek_visual()
    end,
  },
  {
    mode = "n",
    lhs = "\\j",
    desc = "REPL Trace Jump From Bottom",
    direct = function()
      require("repl.jump_trace").jump_from_bottom_with_prompt()
    end,
  },
  {
    mode = "n",
    lhs = "\\J",
    desc = "REPL Trace Jump From Top",
    direct = function()
      require("repl.jump_trace").jump_from_top_with_prompt()
    end,
  },
}

local backends = {}

local Backend = {}
Backend.__index = Backend

function Backend:new(name, actions)
  return setmetatable({
    name = name,
    actions = vim.tbl_extend("force", {}, actions or {}),
  }, self)
end

function Backend:run(action_id, context)
  local handler = self.actions[action_id]
  if type(handler) ~= "function" then
    vim.notify(
      string.format("REPL action %s unavailable for backend %s", tostring(action_id), self.name),
      vim.log.levels.WARN
    )
    return ""
  end

  return handler(context)
end

function M.register_backend(name, actions)
  if type(name) ~= "string" or type(actions) ~= "table" then
    return
  end

  local existing = backends[name] and backends[name].actions or {}
  backends[name] = Backend:new(name, vim.tbl_extend("force", existing, actions))
end

function M.backend_registered(name)
  return backends[name] ~= nil
end

function M.current_context()
  local ok, repl_backend = pcall(require, "repl")
  local filetype = vim.bo.filetype or ""
  local family = "other"
  local configured = "slime"

  if ok and type(repl_backend.family_for_filetype) == "function" then
    family = repl_backend.family_for_filetype(filetype)
  end
  if ok and type(repl_backend.current) == "function" then
    configured = repl_backend.current()
  end

  return {
    backend = configured,
    family = family,
    filetype = filetype,
    bufnr = vim.api.nvim_get_current_buf(),
    path = vim.api.nvim_buf_get_name(0),
  }
end

function M.resolve_backend(context)
  local ok, repl_router = pcall(require, "repl.router")
  if ok and type(repl_router.resolve) == "function" then
    return repl_router.resolve(context)
  end
  return context.backend, "configured"
end

function M.run(action_id, context)
  context = context or M.current_context()
  local backend
  if action_id == "restart_repl" then
    local ok_router, repl_router = pcall(require, "repl.router")
    if ok_router and type(repl_router.resolve_restart) == "function" then
      backend = select(1, repl_router.resolve_restart(context))
    else
      backend = select(1, M.resolve_backend(context))
    end
  else
    backend = select(1, M.resolve_backend(context))
  end

  local repl_backend = require("repl")
  if type(repl_backend.ensure_backend_ready) == "function" and not repl_backend.ensure_backend_ready(backend) then
    vim.notify(
      string.format("REPL backend %s is not ready", tostring(backend)),
      vim.log.levels.WARN
    )
    return ""
  end

  local backend_impl = backends[backend]
  if not backend_impl then
    vim.notify(
      string.format("REPL backend %s is not registered", tostring(backend)),
      vim.log.levels.WARN
    )
    return ""
  end

  local ok, result = pcall(function()
    return backend_impl:run(action_id, context)
  end)
  if not ok then
    vim.notify(
      string.format("REPL action %s failed for backend %s: %s", tostring(action_id), backend, result),
      vim.log.levels.ERROR
    )
    return ""
  end

  if result == nil then
    return ""
  end
  return result
end

function M.run_block_and_move(context)
  context = context or M.current_context()
  return M.run("send_cell_and_move", context)
end

function M.setup_keymaps()
  for _, spec in ipairs(M.index) do
    local opts = { silent = true, desc = spec.desc }
    if spec.expr then
      opts.expr = true
    end

    if type(spec.direct) == "function" then
      vim.keymap.set(spec.mode, spec.lhs, spec.direct, opts)
    elseif spec.id == "send_block_and_move" then
      vim.keymap.set(spec.mode, spec.lhs, function()
        return M.run_block_and_move()
      end, opts)
    elseif spec.mode == "x" then
      vim.keymap.set(spec.mode, spec.lhs, function()
        -- Leave visual mode first: while it is live, '< and '> still hold the
        -- PREVIOUS selection, and every backend (and move_below_visual_selection)
        -- reads them. A stale move collapsed a header-anchored selection to `# %%`.
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
        return M.run(spec.id)
      end, opts)
    else
      vim.keymap.set(spec.mode, spec.lhs, function()
        return M.run(spec.id)
      end, opts)
    end
  end
end

return M
