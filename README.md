# repl.nvim

Manage external Kitty REPL sessions from Neovim: pair source buffers with exact terminal windows, move focus in both directions, inspect values, continue Python blocks across cells, restart in place, and jump from tracebacks to source. vim-slime sends the code. R.nvim, Neopyter and dap-sidecar remain optional providers.

## Installation

With lazy.nvim and a local checkout:

```lua
{
  dir = vim.fn.expand("~/code/plugins/repl.nvim"),
  dependencies = { "jpalardy/vim-slime" },
  config = function()
    require("repl").setup({
      -- Kitty executable. The default is the executable on PATH.
      kitty_bin = "kitty",
      -- kitty_bin = "/absolute/path/to/kitty", -- pin an installed build

      -- Persistent project-to-Conda-environment pairings.
      python_envs = vim.fn.stdpath("data") .. "/repl/python-envs.json",
      -- python_envs = "/absolute/path/to/python-envs.json", -- reuse an existing map

      languages = {
        python = {
          -- Omit command: resolve the project's IPython, without a memory cap.
          -- command = "systemd-run --user --scope -p MemoryMax=100G -p MemorySwapMax=0 ipython", -- Linux: cap REPL and children, no swap
          -- command = "/absolute/path/to/env/bin/ipython", -- pin an interpreter
        },
        r = {
          command = "R --quiet --no-save", -- ordinary R console
          -- command = "radian", -- alternative console, when installed
          -- command = "R --vanilla", -- ignore saved state and startup files
        },
        lua = {
          command = "lua", -- interpreter on PATH
          -- command = "luajit", -- LuaJIT, when installed
          -- command = "/absolute/path/to/lua", -- pin an interpreter
        },
        octave = {
          command = "octave --no-gui --quiet", -- GNU Octave on PATH
        },
        sage = {
          command = "sage", -- SageMath on PATH
        },
      },
    })
  end,
}
```

Use the same setup table with other plugin managers after loading vim-slime. Kitty needs an enabled remote-control Unix socket. Slime prepares the payload; the plugin sends it and queries Kitty through Neovim’s socket API. Python needs IPython. R, Lua, GNU Octave, SageMath, Conda and desktop window tools are needed only for the corresponding features. `systemd-run` caps are Linux user-session features; omitting that prefix leaves memory uncapped. Restart retains the configured Python command. The plugin adds the IPython options and bundled inspection server needed by its send/peek behavior.

The plugin follows the [Neovim plugin layout](https://neovim.io/doc/user/lua-plugin/). Its runtime code is under `lua/repl/`; Python helpers are bundled under `bin/` and `python/`.

## Configuration

`backend_config` selects a family and engine for each filetype. All Slime/Kitty families use the bundled launcher by default. Set `place_window_helper` once for desktop placement. After creating a window, the launcher calls it with the resolved socket, Kitty executable, child window ID (empty on a cold start) and title. The helper receives the language in `DL_REPL_FAMILY`. Reusing a window preserves its position. Each language can configure its interpreter `command` or explicitly override the `launcher`.

Other configuration entries:

- `backend_config`: optional JSON file selecting the provider for each filetype. Omit it for Slime defaults. The existing `nvim/repl-backends.json` shape is supported.
- `python_paths`: optional JSON file of project-specific Python import roots. Omit it to keep the inherited `PYTHONPATH` unchanged.
- `focus_back_helper`: optional compiled window-raise executable or a function returning its path when needed. Without one, Linux uses `xdotool`.
- `focus_target_helper`: optional host focus bridge for existing desktop shortcuts.
- `focus_lab(bufnr)`: optional callback to focus the browser page belonging to a notebook.
- `callbacks.ensure_iron()`: optional host callback to load and configure Iron. Existing host R.nvim and Neopyter adapters register through `repl.actions.register_backend`.

The host configuration at `~/scripts/nvim/lua/user/repl_plugin.lua` documents the active settings and commented alternatives. Generic sends and cell extraction reuse existing plugins. The plugin does not own the DAP console or JupyterLab server lifecycle.

## Keys and reverse focus

The existing send/focus actions are available through `repl.backend`, `repl.actions` and `repl.focus_route`. `M-x` sends a cell; `M-X` sends a SECTION block; `M-e` sends a line or selection; `M-k` peeks (the sidecar value popup while debugging, with no console text); `M-R` restarts; `M-h` focuses the paired destination. The Python continuation state belongs to each target and resets on restart.

In a `.m` file that Neovim identifies as Octave, `# %%` marks a cell. `M-x` sends the cell to the paired Octave window. `M-R` starts a fresh Octave session in that same window using the configured command. Startup and restart wait for Octave's standard `octave:N>` prompt.

In a `.sage` file, `# %%` marks a cell. `M-x` sends it to a separate SageMath window. SageMath interprets its own syntax, including `^` for powers. `M-R` replaces the SageMath process in the same Kitty window using the configured command. Use SageMath's standard interactive prompt (`sage:`).

For reverse focus from Kitty, invoke the bundled `bin/kitty-focus-slime-source --window-id <active Kitty child ID>`. The existing host Kitty/desktop shortcuts remain supported by their desktop entrypoints. Unbound terminals are a no-op; bindings do not expire with age.

## Verification

Run `tools/test --list` to list the plugin-owned checks. `tools/test repl_send_battery.sh` covers the 22 source-preservation and IPython execution cases. Run `~/scripts/oracle/adapters/slime/run.sh` for real Kitty/Neovim behavior on hidden displays. The capture battery is a payload check; Oracle supplies the live transport and focus evidence. Test results are reported from actual runs, not inferred from this document.

Run `:help repl.nvim` for setup and keys. Linux is the current verification host; macOS live focus/launch behavior remains unverified. The hidden-display gate cannot verify physical monitor identity; host placement remains outside the plugin.
