# repl_send_battery V06: try / except A / blank line / except B with f-string concatenation and nested dict literal.
# Copied verbatim from ~/code/fran/fran/preprocessing/regionbounded.py:765-801.
# %%
#SECTION:-------------------- process--------------------------------------------------------------------------------------  # T:block_meta|RegionBoundedDataGenerator.process
    outs = []
    i, row = next(iter(mini_df.iterrows()))  # T:loop_probe|for i, row in mini_df.iterrows():
    try:  # T:indent|    try:
        outs.append(R._process_row(row))  # T:self_ref|        outs.append(self._process_row(row))
    except bdb.BdbQuit:  # T:indent|    except bdb.BdbQuit:
        raise  # T:indent|        raise

    except Exception as e:  # T:indent|    except Exception as e:
        trace = traceback.format_exc()  # T:indent|        trace = traceback.format_exc()
        print(  # T:indent|        print(
            f"[{R.__class__.__name__}] error:"  # T:self_ref|            f"[{self.__class__.__name__}] error:"
            f"\n  case_id={row.get('case_id')}"  # T:indent|            f"\\n  case_id={row.get('case_id')}"
            f"\n  image={row.get('image')}"  # T:indent|            f"\\n  image={row.get('image')}"
            f"\n  lm={row.get('lm')}"  # T:indent|            f"\\n  lm={row.get('lm')}"
            f"\n  lm_imported={row.get('lm_imported')}"  # T:indent|            f"\\n  lm_imported={row.get('lm_imported')}"
        )  # T:indent|        )
        print(trace.rstrip())  # T:indent|        print(trace.rstrip())
        fn_name = strip_extension(Path(str(row.get("image"))).name) + ".pt"  # T:indent|        fn_name = strip_extension(Path(str(row.get("image"))).name) + ".pt"
        outs.append(  # T:indent|        outs.append(
            {  # T:indent|            {
                "case_id": row.get("case_id"),  # T:indent|                "case_id": row.get("case_id"),
                "fn_name": fn_name,  # T:indent|                "fn_name": fn_name,
                "ok": False,  # T:indent|                "ok": False,
                "err": repr(e),  # T:indent|                "err": repr(e),
                "labels": None,  # T:indent|                "labels": None,
                "_preprocess_events": [],  # T:indent|                "_preprocess_events": [],
                "_preprocess_error": {  # T:indent|                "_preprocess_error": {
                    "error_type": type(e).__name__,  # T:indent|                    "error_type": type(e).__name__,
                    "error_message": str(e),  # T:indent|                    "error_message": str(e),
                    "traceback": trace,  # T:indent|                    "traceback": trace,
                },  # T:indent|                },
            }  # T:indent|            }
        )  # T:indent|        )
    process_result = outs  # T:return|return outs
    # end PythonMethodScratch  # T:block_end|RegionBoundedDataGenerator.process
# %%  # T:block_start|RegionBoundedDataGenerator._index_bbox_files_by_case_id
