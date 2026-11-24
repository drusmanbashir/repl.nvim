# REPL Focus State Architecture

Design authority and implementation record for moving buffer-derived work out
of the `<M-h>` focus path. The ready Slime route is implemented in
`repl.focus`; workflow coverage lives in `oracle/adapters/slime/WORKFLOWS.md`.

## Decision

Use three state layers:

1. `vim.b[buf].ub_repl_context`: in-memory context for each loaded buffer.
2. `repl_paths.state_file()`: one atomic JSON projection of the active buffer
   plus its current REPL binding, for OS helpers.
3. `<state-file>.routes/<platform-window-id>.<kitty-child-id>.json`: one atomic
   last-source route per REPL target, used by unnumbered `<M-l>` before the pair
   registry fallback.

Do not create one disk file per buffer or persist every loaded buffer. `<M-h>`
needs only the active source. A buffer map grows stale and makes source
selection ambiguous after buffer deletion or Neovim restart.

Each route payload contains schema version, family, diagnostic timestamp,
publishing Neovim pid, and the source editor's control socket, platform-window
id, and Kitty child id. The target ids come only from the filename. Route age
is ignored.

Keep buffer-derived specification separate from live binding:

```text
buffer path/config -> REPL specification -> launch or bind -> live binding -> focus
```

`<M-h>` owns only the last arrow. It must never resolve an environment,
discover or launch a REPL, update registries, inspect terminal text, or change
IPython mode.

## State schema

The active JSON projection should have three namespaced sections:

```text
schema_version, generation, updated_at
source:
  nvim_pid, buffer_id, path, filetype, project_root
  kitty_listen_on, kitty_window_id, platform_window_id
repl_spec:
  family, backend, namespace
  env_name, env_prefix, executable
  title_base, socket, launcher, start_command, window_class
  fingerprint
binding:
  status                       # unbound | ready | stale
  listen_on, window_id, platform_window_id, title
  fingerprint, bound_at
```

`repl_spec.fingerprint` identifies the buffer-derived contract. At minimum it
includes `family`, `backend`, `namespace`, `env_name`, `socket`, and
`title_base`. A binding is focusable only when its fingerprint equals the
active specification fingerprint.

`generation` increments whenever the active projection changes. Writers use
temporary-file plus atomic rename. Readers reject malformed, old-version,
stale, namespace-mismatched, or fingerprint-mismatched state.

## Ownership and timing

### Current `<M-h>` work: destination

| Current operation | Classification | Future owner |
| --- | --- | --- |
| `print-window-title` | Buffer/environment-derived; unused on the successful focus route | Remove from focus; `repl_spec.title_base` or Initialize fallback |
| `dl-repl-python-buffer-gate` | Buffer family/backend policy | Active-context publisher; focus validates stored backend/family |
| Two `dl_repl_paths.py` calls | Runtime/namespace configuration | Publish paths in `repl_spec`; resolve the state-file location without starting Python per keypress |
| Main Python startup/imports | Implementation overhead, not focus semantics | Eliminate from common focus path |
| Kitty socket scan and `kitty @ ls` | Target discovery/validation | Bind; direct focus uses stored IDs |
| Environment/process/title matching | Buffer spec plus target validation | Spec producer plus Bind |
| Main-state and pair-registry writes | Publication/lifecycle bookkeeping | Buffer publisher and Bind |
| Per-target reverse-route claim | Last bind/send/successful jump ownership | Explicit claim after Bind/send validation or final successful Focus callback |
| First kitty child selection | Live focus | Must remain after `<M-h>` |
| OS-window activation | Live focus | Must remain after `<M-h>` |
| Second kitty child selection | Platform focus correction | Must remain after `<M-h>` unless platform evidence removes it |
| Prompt `get-text`, `Esc`, `A` | Mode mutation unrelated to window focus | Remove; prompt_toolkit owns prompt input mode |

### Buffer-derived: publish before `<M-h>`

Compute on `FileType`/`BufEnter`, project/environment mapping reload, backend
change, and namespace change:

