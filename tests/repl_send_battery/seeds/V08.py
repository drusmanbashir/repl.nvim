import functools
def nozero(func):
    @functools.wraps(func)
    def _inner(*args, **kwargs):
        return [x for x in func(*args, **kwargs) if x != 0]
    return _inner
