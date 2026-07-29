# wt profile for supercast-android - a thin Hotwire native shell over the Rails
# app, built with Gradle and run on the Android Emulator. Sourced by ~/.local/bin/wt.
#
# Unlike supercast.sh, this profile has nothing to isolate per worktree: the app
# builds a fixed applicationId (com.supercast.supercast), so a second install on
# the same emulator just replaces the first. Rather than fight that with an
# emulator per worktree, `wt open` always targets the ONE shared emulator, and
# the last `wt open` wins - so "look at this branch on a device" stays a single
# command, at the cost of only ever being able to look at one branch at a time.
# There is nothing durable outside the worktree to reclaim on `wt rm`, so this
# profile defines no wt_teardown or wt_sweep; the Gradle build directory goes
# when the worktree does, and it is unknowable whether the app currently on the
# device came from the worktree being removed, so nothing uninstalls it.
#
# The dev tab has no bundler or watcher to keep alive, so its long-running
# process is the app's logcat output (wt_dev, below), followed across relaunches
# by re-finding its pid. Ctrl-C on it is the normal way to stop watching, but
# `cmd_dev` (.local/bin/wt) prints "dev server exited (code N)" whenever wt_dev
# returns - read that as expected, not as a crash.
#
# Both apps point at the canonical https://app.supercast.test, not at a
# per-worktree backend: BASE_URL_SUFFIX is hardcoded to "supercast.test" in the
# debug build type (app/build.gradle.kts), and only the subdomain is
# runtime-selectable. So the canonical Rails app has to actually be serving
# app.supercast.test for the app to show real content - wt_open warns, but does
# not fail, when it isn't.
#
# The one AVD on this machine (Pixel_6, android-33, google_apis) is already
# patched per the repo README: the puma-dev CA in /system/etc/security/cacerts
# and a 10.0.2.2 app.supercast.test line in /etc/hosts. Those patches live in the
# AVD's own qcow2 image, written there by a -writable-system boot - which is why
# every boot here passes -writable-system: without it the system partition
# reverts to the pristine image and both patches disappear.

WT_RESOURCES=""            # the emulator is shared; nothing to allocate
WT_AGENT="claude"

: "${WT_ANDROID_AVD:=Pixel_6}"            # override to target a specific AVD
WT_ANDROID_PKG="com.supercast.supercast"

# `adb`/`emulator` are not on PATH by default; they live under whichever SDK
# local.properties (gitignored, so read from the canonical checkout - sdk.dir is
# a machine fact, not a per-worktree one) names. The repo's own README instead
# points at ~/Library/Android/sdk, a SECOND SDK install on this machine - reading
# sdk.dir here is what keeps Gradle and `adb` on the same one.
_wt_android_sdk() {
  local sdk
  sdk=$(sed -n 's/^sdk\.dir=//p' "$WT_REPO/local.properties" 2>/dev/null | head -1)
  printf '%s' "${sdk:-${ANDROID_HOME:-}}"
}

