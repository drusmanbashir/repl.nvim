import types
class _Loader:
    """iter(dlv) is dlv; it turns falsy once drained, so `while iteri:` ends."""
    def __init__(self, n):
        self.left, self.taken = n, 0
    def __iter__(self):
        return self
    def __bool__(self):
        return self.left > 0
    def __next__(self):
        if self.left == 0:
            raise StopIteration
        self.left -= 1
        self.taken += 1
        return {"image": types.SimpleNamespace(shape=(1, 2, 3))}
dlv = _Loader(3)
