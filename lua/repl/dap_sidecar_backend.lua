--- The dap backend sends source text to the separate sidecar Neovim.
--- Text extraction is shared with Slime; transport is dap2.send_repl_text.
--- Value peeks use the cached-value popup directly in repl.peek.

local M = {}

--- Binding and quitting belong to the configured terminal backend.
--- Actions that send source text stay with the debugger.
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

--- Readiness needs no vim-slime. Restarts resolve separately and never use dap.
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
