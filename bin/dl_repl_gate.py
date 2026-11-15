"""The backend focus gate -- one Python implementation of the policy.

The question this answers is narrow: given the published focus state, may a
focus/launch wrapper act, or must it do nothing at all?

FAIL-OPEN, and the asymmetry is the whole design. A deny stops the caller dead:
`sinclair/kitty-focus-edit` treats it as "exit 0, do nothing", so a wrong deny does
not degrade `<M-l>` -- it silently disables the key until the user notices it is
dead. A wrong allow merely lets a focus attempt proceed and miss. So the ONLY
state that denies is one that positively proves an incompatible backend:

    fresh AND parses as an object AND family == "python"
    AND a backend is present AND that backend is neither slime nor neopyter
    AND (no expected namespace, or the state's namespace agrees)

Everything else -- absent file, unparsable JSON, a non-object root, a stale
timestamp, a missing family, a missing backend, another family, a foreign
namespace -- allows. `oracle/adapters/slime/ml_reverse_regression.sh` asserts
exactly this matrix, and asserts that this module and the standalone
`bin/dl-repl-python-buffer-gate` agree on every fixture in it.

WHY THERE IS STILL A SECOND COPY: `bin/dl-repl-python-buffer-gate` carries the
same ladder and is NOT reduced to a wrapper around this module, because editing
that script is currently off limits (it is spawned by `sinclair/kitty-focus-repl`
and asserted directly by `oracle/adapters/slime/fixtures/iron_focus_gate.lua`).
Until that changes, the differential test is what keeps them equal -- if you
change the policy here, change it there in the same commit or that test fails.
"""

from __future__ import annotations

import json
import os
import time

DEFAULT_MAX_AGE = 3600

# Backends that own Python focus themselves; their presence is not a denial.
FOCUSABLE_PYTHON_BACKENDS = ("slime", "neopyter")


def max_age_from_env():
    """`DL_FOCUS_SLIME_MAX_AGE`, or the default. A non-numeric value falls back
    rather than raising: the gate may not fail closed on its own confusion."""
    raw = os.environ.get("DL_FOCUS_SLIME_MAX_AGE", "")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return DEFAULT_MAX_AGE


def denies(state_file, now=None, max_age=None, expected_namespace=None):
    """True only for a confident policy denial. See the module docstring.

    Every early return is an ALLOW. Read the ladder as "give up the moment we
    cannot prove an incompatible backend".
    """
    if now is None:
        now = time.time()
    if max_age is None:
        max_age = max_age_from_env()
    if expected_namespace is None:
        expected_namespace = os.environ.get("DL_SESSION_NAMESPACE", "")

    if not os.path.exists(state_file):
        return False
    try:
        with open(state_file, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except Exception:
        return False
    if not isinstance(state, dict):
        return False

    try:
        age = now - float(state.get("updated_at", 0))
    except Exception:
        return False
    if age > max_age:
        return False

    family = state.get("family")
    if family in (None, ""):
        return False

    state_namespace = state.get("namespace")
    if expected_namespace and state_namespace and state_namespace != expected_namespace:
        return False

    backend = state.get("backend")
    if backend in (None, ""):
        return False

    if family != "python":
        return False

    if backend in FOCUSABLE_PYTHON_BACKENDS:
        return False

    return True
