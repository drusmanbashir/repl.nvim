# repl_send_battery V12: for-loop cell, then a cell whose first line is deeper than its later lines (it continues the loop body).
# Copied verbatim from ~/code/label_analysis/label_analysis/geometry_pt.py:98-110.
# %%
    for cc in lmap.GetLabels():
        print(cc)
# %%
        self.key[int(cc)] = lab

    self.unique_lms.append(
        {
            "lmap": lmap,
            "label_org": lab,
            "n_islands": lmap.GetNumberOfLabelObjects(),
        }
    )
# %%
