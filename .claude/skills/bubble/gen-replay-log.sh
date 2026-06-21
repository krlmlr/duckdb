#!/usr/bin/env bash
#
# gen-replay-log.sh BIF MAINDAG  > REPLAY-LOG.md
#
# Generates the growable provenance log: every first-parent commit since the
# bifurcation BIF up to MAINDAG (origin/main-dag), grouped by run (one run per
# release back-merge). Identity per commit = its PR (-> duckdb/duckdb) + its -dag
# commit (-> krlmlr/duckdb). Every COMPLETED run carries a per-commit SHA + role:
#   replayed  - cherry-picked in that run's de-merge segment (new SHA)
#   copied    - above that run's de-merge point; reattached tree-verbatim (new SHA)
#   empty     - went empty that run (change already in that run's base); no SHA.
#               Once absorbed it stays absorbed -> written once as "from run #N".
# Back-merges: copied (merge) until de-merged, then written once as
#   "from run #N: linearized ..." (stays linearized thereafter, like the
#   "from run #N" form used for absorbed commits).
#
# To add a run: append one line to RUNS (label|de-merged-range|full-result-ref|
#   checkpoint-PR|checkpoint-note). Full-result-ref for run N is the branch state
#   AFTER run N (run1 -> -01, run2 -> -02, ..., latest -> origin/<branch>).
#
# Why PR+`-dag` and not an origin/main SHA: krlmlr's fork `main` is not a faithful
# mirror of duckdb/duckdb main (some PRs, e.g. #20369, are absent), so the -dag
# substrate + the upstream PR number are the authoritative identity.
set -uo pipefail
BIF="$1"; MAINDAG="$2"
CO="https://github.com/krlmlr/duckdb/commit"
PRU="https://github.com/duckdb/duckdb/pull"

# --- completed runs (oldest first) -----------------------------------------
RUNS=(
  "1|00528f79b..0ffd087cddb5|origin/main-v1.5-variegata-01|20488|linearized (clean; checkpoint == segment tail, tree == merge tree)"
  "2|3710298ae..d0ab64a4c323|origin/main-v1.5-variegata-02|20588|linearized → reconcile [\`d0ab64a4\`](CO/d0ab64a4c3232b381bbb058cc23cece04d19f0ee) (tree \`e337ce86\` == merge tree); removed NOT-elimination (#20394) + regenerated churn"
  "3|9c028743f..76e52d65cf|origin/main-v1.5-variegata|20644|linearized (clean; replay reproduced the merge tree, no reconcile)"
)
RUN_NS=(); declare -A CKPT_NOTE
for spec in "${RUNS[@]}"; do
  IFS='|' read -r n range ref pr note <<<"$spec"
  RUN_NS+=("$n"); CKPT_NOTE[$n]="${note//CO\//$CO/}"
  declare -gA "DM_$n" "ALL_$n"
  while read -r sha subj; do
    p=$(echo "$subj" | grep -oE 'pull/[0-9]+|#[0-9]+' | head -1 | grep -oE '[0-9]+')
    [ -n "$p" ] && printf -v "DM_$n[$p]" '%s' "$sha"
  done < <(git log --reverse --first-parent --format='%H %s' "$range" 2>/dev/null)
  while read -r sha subj; do
    p=$(echo "$subj" | grep -oE 'pull/[0-9]+|#[0-9]+' | head -1 | grep -oE '[0-9]+')
    [ -n "$p" ] && printf -v "ALL_$n[$p]" '%s' "$sha"
  done < <(git log --reverse --first-parent --format='%H %s' "$ref" 2>/dev/null)
done

prnum(){ echo "$1" | grep -oE 'pull/[0-9]+|#[0-9]+' | head -1 | grep -oE '[0-9]+'; }
title(){ echo "$1" | sed -E 's@ \(https://redirect[^)]*\)@@; s@ \(#[0-9]+\)$@@'; }
prlink(){ [ -n "$1" ] && printf '[#%s](%s/%s) ' "$1" "$PRU" "$1"; }
link(){ printf '[`%s`](%s/%s)' "${1:0:9}" "$CO" "$1"; }

emit_roles(){ local pr="$1" n dmv allv
  [ -z "$pr" ] && { echo "  - (no PR#)"; return; }
  for n in "${RUN_NS[@]}"; do
    dmv="DM_$n[$pr]"; allv="ALL_$n[$pr]"
    if   [ -n "${!dmv:-}" ];  then echo "  - run #$n: replayed $(link "${!dmv}")"
    elif [ -n "${!allv:-}" ]; then echo "  - run #$n: copied $(link "${!allv}")"
    else echo "  - from run #$n: empty (absorbed — base already has the change; stays absorbed)"; return; fi
  done; }

