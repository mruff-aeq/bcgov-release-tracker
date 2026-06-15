#!/usr/bin/env bash
#
# bn-cd-runs — show the last N manual (workflow_dispatch) runs of a bcgov CD
# workflow as a table, with the resolved deploy environment (dev/test/sandbox/
# prod) for each run.
#
# Usage:
#   bn-cd-runs [count] [workflow-file] [owner/repo] [test-release] [--in-dirs=DIR[,DIR...]] [--html]
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
# of its child dirs, NO otherwise. Multiple dirs may be comma-separated; a PR
# matching ANY of them is YES. Example dir for bcgov/business-ui:
# web/business-registry-dashboard
# This check is done from a local clone (see below), not the API, so it adds
# no API calls regardless of how many PRs are in the list. Requires `git`.
#
# --html (requires `test-release`) suppresses the TEXT rendering of that second
# (merged-PR) table and prints only its HTML version. The first table — the last
# CD runs — is always printed as text.
#
# Examples:
#   bn-cd-runs
#   bn-cd-runs 10                               # last 10
#   bn-cd-runs 2 business-emailer-cd.yml        # a different workflow
#   bn-cd-runs 2 some-cd.yml bcgov/some-repo    # a different repo
#   bn-cd-runs 2 cd.yml bcgov/business-filings-ui test-release   # + PR table
#   bn-cd-runs 2 cd.yml bcgov/business-ui test-release --in-dirs=web/business-registry-dashboard
#
# Requires: curl, jq (and git only when --in-dirs= is used). No authentication is
# required (these bcgov repos are public), but an optional GH_TOKEN/GITHUB_TOKEN
# is used if present — see the api() helper. Anonymous calls share a 60/hour-per-
# IP cap; a token gets its own ~1000-5000/hour. This makes a FIXED 3 calls per
# repo (deployments + runs + PR list), regardless of how many PRs are listed.
#
# --in-dirs= adds NO API calls: instead of querying each PR's changed files via
# the API, it does one blobless, no-checkout `git clone` of the repo (commits +
# trees only, no file contents — ~1-2 MB, ~1 s) and reads each PR's changed
# files locally from its merge commit. Git transport is not part of the REST
# rate limit, so the per-PR cost is removed entirely.
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
#   - "?" means no matching deployment was found for that run (e.g. the run
#     predates the deployments fetched, or it never produced a deployment).

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

COUNT="${pos[0]:-6}"
WORKFLOW="${pos[1]:-business-bn-cd.yml}"
REPO="${pos[2]:-bcgov/lear}"

command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "error: jq not found"   >&2; exit 1; }
# --in-dirs= reads changed files from a local clone, so it needs git.
if [ "$IN_DIRS" -eq 1 ]; then
  command -v git >/dev/null 2>&1 || { echo "error: git not found (needed for --in-dirs=)" >&2; exit 1; }
fi

# --- public GitHub REST API helper ------------------------------------------
# These repos are public, so no auth is required. But if GH_TOKEN or GITHUB_TOKEN
# is set (e.g. injected by GitHub Actions), we send it: anonymous calls share a
# 60/hour-per-IP cap (easily exhausted on shared CI runner IPs), while a token
# gets its own ~1000-5000/hour budget. Either way we read only public data.
API="https://api.github.com"
AUTH_HEADER=()
_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$_TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $_TOKEN")

api() {  # api <path-or-full-url> ; prints body, returns curl's exit status
  local url="$1"
  case "$url" in http*) ;; *) url="$API$url" ;; esac
  curl -fsSL "${AUTH_HEADER[@]}" \
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

