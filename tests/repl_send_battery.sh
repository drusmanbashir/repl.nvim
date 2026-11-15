#!/usr/bin/env bash
# repl_send_battery.sh -- the editor -> IPython "send a code block" battery.
#
# PURPOSE: reds when <M-x> (cell), <M-X> (# SECTION: block) or visual <M-e>
# hands IPython a payload that drops a source line, raises SyntaxError /
# IndentationError, fails to run, runs a block that should be held open for the
# next cell, or leaves IPython waiting when the block was complete.
#
# Authority: REPL_ROUTING.md § `M-x` cell-send contract (python) and the
# operator ruling 2026-10-02 "DO NOT SKIP LINES TO PASS INTO REPL".
# Product under test: lua/repl/python/slime_format.lua, repl/cell.lua,
# repl/sections.lua, slime.lua send_cell / send_current_section / send_selection.
#
# Each case (repl_send_battery/cases.json, fixtures copied from real files in
# ~/code/regex1, ~/code/fran, ~/code/label_analysis):
#   1. capture.lua: headless nvim loads the repo's repl.slime spec through
#      directly configures repl.nvim and vim-slime, feeds the real mappings, and
#      stops at the fake kitty CLI
#      (fake_kitty.py records the send-text bytes);
#   2. judge.py: checks the payload line by line against the fixture, writes the
#      same bytes into a real IPython in a pty (bracketed paste + Enter, as kitty
#      does) and judges what IPython reports.
# Before the cases, paste_lines_unit.lua pins the hold rule's edges no sampled
# file exercises (comment-only gap, last cell, other REPL target, one line).
#
# Hermetic: env -i, private XDG dirs, private IPYTHONDIR, no DISPLAY, a fake
# kitty on PATH. Reads vim-slime under $REPL_BATTERY_VIM_SLIME_ROOT. It proves
# payload bytes and IPython behavior only; it never talks to live Kitty or a REPL.
#
# Usage: bash tests/repl_send_battery.sh [--only V01,V05] [--prove-red]
#   --prove-red  also run each witness mutant (a broken copy of the formatter)
#                and require it to red the cases cases.json says it reds,
#                while its named control stays green.
# Exit: 0 ALL GREEN, 1 FAIL, 2 INCONCLUSIVE.
# Env: NVIM_BIN, REPL_BATTERY_PYTHON (IPython + pexpect), REPL_BATTERY_VIM_SLIME_ROOT,
#      REPL_BATTERY_PLUGIN_ROOT (plugin dir under test), REPL_BATTERY_EVIDENCE.
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BATTERY="$TESTS_DIR/repl_send_battery"
PLUGIN_ROOT="${REPL_BATTERY_PLUGIN_ROOT:-$(cd -- "$TESTS_DIR/.." && pwd)}"
VIM_SLIME_ROOT="${REPL_BATTERY_VIM_SLIME_ROOT:-$HOME/.local/share/nvim/lazy/vim-slime}"
NVIM_BIN="${NVIM_BIN:-$(command -v nvim || true)}"
PY="${REPL_BATTERY_PYTHON:-$HOME/mambaforge/envs/dl/bin/python}"
CASES="$BATTERY/cases.json"
ONLY=""
PROVE_RED=0

while [ $# -gt 0 ]; do
	case "$1" in
	--only) ONLY="$2"; shift 2 ;;
	--prove-red) PROVE_RED=1; shift ;;
	*) echo "INCONCLUSIVE repl_send_battery: unknown argument $1"; exit 2 ;;
	esac
done

