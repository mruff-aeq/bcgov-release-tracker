#!/usr/bin/env bash
#
# report-freshness-check — guard against stale GitHub run-listing responses.
#
# Usage: report-freshness-check.sh PREVIOUS_REPORT NEW_REPORT
#
# The reports' first table per repo section lists CD runs as "#NNN  env ...".
# Run numbers only ever increase, so if a section's newest run number in the
# NEW report is LOWER than in the PREVIOUS one, GitHub's eventually-consistent
# runs API returned an incomplete list (seen 2026-08-11: runs #711-#715 missing
# dropped the test boundary back two weeks and inflated the pending-PR list).
# Exit 1 in that case so CI keeps the previous good report instead.
#
# Sections are keyed by their "<!-- ... -->" marker comment; sections missing
# from either file (config changes, no-runs warnings) are skipped.

set -euo pipefail

prev="$1"
new="$2"

max_runs() {
  awk '
    /^<!-- .* -->$/ { sec = $0 }
    sec != "" && /^#[0-9]+ / {
      n = substr($1, 2) + 0
      if (n > max[sec]) max[sec] = n
    }
    END { for (s in max) printf "%s\t%d\n", s, max[s] }
  ' "$1"
}

prev_maxes=$(max_runs "$prev")
status=0

while IFS=$'\t' read -r sec newmax; do
  [ -z "$sec" ] && continue
  prevmax=$(printf '%s\n' "$prev_maxes" | awk -F'\t' -v s="$sec" '$1 == s { print $2 }')
  [ -z "$prevmax" ] && continue
  if [ "$newmax" -lt "$prevmax" ]; then
    echo "stale run listing: $sec newest run #$newmax < previous report's #$prevmax" >&2
    status=1
  fi
done <<< "$(max_runs "$new")"

exit $status
