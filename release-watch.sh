#!/usr/bin/env bash
#
# bn-cd-runs — show the last N manual (workflow_dispatch) runs of a bcgov CD
# workflow as a table, with the resolved deploy environment (dev/test/sandbox/
# prod) pulled from each run's logs.
#
# Usage:
#   bn-cd-runs [count] [workflow-file] [owner/repo] [test-release] [--in-dirs=DIR[,DIR...]]
#
# Defaults:
#   count          6
#   workflow-file  business-bn-cd.yml
#   owner/repo     bcgov/lear
#
# The literal token `test-release` may appear ANYWHERE in the args. When given,
# the script prints a SECOND table: the merged PRs from newest down to (and
# including) the PR whose merge commit is currently deployed to `test` — i.e.
# the release-candidate list of what's merged but possibly not yet past test.
#
# --in-dirs=DIR[,DIR...] (requires `test-release`, else it errors) adds an extra
# column to that second table: YES if the PR changed any file under DIR or one
# of its child dirs, NA otherwise. Multiple dirs may be comma-separated; a PR
# matching ANY of them is YES. Example dir for bcgov/business-ui:
# web/business-registry-dashboard
#
# Examples:
#   bn-cd-runs                                  
#   bn-cd-runs 10                               # last 10
#   bn-cd-runs 2 business-emailer-cd.yml        # a different workflow
#   bn-cd-runs 2 some-cd.yml bcgov/some-repo    # a different repo
#   bn-cd-runs 2 cd.yml bcgov/business-filings-ui test-release   # + PR table
#   bn-cd-runs 2 cd.yml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard
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
pos=()
for a in "$@"; do
  case "$a" in
    test-release)  TEST_RELEASE=1 ;;
    --in-dirs=*)   IN_DIRS=1; IN_DIRS_ARG="${a#--in-dirs=}" ;;
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

COUNT="${pos[0]:-6}"
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
# (the dir itself or any child dir), NA otherwise. Used only with --in-dirs=.
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
  echo "NA"
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

STOP_SHA=""   # commit of the first `test` row, used by --test-release
STOP_RUN=""
for line in "${rows[@]}"; do
  IFS=$'\t' read -r id num concl created <<< "$line"
  IFS=$'\t' read -r actor sha msg < <(gh api "repos/$REPO/actions/runs/$id" \
    --jq '[.actor.login, (.head_sha[0:7]), (.head_commit.message | split("\n")[0])] | @tsv' 2>/dev/null)
  env=$(get_env "$id")
  created="${created%Z}"; created="${created/T/ }"
  msg=$(printf '%s' "$msg" | cut -c1-29)
  printf '#%-5s %-9s %-8s %-16s %-9s %-21s %-30s\n' "$num" "$env" "$concl" "$actor" "$sha" "$created" "$msg"
  # remember the first occurrence of a `test` deploy and its commit
  if [ "$env" = "test" ] && [ -z "$STOP_SHA" ]; then
    STOP_SHA="$sha"; STOP_RUN="$num"
  fi
done

# --- second table: merged PRs down to the commit currently on test ----------
if [ "$TEST_RELEASE" -eq 1 ]; then
  echo
  if [ -z "$STOP_SHA" ]; then
    echo "test-release: no 'test' deploy found in the last $COUNT runs — nothing to bound the PR list." >&2
    exit 0
  fi

  echo "test-release: merged PRs newer than the commit on test (#$STOP_RUN -> $STOP_SHA, excluded)"
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

  # TICKET comes from the PR body line "*Issue #:* /bcgov/entity#NNNNN"; NA if absent.
  # Full title is carried for the HTML table; the text table truncates with %.41s.
  found=0; shown=0
  pr_rows=()
  while IFS=$'\t' read -r pnum pticket psha pdate pauthor ptitle; do
    # stop AT the commit already on test, without printing it (it's released)
    if [ "$psha" = "$STOP_SHA" ]; then found=1; break; fi
    pauthor="@$pauthor"   # prepend @ to the handle (used by both text and HTML)
    if [ "$IN_DIRS" -eq 1 ]; then
      changed=$(pr_in_dirs "$pnum")
      printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s %-8s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha" "$changed"
    else
      changed=""
      printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha"
    fi
    pr_rows+=("$pnum"$'\t'"$pticket"$'\t'"$psha"$'\t'"$pdate"$'\t'"$pauthor"$'\t'"$ptitle"$'\t'"$changed")
    shown=$((shown + 1))
  done < <(gh pr list -R "$REPO" --state merged -L 100 \
    --json number,title,author,mergedAt,mergeCommit,body \
    --jq '.[] | "#\(.number)\t\(((.body // "") | [scan("/bcgov/entity#([0-9]+)")] | if length>0 then "#"+.[0][0] else "NA" end))\t\((.mergeCommit.oid // "")[0:7])\t\(.mergedAt[0:10])\t\(.author.login)\t\(.title)"')

  if [ "$found" -eq 1 ] && [ "$shown" -eq 0 ]; then
    echo "(none — test is up to date with the newest merged PR)"
  elif [ "$found" -eq 0 ]; then
    echo "test-release: warning — commit $STOP_SHA (run #$STOP_RUN) not found in the last 100 merged PRs;" >&2
    echo "              the list above is not bounded to the test release. (Deploy commit may not be a PR merge commit.)" >&2
  fi

  # Raw HTML version of the second table (no CSS), printed after the text table.
  if [ "$shown" -gt 0 ]; then
    echo
    echo "<table>"
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
