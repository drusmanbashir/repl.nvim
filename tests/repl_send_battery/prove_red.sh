#!/usr/bin/env bash
# prove_red.sh -- the battery's fail-capable witness (called by
# repl_send_battery.sh --prove-red; usable alone: prove_red.sh <plugin tree> <work dir>).
#
# For each mutant in mutants.json: copy <plugin tree>/lua to a throwaway dir,
# plant the named defect in that copy (the `find` text must occur exactly once,
# so a refactor that moves the code makes this INCONCLUSIVE instead of vacuous),
# run the battery against the copy for the mutant's `reds` and `control` cases,
# and require every red case to FAIL and every control case to stay green.
# The operator's tree is never modified.
# Exit: 0 every mutant proved, 1 a mutant failed to red (or reddened a control), 2 inconclusive.
set -uo pipefail
BATTERY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$BATTERY/../repl_send_battery.sh"
TREE="$1"
WORK="$2"
PY="${REPL_BATTERY_PYTHON:-$HOME/mambaforge/envs/dl/bin/python}"
EVROOT="${REPL_BATTERY_EVIDENCE:-${TMPDIR:-/tmp}/repl-send-battery-evidence/prove-red}"
status=0

mutant_ids() {
	"$PY" -c 'import json,sys; [print(m["id"]) for m in json.load(open(sys.argv[1]))["mutants"]]' "$BATTERY/mutants.json"
}

field() { # field <mutant id> <key> -> comma list or text
	"$PY" -c '
import json, sys
m = [m for m in json.load(open(sys.argv[1]))["mutants"] if m["id"] == sys.argv[2]][0]
v = m[sys.argv[3]]
print(",".join(v) if isinstance(v, list) else v)' "$BATTERY/mutants.json" "$1" "$2"
}

plant() { # plant <mutant id> <tree copy>
	"$PY" - "$BATTERY/mutants.json" "$1" "$2" <<'PY'
import json, sys
m = [m for m in json.load(open(sys.argv[1]))["mutants"] if m["id"] == sys.argv[2]][0]
path = sys.argv[3] + "/" + m["file"]
src = open(path, encoding="utf-8").read()
if src.count(m["find"]) != 1:
    print("INCONCLUSIVE prove-red %s: anchor found %d times in %s" % (m["id"], src.count(m["find"]), m["file"]))
    sys.exit(2)
open(path, "w", encoding="utf-8").write(src.replace(m["find"], m["replace"]))
PY
}

while read -r mid; do
	copy="$WORK/mutant-$mid"
	rm -rf "$copy"
	mkdir -p "$copy"
	cp -r "$TREE/lua" "$copy/lua"
	plant "$mid" "$copy" || { status=2; continue; }
	reds="$(field "$mid" reds)"
	control="$(field "$mid" control)"
	out="$(REPL_BATTERY_PLUGIN_ROOT="$copy" REPL_BATTERY_EVIDENCE="$EVROOT/$mid" \
		bash "$RUNNER" --only "$reds,$control")"
	missed=""
	broke=""
	for id in ${reds//,/ }; do
		printf '%s\n' "$out" | grep -q "^FAIL $id " || missed="$missed $id"
	done
	for id in ${control//,/ }; do
		printf '%s\n' "$out" | grep -q "^PASS $id " || broke="$broke $id"
	done
	if [ -z "$missed" ] && [ -z "$broke" ]; then
		echo "PROVE-RED $mid ok: $(field "$mid" what) -> red: $reds; control green: $control"
	else
		echo "PROVE-RED $mid FAILED: $(field "$mid" what) -> stayed green:${missed:- none}; control broke:${broke:- none}"
		printf '%s\n' "$out" | sed 's/^/    /'
		status=1
	fi
done < <(mutant_ids)
exit "$status"
