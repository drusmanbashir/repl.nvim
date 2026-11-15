# repl_send_battery V04: nested def inside the guard: if/else, for/if/else, blank line inside the def, return.
# Copied verbatim from ~/code/fran/fran/inference/cascade.py:684-712.
# %%

    def filter_existing_files(files, target_folder,recursive=True):
        files = [Path(img) for img in files]
        file_names = [fn.name for fn in files]
        print(
            "Filtering existing predictions\nNumber of images provided: {}".format(
                len(files)
            )
        )
        if recursive==True:
            existing_fns = list(target_folder.rglob("*"))
        else:
            existing_fns = list(target_folder.glob("*"))
        existing_fnnames = [fn.name for fn in existing_fns]
        to_do = []
        for fn in file_names:
            if fn in existing_fnnames:
                to_do.append(False)
            else:
                to_do.append(True)

        files = list(il.compress(files, to_do))
        print(
            "Number of images not found in folder {0}:  {1}".format(
                target_folder, len(files)
            )
        )
        return files
# %%
