#!/usr/bin/env bash
#
# post-release-watch — show the last N manual (workflow_dispatch) runs of a
# bcgov CD workflow as a table, with the resolved deploy environment (dev/test/
# sandbox/prod) pulled from each run's logs.
#
# Usage:
#   post-release-watch [count] [workflow-file] [owner/repo] [test-release] [--in-dirs=DIR[,DIR...]] [--html]
#
# Defaults:
#   count          10
#   workflow-file  business-bn-cd.yml
#   owner/repo     bcgov/lear
#
# POST-DEPLOYMENT semantics (this is the difference vs pre-release-watch):
# The literal token `test-release` may appear ANYWHERE in the args. When given,
# the script prints a SECOND table: the merged PRs that shipped in the MOST
# RECENT `test` deployment — i.e. every PR merged BETWEEN the two most-recent
# `test` deploys. The list is bounded:
#   * upper bound (newest, INCLUDED): the commit of the most recent `test` run
#   * lower bound (oldest, EXCLUDED): the commit of the previous `test` run
# So it answers "what was actually deployed to test in the latest push", as
# opposed to pre-release-watch which answers "what is pending a push to test".
#
# Two `test` deploys must exist within `count` runs to bound the window; bump
# `count` if the previous test deploy is older than the runs shown.
#
# --in-dirs=DIR[,DIR...] (requires `test-release`, else it errors) adds an extra
# column to that second table: YES if the PR changed any file under DIR or one
# of its child dirs, NO otherwise. Multiple dirs may be comma-separated; a PR
# matching ANY of them is YES. Example dir for bcgov/business-ui:
# web/business-registry-dashboard
#
# --html (requires `test-release`) suppresses the TEXT rendering of that second
# (merged-PR) table and prints only its HTML version. The first table — the last
# CD runs — is always printed as text.
#
# Examples:
#   post-release-watch
#   post-release-watch 12                              # last 12 runs
#   post-release-watch 10 business-emailer-cd.yml      # a different workflow
#   post-release-watch 10 some-cd.yml bcgov/some-repo  # a different repo
#   post-release-watch 10 cd.yml bcgov/business-filings-ui test-release   # + PR table
#   post-release-watch 10 cd.yml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard
#
# Requires: gh (authenticated), with repo + workflow scopes on the target repo.
#
# Notes:
#   - The deploy target is NOT exposed by the GitHub runs API for
#     workflow_dispatch; it only appears in the run logs, so this reads logs.
#   - GitHub purges run logs after ~90 days. Truly purged runs report
#     "logs-expired" (detected via an HTTP 410 from the logs endpoint).
#   - "?" means the log was present but no "target:" line was found.

set -uo pipefail

# Pull out the optional `test-release` flag and `--in-dirs=` option from anywhere
# in the args, so the count/workflow/repo positionals keep working regardless of
# their position.
TEST_RELEASE=0
IN_DIRS=0
IN_DIRS_ARG=""
HTML=0
pos=()
for a in "$@"; do
  case "$a" in
    test-release)  TEST_RELEASE=1 ;;
    --in-dirs=*)   IN_DIRS=1; IN_DIRS_ARG="${a#--in-dirs=}" ;;
    --html)        HTML=1 ;;
    *)             pos+=("$a") ;;
  esac
done

# --in-dirs= only makes sense alongside the test-release PR table.
if [ "$IN_DIRS" -eq 1 ]; then
  if [ "$TEST_RELEASE" -ne 1 ]; then
    echo "error: --in-dirs= requires the 'test-release' argument" >&2
    exit 1
  fi
  if [ -z "$IN_DIRS_ARG" ]; then
    echo "error: --in-dirs= needs at least one directory (e.g. --in-dirs=web/business-registry-dashboard)" >&2
    exit 1
  fi
  IFS=',' read -r -a IN_DIRS_ARR <<< "$IN_DIRS_ARG"
fi

# --html only affects the test-release (merged-PR) table.
if [ "$HTML" -eq 1 ] && [ "$TEST_RELEASE" -ne 1 ]; then
  echo "error: --html requires the 'test-release' argument" >&2
  exit 1
fi

COUNT="${pos[0]:-10}"
WORKFLOW="${pos[1]:-business-bn-cd.yml}"
REPO="${pos[2]:-bcgov/lear}"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated (run: gh auth login)" >&2; exit 1; }

