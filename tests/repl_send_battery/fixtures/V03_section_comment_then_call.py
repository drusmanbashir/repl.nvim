# repl_send_battery V03: body-only cell: blank line, col-0 `# SECTION:` comment, then indented code ending in a multi-line call.
# Copied verbatim from ~/code/fran/fran/inference/cascade.py:657-674.
# %%

# SECTION:-------------------- TOTALSEG WholeImageinferer-------------------------------------------------------------------------------------- <CR> <CR> <CR> <CR> <CR> <CR> <CR>
    run_w1 = get_run_w("whole")
    spec = scratch_spec(run_w1)
    devices = [0]
    debug_ = True
    safe_mode = False
    overwrite = False
    W = WholeImageInferer(
        spec.run_name,
        project_title="totalseg",
        safe_mode=safe_mode,
        k_largest=spec.k_largest,
        save_channels=False,
        debug=debug_,
        devices=devices,
    )
# %%
