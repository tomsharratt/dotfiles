#!/bin/bash
# Status line: current context usage vs the model's max context window, plus
# the current session's rate-limit usage and reset time.
# Renders e.g. "128K / 1M · session 9% (resets 6:30pm)".
#
# JSON fields used (see statusline stdin payload):
#   .context_window.total_input_tokens   "used" tokens - input tokens
#     currently sitting in the context window, including cache reads/writes.
#     This is the most accurate available signal for "current context size";
#     it is also what Claude Code itself divides by context_window_size to
#     produce used_percentage. Caveat: it reflects the last completed API
#     call, so it may lag slightly (by that call's output tokens) behind the
#     true context size right after a response streams in.
#   .context_window.context_window_size  the max context window for the
#     current model. Claude Code resolves model variants here already (e.g.
#     opus-4.8[1m] -> 1000000), so this is preferred over hardcoding.
#   .model.id                            fallback only, used if
#     context_window_size is missing/zero: detects a "1m" marker in the
#     model id for the 1M-context variant, else assumes the standard 200K
#     window.
#   .rate_limits.five_hour.used_percentage  percent of the current 5-hour
#     session window consumed (integer). This is the "session" usage.
#   .rate_limits.five_hour.resets_at        unix epoch (seconds) at which the
#     current session window resets. Absent on older Claude Code versions, in
#     which case the session segment is omitted.

input=$(cat)

used=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
max=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
model_id=$(echo "$input" | jq -r '.model.id // ""')
session_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
session_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

if [ -z "$max" ] || [ "$max" = "0" ] || [ "$max" = "null" ]; then
  if echo "$model_id" | grep -qi '1m'; then
    max=1000000
  else
    max=200000
  fi
fi

# Compact human-readable token count: "500", "45.2K", "128K", "1M".
format_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) { v = n / 1000000; u = "M" }
    else if (n >= 1000) { v = n / 1000; u = "K" }
    else { printf "%d", n; exit }
    s = sprintf("%.1f", v)
    gsub(/\.0$/, "", s)
    printf "%s%s", s, u
  }'
}

# Format a unix epoch as a clock time (e.g. "6:30pm"), prefixing the weekday
# ("Sat 6:30pm") when the reset falls on a different day than today.
format_reset() {
  local ts="$1"
  local fmt='+%-I:%M%p'
  if [ "$(date -r "$ts" '+%j')" != "$(date '+%j')" ]; then
    fmt='+%a %-I:%M%p'
  fi
  date -r "$ts" "$fmt" | sed 's/AM$/am/; s/PM$/pm/'
}

used_fmt=$(format_tokens "$used")
max_fmt=$(format_tokens "$max")

out=$(printf '%s / %s' "$used_fmt" "$max_fmt")

if [ -n "$session_pct" ]; then
  seg=$(printf 'session %.0f%%' "$session_pct")
  if [ -n "$session_reset" ]; then
    seg=$(printf '%s (resets %s)' "$seg" "$(format_reset "$session_reset")")
  fi
  out=$(printf '%s · %s' "$out" "$seg")
fi

printf '%s' "$out"