inconclusive() { echo "INCONCLUSIVE repl_send_battery: $*"; exit 2; }
[ -x "$NVIM_BIN" ] || inconclusive "no nvim (set NVIM_BIN)"
[ -x "$PY" ] || inconclusive "no python at $PY (set REPL_BATTERY_PYTHON)"
"$PY" -c "import IPython, pexpect, prompt_toolkit" 2>/dev/null || inconclusive "$PY lacks IPython/pexpect/prompt_toolkit"
[ -d "$VIM_SLIME_ROOT" ] || inconclusive "$VIM_SLIME_ROOT is not installed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repl-send-battery.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
rev="$(git -C "$PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null || echo norev)"
dirty="$(git -C "$PLUGIN_ROOT" status --porcelain -- lua 2>/dev/null | head -c1)"
[ -n "$dirty" ] && rev="$rev-dirty"
EVIDENCE="${REPL_BATTERY_EVIDENCE:-${TMPDIR:-/tmp}/repl-send-battery-evidence/$rev}"
mkdir -p "$EVIDENCE"

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cp "$BATTERY/fake_kitty.py" "$FAKEBIN/kitty"
chmod +x "$FAKEBIN/kitty"
for tool in kitty-focus-slime-target xdotool xprop wmctrl tmux; do
	printf '#!/bin/sh\necho "fake %s $*" >>"$BATTERY_CAPTURE_DIR/argv.log"\nexit 0\n' "$tool" >"$FAKEBIN/$tool"
	chmod +x "$FAKEBIN/$tool"
done

case_ids() {
	"$PY" -c 'import json,sys; [print(c["id"], c["fixture"]) for c in json.load(open(sys.argv[1]))["cases"]]' "$CASES"
}

# run_case <id> <fixture> <nvim tree> <evidence dir> -> prints the judge line, returns its exit code
run_case() {
	local id="$1" fixture="$2" tree="$3" evidence="$4"
	local cw="$WORK/$(basename "$tree")-$id"
	mkdir -p "$cw/run" "$cw/state" "$cw/config" "$cw/cache" "$cw/data" "$cw/capture" "$cw/src" "$cw/ipy"
	chmod 700 "$cw/run"
	cp "$BATTERY/fixtures/$fixture" "$cw/src/$fixture"
	(cd "$cw/src" && env -i HOME="$HOME" USER="${USER:-ub}" LANG="${LANG:-C.UTF-8}" \
		PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" \
		XDG_RUNTIME_DIR="$cw/run" XDG_STATE_HOME="$cw/state" XDG_CONFIG_HOME="$cw/config" \
		XDG_CACHE_HOME="$cw/cache" XDG_DATA_HOME="$cw/data" \
		NVIM_SLIME_TARGET=kitty NVIM_SLIME_KITTY_BIN="$FAKEBIN/kitty" \
		NVIM_SLIME_FOCUS_TARGET_HELPER="$FAKEBIN/kitty-focus-slime-target" \
		BATTERY_PLUGIN_ROOT="$tree" BATTERY_VIM_SLIME_ROOT="$VIM_SLIME_ROOT" BATTERY_CASES="$CASES" \
		BATTERY_CASE_ID="$id" BATTERY_FIXTURE="$cw/src/$fixture" BATTERY_CAPTURE_DIR="$cw/capture" \
		BATTERY_FAKE_TREE="$cw/fake-tree.json" BATTERY_WORK="$cw" \
		timeout 60 "$NVIM_BIN" --headless -n -i NONE -u NONE \
		-c "luafile $BATTERY/capture.lua" </dev/null >"$cw/nvim.log" 2>&1)
	local rc=$?
	mkdir -p "$evidence"
	cp "$cw/nvim.log" "$evidence/nvim.log" 2>/dev/null
	[ -f "$cw/capture/argv.log" ] && cp "$cw/capture/argv.log" "$evidence/argv.log"
	if [ ! -f "$cw/capture/manifest.json" ]; then
		echo "INCONCLUSIVE $id capture: nvim exited $rc without a manifest ($(tail -c 300 "$cw/nvim.log" | tr '\n' ' '))"
		return 2
	fi
	env -i HOME="$HOME" USER="${USER:-ub}" LANG="${LANG:-C.UTF-8}" PATH="/usr/local/bin:/usr/bin:/bin" \
		MPLCONFIGDIR="$cw/ipy/mpl" \
		timeout 300 "$PY" "$BATTERY/judge.py" --cases "$CASES" --case "$id" \
		--fixture "$BATTERY/fixtures/$fixture" --capture "$cw/capture" --python "$PY" \
		--work "$cw/ipy" --evidence "$evidence"
	rc=$?
	[ "$rc" -eq 124 ] && { echo "INCONCLUSIVE $id judge timed out"; return 2; }
	return "$rc"
}

# run_battery <nvim tree> <evidence root> <log> -> counts in globals
run_battery() {
	local tree="$1" evroot="$2" log="$3"
	N=0; NPASS=0; NFAIL=0; NINC=0; FAILED=""
	: >"$log"
	while read -r id fixture; do
		if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$id,"; then continue; fi
		N=$((N + 1))
		line="$(run_case "$id" "$fixture" "$tree" "$evroot/$id")"
		rc=$?
		echo "$line" | tee -a "$log"
		case "$rc" in
		0) NPASS=$((NPASS + 1)) ;;
		1) NFAIL=$((NFAIL + 1)); FAILED="$FAILED $id" ;;
		*) NINC=$((NINC + 1)); FAILED="$FAILED $id(inconclusive)" ;;
		esac
	done < <(case_ids)
}

