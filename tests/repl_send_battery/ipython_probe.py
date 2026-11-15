"""IPython startup instrument for the REPL send battery (not product code).

Loaded as a profile startup file in a PRIVATE ipython dir. It never changes how
IPython parses or executes input; it only reports what IPython did:

  * every executed cell (post_run_cell): success, error type and message;
  * a FENCE key (F20, ESC[34~): the judge sends it after the payload bytes.
    prompt_toolkit handles keys in order and keeps typeahead across prompts,
    so when the fence handler runs, IPython has consumed everything before it.
    The handler records the pending input buffer (non-empty = IPython is
    waiting at a continuation prompt), the execution count and the watched
    names in the user namespace.

Env: BATTERY_EVENTS (jsonl out), BATTERY_WATCH_FILE (JSON list of expressions
the judge wants evaluated at the next fence), BATTERY_SEED (python run once in
user_ns before the first prompt).
"""
import json
import os

from IPython import get_ipython
from prompt_toolkit.key_binding import KeyBindings, merge_key_bindings

_ip = get_ipython()
_events_path = os.environ["BATTERY_EVENTS"]
_watch_file = os.environ["BATTERY_WATCH_FILE"]


def _emit(kind, **fields):
    fields["kind"] = kind
    with open(_events_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(fields, default=repr) + "\n")


def _post_run_cell(result):
    error = result.error_before_exec or result.error_in_exec
    _emit(
        "run",
        ok=bool(result.success),
        error=type(error).__name__ if error is not None else None,
        message=str(error)[:400] if error is not None else None,
        cell=result.info.raw_cell if result.info is not None else None,
    )


_ip.events.register("post_run_cell", _post_run_cell)

_fence_bindings = KeyBindings()


@_fence_bindings.add("f20")
def _fence(event):
    ns = _ip.user_ns
    values = {}
    with open(_watch_file, encoding="utf-8") as fh:
        watch = json.load(fh)
    for expr in watch:
        try:
            values[expr] = repr(eval(expr, ns))
        except Exception as exc:  # the judge reports the expression as unmet
            values[expr] = None
    _emit(
        "fence",
        buffer=event.app.current_buffer.text,
        execution_count=_ip.execution_count,
        names=sorted(k for k in ns if not k.startswith("_")),
        values=values,
    )


_ip.pt_app.key_bindings = merge_key_bindings([_ip.pt_app.key_bindings, _fence_bindings])

_seed = os.environ.get("BATTERY_SEED")
if _seed:
    exec(compile(_seed, "<battery-seed>", "exec"), _ip.user_ns)

_emit("ready")
