# repl_send_battery V10: parenthesised conditional expression (if/else lines inside the parens), with-block holding a for-loop, trailing comment.
# Copied verbatim from ~/code/fran/fran/inference/ensemble.py:991-1029.
# %%
#SECTION:-------------------- _base_runs--------------------------------------------------------------------------------------  # T:block_meta|EnsembleInferer._base_runs
    prds_all_base = {}
    r = next(iter(E.base_runs))  # T:loop_probe|for r in self.base_runs:
    prds_all_base[r] = []  # T:indent|    prds_all_base[r] = []
    mode, _ = get_mode_outchannels(r)  # T:indent|    mode, _ = get_mode_outchannels(r)
    member = (  # T:indent|    member = (
        WholeImageInferer(  # T:indent|        WholeImageInferer(
            r,  # T:indent|            r,
            devices=E.devices,  # T:self_ref|            devices=self.devices,
            safe_mode=E.safe_mode,  # T:self_ref|            safe_mode=self.safe_mode,
            save_channels=E.save_channels,  # T:self_ref|            save_channels=self.save_channels,
            debug=E.debug_base,  # T:self_ref|            debug=self.debug_base,
        )  # T:indent|        )
        if mode == "whole"  # T:indent|        if mode == "whole"
        else BaseInferer(  # T:indent|        else BaseInferer(
            r,  # T:indent|            r,
            devices=E.devices,  # T:self_ref|            devices=self.devices,
            safe_mode=E.safe_mode,  # T:self_ref|            safe_mode=self.safe_mode,
            save_channels=E.save_channels,  # T:self_ref|            save_channels=self.save_channels,
            debug=E.debug_base,  # T:self_ref|            debug=self.debug_base,
        )  # T:indent|        )
    )  # T:indent|    )
    with _InferenceSession(member) as inf:  # T:indent|    with _InferenceSession(member) as inf:
        inf.setup()  # T:indent|        inf.setup()
        inf.prepare_data(  # T:indent|        inf.prepare_data(
            data,  # T:indent|            data,
            collate_fn=img_bbox_collated  # T:indent|            collate_fn=img_bbox_collated
            if "bounding_box" in data[0].keys()  # T:indent|            if "bounding_box" in data[0].keys()
            else None,  # T:indent|            else None,
        )  # T:indent|        )
        inf.create_and_set_postprocess_transforms()  # T:indent|        inf.create_and_set_postprocess_transforms()
        for num_batches, batch in enumerate(inf.predict(), 1):  # T:indent|        for num_batches, batch in enumerate(inf.predict(), 1):
            batch = inf.postprocess(batch)  # T:indent|            batch = inf.postprocess(batch)
            prds_all_base[r].append(batch)  # T:indent|            prds_all_base[r].append(batch)
    preds_all_base = E.decollate_base_predictions(prds_all_base)  # T:self_ref|preds_all_base = self.decollate_base_predictions(prds_all_base)
    _base_runs_result = preds_all_base  # T:return|return preds_all_base
    # end PythonMethodScratch  # T:block_end|EnsembleInferer._base_runs

# %%
