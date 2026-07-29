#!/usr/bin/env bash
# test/wv-args.sh - wv's pure argument/environment logic. Every one of these
# must fail before wv ever touches a device, a proxy, or Node itself - picking
# a platform by accident would drive the wrong device and produce a
# measurement of nothing (see .local/bin/wv's own header). Follows
# test/wt-open.sh's pattern: pass/fail counters with ok/bad helpers, a stubbed
# PATH, trap cleanup EXIT, and a final tally with a non-zero exit on any
# failure.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WV="$HERE/../.local/bin/wv"

# None of these cases should ever reach xcrun, adb, ios_webkit_debug_proxy or
# node - stubbing them anyway turns a regression that DID reach one into a
# loud, specific failure instead of this test quietly hanging or touching
# real hardware.
STUBBIN=$(mktemp -d)
for cmd in xcrun adb ios_webkit_debug_proxy node; do
  cat > "$STUBBIN/$cmd" <<EOF
#!/bin/sh
echo "$cmd should never be invoked by these test cases" >&2
exit 99
EOF
  chmod +x "$STUBBIN/$cmd"
done

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

cleanup() { rm -rf "$STUBBIN"; }
trap cleanup EXIT

# Every case starts from a clean, known environment - the ambient
# ANDROID_SERIAL a real emulator exposes, or an interactive shell's own
# WT_IOS_UDID/WV_NODE, must never leak into a case that is testing the
# ABSENCE of these variables.
CLEAN=(env -u WT_IOS_UDID -u ANDROID_SERIAL -u WV_NODE PATH="$STUBBIN:$PATH")

# Each of the next two checks both variable names AND the branch-specific
# word ("neither"/"both") - substrings alone don't tell the two die branches
# apart, so a regression that swapped which condition fires which message
# would still pass a check that only grepped for the variable names.
echo "== neither WT_IOS_UDID nor ANDROID_SERIAL set: fails, naming both ==" >&2
out=$("${CLEAN[@]}" "$WV" eval 'location.href' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when neither device var is set (got rc=$rc)"
if grep -q 'WT_IOS_UDID' <<<"$out" && grep -q 'ANDROID_SERIAL' <<<"$out" && grep -qi 'neither' <<<"$out"; then
  ok
else
  bad "error should name both WT_IOS_UDID and ANDROID_SERIAL, and say 'neither' (got '$out')"
fi

echo "== both WT_IOS_UDID and ANDROID_SERIAL set: fails, naming both ==" >&2
out=$(env -u WV_NODE WT_IOS_UDID=fake-udid ANDROID_SERIAL=fake-serial PATH="$STUBBIN:$PATH" \
  "$WV" eval 'location.href' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when both device vars are set (got rc=$rc)"
if grep -q 'WT_IOS_UDID' <<<"$out" && grep -q 'ANDROID_SERIAL' <<<"$out" && grep -qi 'both' <<<"$out"; then
  ok
else
  bad "error should name both WT_IOS_UDID and ANDROID_SERIAL, and say 'both' (got '$out')"
fi

echo "== no subcommand: usage on stderr, non-zero exit ==" >&2
out=$("${CLEAN[@]}" "$WV" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero with no subcommand (got rc=$rc)"
case "$out" in *usage:*) ok ;; *) bad "should print usage (got '$out')" ;; esac

echo "== unknown subcommand: usage on stderr, non-zero exit ==" >&2
out=$("${CLEAN[@]}" "$WV" bogus 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero with an unknown subcommand (got rc=$rc)"
case "$out" in *usage:*) ok ;; *) bad "should print usage (got '$out')" ;; esac

echo "== eval with no expression: a clear error, non-zero exit ==" >&2
out=$("${CLEAN[@]}" "$WV" eval 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when eval gets no expression (got rc=$rc)"
case "$out" in *expression*) ok ;; *) bad "should name the missing expression (got '$out')" ;; esac

echo "== WV_NODE pointing at a path that does not exist: names the interpreter, not 'command not found' ==" >&2
out=$(env -u ANDROID_SERIAL WT_IOS_UDID=fake-udid WV_NODE=/no/such/node PATH="$STUBBIN:$PATH" \
  "$WV" eval 'location.href' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when WV_NODE points nowhere (got rc=$rc)"
case "$out" in
  *"command not found"*) bad "should not surface a bare 'command not found' (got '$out')" ;;
  *"/no/such/node"*)     ok ;;
  *)                     bad "should name the interpreter path it could not find (got '$out')" ;;
esac

echo "== eval given more than one argument: a clear error, non-zero exit ==" >&2
out=$("${CLEAN[@]}" "$WV" eval 'true' 'false' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when eval gets more than one argument (got rc=$rc)"
case "$out" in *"one expression"*) ok ;; *) bad "should say to quote the expression (got '$out')" ;; esac

echo "== shot given more than one argument: a clear error, non-zero exit ==" >&2
out=$("${CLEAN[@]}" "$WV" shot one two 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "should exit non-zero when shot gets more than one argument (got rc=$rc)"
case "$out" in *"usage"*) ok ;; *) bad "should print a usage error (got '$out')" ;; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ]
