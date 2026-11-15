# repl_send_battery V13: guard body split by INDENTED `    # %%` markers; cursor in the middle sub-cell.
# Copied verbatim from ~/code/fran/build/lib/fran/extra/rough.py:627-645 (closing `# %%` added).
# %%
if __name__ == "__main__":
    fn = "/s/xnat_shadow/crc/sampling/tensors/fixed_spacing/images/crc_CRC012_20180422_ABDOMEN.pt"
    lm = torch.load(fn)
    ImageMaskViewer([lm, lm])
    fldr = Path("/s/xnat_shadow/crc/tensors/fixed_spacing/lms/")
    fls = list(fldr.glob("*"))
    # %%
    bad = []
    for fn in fls:
        lm = torch.load(fn)
        if "filename_or_obj" in lm.meta.keys():
            print("Pass")
        else:
            bad.append(fn)
    # %%
    fn = "/s/xnat_shadow/crc/tensors/fixed_spacing/lms/crc_CRC016_20190121_CAP11.pt"

    lm = torch.load(fn)
    lm.meta
# %%
