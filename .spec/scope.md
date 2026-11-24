# REPL-session plugin: feature scope

`setup()` takes per-language settings, such as `languages.python.command`. Python is uncapped by default. A custom launch command can add `systemd-run --user --scope -p MemoryMax=100G -p MemorySwapMax=0`; there is no separate memory-cap setting.

**Verdict: yes.** The substantial contribution is managing existing external REPL sessions: pairing, focus, runtime inspection, continuation and restart.

Paths below are relative to `/home/ub/scripts/`. **UNIQUE** means no equivalent found in the reviewed plugins’ documented features; it does not establish global novelty. Comparisons describe capability, with partial matches identified explicitly.

### Kitty

| Feature | Local evidence | Existing provision |
|---|---|---|
| Launch or reuse an external Kitty REPL; create numbered sessions and select among existing sessions. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `sinclair/dl-repl-window:151–196` | [kitty-runner.nvim](https://github.com/jghauser/kitty-runner.nvim) already launches runners; [yarepl.nvim](https://github.com/milanglacier/yarepl.nvim) manages multiple REPL instances, inside Neovim. |
| Place newly launched OS windows through a shared placement helper. | `sinclair/dl-repl-window:180,206`; `bin/repl_kitty_window_place.sh:45` | **UNIQUE** among reviewed plugins for external desktop placement; principally host-specific integration. |
| Preserve editor focus during automatic launch; explicit focus selects the stored OS window and Kitty child. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/focus.lua` | [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) provides focus-return behavior inside Neovim; **UNIQUE** exact external-window binding and focus behavior. |
| Discover Kitty’s OS-window/tab/child tree, cache reads, flatten windows and refresh a missing child. | `/home/ub/code/plugins/repl.nvim/lua/repl/kitty_tree.lua` | Kitty supplies the underlying window information; **UNIQUE** shared cache/lookup implementation among reviewed plugins, rather than a separate user-facing novelty. |
| Return from a REPL to its paired editor using exact platform-window and child identities, with bindings that do not age-expire. | `/home/ub/code/plugins/repl.nvim/lua/repl/focus_state.lua`; `bin/kitty_focus_slime_source.py:233–249,310–352`; `REPL_ROUTING.md:1138–1157` | **UNIQUE** durable bidirectional pairing and per-target editor ownership. |

### Sending code

| Feature | Local evidence | Existing provision |
|---|---|---|
| Send a line, word, rest of line, visual selection, motion, paragraph, file or file prefix; advance after selected sends. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/send_motion.lua` | [vim-slime](https://github.com/jpalardy/vim-slime), toggleterm.nvim and [molten-nvim](https://github.com/benlubas/molten-nvim) provide overlapping selection/operator/range sends. |
| Send `# %%` cells, including indented delimiters, optionally advancing to the next cell. | `/home/ub/code/plugins/repl.nvim/lua/repl/cell.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | vim-slime supports cells; [vim-ipython-cell](https://github.com/hanschen/vim-ipython-cell) already provides cell execution, nested cell markers and execute-and-jump. |
| Independently send and navigate `# SECTION:` blocks. | `/home/ub/code/plugins/repl.nvim/lua/repl/sections.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | vim-slime’s configurable cell delimiter and vim-ipython-cell’s custom tags cover marker-delimited execution; the simultaneous cell/section distinction is local convenience. |
| Find and send the import statement containing the symbol under the cursor, including multiline imports. | `/home/ub/code/plugins/repl.nvim/lua/repl/send_context.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | **UNIQUE** symbol-to-import send command among reviewed plugins. |
| Send Python as bracketed paste, preserving blank lines and comments and applying outer dedentation. | `/home/ub/code/plugins/repl.nvim/lua/repl/python/slime_format.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | [vim-slime](https://github.com/jpalardy/vim-slime/blob/main/assets/doc/targets/kitty.md) already supports bracketed paste; vim-ipython-cell provides dedentation through IPython paste execution. |
| Hold a compound statement open across cells when the next cell starts deeper; retain indentation state separately for each target and execute when continuation finishes. | `/home/ub/code/plugins/repl.nvim/lua/repl/cell.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/python/slime_format.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | **UNIQUE** target-specific continuation behavior; ordinary cell execution and dedentation do not provide this contract. |

### Getting results back

| Feature | Local evidence | Existing provision |
|---|---|---|
| Evaluate an expression in the existing terminal IPython namespace and return its `repr` through a local socket, without typing into its prompt. | `/home/ub/code/plugins/repl.nvim/python/repl_peek_server.py`; `bin/slime-repl-restart:496–509`; `/home/ub/code/plugins/repl.nvim/lua/repl/peek.lua` | **UNIQUE** existing terminal-IPython inspection route; molten-nvim provides kernel results through Jupyter instead. |
| Fall back to sending a probe and reading its result from a local file for Python and R. Debugger Alt-K instead opens the sidecar cached-value popup without sending console text. | `/home/ub/code/plugins/repl.nvim/lua/repl/peek.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `REPL_ROUTING.md:424–465` | **UNIQUE** shared terminal/R probe mechanism; molten-nvim, [Jupynium](https://github.com/kiyoon/jupynium.nvim) and [Neopyter](https://github.com/SUSTech-data/neopyter) provide kernel-based interaction through different connections. |
| Show peek results beside source as a popup or inline text; suppress undefined-expression and timeout noise. | `/home/ub/code/plugins/repl.nvim/lua/repl/peek.lua`; `REPL_ROUTING.md:413–450` | molten-nvim already displays floating and virtual-text results; the terminal-REPL connection is the distinction. |
| Capture REPL scrollback, extract the latest traceback or last N lines, and navigate traceback frames back into source, including IPython cell offsets. | `/home/ub/code/plugins/repl.nvim/lua/repl/jump_trace.lua` | [kitty-scrollback.nvim](https://github.com/mikesmithgh/kitty-scrollback.nvim) already retrieves/searches terminal history; **UNIQUE** traceback interpretation and IPython-cell-to-source matching among reviewed plugins. |

### Environment/project pairing

| Feature | Local evidence | Existing provision |
|---|---|---|
| Resolve project/file mappings to Conda Python/IPython paths, with a default environment. | `nvim/configs/repl-python-envs.json:1`; `/home/ub/code/plugins/repl.nvim/lua/repl/python_env.lua` | yarepl.nvim documents project-specific interpreter commands, including Conda paths. |
| Prompt for an unmapped project’s Conda environment and retain the pairing. | `/home/ub/code/plugins/repl.nvim/lua/repl/python_env.lua` | **UNIQUE** integrated persistent pairing prompt among reviewed REPL plugins; environment selection itself is established functionality. |
| Filter discovered REPLs by the buffer’s environment title and pin the absolute interpreter on launch/restart. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | **UNIQUE** external-session adoption policy among reviewed plugins. Existing-session validation uses environment-scoped titles; it is not independent proof of the process’s interpreter environment. |
| Add project-specific import roots to `PYTHONPATH` for launch/restart. | `/home/ub/code/plugins/repl.nvim/lua/repl/python/project_paths.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | Configurable launch commands/environments in yarepl.nvim and toggleterm.nvim cover the general capability. |

### Restart

| Feature | Local evidence | Existing provision |
|---|---|---|
| Restart Python in the bound Kitty window or tmux pane, retaining target identity and environment selection. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `bin/slime-repl-restart:469–493` | vim-ipython-cell already restarts IPython; molten-nvim and Neopyter restart kernels. Exact external-target preservation is additional integration. |
| Clean up owned Python descendants with escalating signals and handle a foreground interpreter without replacing its terminal window. | `bin/slime-repl-restart:308–330,373–386,477–490` | **UNIQUE** explicit owned-process cleanup and foreground restart handling among reviewed plugins. |
| Clear held cross-cell indentation state on restart. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/python/slime_format.lua` | **UNIQUE**, supporting the continuation feature above. |

### Routing between multiple REPLs

| Feature | Local evidence | Existing provision |
|---|---|---|
| Bind a source buffer to a specific socket/window and select among compatible sessions. | `/home/ub/code/plugins/repl.nvim/lua/repl/slime.lua` | vim-slime already has buffer-local target configuration; yarepl.nvim provides buffer attachment and multiple instances; molten-nvim supports multiple/shared kernels. |
| Dispatch common actions across terminal REPLs, R.nvim, explicitly connected Neopyter notebooks and the matching debugger language. | `/home/ub/code/plugins/repl.nvim/lua/repl/actions.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/router.lua` | **UNIQUE** this cross-plugin dispatcher; individual backends already provide their own execution. |
| Resolve restart separately from normal sends so a debugger destination does not automatically capture terminal restart. | `/home/ub/code/plugins/repl.nvim/lua/repl/actions.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/router.lua` | **UNIQUE** routing policy across these providers. |

Managed notebooks and explicitly attached percent files are resolved before debugger routing, so their sends stay with the notebook kernel.

### DAP sidecar

| Feature | Local evidence | Existing provision |
|---|---|---|
| Reuse source-send actions for the matching debugger console, including frame-bound Python evaluation. | `/home/ub/code/plugins/repl.nvim/lua/repl/dap_sidecar_backend.lua`; `/home/ub/code/plugins/repl.nvim/lua/repl/router.lua` | The console already belongs to **dap-sidecar.nvim**; **nvim-dap** supplies ordinary debugger evaluation. **UNIQUE** contribution here is the common source-send bridge. |
| Reuse cell/section/import readers and Python indentation handling between terminal and debugger execution. | `REPL_ROUTING.md:18–24,125–130`; `/home/ub/code/plugins/repl.nvim/lua/repl/python/slime_format.lua` | **UNIQUE** shared execution behavior across these destinations; the underlying debugger functionality is already a plugin dependency. |

### Other relevant assets

| Feature or asset | Local evidence | Existing provision |
|---|---|---|
| Resolve host-specific launchers and family-specific runtime sockets. | `nvim/lua/user/core/host_paths.lua:73–96`; `/home/ub/code/plugins/repl.nvim/lua/repl/paths.lua` | **UNIQUE** local host integration, rather than a strong standalone product distinction. |
| Expose traceback/tail capture to agent-prompt consumers. | `/home/ub/code/plugins/repl.nvim/lua/repl/jump_trace.lua`; `REPL_ROUTING.md:250–251` | kitty-scrollback.nvim covers text retrieval; **UNIQUE** automatic traceback/tail context selection in this integration. |
| Maintain an expected-outcome battery covering 22 Python-send cases, including guards, nested cells, blank lines and strings. | `/home/ub/code/plugins/repl.nvim/tests/repl_send_battery/cases.json:2–15,256–281` | Verification asset, not a novel runtime feature. Its presence does not establish a current passing run. |

### Verdict

**YES:** the external-session pairing, bidirectional focus, quiet runtime inspection, cross-cell continuation and restart lifecycle form a cohesive, substantial plugin.
Generic sending, cells, terminal creation and multiple sessions already have strong existing implementations.
Recommend a standalone plugin whose purpose is managing existing external REPL sessions, continuing to reuse those implementations.
Do not count host placement preferences, the existing DAP console or generic routing as additional novel capabilities.

### Astra adversarial review

**Astra independently agrees: YES.** Its strongest justification is the combination of external-session identity, runtime inspection and bidirectional focus.
It rejects generic sends/cells as novelty and limits “UNIQUE” to the reviewed comparison set.
Source inspection does not establish reliability outside the tested setup.