# --in-dirs= reads each PR's changed files from a local clone instead of the
# API. CLONE_STATE is "" (not yet attempted), "ok", or "fail". The clone is
# blobless + no-checkout: it pulls commits and trees (enough for name-only
# diffs) but no file contents and no working tree — a couple MB, about a second.
#
# IN_DIRS_CLONE_DIR (optional env var): a directory where the clone of $REPO
# lives or should be created, OWNED BY THE CALLER. When a wrapper runs this
# script many times against the same monorepo — one invocation per child dir,
# e.g. the release-report output scripts looping over bcgov/lear's
# queue_services/* — it can clone that large repo ONCE into a shared dir and
# export IN_DIRS_CLONE_DIR so every invocation reuses it instead of re-cloning.
# Contract: the dir is scoped to a single $REPO by the caller (we don't verify),
# the first invocation populates it, the rest reuse it, and the caller removes
# it afterwards (we never delete a caller-provided dir). When the var is unset
# we fall back to a private mktemp clone that this process removes on exit.
CLONE_DIR=""; CLONE_STATE=""
ensure_clone() {
  [ -n "$CLONE_STATE" ] && { [ "$CLONE_STATE" = ok ]; return; }
  if [ -n "${IN_DIRS_CLONE_DIR:-}" ]; then
    CLONE_DIR="$IN_DIRS_CLONE_DIR"
    # Already populated by an earlier invocation sharing this dir? Reuse it.
    if git -C "$CLONE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      CLONE_STATE=ok; return 0
    fi
    mkdir -p "$CLONE_DIR"
    if git clone --quiet --filter=blob:none --no-checkout "https://github.com/$REPO.git" "$CLONE_DIR" 2>/dev/null; then
      CLONE_STATE=ok; return 0
    fi
    CLONE_STATE=fail
    echo "in-dirs: git clone of $REPO into $CLONE_DIR failed — IN-DIRS column will show ERR." >&2
    return 1
  fi
  CLONE_DIR=$(mktemp -d)
  trap 'rm -rf "$CLONE_DIR"' EXIT
  if git clone --quiet --filter=blob:none --no-checkout "https://github.com/$REPO.git" "$CLONE_DIR" 2>/dev/null; then
    CLONE_STATE=ok; return 0
  fi
  CLONE_STATE=fail
  echo "in-dirs: git clone of $REPO failed — IN-DIRS column will show ERR." >&2
  return 1
}