# A back-merge is identified by its PR# (p). Per run:
#   n < k             : still a merge above the de-merge point  -> copied (merge) [ALL_n]
#   n >= k, DM_n has p : a reconcile commit exists this run (re-created, new SHA)
#                        -> linearized -> reconcile [DM_n] (note on the first run)
#   n >= k, DM_n lacks p: clean checkpoint (no reconcile); content folds into the
#                        base -> linearized (clean) at run k, then "from run #N"
#                        (collapse, like absorbed) thereafter.
emit_ckpt(){ local k="$1" p="$2" n dmv allv
  for n in "${RUN_NS[@]}"; do
    dmv="DM_$n[$p]"; allv="ALL_$n[$p]"
    if [ "$n" -lt "$k" ]; then
      [ -n "${!allv:-}" ] && echo "  - run #$n: copied (merge) $(link "${!allv}")" || echo "  - run #$n: copied (merge)"
    elif [ -n "${!dmv:-}" ]; then          # reconcile commit present this run (persists, per-run SHA)
      if [ "$n" -eq "$k" ]; then echo "  - run #$n: ${CKPT_NOTE[$k]}"
      else echo "  - run #$n: linearized → reconcile $(link "${!dmv}") (re-created; same cross-side reconciliation)"; fi
    else                                   # clean checkpoint: no reconcile commit
      if [ "$n" -eq "$k" ]; then echo "  - run #$n: ${CKPT_NOTE[$k]}"
      else echo "  - from run #$n: absorbed (clean checkpoint; its segment is now in the v1.5 base)"; return; fi
    fi
  done; }

MAXRUN=$(git rev-list --count --first-parent --merges "${BIF}..${MAINDAG}" 2>/dev/null)

cat <<EOF
# Replay log — \`main-v1.5-variegata\`

Generated by \`gen-replay-log.sh\`; **regenerate each run** (skill step 5). Oldest
first (\`git log --reverse\`), grouped by **run** (de-merge === run; one run per
release back-merge). Identity = the upstream **PR** (→ \`duckdb/duckdb\`) and the
\`-dag\` commit (→ \`krlmlr/duckdb\`). Every **completed run** carries a per-commit
SHA (→ \`krlmlr/duckdb\`) with a role:

- **replayed** \`sha\` — cherry-picked in that run's de-merge segment (new SHA);
- **copied** \`sha\` — above that run's de-merge point; reattached tree-verbatim by
  the graft (new SHA, byte-identical tree);
- **empty (absorbed)** — went empty that run (change already in that run's base);
  no SHA. Once absorbed it stays absorbed, so it is written once as **from run #N**.

Back-merges (checkpoints): **copied (merge)** until de-merged; then **linearized**
— if the de-merge needed a reconcile commit it is re-created every run with a new
SHA (**linearized → reconcile** \`sha\`, per run); a **clean** checkpoint folds into
the base and reads **from run #N: absorbed** thereafter.

Each run re-roots the de-merged-so-far spine onto the next back-merge's second
parent, so a commit replayed by an earlier run can later go **empty** once the
advancing v1.5 base already reflects it (cherry-pick onto the base is empty —
confirmed; the v1.5 base reached the same state via other commits, so there is no
single attributable v1.5 PR). **Completed runs: ${#RUN_NS[@]} of $MAXRUN.**
EOF

run=0; started=0
while IFS=$'\t' read -r sha parents subj; do
  np=$(echo "$parents" | wc -w); pr=$(prnum "$subj"); t=$(title "$subj")
  if [ "$np" -ge 2 ]; then
    k=$((run+1)); echo
    echo "- **[checkpoint] Run #$k back-merge** $(prlink "$pr")\"$t\""
    echo "  - \`-dag\`: $(link "$sha")"
    emit_ckpt "$k" "$pr"
    run=$k; started=0; continue
  fi
  if [ "$started" -eq 0 ]; then
    echo
    if [ "$((run+1))" -gt "${MAXRUN:-0}" ]; then
      echo "### Tail (no back-merge yet — appended by step 1 'track main'; becomes run #$((run+1))'s segment when the next back-merge lands)"
    else echo "### Run #$((run+1)) segment"; fi
    started=1
  fi
  echo "- $(prlink "$pr")$t"
  echo "  - \`-dag\`: $(link "$sha")"
  emit_roles "$pr"
done < <(git log --reverse --first-parent --format='%H%x09%P%x09%s' "${BIF}..${MAINDAG}" 2>/dev/null)
