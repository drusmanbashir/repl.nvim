# Migration

Move the existing REPL session implementation into this repository. Keep one owner per responsibility: Lua modules here, bundled launch/restart/inspection/reverse-focus helpers here, desktop placement and application-specific integration in the host configuration. Preserve existing module consumers through one-line forwarding adapters until they can use `repl.*` directly.

1. Extract Lua modules and remove dependencies on `user.*` configuration.
2. Bundle runtime helpers with paths resolved relative to this plugin.
3. Forward the host configuration and scripts; retain project/environment maps, shortcuts and placement policy. Leave Python uncapped and show the optional 100G command in comments.
4. Verify independent setup/imports, all 22 send cases, the complete Slime Oracle adapter and a real capped Python process. Fix regressions before installing the host adapters.
5. Install the verified adapters and recheck the installed configuration.

The test family includes the Slime Oracle adapter's launch, bind, send, cross-environment, continuation, focus, reverse-focus and placement rows; Python send battery; Python inspection probes; Lua/Python path parity; standalone module/configuration checks; bundled runtime command and memory-scope checks. Neopyter and DAP implementation stay in their existing plugins; routing precedence is checked directly without modifying those providers.

Completion means the active host configuration uses the standalone plugin, the old implementation files contain only forwarding code, and the declared checks have recorded results. Unrelated dirty work stays untouched.

Physical monitor EDID identity is OUT on the hidden Xvfb display: it has no hardware EDID. This host-specific placement preference is outside the plugin scope. The placement fixture's geometry assertions passed; its physical GSM-monitor identity assertion remains unavailable. Focus, reverse focus, launch and sends remain TEST and must pass unchanged assertions.
