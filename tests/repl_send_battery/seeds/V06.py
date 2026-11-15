import bdb
import traceback
from pathlib import Path
import pandas as pd
mini_df = pd.DataFrame([{"case_id": "c1", "image": "/x/img_1.nii.gz", "lm": "/x/lm_1.nii.gz", "lm_imported": None}])
class RegionBoundedDataGenerator:
    def _process_row(self, row):
        raise ValueError("bad spacing")
R = RegionBoundedDataGenerator()
def strip_extension(name):
    return name.split(".")[0]
