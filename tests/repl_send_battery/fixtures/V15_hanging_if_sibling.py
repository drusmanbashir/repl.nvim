# repl_send_battery V15: cell ends in a non-guard `if ...:` header with no body; the next cell is a sibling, not its body.
# Copied verbatim from ~/code/fran/build/lib/fran/extra/rough.py:803-815 (closing `# %%` added).
# %%
        # %%
        lm = sitk.ReadImage(str(lm_fn))
        labels = get_labels(lm)
        if not labels == [1]:

# %%
#SECTION:-------------------- Gradients--------------------------------------------------------------------------------------
        from torch import nn
        x = torch.tensor([0.0,2], requires_grad=True)
        y = (x>0.5).float()



# %%
