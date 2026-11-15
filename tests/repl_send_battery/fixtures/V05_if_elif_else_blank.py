# repl_send_battery V05: body-only if / blank line / elif / else with a multi-line call.
# Copied verbatim from ~/code/label_analysis/label_analysis/overlap/core.py:1580-1591.
# %%
# SECTION:-------------------- compute--------------------------------------------------------------------------------------
    if S.empty_lm == "both":
        S.dsc_overall, S.jac_overall = np.nan, np.nan

    elif S.empty_lm == "one":
        S.dsc_overall, S.jac_overall = 0.0, 0.0
    else:
        S.dsc_overall, S.jac_overall = labels_overlap(
            S.LG.li_binary_sitk, S.LP.li_binary_sitk, 1, 1
        )

# %%
