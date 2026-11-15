# repl_send_battery V02: guard with its body; blank lines, a lambda, and an indented `    # %%` splitting the body into two cells.
# Copied verbatim from ~/code/fran/fran/evaluation/losses.py:383-400.
# %%
if __name__ == "__main__":
    from nnunet.utilities.nd_softmax import softmax_helper

    softmax_helper = lambda x: F.softmax(x, 1)
    P = Project("nodes")
    conf = ConfigMaker(P, configuration_filename=None).config
    loss_params = conf["loss_params"]

    targ = torch.load("tests/files/image.pt", weights_only=False)
    pred = torch.load("tests/files/pred.pt", weights_only=False)
    target = torch.load("tests/files/target.pt", weights_only=False)

    fg_classes = 1
    # %%
    loss_func = CombinedLoss(**loss_params, fg_classes=fg_classes)

    loss = loss_func.forward(pred, target)
# %%
