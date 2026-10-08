#!/usr/bin/env bash
# Turn what a failed step printed into annotations, which anyone can read —
# on the run's page and through the API — where the logs need a sign-in.
# The error lines themselves when there are any (GitHub keeps ten per step),
# and the last lines of the log otherwise.
for log in "$@"; do
  [ -f "$log" ] || continue
  errors=$(grep -E 'error(\[E[0-9]+\])?:|error: |panicked at|recorded an issue|Expectation failed|fatal error|undefined reference|ld: ' "$log" | awk '!seen[$0]++' | head -10)
  [ -n "$errors" ] || errors=$(tail -10 "$log")
  while IFS= read -r line; do
    line=${line//'%'/'%25'}
    echo "::error title=${log}::${line}"
  done <<< "$errors"
  { echo "### ${log}"; echo '```'; tail -80 "$log"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
done
