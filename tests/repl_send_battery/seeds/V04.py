import itertools as il
from pathlib import Path
Path("v04").mkdir(exist_ok=True)
(Path("v04") / "b.nii.gz").write_text("x")