# Echo YES if the PR whose merge commit is $1 (a 7-char SHA) changed any file
# under one of the IN_DIRS_ARR prefixes, NO otherwise. Used only with --in-dirs=.
# Echoes ERR if the clone failed or the commit isn't present.
# The PR's changes are the diff of its merge commit against its first parent
# (the base branch) — which works for both squash merges (1 parent) and merge
# commits (2 parents). Git pathspecs match at directory boundaries.
pr_in_dirs() {
  local sha="$1" base nparents
  ensure_clone || { echo "ERR"; return; }
  git -C "$CLONE_DIR" cat-file -e "${sha}^{commit}" 2>/dev/null || { echo "ERR"; return; }
  nparents=$(( $(git -C "$CLONE_DIR" rev-list --parents -n1 "$sha" 2>/dev/null | wc -w) - 1 ))
  if [ "$nparents" -ge 2 ]; then base="${sha}^1"; else base="${sha}^"; fi
  if git -C "$CLONE_DIR" diff --name-only "$base" "$sha" -- "${IN_DIRS_ARR[@]}" 2>/dev/null | grep -q .; then
    echo "YES"
  else
    echo "NO"
  fi
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

# --- second table: merged PRs down to the commit currently on test ----------
if [ "$TEST_RELEASE" -eq 1 ]; then
  echo

  # The commit currently on test = the newest dispatch run of THIS workflow
  # whose deployment landed in the `test` environment. We scope to this
  # workflow's own runs (not the repo's global latest `test` deployment)
  # because monorepos like bcgov/lear and bcgov/business-ui run several CD
  # workflows that all deploy to one shared `test` environment — the global
  # latest could belong to a different component. We scan all fetched runs
  # (up to 50), not just the COUNT shown above, so an older test deploy is
  # still found if the most recent runs went to dev/prod.
  STOP_SHA=""; STOP_WHEN=""
  while IFS=$'\t' read -r rsha rcreated; do
    [ -z "$rsha" ] && continue
    if [ "$(get_env "$rsha" "$rcreated")" = "test" ]; then
      STOP_SHA="${rsha:0:7}"
      STOP_WHEN="${rcreated:0:10}"
      break
    fi
  # Here-string (not process substitution): jq runs to completion and its output
  # is captured BEFORE the loop, so the early `break` above can't close the pipe
  # under jq and leave it writing into a dead reader ("jq: writing output failed:
  # Broken pipe"). The fetched run list is tiny, so buffering it is free.
  done <<< "$(printf '%s' "$RUNS_JSON" | jq -r '.workflow_runs[] | [ .head_sha, .created_at ] | @tsv')"

  if [ -z "$STOP_SHA" ]; then
    echo "test-release: no 'test' deployment found in the recent runs of $WORKFLOW — nothing to bound the PR list." >&2
    exit 0
  fi

  # --html suppresses this text table (header + rows); only the HTML prints.
  if [ "$HTML" -ne 1 ]; then
    echo "test-release: merged PRs newer than the commit on test ($STOP_SHA, test run dated $STOP_WHEN, excluded)"
    # With --in-dirs the rows are already filtered to commits that touched the
    # dirs, so the table looks like the others — just label it with the filter.
    [ "$IN_DIRS" -eq 1 ] && echo "these are the commits IN-DIRS=$IN_DIRS_ARG"
    printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "TITLE" "AUTHOR" "PR" "TICKET" "Merged_Date" "COMMIT"
    printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "------------------------------------------" "--------------------" "-------" "-------" "-----------" "-------"
  fi

  # Pull recent closed PRs, keep the merged ones, newest-merged first. TICKET
  # comes from the PR body line "*Issue #:* /bcgov/entity#NNNNN"; NA if absent.
  # Full title is carried for the HTML table; the text table truncates with %.41s.
  PRS_JSON=$(api "/repos/$REPO/pulls?state=closed&per_page=100&sort=updated&direction=desc") || PRS_JSON='[]'

  found=0; shown=0
  pr_rows=()
  while IFS=$'\t' read -r pnum pticket psha pdate pauthor ptitle; do
    [ -z "$pnum" ] && continue
    # stop AT the commit already on test, without printing it (it's released)
    if [ "$psha" = "$STOP_SHA" ]; then found=1; break; fi
    pauthor="@$pauthor"   # prepend @ to the handle (used by both text and HTML)
    if [ "$IN_DIRS" -eq 1 ]; then
      changed=$(pr_in_dirs "$psha")
      # With --in-dirs, drop PRs that didn't touch the filtered dirs (NO); keep
      # YES and ERR (ERR is a clone/lookup failure worth surfacing).
      [ "$changed" = "NO" ] && continue
    else
      changed=""
    fi
    [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$ptitle" "$pauthor" "$pnum" "$pticket" "$pdate" "$psha"
    pr_rows+=("$pnum"$'\t'"$pticket"$'\t'"$psha"$'\t'"$pdate"$'\t'"$pauthor"$'\t'"$ptitle"$'\t'"$changed")
    shown=$((shown + 1))
  # Here-string (not process substitution) so the early `break` above can't
  # SIGPIPE jq mid-write ("Broken pipe"); jq finishes into the captured string.
  done <<< "$(printf '%s' "$PRS_JSON" | jq -r '
    [ .[] | select(.merged_at != null) ] | sort_by(.merged_at) | reverse | .[] |
    [ ("#" + (.number|tostring)),
      ((.body // "") | [scan("/bcgov/entity#([0-9]+)")] | if length>0 then "#"+.[0][0] else "NA" end),
      ((.merge_commit_sha // "")[0:7]),
      (.merged_at[0:10]),
      .user.login,
      .title ] | @tsv')"

  if [ "$found" -eq 1 ] && [ "$shown" -eq 0 ]; then
    # With --in-dirs every in-scope PR may have been filtered out (all NO); say
    # so explicitly (printed in HTML too, since there's no table to show).
    if [ "$IN_DIRS" -eq 1 ]; then
      echo "No commits in IN-DIRS=$IN_DIRS_ARG"
    else
      [ "$HTML" -ne 1 ] && echo "(none — test is up to date with the newest merged PR)"
    fi
  elif [ "$found" -eq 0 ]; then
    echo "test-release: warning — commit $STOP_SHA (newest test run of $WORKFLOW) not found in the last 100 merged PRs;" >&2
    echo "              the list above is not bounded to the test release. (Deploy commit may not be a PR merge commit.)" >&2
  fi

  # Raw HTML version of the second table (no CSS), printed after the text table.
  if [ "$shown" -gt 0 ]; then
    echo
    # With --in-dirs the rows are already filtered to commits that touched the
    # dirs, so the table looks like the others — just label it with the filter.
    [ "$IN_DIRS" -eq 1 ] && echo "these are the commits IN-DIRS=$IN_DIRS_ARG"
    echo "<table border=\"1\">"
    echo "  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>"
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
      # Commit cell -> link to the commit on the repo this table is for ($REPO),
      # e.g. https://github.com/bcgov/lear/commit/abc1234.
      commit_cell="<a href=\"https://github.com/$REPO/commit/$hsha\">$(html_escape "$hsha")</a>"
      printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$pr_cell" \
        "$ticket_cell" "$(html_escape "$hdate")" "$commit_cell"
    done
    echo "</table>"
  fi
fi
