# Shared by pre-release-watch.sh and post-release-watch.sh (sourced, not run).
# Reads the watch script's globals: REPO, CLONE_DIR, IN_DIRS, IN_DIRS_ARR, HTML,
# TEST_ROWS, and its parse_commit function.

# Write the PRs in git range $1 (e.g. "STOP..origin/HEAD"), newest first and
# honouring --in-dirs, to file $2 as a JSON array. Without --html the rows are
# also printed as text. Sets SHOWN to the number of rows.
list_prs() {  # list_prs <git-range> <out-file>
  local range="$1" out="$2" pathspec=() rows="" csha cdate cname cemail csubj cbody
  [ "$IN_DIRS" -eq 1 ] && pathspec=(-- "${IN_DIRS_ARR[@]}")
  SHOWN=0
  # NUL-terminated records, unit-separator (\x1f) between fields: the body may
  # contain anything (tabs, newlines) so tsv isn't safe.
  while IFS=$'\x1f' read -r -d '' csha cdate cname cemail csubj cbody; do
    [ -z "$csha" ] && continue
    parse_commit "$csubj" "$cbody" "$cname" "$cemail" "$csha"
    [ "$HTML" -ne 1 ] && printf '%-42.41s %-20.20s %-7s %-9s %-12s %-9s\n' "$PR_TITLE" "$PR_AUTHOR" "$PR_NUM" "$PR_TICKET" "$cdate" "$csha"
    rows+="$PR_NUM"$'\t'"$PR_TICKET"$'\t'"$csha"$'\t'"$cdate"$'\t'"$PR_AUTHOR"$'\t'"$PR_TITLE"$'\n'
    SHOWN=$((SHOWN + 1))
  done < <(git -C "$CLONE_DIR" log --first-parent -z --abbrev=7 \
             --format='%h%x1f%cs%x1f%an%x1f%ae%x1f%s%x1f%b' "$range" ${pathspec[@]+"${pathspec[@]}"} 2>/dev/null)

  printf '%s' "$rows" | jq -Rs 'split("\n") | map(select(length > 0) | split("\t")
    | {pr: .[0], ticket: .[1], commit: .[2], date: .[3], author: .[4], title: (.[5:] | join("\t"))})' > "$out"
}

# Print this section's inline data, attached to its enclosing <pre>; the
# report-view.js loaded at the end of the report renders the tables from it.
#   optimistic  the default list: the exact rows of <optimistic-range>
#   points      the `test` rows of the run log above: the only selectable bounds
#   dynamic     every PR from the oldest point to origin/HEAD, newest first
#   head/branch the default branch at generation, for the page's behind-head check
# A point's `newer` counts the dynamic rows newer than it, so the PRs between
# two points are dynamic.slice(newer(Y), newer(X)) without any git in the page.
emit_view_data() {  # emit_view_data <pre|post> <optimistic-range> <from-sha> <to-sha|"">
  local kind="$1" range="$2" from="$3" to="$4" dir row num sha date result newer on_main
  local oldest="" oldest_newer=-1 pathspec=() head branch
  [ "$IN_DIRS" -eq 1 ] && pathspec=(-- "${IN_DIRS_ARR[@]}")
  dir=$(mktemp -d)
  # No range: no default list could be bounded, but dynamic mode still works.
  echo '[]' > "$dir/optimistic"
  [ -n "$range" ] && list_prs "$range" "$dir/optimistic"

  : > "$dir/points"
  for row in ${TEST_ROWS[@]+"${TEST_ROWS[@]}"}; do
    IFS=$'\t' read -r num sha date result <<< "$row"
    git -C "$CLONE_DIR" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    newer=$(git -C "$CLONE_DIR" rev-list --first-parent --count "$sha..origin/HEAD" ${pathspec[@]+"${pathspec[@]}"})
    on_main=false
    git -C "$CLONE_DIR" merge-base --is-ancestor "$sha" origin/HEAD 2>/dev/null && on_main=true
    jq -n --argjson run "$num" --arg sha "${sha:0:7}" --arg date "$date" --arg result "$result" \
      --argjson newer "$newer" --argjson onMain "$on_main" \
      '{run: $run, sha: $sha, date: $date, result: $result, newer: $newer, onMain: $onMain}' >> "$dir/points"
    if [ "$newer" -gt "$oldest_newer" ]; then oldest="$sha"; oldest_newer="$newer"; fi
  done

  echo '[]' > "$dir/dynamic"
  [ -n "$oldest" ] && list_prs "$oldest..origin/HEAD" "$dir/dynamic"

  head=$(git -C "$CLONE_DIR" rev-parse origin/HEAD)
  branch=$(git -C "$CLONE_DIR" symbolic-ref --short refs/remotes/origin/HEAD)
  branch="${branch#origin/}"

  # "<" is escaped so a PR title can never close the <script> element.
  printf '<script>document.currentScript.parentElement.prData = %s;</script>\n' "$(
    jq -rn --arg kind "$kind" --arg repo "$REPO" --arg head "$head" --arg branch "$branch" \
      --arg from "${from:0:7}" --arg to "${to:0:7}" \
      --slurpfile optimistic "$dir/optimistic" --slurpfile points "$dir/points" --slurpfile dynamic "$dir/dynamic" \
      '{kind: $kind, repo: $repo, head: $head, branch: $branch, from: $from, to: $to,
        optimistic: $optimistic[0], points: $points, dynamic: $dynamic[0]}
       | tojson | gsub("<"; "\\u003c")'
  )"
  rm -rf "$dir"
}
