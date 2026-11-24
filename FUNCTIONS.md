# FUNCTIONS.md
Scope: `bin/`, `lua/`, `plugin/`, `python/`, `tests/`, `tools/`, `!tests/repl_send_battery/fixtures/`, `!tests/repl_send_battery/seeds/`, `!tests/repl_send_battery/stubs/`

## Runtime commands
- `bin/repl-launch`: launch or reuse the configured external Kitty REPL; receives family, command, environment and socket through environment variables.
- `bin/slime-repl-restart`: launch IPython or restart the bound Kitty/tmux Python process; retains custom command and environment.
- `bin/kitty-focus-slime-source`: return from a Kitty child to its exact paired editor; optional compiled selector, complete Python fallback.
- `bin/dl_repl_paths.py`: print shared runtime path values as JSON or one selected field.

## Libraries (import, not run)
- `lua/repl/actions.lua`: Register backend actions and dispatch common send/peek/navigation keys.
- `lua/repl/backend.lua`: Select and load configured REPL providers; expose administration actions.
- `lua/repl/cell.lua`: Read percent-cell boundaries and continuation indentation.
- `lua/repl/config.lua`: Resolve plugin defaults, per-language options and bundled helper paths.
- `lua/repl/dap_sidecar_backend.lua`: Bridge common source actions to the optional DAP sidecar.
- `lua/repl/focus.lua`: Validate and focus exact Kitty bindings; publish and claim reverse routes.
- `lua/repl/focus_route.lua`: Choose the debug, notebook or terminal focus destination.
- `lua/repl/focus_state.lua`: Persist source/target context, pair ownership and route claims.
- `lua/repl/init.lua`: Public setup entry and backend administration API.
- `lua/repl/jump_trace.lua`: Capture terminal traceback/tail and navigate frames to source.
- `lua/repl/kitty_discovery.lua`: Match Kitty windows, process families and existing sessions.
- `lua/repl/kitty_rpc.lua`: Send ordered text frames and request Kitty replies over a Unix socket with bounded reads and handle cleanup.
- `lua/repl/kitty_tree.lua`: Read/cache Kitty window trees and refresh changed identities.
- `lua/repl/paths.lua`: Resolve shared sockets, focus state, registry and namespace paths.
- `lua/repl/peek.lua`: Evaluate and display values through the socket or file-probe routes.
- `lua/repl/python/project_paths.lua`: Read configured project import roots and extend Python paths.
- `lua/repl/python/slime_format.lua`: Preserve Python source while formatting bracketed paste and per-target continuation.
- `lua/repl/python/text.lua`: Outer Python dedentation used by the formatter.
- `lua/repl/python_env.lua`: Resolve and persist project-to-Conda pairings and interpreter paths.
- `lua/repl/registry.lua`: Read filetype families and configured default providers.
- `lua/repl/router.lua`: Route managed notebooks, matching debugger sessions and ordinary REPL sends.
- `lua/repl/sections.lua`: Read and navigate SECTION blocks.
- `lua/repl/send_context.lua`: Read selected regions, cursor symbols and matching import statements.
- `lua/repl/send_motion.lua`: Implement source motions and cursor advance after sending.
- `lua/repl/slime.lua`: Integrate session lifecycle and vim-slime sending, discovery and restart.
- `lua/repl/specs.lua`: Build each language session specification and startup command.
- `plugin/repl.lua`: Mark the plugin script loaded; setup is explicit.
- `python/repl_peek_server.py`: Run inside IPython to answer value probes in its namespace.
- `bin/dl_kitty.py`: Kitty tree, process and registry utilities.
- `bin/dl_repl_gate.py`: Evaluate the standalone focus backend policy.
- `bin/kitty_focus_slime_source.py`: Resolve reverse-focus identity and select the live paired source.

## Tests
- `tests/contracts.lua`: standalone load/setup, source preservation, managed-notebook/DAP routing and custom-command checks under Neovim.

- `tests/runtime_contract.py`: inspect Python startup arguments and warm/cold Kitty family/environment forwarding; argument probes, not live-session evidence.

## Product test seams

The library entries for `repl.dap_sidecar_backend`, `repl.focus_route`,
`repl.kitty_tree` and `repl.peek` expose their existing `M._test` observation
helpers. See those library entries for their owning files.

## Test instruments
- `tools/test`: run one top-level test by filename; --list discovers tests, --help describes invocation.
- `tests/iron_ondemand_dapui_poison_smoke.lua`: iron ondemand dapui poison smoke; standalone plugin contract or payload instrument.
- `tests/jump_trace_index_semantics_smoke.sh`: jump trace index semantics smoke; standalone plugin contract or payload instrument.
- `tests/jump_trace_last_repl_tail_smoke.sh`: jump trace last repl tail smoke; standalone plugin contract or payload instrument.
- `tests/jump_trace_last_traceback_smoke.sh`: jump trace last traceback smoke; standalone plugin contract or payload instrument.
- `tests/jump_trace_samefile_cell_smoke.sh`: jump trace samefile cell smoke; standalone plugin contract or payload instrument.
- `tests/kitty_tree_cache_smoke.lua`: kitty tree cache smoke; standalone plugin contract or payload instrument.
- `tests/kitty_tree_cache_smoke.sh`: kitty tree cache smoke; standalone plugin contract or payload instrument.
- `tests/lib/private_state.lua`: private state; standalone plugin contract or payload instrument.
- `tests/repl_focus_route_contract.lua`: repl focus route contract; standalone plugin contract or payload instrument.
- `tests/repl_paths_parity_smoke.sh`: repl paths parity smoke; standalone plugin contract or payload instrument.
- `tests/repl_peek_paint_contract.lua`: repl peek paint contract; standalone plugin contract or payload instrument.
- `tests/repl_peek_probe_contract.lua`: repl peek probe contract; standalone plugin contract or payload instrument.
- `tests/repl_peek_server_contract.lua`: repl peek server contract; standalone plugin contract or payload instrument.
- `tests/repl_route_exclusivity_contract.lua`: repl route exclusivity contract; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/capture.lua`: capture; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/fake_kitty.py`: fake kitty; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/ipython_probe.py`: ipython probe; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/judge.py`: judge; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/paste_lines_unit.lua`: paste lines unit; standalone plugin contract or payload instrument.
- `tests/repl_send_battery/prove_red.sh`: prove red; standalone plugin contract or payload instrument.
- `tests/repl_send_battery.sh`: repl send battery; standalone plugin contract or payload instrument.
- `tests/slime_python_format_smoke.lua`: slime python format smoke; standalone plugin contract or payload instrument.