- buffer path, filetype, project root;
- REPL family and configured backend;
- namespace and platform;
- conda environment name/prefix;
- absolute Python/IPython executable;
- REPL title base and window class;
- kitty socket, launcher, and start command;
- source kitty IDs already available in Neovim's environment;
- specification fingerprint.

These values depend on buffer/configuration, not a keypress. Publish them from
one method even when no REPL is bound. This lets external helpers fail closed
for Iron, Neopyter, R.nvim, non-REPL buffers, and wrong namespaces without
starting Python to rediscover policy.

### Invalidation matrix

| Event | Recompute | Preserve |
| --- | --- | --- |
| `FileType`, `BufEnter`, `BufFilePost`, or `DirChanged` | Source fields and full `repl_spec` | Binding only when the new fingerprint matches |
| Environment-pairing config reload | Environment, executable, title, launcher/start command, fingerprint | Source identity |
| Backend toggle | Backend and fingerprint | Target identity only as dormant history; active binding becomes unbound unless compatible Slime is explicitly rebound |
| Namespace/session change | Namespace, socket, fingerprint, source identity | Nothing from the foreign namespace |
| Kitty source window/tab change or `FocusGained` | Source kitty IDs and active projection | Matching .spec/binding |
| Initialize/Bind/restart | Binding identity/status/timestamp | Active source and spec |
| Target exit or direct-focus failure | Binding status becomes stale outside the hot path | Spec, so explicit Bind can recover |
| Buffer deletion | Delete only in-memory `vim.b` context | Active disk projection is replaced by the next valid active buffer |

### Lifecycle-derived: publish at launch or bind

Compute only when a target is created, discovered, selected, restarted, or
invalidated:

- target kitty socket/window/platform IDs;
- actual window title and optional process identity;
- binding status and binding fingerprint;
- source-to-target registry entry;
- bind timestamp.

Launch and bind may perform process discovery, socket scans, title filtering,
environment validation, user selection, and registry writes. None belong in
the repeated focus path.

### Must happen after `<M-h>`

The ready-binding path is limited to:

1. Read `vim.b.ub_repl_context` in memory. The JSON projection exists for
   external compatibility consumers, not for Neovim's keypress path.
2. Validate schema, namespace, backend, `binding.status == ready`,
   and matching fingerprints.
3. Use the minimum measured kitty-child/OS-window focus sequence. Compare
   child-before-raise-plus-reassert, raise-then-child, and already-active
   variants instead of assuming both child-selection calls are required.
4. Avoid `kitty @` subprocess startup in the hot path; use in-process remote
   control where supported. Measure macOS activation separately from Linux.

After the final child-focus callback succeeds, schedule one tiny atomic route
claim using the already-validated buffer context. A direct focus failure marks
the binding stale outside the critical path, preserves the prior route owner,
and directs the user to explicit bind/launch. It must not silently scan sockets
or launch a second REPL from `<M-h>`.

## Lifecycle separation

### Initialize a new REPL

Owner: `launch_new_repl`-style command (`<leader>in` for Python Slime).

1. Read the active `repl_spec`.
2. Launch the specified kitty window/process.
3. Wait for the exact environment-scoped title and process.
4. Pass the resulting identity to Bind.

### Bind an existing REPL

Owner: explicit select/discover path (`<leader>it`, `<leader>rp`, or the
documented discover-only consumer).

1. Read the active `repl_spec`.
2. Discover only matching socket/title/family/environment targets.
3. Select when multiple matches exist.
4. Validate and publish a `ready` binding with the same fingerprint.

Bind never starts a process. Initialize may call Bind after creation.

### Focus an already-bound REPL

Owner: `<M-h>`.

Read and validate the ready binding, then focus it directly. Unbound, stale,
wrong-backend, and wrong-namespace states are fail-fast outcomes, not alternate
launch algorithms.

## Existing Neovim methods and intersections

