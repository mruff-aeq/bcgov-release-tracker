#!/usr/bin/env bash
#
# post-release-watch — show the last N manual (workflow_dispatch) runs of a
# bcgov CD workflow as a table, with the resolved deploy environment (dev/test/
# sandbox/prod) for each run.
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
# Two `test` deploys of this workflow must exist among the runs fetched (up to
# 50) to bound the window; otherwise the script says so.
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
# Requires: curl, jq. NO authentication needed — these bcgov repos are public,
# and everything this script reads is on the public REST API. Anonymous calls
# to api.github.com are capped at 60/hour per IP. This makes 3 calls per repo
# (deployments + runs + PR list), PLUS — only with --in-dirs= — one extra call
# per PR in the release window (to read its changed files). To keep an unusually
# large window from exhausting the budget, if the window holds more than
# IN_DIRS_MAX (default 30) PRs, the per-PR lookups are skipped and the IN-DIRS
# column reads SKIP.
#
# How the deploy environment is resolved:
#   - The deploy target is NOT exposed by the workflow-runs API. We instead read
#     the repo's public Deployments API (`/repos/OWNER/REPO/deployments`): every
#     CD run creates a GitHub deployment recording its environment + commit, a
#     few seconds after the run starts. We match each run to its deployment by
#     commit SHA + nearest timestamp at/after the run's start.
#   - This replaces the old approach of grepping the run LOGS for a `target:`
#     line, which required authentication (the logs endpoint returns 403 to
#     anonymous callers even on public repos) and broke when a job name
#     contained a "/" (gh run view --log silently returned nothing).
#   - "?" means no matching deployment was found for that run.

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

# Budget for --in-dirs= per-PR file lookups (one anonymous API call each). If the
# release window holds more than this many PRs, we skip those lookups entirely so
# an unusually large window can't exhaust the 60/hour anonymous rate limit; the
# IN-DIRS column then reads SKIP. Override with e.g. IN_DIRS_MAX=50.
IN_DIRS_MAX="${IN_DIRS_MAX:-30}"

command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "error: jq not found"   >&2; exit 1; }

# --- public GitHub REST API helper ------------------------------------------
# No auth: these repos are public and every endpoint below serves anonymous
# callers. Plain unauthenticated curl, nothing else.
API="https://api.github.com"

api() {  # api <path-or-full-url> ; prints body, returns curl's exit status
  local url="$1"
  case "$url" in http*) ;; *) url="$API$url" ;; esac
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url"
}

# Fetch the repo's recent deployments once; reused to resolve every run's env.
# 100 covers a wide window even for repos with frequent auto-deploys to dev.
DEPLOYS_JSON=$(api "/repos/$REPO/deployments?per_page=100") || DEPLOYS_JSON='[]'

