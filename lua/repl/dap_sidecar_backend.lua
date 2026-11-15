--- R-SEND-03, shared source-send contract: the "dap" REPL backend.
---
--- In production the DAP session, its adapter and its
--- console all live in a SEPARATE sidecar nvim, so the editor's own
--- `dap.session()` is nil for the whole session. Every editor-side REPL send
--- therefore fell through to kitty while the debugger sat stopped at a frame.
---
--- The fix is a BACKEND, not a special case bolted into slime's send functions:
--- a live sidecar is another place a registered buffer's REPL can be, reached
--- down the same pathway kitty is reached by --
---
---   repl_actions.run -> repl_router.resolve -> registered backend -> transport
---
--- repl_router returns ("dap", "sidecar") first while `sidecar.session_live()`
--- is true and the buffer's provider permits this route; this module registers
--- the backend those sends land on (R6'). Text extraction is the SAME code slime
--- uses -- `repl.cell`, `repl.sections`, `repl.send_context` and
--- the two extractors slime exports for this purpose -- so a cell sent to the
--- debugger is byte-for-byte the cell that would have gone to kitty.
---
--- Transport is `dap-sidecar.engine.dap2`.send_repl_text (R6). Nothing here ever falls back to
--- kitty: while the sidecar is live, the silent fallback IS the reported bug (R5).

local M = {}

--- Actions that are about the KITTY repl itself -- binding a target, quitting
--- it -- rather than about sending code. They still mean kitty while the
--- debugger owns the sends, so they are handed back to the configured backend.
---
--- `send_file` and `send_until_cursor` are NOT here: they produce text, so R3
--- routes them to the sidecar like every other send. Handing them to kitty while
--- a session is live was the R1/R5 breach the round-1 review found.
local PASSTHROUGH_ACTIONS = {
	"use_repl_target",
	"quit_repl",
}

local registered = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN)
end

--- The one place text leaves this module. Native focus is NOT passed: R4 keeps the
--- <M-e> family's cursor in the editor, and `focus_sidecar` stays reserved for
--- the callers that already asked for it (`<leader>db` / dap2.repl_send).
local function send(text, opts)
	if type(text) ~= "string" or text == "" then
		notify("Nothing to send to the debug console")
		return false
	end
	return require("dap-sidecar.engine.dap2").send_repl_text(text,
		{ focus = false, hold = opts and opts.hold })
end

local function send_motion_helper()
	return require("repl.send_motion")
end

local function move_cursor_down_after_send()
	local current = vim.fn.line(".")
	local target = math.min(current + 1, vim.fn.line("$"))
	vim.api.nvim_win_set_cursor(0, { target, 0 })
	vim.cmd("normal! zz")
end

local function move_to_line(line)
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	vim.cmd("normal! zz")
end

local function send_context()
	return require("repl.send_context")
end

-- Operator support. `send_motion` and `send_paragraph` reuse vim's own motions
-- and text objects by running an operator and reading back the '[ / '] marks vim
-- sets, rather than reimplementing `ip` or an arbitrary motion. The shared
-- extractor honours the motion's SHAPE, so a `<C-v>` block motion sends the
-- rectangle rather than the whole lines it touches.
function M.send_operator(motion_type)
	local text = send_context().operator_region(motion_type)
	if text ~= "" then
		send(text)
	end
	send_motion_helper().move_below_sent_block()
end

_G.ub_dap_repl_send_op = M.send_operator

local function arm_operator()
	vim.o.operatorfunc = "v:lua.ub_dap_repl_send_op"
	return "g@"
end

--- Hand one action back to the configured (kitty) backend. `dap_route = false`
--- is what stops repl_router choosing this backend again and recursing.
local function passthrough(action_id)
	return function(context)
		local repl_actions = require("repl.actions")
		local ctx = vim.tbl_extend("force", context or repl_actions.current_context(), { dap_route = false })
		return repl_actions.run(action_id, ctx)
	end
end

