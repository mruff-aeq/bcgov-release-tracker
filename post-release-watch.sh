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
# That PR list is read from a local git clone of the repo, NOT the GitHub PR
# API: every first-parent commit on the default branch is one merged PR (squash
# or merge commit), so `git log PREV_TEST..LATEST_TEST` is the exact, complete
# list — no 100-PR API window that can miss a bounding commit, no sort-by-
# updated staleness. Columns are derived from the commit: PR number and title
# from the subject, ticket from a bcgov/entity#N ref or the leading number of
# the title ("34267 - ..."), author from the GitHub noreply email (login) or the
# git author name.
#
# --in-dirs=DIR[,DIR...] (requires `test-release`, else it errors) limits that
# second table to the PRs that changed any file under DIR or one of its child
# dirs (a git pathspec on the log). Multiple dirs may be comma-separated; a PR
# matching ANY of them is kept. Example dir for bcgov/business-ui:
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
# Requires: curl, jq, and git (for `test-release`). No authentication is
# required (these bcgov repos are public), but an optional GH_TOKEN/GITHUB_TOKEN
# is used if present — see the api() helper. Anonymous calls share a 60/hour-per-
# IP cap; a token gets its own ~1000-5000/hour. This makes a FIXED 2 API calls
# per repo (deployments + runs) — the deploy environment of a run exists only in
# the GitHub Deployments/Actions API, so that part can't come from git — plus at
# most one extra per printed row when a run's deployment is older than the
# recent-deployments cache (see get_env). The PR list adds NO API calls: it does
# one blobless, no-checkout `git clone` (commits + trees only, no file contents
# — a few MB, a second or two) and reads the history locally. Git transport is
# not part of the REST rate limit.
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

command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "error: jq not found"   >&2; exit 1; }
# The test-release PR table is read from a local clone, so it needs git.
if [ "$TEST_RELEASE" -eq 1 ]; then
  command -v git >/dev/null 2>&1 || { echo "error: git not found (needed for test-release)" >&2; exit 1; }
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

# Number of attempts for a single API call. Overridable via the environment.
API_RETRIES="${API_RETRIES:-5}"

api() {  # api <path-or-full-url> ; prints body on success, returns nonzero on failure
  local url="$1" attempt code tmp
  case "$url" in http*) ;; *) url="$API$url" ;; esac
  tmp=$(mktemp)
  # Retry only TRANSIENT failures (rate limit / 5xx / network) so a single
  # hiccup on the deployments or runs fetch doesn't blank a whole table's ENV
  # column to "?". A hard 4xx like 404 is not retried (retrying won't help).
  # We keep the body off stderr and emit 'error: CODE' only when we give up —
  # the report workflow greps stderr for 'error: 403' / 'error: 429' to fail
  # loudly (red X) instead of committing a degraded all-"?" report, so that
  # exact text is preserved for the rate-limit codes.
  for attempt in $(seq 1 "$API_RETRIES"); do
    code=$(curl -sSL -o "$tmp" -w '%{http_code}' ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null)
    if [ "$code" = "200" ]; then
      cat "$tmp"; rm -f "$tmp"; return 0
    fi
    case "$code" in
      403|429|500|502|503|504|000)
        [ "$attempt" -lt "$API_RETRIES" ] && sleep "$(( attempt < 5 ? attempt : 5 ))" ;;
      *) break ;;
    esac
  done
  rm -f "$tmp"
  echo "error: $code (GET $url)" >&2
  return 1
}

# Fetch the repo's recent deployments once; reused to resolve every run's env.
# 100 covers a wide window even for repos with frequent auto-deploys to dev.
DEPLOYS_JSON=$(api "/repos/$REPO/deployments?per_page=100") || DEPLOYS_JSON='[]'