# Single source of truth for this worktree's build/adb env - shared by
# wt_provision, wt_open, wt_dev AND `wt run` (e.g. `wt run adb shell ...`), so all
# of them agree on the same SDK and the same running device.
wt_env() {
  local sdk; sdk=$(_wt_android_sdk)
  [ -n "$sdk" ] || { warn "no sdk.dir in $WT_REPO/local.properties and ANDROID_HOME is unset"; return 1; }
  export ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk"
  export PATH="$sdk/platform-tools:$sdk/emulator:$PATH"
  local serial; serial=$(adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
  # No device connected yet is a normal, expected state (before the emulator has
  # been booted) - not a failure, so this must not become wt_env's own exit
  # status merely because the && test was false.
  [ -n "$serial" ] && export ANDROID_SERIAL="$serial"
  return 0
}

# Warn - never fail - when the shared AVD's own patches (see header) seem to be
# missing, naming the exact repo README commands that fix each. This is a
# property of the AVD, not of any worktree, so it is skipped entirely when no
# device is connected at all.
_wt_android_check() {
  adb get-state >/dev/null 2>&1 || return 0

  adb shell "grep -q supercast.test /etc/hosts" >/dev/null 2>&1 || {
    warn "the emulator's /etc/hosts has no supercast.test entry - fix with:"
    warn "  adb root && adb remount"
    warn "  adb shell \"echo '10.0.2.2 app.supercast.test' >> /etc/hosts\""
  }

  local ca=$HOME/Library/'Application Support'/io.puma.dev/cert.pem hash
  if [ -f "$ca" ]; then
    hash=$(openssl x509 -inform PEM -subject_hash_old -in "$ca" 2>/dev/null | head -1)
    if [ -n "$hash" ] && ! adb shell "[ -f /system/etc/security/cacerts/$hash.0 ]" >/dev/null 2>&1; then
      warn "the puma-dev CA is not in the emulator's system trust store - fix with:"
      warn "  CERT=\"$ca\"; HASH=\$(openssl x509 -inform PEM -subject_hash_old -in \"\$CERT\" | head -1)"
      warn '  cp "$CERT" "/tmp/$HASH.0" && adb push "/tmp/$HASH.0" "/sdcard/$HASH.0"'
      warn '  adb shell "cp /sdcard/$HASH.0 /system/etc/security/cacerts/$HASH.0 && chmod 644 /system/etc/security/cacerts/$HASH.0"'
      warn "  adb reboot"
    fi
  fi
  # This is diagnostic-only and must always report success - wt_provision calls it
  # as its own last statement, so the "nothing to warn about" case (an unfired if)
  # must not leak through as a false failure.
  return 0
}

# Reuse the emulator already in `adb devices`; otherwise boot the shared AVD,
# ALWAYS with -writable-system (see header), detached so it survives this
# command returning. Logged outside the repo since the emulator is shared, not
# this worktree's.
#
# Two `wt open`/`wt dev` calls racing this at once (two mobile worktrees'
# implementer sessions starting together, say) are safe without any locking
# here: the emulator binary itself refuses to start a second instance against
# an AVD that is already running ("Running multiple emulators with the same
# AVD is an experimental feature") - verified directly, not assumed. The
# loser's spawn just fails fast into its own log, and both callers converge on
# the one real device via the polling below.
_wt_android_boot() {
  local serial log="" device_timeout=60 boot_timeout=180 waited=0
  serial=$(adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
  if [ -z "$serial" ]; then
    log="${TMPDIR:-/tmp}/wt-supercast-android-emulator.log"
    msg "booting emulator $WT_ANDROID_AVD -writable-system (log: $log)..."
    nohup emulator -avd "$WT_ANDROID_AVD" -writable-system >"$log" 2>&1 &
    disown 2>/dev/null || true
  fi
  # adb wait-for-device has no timeout of its own, so a dead or never-starting
  # emulator process would otherwise hang wt_open/wt_dev forever - poll instead.
  while ! adb get-state >/dev/null 2>&1; do
    if [ "$waited" -ge "$device_timeout" ]; then
      warn "no emulator device appeared within ${device_timeout}s${log:+ (see $log)}"
      return 1
    fi
    sleep 2; waited=$((waited + 2))
  done
  waited=0
  while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" != "1" ]; do
    if [ "$waited" -ge "$boot_timeout" ]; then warn "emulator did not finish booting within ${boot_timeout}s"; return 1; fi
    sleep 2; waited=$((waited + 2))
  done
  serial=$(adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
  [ -n "$serial" ] && export ANDROID_SERIAL="$serial"
  return 0
}

wt_provision() {
  if [ ! -e "$WT_PATH/local.properties" ]; then
    ln -s "$WT_REPO/local.properties" "$WT_PATH/local.properties" && msg "linked local.properties"
  fi
  wt_env || return 1
  # So `wt ls` shows the backend the app actually talks to, not a fake <slug>.test.
  wt_state_set WT_URL "https://app.supercast.test"
  _wt_android_check
}

# Build (unless --launch-only/-l), install and launch the app on the shared
# emulator - the "look at this branch on a device" action. Rerunning this is
# the reload.
wt_open() {
  local launch_only=0 activity
  case "${1:-}" in --launch-only|-l) launch_only=1 ;; esac
  wt_env || return 1
  _wt_android_boot || return 1
  _wt_android_check

  if [ "$launch_only" = 0 ]; then
    msg "installDebug on ${ANDROID_SERIAL:-the emulator}..."
    ( cd "$WT_PATH" && ./gradlew --console=plain installDebug ) || { warn "installDebug failed"; return 1; }
  fi

  adb shell am force-stop "$WT_ANDROID_PKG" >/dev/null 2>&1 || true
  activity=$(adb shell cmd package resolve-activity --brief "$WT_ANDROID_PKG" 2>/dev/null | tail -1 | tr -d '\r')
  [ -n "$activity" ] || { warn "could not resolve a launcher activity for $WT_ANDROID_PKG - is it installed?"; return 1; }
  adb shell am start -n "$activity" >/dev/null || { warn "am start failed"; return 1; }

  # Warn only: a down Rails app means the app comes up on an error page, not that
  # anything here is broken.
  curl -sk -m 3 https://app.supercast.test >/dev/null \
    || warn "https://app.supercast.test is not answering - is the canonical Rails app running?"
  msg "opened $WT_ANDROID_PKG on ${ANDROID_SERIAL:-the emulator}"
}

# The dev tab's long-running process: the app's own logcat, followed across
# relaunches. A plain `adb logcat` is unusably noisy and logcat's own filters key
# on tag, not package, so this instead waits for the app's pid and scopes to it -
# then, once that process exits (the app was killed by the next `wt open`),
# loops back and waits for the new one.
wt_dev() {
  wt_env || return 1
  msg "streaming logcat for $WT_ANDROID_PKG (Ctrl-C to stop - see this profile's header comment)"
  while :; do
    local pid=""
    while [ -z "$pid" ]; do
      pid=$(adb shell pidof "$WT_ANDROID_PKG" 2>/dev/null | tr -d '\r\n ')
      [ -n "$pid" ] || sleep 2
    done
    adb logcat --pid="$pid"
  done
}