# Resolve the deploy environment for a run id.
# Retries the whole detection so a transient 500 from the logs endpoint
# doesn't get mistaken for "no target". A real purge returns HTTP 410.
get_env() {
  local id="$1" log env tries=0
  while [ "$tries" -lt 3 ]; do
    log=$(gh run view "$id" -R "$REPO" --log 2>/dev/null)
    env=$(printf '%s' "$log" | grep -m1 -iE '[[:space:]]target: [a-z]+' | sed -E 's/.*target: *//' | tr -d '\r')
    [ -n "$env" ] && { echo "$env"; return; }
    # No target in the log this attempt — is the log actually purged?
    # Capture stderr into a var (don't pipe to grep): under `set -o pipefail`
    # the pipeline would return gh's non-zero exit and mask the match.
    local err
    err=$(gh api "repos/$REPO/actions/runs/$id/logs" 2>&1 >/dev/null)
    case "$err" in
      *"HTTP 410"*) echo "logs-expired"; return ;;
    esac
    tries=$((tries + 1))
  done
  echo "?"
}

# Minimal HTML escaping for table cell text (&, <, > only — no CSS, no quotes-in-attrs).
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Echo YES if PR #$1 changed any file under one of the IN_DIRS_ARR prefixes
# (the dir itself or any child dir), NO otherwise. Used only with --in-dirs=.
pr_in_dirs() {
  local pnum="${1#\#}" files f d
  files=$(gh pr view "$pnum" -R "$REPO" --json files --jq '.files[].path' 2>/dev/null)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    for d in "${IN_DIRS_ARR[@]}"; do
      d="${d%/}"   # tolerate a trailing slash in the supplied dir
      case "$f" in
        "$d"/*) echo "YES"; return ;;
      esac
    done
  done <<< "$files"
  echo "NO"
}

printf '%-6s %-9s %-8s %-16s %-9s %-21s %-30s\n' "RUN" "ENV" "RESULT" "ACTOR" "COMMIT" "CREATED (UTC)" "MESSAGE"
printf '%-6s %-9s %-8s %-16s %-9s %-21s %-30s\n' "------" "-------" "------" "----------------" "-------" "---------------------" "------------------------------"

# Read the run list into an array FIRST. Looping over a pipe (... | while read)
# breaks here because the gh calls inside the loop consume the loop's stdin.
rows=()
while IFS= read -r line; do
  rows+=("$line")
done < <(gh run list --workflow="$WORKFLOW" -R "$REPO" -L 50 \
  --json databaseId,number,event,conclusion,createdAt \
  --jq '.[] | select(.event=="workflow_dispatch") | "\(.databaseId)\t\(.number)\t\(.conclusion)\t\(.createdAt)"' \
  | head -"$COUNT")

# Post-deployment needs TWO `test` deploys to bound the release window:
#   START = newest test deploy (its commit is the upper bound, INCLUDED)
#   STOP  = previous test deploy (its commit is the lower bound, EXCLUDED)
START_SHA=""; START_RUN=""
STOP_SHA="";  STOP_RUN=""
for line in "${rows[@]}"; do
  IFS=$'\t' read -r id num concl created <<< "$line"
  IFS=$'\t' read -r actor sha msg < <(gh api "repos/$REPO/actions/runs/$id" \
    --jq '[.actor.login, (.head_sha[0:7]), (.head_commit.message | split("\n")[0])] | @tsv' 2>/dev/null)
  env=$(get_env "$id")
  created="${created%Z}"; created="${created/T/ }"
  msg=$(printf '%s' "$msg" | cut -c1-29)
  printf '#%-5s %-9s %-8s %-16s %-9s %-21s %-30s\n' "$num" "$env" "$concl" "$actor" "$sha" "$created" "$msg"
  # capture the two most-recent `test` deploys (newest first)
  if [ "$env" = "test" ]; then
    if [ -z "$START_SHA" ]; then
      START_SHA="$sha"; START_RUN="$num"
    elif [ -z "$STOP_SHA" ]; then
      STOP_SHA="$sha"; STOP_RUN="$num"
    fi
  fi
done

# --- second table: merged PRs shipped in the latest test deploy --------------
# (those merged between the previous test deploy and the most-recent one)
if [ "$TEST_RELEASE" -eq 1 ]; then
  echo
  if [ -z "$START_SHA" ]; then
    echo "test-release: no 'test' deploy found in the last $COUNT runs — nothing to report." >&2
    exit 0
  fi
  if [ -z "$STOP_SHA" ]; then
    echo "test-release: only ONE 'test' deploy found in the last $COUNT runs — cannot bound the" >&2
    echo "              release window (need a previous test deploy). Re-run with a larger count." >&2
    exit 0
  fi

  # --html suppresses this text table (header + rows); only the HTML prints.
  if [ "$HTML" -ne 1 ]; then
    echo "post-release: merged PRs deployed to test in the latest push"
    echo "              (newest #$START_RUN -> $START_SHA included, down to previous #$STOP_RUN -> $STOP_SHA excluded)"
    if [ "$IN_DIRS" -eq 1 ]; then
      # Name the In-Dirs column after the directory filter actually supplied,
      # e.g. IN-DIRS=web/business-registry-dashboard. Dashes match its width.
      in_dirs_label="IN-DIRS=$IN_DIRS_ARG"
      in_dirs_dashes=$(printf '%*s' "${#in_dirs_label}" '' | tr ' ' '-')
      printf '%-42s %-20s %-7s %-9s %-12s %-9s %s\n' "TITLE" "AUTHOR" "PR" "TICKET" "Merged_Date" "COMMIT" "$in_dirs_label"
      printf '%-42s %-20s %-7s %-9s %-12s %-9s %s\n' "------------------------------------------" "--------------------" "-------" "-------" "-----------" "-------" "$in_dirs_dashes"
    else
      printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "TITLE" "AUTHOR" "PR" "TICKET" "Merged_Date" "COMMIT"
      printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "------------------------------------------" "--------------------" "-------" "-------" "-----------" "-------"
    fi
  fi

  # TICKET comes from the PR body line "*Issue #:* /bcgov/entity#NNNNN"; NA if absent.
  # Full title is carried for the HTML table; the text table truncates with %.41s.
  #
  # Walk merged PRs newest-first. Skip everything until START_SHA (those were
  # merged AFTER the latest test deploy and aren't in it). Include from START_SHA
  # down to — but excluding — STOP_SHA (the previous release boundary).
  in_scope=0; found_stop=0; shown=0
  pr_rows=()
  while IFS=$'\t' read -r pnum pticket psha pdate pauthor ptitle; do
    # not yet at the latest test deploy commit -> merged after the deploy, skip
    if [ "$in_scope" -eq 0 ]; then
      if [ "$psha" = "$START_SHA" ]; then in_scope=1; else continue; fi
    fi
    # reached the previous test deploy commit -> stop without printing it
    if [ "$psha" = "$STOP_SHA" ]; then found_stop=1; break; fi
    pauthor="@$pauthor"   # prepend @ to the handle (used by both text and HTML)
    if [ "$IN_DIRS" -eq 1 ]; then
      changed=$(pr_in_dirs "$pnum")
      [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s %-8s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha" "$changed"
    else
      changed=""
      [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha"
    fi
    pr_rows+=("$pnum"$'\t'"$pticket"$'\t'"$psha"$'\t'"$pdate"$'\t'"$pauthor"$'\t'"$ptitle"$'\t'"$changed")
    shown=$((shown + 1))
  done < <(gh pr list -R "$REPO" --state merged -L 100 \
    --json number,title,author,mergedAt,mergeCommit,body \
    --jq '.[] | "#\(.number)\t\(((.body // "") | [scan("/bcgov/entity#([0-9]+)")] | if length>0 then "#"+.[0][0] else "NA" end))\t\((.mergeCommit.oid // "")[0:7])\t\(.mergedAt[0:10])\t\(.author.login)\t\(.title)"')

  if [ "$in_scope" -eq 0 ]; then
    echo "post-release: warning — latest test commit $START_SHA (run #$START_RUN) not found in the last" >&2
    echo "              100 merged PRs; cannot scope the release. (Deploy commit may not be a PR merge commit.)" >&2
  elif [ "$found_stop" -eq 0 ]; then
    echo "post-release: warning — previous test commit $STOP_SHA (run #$STOP_RUN) not found in the last" >&2
    echo "              100 merged PRs; the list above may extend past the actual release window." >&2
  elif [ "$shown" -eq 0 ]; then
    [ "$HTML" -ne 1 ] && echo "(none — the latest test deploy contained no new merged PRs)"
  fi

  # Raw HTML version of the second table (no CSS), printed after the text table.
  if [ "$shown" -gt 0 ]; then
    echo
    echo "<table border=\"1\">"
    if [ "$IN_DIRS" -eq 1 ]; then
      echo "  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th><th>$(html_escape "IN-DIRS=$IN_DIRS_ARG")</th></tr>"
    else
      echo "  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>"
    fi
    for r in "${pr_rows[@]}"; do
      IFS=$'\t' read -r hnum hticket hsha hdate hauthor htitle hchanged <<< "$r"
      # Ticket cell -> link to the bcgov/entity issue, unless it's NA.
      if [ "$hticket" = "NA" ]; then
        ticket_cell="NA"
      else
        ticket_cell="<a href=\"https://github.com/bcgov/entity/issues/${hticket#\#}\">$(html_escape "$hticket")</a>"
      fi
      if [ "$IN_DIRS" -eq 1 ]; then
        printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$(html_escape "$hnum")" \
          "$ticket_cell" "$(html_escape "$hdate")" "$(html_escape "$hsha")" "$(html_escape "$hchanged")"
      else
        printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$(html_escape "$hnum")" \
          "$ticket_cell" "$(html_escape "$hdate")" "$(html_escape "$hsha")"
      fi
    done
    echo "</table>"
  fi
fi
