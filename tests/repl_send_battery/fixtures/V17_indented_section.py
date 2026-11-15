# repl_send_battery V17: indented `    # SECTION:` markers; the block has blank lines, comments, an f-string and ends with an indented `    # %%`.
# Copied verbatim from ~/code/fran/fran/trainers/incremental.py:527-561.
# %%
    # %%
    # SECTION:-------------------- COnfirm plans exist--------------------------------------------------------------------------------------

    device_id = 1
    bs = 4

    # run_name ='LITS-1285'
    compiled = False
    profiler = False
    # NOTE: if wandb = False, should store checkpoint locally
    batchsize_finder = False
    wandb = True
    override_dm = False
    tags = []
    description = f"first run on partial ds"

    conf["plan_train"]

    # cbs = [PeriodicTest(every_n_epochs=1,limit_batches=50)]

    conf["dataset_params"]["cache_rate"] = 0.0
    print(conf["model_params"]["out_channels"])

    conf["dataset_params"]["cache_rate"]

    conf["dataset_params"]["fold"] = 0
    run_name = "LIDC-0002"
    run_name = None
    lr = 1e-2
    debug = True
    debug = False
    train_init_indices = 150
    # %%
    # SECTION:-------------------- TRAIN--------------------------------------------------------------------------------------
    Tm = TrainerIncremental(P.project_title, conf, run_name, debug=debug)
