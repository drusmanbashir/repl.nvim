# repl_send_battery V11: cell ends inside a while-loop body.
# Copied verbatim from ~/code/fran/fran/twop5d/training.py:220-226.
# %%

    iteri = iter(dlv)
    while iteri:
        batch = next(iteri)
        print(batch["image"].shape)

# %%
