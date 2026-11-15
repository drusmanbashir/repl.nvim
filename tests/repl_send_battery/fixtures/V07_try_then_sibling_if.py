# repl_send_battery V07: try/except/raise followed by a sibling if-block, an `# end` comment and a whitespace-only line.
# Copied verbatim from ~/code/fran/fran/preprocessing/fixed_spacing.py:831-851.
# %%
    try:
        shard_paths = writer.run(num_processes=num_processes)
    except Exception as e:
        F.logger.exception(  # T:self_ref|    self.logger.exception(
            e,
            error_type="HDF5ShardWrite",
            image=str(F.output_folder / "images"),  # T:self_ref|        image=str(self.output_folder / "images"),
            lm=str(F.output_folder / "lms"),  # T:self_ref|        lm=str(self.output_folder / "lms"),
        )
        raise
    if F.delete_pt_after_shard_creation:  # T:self_ref|if self.delete_pt_after_shard_creation:
        for subfolder in ("images", "lms", "indices"):
            pth = F.output_folder / subfolder  # T:self_ref|        pth = self.output_folder / subfolder
            if pth.exists():
                shutil.rmtree(pth)
    process_hdf5_result = shard_paths  # T:return|return shard_paths
    # end PythonMethodScratch  # T:block_end|FGBGIndicesResampleDataset.process_hdf5

    

# %%
