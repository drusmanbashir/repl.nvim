import types
from battery_standins import Anything
np = Anything("np")
S = types.SimpleNamespace(empty_lm="one", LG=Anything("LG"), LP=Anything("LP"))
labels_overlap = lambda *args: (0.5, 0.25)