local function send_cell(move_after_send)
	local repl_cell = require("repl.cell")
	local text = table.concat(repl_cell.current_lines(), "\n")
	if text == "" then
		return
	end
	if send(text, { hold = vim.bo.filetype == "python" and repl_cell.next_cell_continues() }) and move_after_send then
		repl_cell.move_below_next_delimiter()
	end
end

local function send_section(move_after_send)
	local payload = require("repl.sections").current_section_lines(0)
	if payload == nil then
		notify("Could not resolve current SECTION block")
		return
	end
	if not payload.has_marker then
		notify("No SECTION markers found in current buffer")
		return
	end
	if #payload.lines == 0 then
		notify("Current SECTION block is empty")
		return
	end
	if send(table.concat(payload.lines, "\n")) and move_after_send then
		move_to_line(payload.range.move_line)
	end
end

local function send_import()
	if vim.bo.filetype ~= "python" then
		return notify("Auto-import send only works in python buffers")
	end
	local symbol = vim.fn.expand("<cword>")
	local lines = send_context().import_block(symbol)
	if not lines or #lines == 0 then
		return notify("Import statement not found for " .. symbol)
	end
	if send(table.concat(lines, "\n")) then
		move_cursor_down_after_send()
		vim.cmd("normal! ^")
	end
end

local function send_selection()
	-- The same MODE-aware reader slime uses, so a charwise, linewise or blockwise
	-- selection reaches the debugger as exactly the characters the operator marked.
	if send(send_context().visual_selection()) then
		send_motion_helper().move_below_visual_selection()
	end
end

--- Whole buffer, and buffer start to the cursor line. Both produce text, so R3
--- routes them here while the sidecar is live rather than to kitty.
local function buffer_text(last_line)
	return table.concat(vim.api.nvim_buf_get_lines(0, 0, last_line or -1, false), "\n")
end

local ACTIONS = {
	--- REPL_ROUTING.md § `<M-k>` peek. The probe reads through
	--- `dict(locals())`, so sent to the console of a session stopped at a frame
	--- it answers with that FRAME's value -- which is the value the operator is
	--- looking at while debugging, not kitty's stale one.
	peek_value = function(context)
		local text = context and context.text
		if type(text) ~= "string" or text == "" then
			return false
		end
		return require("dap-sidecar.engine.dap2").send_repl_text(text, { focus = false }) == true
	end,
	send_selection = send_selection,
	send_line = function()
		if send(vim.api.nvim_get_current_line()) then
			move_cursor_down_after_send()
		end
	end,
	send_word = function()
		send(require("repl.send_context").word_under_cursor())
	end,
	send_rest_of_line = function()
		send(require("repl.send_context").rest_of_line_from_cursor())
	end,
	send_import = send_import,
	send_motion = function()
		return arm_operator()
	end,
	send_paragraph = function()
		vim.api.nvim_feedkeys(vim.keycode(arm_operator() .. "ip"), "m", false)
	end,
	send_cell = function()
		send_cell(false)
	end,
	send_cell_and_move = function()
		send_cell(true)
	end,
	send_block_and_move = function()
		send_cell(true)
	end,
	send_section = function()
		send_section(false)
	end,
	send_section_and_move = function()
		send_section(true)
	end,
	send_file = function()
		send(buffer_text())
	end,
	send_until_cursor = function()
		send(buffer_text(vim.fn.line(".")))
	end,
}

--- Register the backend. Idempotent, and cheap enough to be its own readiness
--- check: this backend needs no plugin at all, which is why
--- `repl_backend.ensure_backend_ready("dap")` can answer true without loading
--- vim-slime. `restart_repl` is deliberately absent (R3, R2'): restarts resolve
--- through `repl_router.resolve_restart`, which never returns this backend.
function M.ensure()
	if registered then
		return true
	end
	local actions = vim.tbl_extend("force", {}, ACTIONS)
	for _, action_id in ipairs(PASSTHROUGH_ACTIONS) do
		actions[action_id] = passthrough(action_id)
	end
	require("repl.actions").register_backend("dap", actions)
	registered = true
	return true
end

M._test = {
	actions = ACTIONS,
	passthrough_actions = PASSTHROUGH_ACTIONS,
	reset = function()
		registered = false
	end,
}

return M