# Resolve the deploy environment for a run, given its commit SHA + start time.
# A run's deployment shares its SHA and is created a few seconds later, so we
# pick the earliest deployment with the same 7-char SHA at/after the run start.
# ISO-8601 'Z' timestamps compare correctly as plain strings.
get_env() {  # get_env <full-sha> <created_at>
  printf '%s' "$DEPLOYS_JSON" | jq -r --arg sha "${1:0:7}" --arg t "$2" '
    [ .[] | select((.sha[0:7]) == $sha and .created_at >= $t) ]
    | sort_by(.created_at) | (.[0].environment // "?")'
}

# Minimal HTML escaping for table cell text (&, <, > only — no CSS, no quotes-in-attrs).
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Echo YES if PR #$1 changed any file under one of the IN_DIRS_ARR prefixes
# (the dir itself or any child dir), NO otherwise. Used only with --in-dirs=.
# Echoes ERR if the file list couldn't be fetched (e.g. an anonymous-rate-limit
# 403) so a throttled run shows ERR rather than a false NO.
pr_in_dirs() {
  local pnum="${1#\#}" raw files f d
  raw=$(api "/repos/$REPO/pulls/$pnum/files?per_page=100") || { echo "ERR"; return; }
  files=$(printf '%s' "$raw" | jq -r '.[].filename' 2>/dev/null)
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

# One call gets the last 50 workflow_dispatch runs with everything the table
# needs: run number, commit, conclusion, time, actor and commit subject. We
# then keep the newest COUNT. (No per-run API calls — keeps us well under the
# anonymous rate limit.)
RUNS_JSON=$(api "/repos/$REPO/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&per_page=50") || {
  echo "error: failed to fetch runs for $REPO ($WORKFLOW)." >&2
  exit 1
}

rows=()
while IFS= read -r line; do
  rows+=("$line")
done < <(printf '%s' "$RUNS_JSON" | jq -r --argjson n "$COUNT" '
  .workflow_runs[:$n][] |
  [ (.run_number|tostring),
    .head_sha,
    (.conclusion // ""),
    .created_at,
    (.actor.login // ""),
    ((.head_commit.message // "") | split("\n")[0]) ] | @tsv')

for line in "${rows[@]}"; do
  IFS=$'\t' read -r num sha concl created actor msg <<< "$line"
  env=$(get_env "$sha" "$created")
  sha7="${sha:0:7}"
  created="${created%Z}"; created="${created/T/ }"
  msg=$(printf '%s' "$msg" | cut -c1-29)
  printf '#%-5s %-9s %-8s %-16s %-9s %-21s %-30s\n' "$num" "$env" "$concl" "$actor" "$sha7" "$created" "$msg"
done

# --- second table: merged PRs shipped in the latest test deploy --------------
# (those merged between the previous test deploy and the most-recent one)
if [ "$TEST_RELEASE" -eq 1 ]; then
  echo

  # Post-deployment needs the TWO most-recent `test` deploys to bound the window:
  #   START = newest test deploy (its commit is the upper bound, INCLUDED)
  #   STOP  = previous test deploy (its commit is the lower bound, EXCLUDED)
  # Scoped to THIS workflow's runs (not the repo's global `test` deployments)
  # because monorepos like bcgov/lear and bcgov/business-ui run several CD
  # workflows that all deploy to one shared `test` environment. We scan all
  # fetched runs (up to 50), not just the COUNT shown above.
  START_SHA=""; START_RUN=""
  STOP_SHA="";  STOP_RUN=""
  while IFS=$'\t' read -r rnum rsha rcreated; do
    [ -z "$rsha" ] && continue
    if [ "$(get_env "$rsha" "$rcreated")" = "test" ]; then
      if [ -z "$START_SHA" ]; then
        START_SHA="${rsha:0:7}"; START_RUN="$rnum"
      else
        STOP_SHA="${rsha:0:7}"; STOP_RUN="$rnum"
        break
      fi
    fi
  done < <(printf '%s' "$RUNS_JSON" | jq -r '.workflow_runs[] | [ (.run_number|tostring), .head_sha, .created_at ] | @tsv')

  if [ -z "$START_SHA" ]; then
    echo "test-release: no 'test' deploy found in the recent runs of $WORKFLOW — nothing to report." >&2
    exit 0
  fi
  if [ -z "$STOP_SHA" ]; then
    echo "test-release: only ONE 'test' deploy found in the recent runs of $WORKFLOW — cannot bound the" >&2
    echo "              release window (need a previous test deploy)." >&2
    exit 0
  fi

  echo "showing PRs between $STOP_SHA and $START_SHA"

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

  # Pull recent closed PRs, keep the merged ones, newest-merged first. TICKET
  # comes from the PR body line "*Issue #:* /bcgov/entity#NNNNN"; NA if absent.
  # Full title is carried for the HTML table; the text table truncates with %.41s.
  PRS_JSON=$(api "/repos/$REPO/pulls?state=closed&per_page=100&sort=updated&direction=desc") || PRS_JSON='[]'

  # Accounting: count how many merged PRs fall in the release window [START, STOP)
  # (= the number of per-PR /files calls --in-dirs= would make). If that exceeds
  # the budget, skip those lookups so an unusually large window can't blow the
  # 60/hour anonymous rate limit; the IN-DIRS column reads SKIP instead.
  SKIP_IN_DIRS=0
  if [ "$IN_DIRS" -eq 1 ]; then
    window=$(printf '%s' "$PRS_JSON" | jq -r --arg start "$START_SHA" --arg stop "$STOP_SHA" '
      ([ .[] | select(.merged_at != null) ] | sort_by(.merged_at) | reverse | map(.merge_commit_sha[0:7])) as $s
      | ($s | index($start)) as $a
      | ($s | index($stop))  as $b
      | if $a == null then 0
        elif $b == null then (($s | length) - $a)
        else ($b - $a) end')
    if [ "$window" -gt "$IN_DIRS_MAX" ]; then
      SKIP_IN_DIRS=1
      echo "in-dirs: release window for $REPO holds $window PRs (> IN_DIRS_MAX=$IN_DIRS_MAX);" >&2
      echo "         skipping per-PR file lookups to stay under the API rate limit (IN-DIRS column = SKIP)." >&2
    fi
  fi

  # Walk merged PRs newest-first. Skip everything until START_SHA (those were
  # merged AFTER the latest test deploy and aren't in it). Include from START_SHA
  # down to — but excluding — STOP_SHA (the previous release boundary).
  in_scope=0; found_stop=0; shown=0
  pr_rows=()
  while IFS=$'\t' read -r pnum pticket psha pdate pauthor ptitle; do
    [ -z "$pnum" ] && continue
    # not yet at the latest test deploy commit -> merged after the deploy, skip
    if [ "$in_scope" -eq 0 ]; then
      if [ "$psha" = "$START_SHA" ]; then in_scope=1; else continue; fi
    fi
    # reached the previous test deploy commit -> stop without printing it
    if [ "$psha" = "$STOP_SHA" ]; then found_stop=1; break; fi
    pauthor="@$pauthor"   # prepend @ to the handle (used by both text and HTML)
    if [ "$IN_DIRS" -eq 1 ]; then
      if [ "$SKIP_IN_DIRS" -eq 1 ]; then changed="SKIP"; else changed=$(pr_in_dirs "$pnum"); fi
      [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s %-8s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha" "$changed"
    else
      changed=""
      [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha"
    fi
    pr_rows+=("$pnum"$'\t'"$pticket"$'\t'"$psha"$'\t'"$pdate"$'\t'"$pauthor"$'\t'"$ptitle"$'\t'"$changed")
    shown=$((shown + 1))
  done < <(printf '%s' "$PRS_JSON" | jq -r '
    [ .[] | select(.merged_at != null) ] | sort_by(.merged_at) | reverse | .[] |
    [ ("#" + (.number|tostring)),
      ((.body // "") | [scan("/bcgov/entity#([0-9]+)")] | if length>0 then "#"+.[0][0] else "NA" end),
      ((.merge_commit_sha // "")[0:7]),
      (.merged_at[0:10]),
      .user.login,
      .title ] | @tsv')

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
      # PR cell -> link to the PR on the repo this table is for ($REPO), e.g.
      # https://github.com/bcgov/lear/pull/123. $hnum is like "#123".
      pr_cell="<a href=\"https://github.com/$REPO/pull/${hnum#\#}\">$(html_escape "$hnum")</a>"
      if [ "$IN_DIRS" -eq 1 ]; then
        printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$pr_cell" \
          "$ticket_cell" "$(html_escape "$hdate")" "$(html_escape "$hsha")" "$(html_escape "$hchanged")"
      else
        printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$pr_cell" \
          "$ticket_cell" "$(html_escape "$hdate")" "$(html_escape "$hsha")"
      fi
    done
    echo "</table>"
  fi
fi
