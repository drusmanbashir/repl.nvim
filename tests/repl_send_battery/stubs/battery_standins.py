"""Stand-ins for the REPL send battery's fixtures (not product code).

The fixtures are copies of real REPL cells from ~/code/fran and
~/code/label_analysis. Their names (torch, SimpleITK, fran managers, `self`-
like scratch objects) do not exist in the battery's IPython, and what the
battery judges is how IPython PARSES and RUNS the sent block, not what those
libraries compute. So a case's seed installs:

  * install([...module names]): those imports resolve to synthetic modules;
  * Anything(name): an object that absorbs any call, attribute, index,
    arithmetic or `with`, so a copied line runs without its library.

Values a case asserts on are always plain Python the fixture computes itself.
"""
import importlib.abc
import importlib.machinery
import sys
import types


class Anything:
    def __init__(self, name="standin", *args, **kwargs):
        object.__setattr__(self, "_name", str(name))

    def __mro_entries__(self, bases):
        return (object,)  # `class C(nn.Module)` with nn a stand-in: a plain class

    def __call__(self, *args, **kwargs):
        return Anything(self._name + "()")

    def __getattr__(self, attr):
        if attr.startswith("__") and attr.endswith("__"):
            raise AttributeError(attr)
        return Anything(self._name + "." + attr)

    def __setattr__(self, attr, value):
        pass

    def __getitem__(self, key):
        return Anything(self._name + "[]")

    def __setitem__(self, key, value):
        pass

    def __iter__(self):
        return iter(())

    def __len__(self):
        return 0

    def __bool__(self):
        return True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def __repr__(self):
        return "<standin %s>" % self._name

    def _binary(self, other):
        return Anything(self._name + "op")

    __add__ = __radd__ = __sub__ = __rsub__ = __mul__ = __rmul__ = _binary
    __truediv__ = __rtruediv__ = __mod__ = __rmod__ = __matmul__ = __or__ = __and__ = _binary


class _Finder(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def __init__(self, roots):
        self.roots = set(roots)

    def find_spec(self, fullname, path, target=None):
        if fullname.split(".")[0] in self.roots:
            return importlib.machinery.ModuleSpec(fullname, self, is_package=True)
        return None

    def create_module(self, spec):
        module = types.ModuleType(spec.name)
        module.__path__ = []
        module.__getattr__ = lambda attr: Anything(spec.name + "." + attr)
        return module

    def exec_module(self, module):
        return None


def install(roots):
    for root in roots:
        sys.modules.pop(root, None)
    sys.meta_path.insert(0, _Finder(roots))
