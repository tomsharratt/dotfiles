#!/bin/bash
# Status line: current context usage vs the model's max context window, plus how
# much of this month's usage budget the account has spent.
# Renders e.g. "128K / 1M · budget 2% ($217 / $10K)".
#
# Context, from the statusline stdin payload:
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
#
# Budget, from Claude Code's own cache in ~/.claude.json, because the stdin
# payload has nothing to offer: the account is an Enterprise seat with a
# monthly spend limit and no five-hour or weekly window, so `.rate_limits`
# is absent altogether (`.rate_limits.spend_limit` is only filled behind a
# Claude gateway). Claude Code writes the cache whenever it reads its usage
# endpoint, which it does now and then rather than on a schedule - a headless
# `claude -p` never does - so the segment says when the figure is from once
# it is more than an hour old.
#   .cachedUsageUtilization.accountUuid  must match .oauthAccount.accountUuid,
#     the check Claude Code itself makes, so another login's spend is never shown.
#   .cachedUsageUtilization.fetchedAtMs  when the snapshot was taken.
#   .cachedUsageUtilization.utilization.extra_usage
#     .used_credits / .monthly_limit     minor units of .currency, scaled by
#       .decimal_places (cents for USD: 1000000 is $10,000).
#     .utilization                       percent of the limit spent.
#     .spend_limit_reached               the hard stop: nothing runs until the
#       month turns over or the limit is raised.
# Anything missing or unexpected omits the segment rather than guessing.

input=$(cat)

used=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
max=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
model_id=$(echo "$input" | jq -r '.model.id // ""')

if [ -z "$max" ] || [ "$max" = "0" ] || [ "$max" = "null" ]; then
  if echo "$model_id" | grep -qi '1m'; then
    max=1000000
  else
    max=200000
  fi
fi

# Compact human-readable amount: "500", "45.2K", "128K", "1M", with an
# optional prefix for money ("$217", "$10K").
format_amount() {
  awk -v n="$1" -v p="${2:-}" 'BEGIN {
    if (n >= 1000000) { v = n / 1000000; u = "M" }
    else if (n >= 1000) { v = n / 1000; u = "K" }
    else { printf "%s%.0f", p, n; exit }
    s = sprintf("%.1f", v)
    gsub(/\.0$/, "", s)
    printf "%s%s%s", p, s, u
  }'
}

# When a snapshot was taken: a clock time today ("1:32pm"), else a date ("Sep 30").
format_taken() {
  local ts="$1"
  if [ "$(date -r "$ts" '+%Y%j')" = "$(date '+%Y%j')" ]; then
    date -r "$ts" '+%-I:%M%p' | sed 's/AM$/am/; s/PM$/pm/'
  else
    date -r "$ts" '+%b %-d'
  fi
}

out=$(printf '%s / %s' "$(format_amount "$used")" "$(format_amount "$max")")

budget=$(jq -r '
  .oauthAccount.accountUuid as $me
  | .cachedUsageUtilization
  | select(. != null and $me != null and .accountUuid == $me)
  | (.fetchedAtMs / 1000 | floor) as $at
  | .utilization.extra_usage
  | select(. != null and .is_enabled == true and (.monthly_limit // 0) > 0)
  | pow(10; .decimal_places // 2) as $unit
  | [ (.used_credits // 0) / $unit,
      .monthly_limit / $unit,
      (.utilization // ((.used_credits // 0) * 100 / .monthly_limit)),
      (.currency // "USD"),
      $at,
      (.spend_limit_reached == true) ]
  | @tsv' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null)

if [ -n "$budget" ]; then
  IFS=$'\t' read -r spent limit pct currency taken reached <<<"$budget"
  [ "$currency" = USD ] && sym='$' || sym="$currency "
  notes=""
  [ "$reached" = true ] && notes=", limit reached"
  [ $(( $(date '+%s') - taken )) -gt 3600 ] && notes="$notes, as of $(format_taken "$taken")"
  out=$(printf '%s · budget %.0f%% (%s / %s%s)' "$out" "$pct" \
    "$(format_amount "$spent" "$sym")" "$(format_amount "$limit" "$sym")" "$notes")
fi

printf '%s' "$out"
