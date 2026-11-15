import os
import zipfile
from battery_standins import install
install(["torch"])
path = "v09.bin"
with open(path, "wb") as _fh:
    _fh.write(b"PK\x03\x04battery")