if [ "$PROVE_RED" -eq 1 ]; then
	REPL_BATTERY_EVIDENCE="$EVIDENCE/prove-red" bash "$BATTERY/prove_red.sh" "$PLUGIN_ROOT" "$WORK" || exit $?
fi

# Hermeticity, measured: the battery must leave the tree under test exactly as
# it found it (lazy's lockfile, any file the editor might write).
tree_snapshot() {
	{ git -C "$PLUGIN_ROOT" status --porcelain --untracked-files=all -- . 2>/dev/null
	  stat -c '%n %s %Y' "$PLUGIN_ROOT/lazy-lock.json" 2>/dev/null; } | md5sum
}
before="$(tree_snapshot)"
unit_line="$(cd "$WORK" && env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin" XDG_STATE_HOME="$WORK/unit" \
	XDG_DATA_HOME="$WORK/unit" XDG_CONFIG_HOME="$WORK/unit" XDG_CACHE_HOME="$WORK/unit" \
	timeout 60 "$NVIM_BIN" --headless -n -i NONE -u NONE \
	-c "lua package.path = '$PLUGIN_ROOT/lua/?.lua;' .. package.path; vim.opt.rtp:prepend('$PLUGIN_ROOT')" \
	-c "luafile $BATTERY/paste_lines_unit.lua" </dev/null 2>&1)"
unit_rc=$?
echo "$unit_line"
run_battery "$PLUGIN_ROOT" "$EVIDENCE" "$WORK/battery.log"
if [ "$unit_rc" -ne 0 ]; then
	NFAIL=$((NFAIL + 1)); FAILED="$FAILED paste_lines_unit"
fi
if [ "$(tree_snapshot)" != "$before" ]; then
	echo "FAIL repl_send_battery: the run modified the tree under test ($PLUGIN_ROOT)"
	exit 1
fi
[ "$N" -gt 0 ] || inconclusive "no case selected (--only '$ONLY' matched nothing)"
cp "$WORK/battery.log" "$EVIDENCE/battery.log"
if [ "$NFAIL" -eq 0 ] && [ "$NINC" -eq 0 ]; then
	echo "ALL GREEN repl_send_battery ($N cases) evidence: $EVIDENCE"
	exit 0
fi
if [ "$NFAIL" -eq 0 ]; then
	echo "INCONCLUSIVE repl_send_battery: $NPASS/$N green, inconclusive:$FAILED evidence: $EVIDENCE"
	exit 2
fi
echo "FAIL repl_send_battery: $NPASS/$N green, red:$FAILED evidence: $EVIDENCE"
exit 1
