# wt profile for supercast-ios - a thin Hotwire native shell over the Rails app,
# built with xcodebuild and run on the iOS Simulator. Sourced by ~/.local/bin/wt.
#
# Unlike supercast.sh, this profile has nothing to isolate per worktree: the app
# builds a fixed bundle id (com.supercast.supercast-ios), so a second install on
# the same simulator just replaces the first. Rather than fight that with a
# simulator per worktree, `wt open` always targets the ONE shared simulator, and
# the last `wt open` wins - so "look at this branch on a device" stays a single
# command, at the cost of only ever being able to look at one branch at a time.
# Nothing is created per worktree, so `wt rm` and `wt gc --sweep` have no device
# lifecycle to get wrong - only a DerivedData directory to reclaim.
#
# The dev tab has no bundler or watcher to keep alive, so its long-running
# process is the device log filtered to this app (wt_dev, below). Ctrl-C on it
# is the normal way to stop watching, but `cmd_dev` (.local/bin/wt) prints "dev
# server exited (code N)" whenever wt_dev returns - read that as expected, not
# as a crash.
#
# Both apps point at the canonical https://app.supercast.test, not at a
# per-worktree backend: the debug host suffix is hardcoded in
# supercast-ios/Delegates/SceneDelegate.swift (DEBUG_SUFFIX = "supercast.test"),
# and only the subdomain is runtime-selectable. So the canonical Rails app has to
# actually be serving app.supercast.test for the app to show real content - wt_open
# warns, but does not fail, when it isn't.

WT_RESOURCES=""            # the simulator is shared; no port, no redis, nothing to allocate
WT_AGENT="claude"

: "${WT_IOS_DEVICE:=iPhone 17}"          # override to target a specific simulator
WT_IOS_SCHEME="supercast-ios"
WT_IOS_BUNDLE_ID="com.supercast.supercast-ios"
WT_IOS_APP="Supercast.app"
# The repo's own README documents ~/.puma-dev-ssl/root.pem, which does not exist
# on this machine - puma-dev's actual CA lives here instead.
WT_IOS_CA="$HOME/Library/Application Support/io.puma.dev/cert.pem"

# xcode-select -p on this machine is the bare CommandLineTools, which breaks both
# `xcodebuild` and `xcrun simctl` - DEVELOPER_DIR fixes both with no
# `sudo xcode-select -s`. Set inline (not just via wt_env's export) so any direct
# _wt_simctl call works even before wt_env has run in this shell.
_wt_simctl() { DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl "$@"; }

# The shared simulator's udid, resolved fresh on every call rather than recorded
# in state - it is not a per-worktree fact. Prefer whichever device is already
# booted (the one you are looking at); otherwise the first device named
# $WT_IOS_DEVICE. Candidates named alike differ only by runtime, and the app's
# deployment target (17.6) is satisfied by every runtime installed here, so which
# one we land on doesn't matter - which is what lets this not depend on the order
# `simctl` happens to emit its runtime keys in, not a documented guarantee.
_wt_ios_sim() {
  local udid
  udid=$(_wt_simctl list devices booted -j 2>/dev/null | jq -r '.devices[][] | .udid' 2>/dev/null | head -1)
  [ -n "$udid" ] && { printf '%s' "$udid"; return 0; }
  _wt_simctl list devices -j 2>/dev/null \
    | jq -r --arg name "$WT_IOS_DEVICE" '.devices[][] | select(.name == $name) | .udid' 2>/dev/null | head -1
}

# Single source of truth for this worktree's build env - shared by wt_provision,
# wt_open, wt_dev AND `wt run` (e.g. `wt run xcodebuild -version`), so all of them
# agree on the same DerivedData. The repo name is in the path deliberately:
# wt_sweep reclaims on a name pattern, and scoping it to this repo is what stops
# this profile ever claiming another project's build output.
#
# Also exports WT_IOS_UDID: device selection belongs to this profile (see
# _wt_ios_sim), so anything driving that device - `wt run wv eval '...'`, say -
# gets told which one rather than resolving it again itself. No simulator being
# resolvable yet is a normal state (e.g. before the first `wt open`), not a
# failure, so this must still return 0 in that case - same trap
# supercast-android's own wt_env documents for ANDROID_SERIAL.
#
# Deliberately NOT _wt_ios_sim: that helper also falls back to the first
# device merely NAMED $WT_IOS_DEVICE when nothing is booted, which is exactly
# right for wt_open (it needs a udid to boot) but wrong here - anything
# reading WT_IOS_UDID only drives an already-running device, and naming one
# that isn't booted yet would make an empty page list read as "wrong build"
# (see wv's own header) when the real fix is just "wt open first".
#
# Also unsets ANDROID_SERIAL and its own WT_IOS_UDID before resolving fresh:
# `wt run` exports straight into the calling shell (not a subshell), so
# switching from an Android worktree to this one in the same terminal
# without opening a new shell would otherwise leave a stale ANDROID_SERIAL
# sitting alongside the new WT_IOS_UDID - exactly the "both set" case wv
# treats as unrecoverable ambiguity. Unsetting WT_IOS_UDID too, not just
# conditionally overwriting it, closes the same staleness gap for a
# simulator that was booted, then shut down, without a fresh shell in between.
wt_env() {
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export WT_IOS_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/wt-$WT_REPO_NAME-$WT_SLUG"
  unset ANDROID_SERIAL WT_IOS_UDID
  local udid
  udid=$(_wt_simctl list devices booted -j 2>/dev/null | jq -r '.devices[][] | .udid' 2>/dev/null | head -1)
  [ -n "$udid" ] && export WT_IOS_UDID="$udid"
  return 0
}