# Resolve the deploy environment for a run, given its commit SHA + start time.
# A run's deployment shares its SHA and is created a few seconds later, so we
# pick the earliest deployment with the same 7-char SHA at/after the run start.
# ISO-8601 'Z' timestamps compare correctly as plain strings.
get_env() {  # get_env <full-sha> <created_at> [deep]
  local sha="$1" t="$2" deep="${3:-0}" env
  env=$(printf '%s' "$DEPLOYS_JSON" | jq -r --arg sha "${sha:0:7}" --arg t "$t" '
    [ .[] | select((.sha[0:7]) == $sha and .created_at >= $t) ]
    | sort_by(.created_at) | (.[0].environment // "?")')
  # The recent-deployments cache is the latest 100 deployments repo-wide. On a
  # busy monorepo like bcgov/lear that only spans a couple of weeks, so a run
  # that deployed longer ago than that window isn't in it and resolves to "?".
  # When deep=1 (used only for the few rows the table actually prints, not the
  # 50-run test-bounding scan), fall back to a query filtered by this run's FULL
  # commit SHA — the deployments ?sha= filter needs the full SHA, not a prefix —
  # which returns that commit's deployments regardless of age. Costs at most one
  # extra API call per printed row, and only when the cache couldn't resolve it.
  if [ "$env" = "?" ] && [ "$deep" = "1" ]; then
    local by_sha
    by_sha=$(api "/repos/$REPO/deployments?sha=$sha&per_page=100") || by_sha=""
    if [ -n "$by_sha" ]; then
      env=$(printf '%s' "$by_sha" | jq -r --arg t "$t" '
        [ .[] | select(.created_at >= $t) ]
        | sort_by(.created_at) | (.[0].environment // "?")')
    fi
  fi
  printf '%s' "$env"
}

# Minimal HTML escaping for table cell text (&, <, > only — no CSS, no quotes-in-attrs).
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# --- local clone of the repo (the PR list comes from git, not the API) --------
# The merged-PR list is read from a local clone: every first-parent commit on the
# default branch is one merged PR (squash or merge commit), so `git log` over a
# commit range gives the exact list bounded by the deploy commits — no PR API,
# no 100-item window that can miss the bounding commit, no sort-by-updated
# staleness. Git transport is not part of the REST rate limit either.
#
# The clone is blobless + no-checkout: it pulls commits and trees (enough for
# `--in-dirs` pathspec filtering) but no file contents and no working tree — a
# couple MB, about a second. CLONE_STATE is "" (not yet attempted), "ok" or "fail".
#
# REPO_CLONE_DIR (optional env var): a directory where the clone of $REPO lives
# or should be created, OWNED BY THE CALLER. When a wrapper runs this script
# many times against the same monorepo — one invocation per child dir, e.g. the
# release-report output scripts looping over bcgov/lear's queue_services/* — it
# can clone that large repo ONCE into a shared dir and export REPO_CLONE_DIR so
# every invocation reuses it instead of re-cloning. Contract: the dir is scoped
# to a single $REPO by the caller (we don't verify), the first invocation
# populates it, the rest reuse it as-is (no re-fetch — a report run is short), and the
# caller removes it afterwards (we never delete a caller-provided dir). When the
# var is unset we fall back to a private mktemp clone removed on exit.
CLONE_DIR=""; CLONE_STATE=""
ensure_clone() {
  [ -n "$CLONE_STATE" ] && { [ "$CLONE_STATE" = ok ]; return; }
  if [ -n "${REPO_CLONE_DIR:-}" ]; then
    CLONE_DIR="$REPO_CLONE_DIR"
    # Already populated by an earlier invocation sharing this dir? Reuse it.
    if git -C "$CLONE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      CLONE_STATE=ok; return 0
    fi
    mkdir -p "$CLONE_DIR"
  else
    CLONE_DIR=$(mktemp -d)
    trap 'rm -rf "$CLONE_DIR"' EXIT
  fi
  if git clone --quiet --filter=blob:none --no-checkout "https://github.com/$REPO.git" "$CLONE_DIR" 2>/dev/null; then
    CLONE_STATE=ok; return 0
  fi
  CLONE_STATE=fail
  echo "clone: git clone of $REPO failed — no PR list." >&2
  return 1
}

# Derive the PR table columns from one first-parent commit of the default branch.
# Sets PR_NUM ("#123", or "-" for a direct push), PR_TITLE, PR_TICKET ("#N" or
# NA) and PR_AUTHOR from the commit's subject, body, author name and email.
#   * squash merge:  subject "Title (#123)"            -> title, PR 123
#   * merge commit:  subject "Merge pull request #123 from ..." + body "Title"
#   * ticket: a "bcgov/entity#N" / ".../entity/issues/N" ref anywhere in the
#     message, else the leading ticket number of the title ("34267 - Fix ..."),
#     else NA. (The PR body isn't in git, so title convention is the source.)
#   * author: the GitHub login when the author email is a GitHub noreply address
#     (squash merges: "12345+login@users.noreply.github.com"), else the git name.
parse_commit() {  # parse_commit <subject> <body> <author-name> <author-email>
  local subj="$1" body="$2" name="$3" email="$4"
  if [[ "$subj" =~ ^Merge\ pull\ request\ \#([0-9]+)\  ]]; then
    PR_NUM="#${BASH_REMATCH[1]}"
    PR_TITLE="${body%%$'\n'*}"
    [ -z "$PR_TITLE" ] && PR_TITLE="$subj"
  elif [[ "$subj" =~ ^(.*)\ \(\#([0-9]+)\)$ ]]; then
    PR_NUM="#${BASH_REMATCH[2]}"
    PR_TITLE="${BASH_REMATCH[1]}"
  else
    PR_NUM="-"
    PR_TITLE="$subj"
  fi
  if [[ "$subj"$'\n'"$body" =~ bcgov/entity(#|/issues/)([0-9]+) ]]; then
    PR_TICKET="#${BASH_REMATCH[2]}"
  elif [[ "$PR_TITLE" =~ ^[[:space:]]*#?([0-9]{4,6})([^0-9]|$) ]]; then
    PR_TICKET="#${BASH_REMATCH[1]}"
  else
    PR_TICKET="NA"
  fi
  if [[ "$email" =~ ^([0-9]+\+)?([^@]+)@users\.noreply\.github\.com$ ]]; then
    PR_AUTHOR="@${BASH_REMATCH[2]}"
  else
    PR_AUTHOR="$name"
  fi
}

# Print the PR table (text unless --html, then HTML) for the first-parent commits
# in git range $1 (e.g. "STOP..origin/HEAD"), newest first, honouring --in-dirs.
# Sets SHOWN to the number of rows.
list_prs() {  # list_prs <git-range>
  local range="$1" pathspec=() csha cdate cname cemail csubj cbody
  local pr_cell ticket_cell commit_cell r hnum hticket hsha hdate hauthor htitle
  [ "$IN_DIRS" -eq 1 ] && pathspec=(-- "${IN_DIRS_ARR[@]}")
  SHOWN=0
  local pr_rows=()
  # NUL-terminated records, unit-separator (\x1f) between fields: the body may
  # contain anything (tabs, newlines) so tsv isn't safe.
  while IFS=$'\x1f' read -r -d '' csha cdate cname cemail csubj cbody; do
    [ -z "$csha" ] && continue
    parse_commit "$csubj" "$cbody" "$cname" "$cemail"
    [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$PR_TITLE" "$PR_AUTHOR" "$PR_NUM" "$PR_TICKET" "$cdate" "$csha"
    pr_rows+=("$PR_NUM"$'\t'"$PR_TICKET"$'\t'"$csha"$'\t'"$cdate"$'\t'"$PR_AUTHOR"$'\t'"$PR_TITLE")
    SHOWN=$((SHOWN + 1))
  done < <(git -C "$CLONE_DIR" log --first-parent -z --abbrev=7 \
             --format='%h%x1f%cs%x1f%an%x1f%ae%x1f%s%x1f%b' "$range" ${pathspec[@]+"${pathspec[@]}"} 2>/dev/null)

  # Raw HTML version of the table (no CSS), printed after the text table.
  if [ "$SHOWN" -gt 0 ]; then
    echo
    # With --in-dirs the rows are already filtered to commits that touched the
    # dirs, so the table looks like the others — just label it with the filter.
    [ "$IN_DIRS" -eq 1 ] && echo "these are the commits IN-DIRS=$IN_DIRS_ARG"
    echo "<table border=\"1\">"
    echo "  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>"
    for r in "${pr_rows[@]}"; do
      IFS=$'\t' read -r hnum hticket hsha hdate hauthor htitle <<< "$r"
      # Ticket cell -> link to the bcgov/entity issue, unless it's NA.
      if [ "$hticket" = "NA" ]; then
        ticket_cell="NA"
      else
        ticket_cell="<a href=\"https://github.com/bcgov/entity/issues/${hticket#\#}\">$(html_escape "$hticket")</a>"
      fi
      # PR cell -> link to the PR on $REPO, e.g. https://github.com/bcgov/lear/pull/123
      # ($hnum is like "#123"); "-" for a commit that isn't a PR merge.
      if [ "$hnum" = "-" ]; then
        pr_cell="-"
      else
        pr_cell="<a href=\"https://github.com/$REPO/pull/${hnum#\#}\">$(html_escape "$hnum")</a>"
      fi
      # Commit cell -> link to the commit on $REPO.
      commit_cell="<a href=\"https://github.com/$REPO/commit/$hsha\">$(html_escape "$hsha")</a>"
      printf '  <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(html_escape "$htitle")" "$(html_escape "$hauthor")" "$pr_cell" \
        "$ticket_cell" "$(html_escape "$hdate")" "$commit_cell"
    done
    echo "</table>"
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
    (.conclusion // .status // "?"),
    .created_at,
    (.actor.login // "-"),
    ((.head_commit.message // "") | split("\n")[0]) ] | @tsv')

for line in "${rows[@]}"; do
  IFS=$'\t' read -r num sha concl created actor msg <<< "$line"
  env=$(get_env "$sha" "$created" 1)
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
  # Here-string (not process substitution): jq runs to completion and its output
  # is captured BEFORE the loop, so the early `break` above can't close the pipe
  # under jq and leave it writing into a dead reader ("jq: writing output failed:
  # Broken pipe"). The fetched run list is tiny, so buffering it is free.
  done <<< "$(printf '%s' "$RUNS_JSON" | jq -r '.workflow_runs[] | [ (.run_number|tostring), .head_sha, .created_at ] | @tsv')"

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
    # With --in-dirs the rows are already filtered to commits that touched the
    # dirs, so the table looks like the others — just label it with the filter.
    [ "$IN_DIRS" -eq 1 ] && echo "these are the commits IN-DIRS=$IN_DIRS_ARG"
    printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "TITLE" "AUTHOR" "PR" "TICKET" "Merged_Date" "COMMIT"
    printf '%-42s %-20s %-7s %-9s %-12s %-9s\n' "------------------------------------------" "--------------------" "-------" "-------" "-----------" "-------"
  fi

  # The list itself comes from git: every first-parent commit on the default
  # branch in the range previous-test..latest-test is one merged PR shipped in
  # the latest push (see ensure_clone / list_prs). --in-dirs is a pathspec.
  ensure_clone || exit 1
  if ! git -C "$CLONE_DIR" cat-file -e "${START_SHA}^{commit}" 2>/dev/null; then
    echo "post-release: latest test commit $START_SHA (run #$START_RUN) is not in $REPO's history — cannot scope the release." >&2
    [ "$HTML" -eq 1 ] && echo "warning: test commit $START_SHA not found in $REPO history — no PR list"
    exit 0
  fi
  if ! git -C "$CLONE_DIR" cat-file -e "${STOP_SHA}^{commit}" 2>/dev/null; then
    echo "post-release: previous test commit $STOP_SHA (run #$STOP_RUN) is not in $REPO's history — cannot bound the release window." >&2
    [ "$HTML" -eq 1 ] && echo "warning: previous test commit $STOP_SHA not found in $REPO history — no PR list"
    exit 0
  fi
  if ! git -C "$CLONE_DIR" merge-base --is-ancestor "$STOP_SHA" "$START_SHA" 2>/dev/null; then
    # e.g. one of the two deploys came from a feature/hotfix branch; the range
    # then lists what's reachable from START but not STOP, which may overshoot.
    echo "post-release: warning — previous test commit $STOP_SHA is not an ancestor of $START_SHA; the list may be inexact." >&2
    [ "$HTML" -eq 1 ] && echo "warning: test commits $STOP_SHA and $START_SHA are not on one line of history — list may be inexact"
  fi

  list_prs "$STOP_SHA..$START_SHA"

  if [ "$SHOWN" -eq 0 ]; then
    # With --in-dirs every in-scope PR may have been filtered out; say so
    # explicitly (printed in HTML too, since there's no table to show).
    if [ "$IN_DIRS" -eq 1 ]; then
      echo "No commits in IN-DIRS=$IN_DIRS_ARG"
    else
      [ "$HTML" -ne 1 ] && echo "(none — the latest test deploy contained no new merged PRs)"
    fi
  fi
fi
