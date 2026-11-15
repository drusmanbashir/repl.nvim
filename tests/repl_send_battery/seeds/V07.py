import shutil
import types
from pathlib import Path
from battery_standins import Anything
class _Writer:
    def run(self, num_processes):
        return ["shard0.h5"]
writer = _Writer()
num_processes = 1
F = types.SimpleNamespace(logger=Anything("logger"), output_folder=Path("v07"), delete_pt_after_shard_creation=True)
(Path("v07") / "images").mkdir(parents=True, exist_ok=True)