wt_provision() {
  wt_env
  msg "resolving Swift package dependencies (can take a while on a fresh worktree)..."
  xcodebuild -resolvePackageDependencies -project "$WT_PATH/supercast-ios.xcodeproj" \
    -scheme "$WT_IOS_SCHEME" -derivedDataPath "$WT_IOS_DERIVED_DATA" \
    || { warn "resolvePackageDependencies failed - check Package.resolved"; return 1; }
  # So `wt ls` shows the backend the app actually talks to, not a fake <slug>.test.
  wt_state_set WT_URL "https://app.supercast.test"
}

# Build (unless --launch-only/-l), install and launch the app on the shared
# simulator - the "look at this branch on a device" action. Rerunning this is
# the reload.
wt_open() {
  local launch_only=0 udid app_path
  case "${1:-}" in --launch-only|-l) launch_only=1 ;; esac
  wt_env

  udid=$(_wt_ios_sim)
  [ -n "$udid" ] || { warn "no simulator named \"$WT_IOS_DEVICE\" is installed - create one in Xcode first"; return 1; }

  # Boot (if needed) and wait for boot to finish before anything else touches the
  # device, so install can't race it; then bring the Simulator window forward.
  _wt_simctl bootstatus "$udid" -b >/dev/null 2>&1
  open -a Simulator

  if [ -f "$WT_IOS_CA" ]; then
    _wt_simctl keychain "$udid" add-root-cert "$WT_IOS_CA" >/dev/null 2>&1 \
      || warn "installing the puma-dev CA into the simulator keychain failed (continuing)"
  fi

  if [ "$launch_only" = 0 ]; then
    msg "building $WT_IOS_SCHEME on $udid (this can take a while)..."
    # -quiet: the output lands in the terminal you typed `wt open` in; failures still print.
    xcodebuild -project "$WT_PATH/supercast-ios.xcodeproj" -scheme "$WT_IOS_SCHEME" \
      -configuration Debug -destination "id=$udid" \
      -derivedDataPath "$WT_IOS_DERIVED_DATA" -quiet build \
      || { warn "build failed"; return 1; }
  fi

  app_path="$WT_IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/$WT_IOS_APP"
  [ -d "$app_path" ] \
    || { warn "no build of $WT_IOS_APP found at $app_path - run 'wt open' once without --launch-only first"; return 1; }

  _wt_simctl terminate "$udid" "$WT_IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  _wt_simctl install "$udid" "$app_path" || { warn "install failed"; return 1; }
  _wt_simctl launch "$udid" "$WT_IOS_BUNDLE_ID" || { warn "launch failed"; return 1; }

  # Warn only: a down Rails app means the app comes up on an error page, not that
  # anything here is broken.
  curl -sk -m 3 https://app.supercast.test >/dev/null \
    || warn "https://app.supercast.test is not answering - is the canonical Rails app running?"
  msg "opened $WT_IOS_BUNDLE_ID on $udid"
}

# The dev tab's long-running process: device logs filtered to this app. There is
# no bundler to keep alive, so this - rather than a server - is what "dev"
# means here. The predicate survives relaunches, so this pane keeps working
# across every later `wt open`.
wt_dev() {
  wt_env
  local udid
  udid=$(_wt_ios_sim)
  [ -n "$udid" ] || { warn "no simulator named \"$WT_IOS_DEVICE\" is installed - create one in Xcode first"; return 1; }
  _wt_simctl bootstatus "$udid" -b >/dev/null 2>&1
  msg "streaming device logs for $WT_IOS_APP (Ctrl-C to stop - see this profile's header comment)"
  _wt_simctl spawn "$udid" log stream --style compact --predicate 'processImagePath CONTAINS "Supercast"'
}

# Reclaim what this profile allocates once a worktree is gone entirely: its
# DerivedData. Guarded to the full repo-scoped prefix with something after it, so
# neither a malformed nor an empty slug can ever widen this to another directory.
wt_sweep() {
  local live dir slug dry=${WT_SWEEP_DRY:-}
  live=$(printf '%s\n' "${WT_LIVE_SLUGS:-}" | sed '/^$/d')
  for dir in "$HOME"/Library/Developer/Xcode/DerivedData/wt-supercast-ios-*; do
    [ -d "$dir" ] || continue
    slug=${dir##*/wt-supercast-ios-}
    [ -n "$slug" ] || continue
    grep -qxF "$slug" <<<"$live" && continue
    if [ -n "$dry" ]; then printf '%s\n' "$dir"; continue; fi
    rm -rf "$dir" && msg "swept $dir"
  done
}

wt_teardown() {
  wt_env
  case "$WT_IOS_DERIVED_DATA" in
    "$HOME/Library/Developer/Xcode/DerivedData/wt-supercast-ios-"?*)
      rm -rf "$WT_IOS_DERIVED_DATA" && msg "removed $WT_IOS_DERIVED_DATA" ;;
    *) warn "WT_IOS_DERIVED_DATA ($WT_IOS_DERIVED_DATA) doesn't match the expected prefix - not removing" ;;
  esac
}