| Current method | Current responsibility | Design role |
| --- | --- | --- |
| `repl_python_env.context_root` / `resolve_for_buffer` | Project and conda environment resolution | Buffer-context producer; compute once per invalidation |
| `repl_specs.slime_kitty_spec` | Title, socket, launcher, executable/start command | Produce `repl_spec` from one environment resolution |
| `repl_backend.current` / `set_current` | Family backend policy and transitions | Producer plus invalidation trigger |
| `repl_focus.publish_target` | Public state/context publication interface; source and optional target | Delegates only the atomic main-state write to `repl_focus_state` |
| `repl_focus.claim_route` | Explicit reverse-route ownership interface | Delegates the one atomic route write to `repl_focus_state.claim_route` |
| `slime.publish_active_slime_focus_target` | Publishes on `BufEnter`/`FocusGained` | Publish complete buffer spec, then overlay any matching binding |
| `slime.bind_kitty_repl` | Stores selected target and emits `ReplChanged` | Sole ready-binding publisher |
| `slime.register_kitty_repl` | Ensure/discover/start/select mixture | Split Initialize from Bind |
| `slime.launch_new_repl` | Explicit new-window creation | Initialize, then Bind |
| `slime.discover_kitty_repl_target` | Existing-target discovery without launch | Bind |
| `kitty-focus-slime-target` | Resolve, repair, register, and focus for external compatibility consumers | No longer used by Neovim's ready-focus path; prompt mutation removed |

`publish_target`, `BufEnter`, and `FocusGained` write state/context only and
never create, overwrite, or remove a reverse route. The single explicit
`claim_route` API is used by changed binds, validated unchanged binds on the
send path, and `M-h` only after its final child-focus callback succeeds. A
failed focus preserves the prior owner. The centralized pager guard denies
both state publication and route claims. `VimLeavePre` removes routes naming
the exiting editor while leaving other targets and editors untouched. Cleanup
requires the route's publishing pid as well as its Kitty identity, so a nested
Neovim with inherited environment cannot delete its parent's route.

Current state is duplicated across `vim.b.slime_config`, per-family `vim.g`
variables, the active focus JSON, and the pair registry. The active buffer
context should be canonical inside Neovim; compatibility mirrors may remain
during migration but must not independently resolve policy.

## LSP/import comparison

The pass found no persistent LSP/import buffer-state publisher to merge:

- `lspconfig.on_attach` installs buffer-local mappings and capabilities.
- `pymple.lua` supplies plugin configuration and root markers.
- `python/import_cleanup.lua` reads the current buffer on demand and caches a
  donor import map by path plus modification time.

Share the method pattern, not the REPL file:

- namespaced buffer-local tables;
- one producer per domain;
- explicit invalidation events;
- cached derived values keyed by stable inputs;
- persistence only when an external process needs the value.

Putting import maps, LSP capabilities, or diagnostics in the focus JSON would
couple unrelated invalidation rates, enlarge every focus read, and create stale
cross-domain state. A future generic `buffer_context` utility may provide
namespaced in-memory storage and atomic projection helpers, but the external
projection remains REPL-focus-specific.

## Locked invariants

1. Common `<M-h>` starts no policy/path/discovery interpreter, external kitty
   CLI, or socket scan; use stored IDs and in-process remote control.
2. `<M-h>` never creates, binds, starts, or restarts a REPL.
3. Buffer/environment/title/executable resolution occurs before `<M-h>`.
4. A target is focusable only when binding and active-spec fingerprints match.
5. Iron, R.nvim, Neopyter, non-REPL buffers, and namespace mismatches cannot
   reuse a stale Slime binding.
6. Linux and macOS share the schema and lifecycle; OS activation and its
   measured latency remain platform-specific.
7. No terminal transcript read or `Esc`/`A` mode mutation occurs during focus.
8. Workflow changes satisfy the Oracle contract in
   `oracle/adapters/slime/WORKFLOWS.md`.

## Measured focus sequence

Sinclair's accepted F01 Oracle run used one child selection after exact X11
window activation and measured 63.40–70.34 ms from mapping dispatch to
confirmed X input focus across targeted and full-suite runs (120 ms ceiling).
The earlier child-before-raise plus reassert
sequence is therefore unnecessary on Linux. macOS retains child select,
application activation, and child reassert because application activation can
change kitty's active OS window; its F02 latency remains a separate Mac-host
gate and must not be inferred from the Linux number.
