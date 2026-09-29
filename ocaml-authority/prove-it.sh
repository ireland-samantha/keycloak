#!/usr/bin/env bash
# prove-it.sh: Keycloak files its authorization types with OCaml.
#
# Re-extracts the Authorization Services slice (tools/java-graph/authz-slice.txt)
# from a Keycloak source tree and compares it with the graph the committed
# certificate was issued for.
#   - unchanged:   the committed certificate is re-checked and stands
#   - changed:     attempt_proof runs on the new graph, the independent checker
#                  verifies the new certificate, and the verdicts are compared
#                  obligation by obligation with the committed ones
# Prints OCaml's review as Markdown (also to $GITHUB_STEP_SUMMARY when set).
# Exits 1 if the reviewed tree gains a REFUTED obligation, 2 on usage errors.
#
#   ./prove-it.sh                          review this checkout
#   ./prove-it.sh --root DIR               review another Keycloak tree
#   ./prove-it.sh --what-if PATCH...       review this checkout with PATCHes applied to a scratch copy
#                                          of the slice (the real tree is never touched)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
BASELINE=6688a3d63f59e0c4a9131bfdd556c4312799f04e
SLICE=tools/java-graph/authz-slice.txt
GRAPH=examples/proof/keycloak-authz.graph.json
CERT=examples/proof/certificate.json
ROOT="$(cd .. && pwd)"
PATCHES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --what-if) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do PATCHES+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"); shift; done ;;
    *) echo "usage: $0 [--root DIR] [--what-if PATCH...]" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PROVE="$HERE/_build/default/bin/prove/main.exe"
[ -x "$PROVE" ] || dune build ./bin/prove/main.exe >&2

LABEL="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unversioned)"
if [ ${#PATCHES[@]} -gt 0 ]; then
  # Copy only the slice, then apply the patches to the copy.
  while read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    mkdir -p "$WORK/tree/$(dirname "$f")"; cp "$ROOT/$f" "$WORK/tree/$f"
  done < "$SLICE"
  for p in "${PATCHES[@]}"; do patch -s -p1 -d "$WORK/tree" < "$p"; done
  ROOT="$WORK/tree"
  LABEL="what-if: $(for p in "${PATCHES[@]}"; do basename "$p"; done | paste -sd, -) (applied to this tree's slice)"
fi

extract() { # COMMIT_LABEL OUT
  java tools/java-graph/JavaGraph.java --root "$ROOT" --commit "$1" --slice "$SLICE" --out "$2" >/dev/null
}

OUT="$WORK/review.md"
say() { printf '%s\n' "$*" >> "$OUT"; }
counts() { jq -r '[.obligations[].verdict] | group_by(.) | map({(.[0]): length}) | add
                  | "PROVEN \(.PROVEN // 0) · STRENGTHENED \(.STRENGTHENED // 0) · UNKNOWN \(.UNKNOWN // 0) · REFUTED \(.REFUTED // 0)"' "$1"; }

say "### OCaml's review of Keycloak's authorization types"
say ""
say "Reviewed: \`$LABEL\` · baseline certificate: \`$BASELINE\` · slice: $(grep -vc '^\s*\(#\|$\)' "$SLICE") files"
say ""
status=0
extract "$BASELINE" "$WORK/pinned.json"
if cmp -s "$WORK/pinned.json" "$GRAPH"; then
  "$PROVE" --check "$GRAPH" "$CERT" > "$WORK/check.txt"
  say "**No drift.** The slice is byte-identical to the one the certificate was issued for, and the"
  say "independent checker accepts the certificate again:"
  say ""
  say "\`$(head -1 "$WORK/check.txt")\`"
  say ""
  say "$(counts "$CERT")"
else
  extract "$LABEL" "$WORK/graph.json"
  "$PROVE" "$WORK/graph.json" --certificate "$WORK/cert.json" --emit "$WORK/types.ml" --report > "$WORK/report.txt"
  "$PROVE" --check "$WORK/graph.json" "$WORK/cert.json" > "$WORK/check.txt"
  jq -n --slurpfile old "$CERT" --slurpfile new "$WORK/cert.json" '
    ($old[0].obligations | map({key: .id, value: .}) | from_entries) as $o
    | ($new[0].obligations | map({key: .id, value: .}) | from_entries) as $n
    | { newly_refuted: [ $n[] | select(.verdict == "REFUTED" and (($o[.id].verdict // "") != "REFUTED")) ],
        newly_unknown: [ $n[] | select(.verdict == "UNKNOWN" and (($o[.id].verdict // "") != "UNKNOWN")) ],
        resolved:      [ $o[] | select(.verdict == "REFUTED" or .verdict == "UNKNOWN")
                              | select(($n[.id].verdict // "gone") as $v | $v == "PROVEN" or $v == "STRENGTHENED") ],
        added_list: [ $n[] | select($o[.id] == null) ],
        gone: [ $o[] | select($n[.id] == null) | select(.verdict == "REFUTED" or .verdict == "UNKNOWN") ],
        new_types: ([ $n[].owner ] - [ $o[].owner ] | unique),
        added:   [ $n | keys[] | select($o[.] == null) ] | length,
        removed: [ $o | keys[] | select($n[.] == null) ] | length }' > "$WORK/delta.json"
  say "**Drift.** Keycloak's authorization types differ from the certified baseline. OCaml re-proved them;"
  say "the independent checker accepts the new certificate (\`$(head -1 "$WORK/check.txt")\`)."
  say ""
  say "| | verdicts |"
  say "|---|---|"
  say "| baseline | $(counts "$CERT") |"
  say "| reviewed | $(counts "$WORK/cert.json") |"
  say ""
  say "Obligations added: $(jq .added "$WORK/delta.json") · removed: $(jq .removed "$WORK/delta.json")"
  for kind in newly_refuted newly_unknown resolved gone added_list; do
    n=$(jq ".$kind | length" "$WORK/delta.json")
    [ "$n" = 0 ] && continue
    case $kind in
      newly_refuted) say ""; say "**Newly REFUTED ($n):** no OCaml encoding in the catalogue carries these without weakening." ;;
      newly_unknown) say ""; say "**Newly UNKNOWN ($n):** these depend on facts the source graph does not state." ;;
      resolved)      say ""; say "**Resolved ($n):** previously UNKNOWN or REFUTED, now PROVEN or STRENGTHENED." ;;
      gone)          say ""; say "**Gone ($n):** previously UNKNOWN or REFUTED; the Java declaration no longer raises them." ;;
      added_list)    say ""; say "**Added ($n):**" ;;
    esac
    say ""
    if [ $kind = added_list ]; then
      jq -r ".$kind[:20][] | \"- \\(.verdict) \`\\(.id)\`\"" "$WORK/delta.json" >> "$OUT"
      [ "$n" -le 20 ] || say "- ... and $((n - 20)) more"
    else
      jq -r ".$kind[] | \"- \`\\(.id)\` (\\(.owner), line \\(.line)): \\(.reason)\"" "$WORK/delta.json" >> "$OUT"
    fi
  done
  # New Java types: show the OCaml type OCaml would give them.
  for t in $(jq -r '.new_types[]' "$WORK/delta.json"); do
    snake=$(printf '%s' "$t" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g; s/\./_/g' | tr 'A-Z' 'a-z')
    say ""
    say "New type \`$t\`, as OCaml would carry it:"
    say ""
    say '```ocaml'
    awk -v n="$snake" '$1 ~ /^(type|and)$/ && $2 == n {p=1} p {print} p && /^}/ {exit}' "$WORK/types.ml" >> "$OUT"
    say '```'
  done
  [ "$(jq '.newly_refuted | length' "$WORK/delta.json")" = 0 ] || status=1
fi

# The README advertises the certified verdict counts; hold it to them.
badge_ok=1
for v in PROVEN STRENGTHENED UNKNOWN REFUTED; do
  n=$(jq "[.obligations[] | select(.verdict == \"$v\")] | length" "$CERT")
  grep -q "attempt_proof.*$n%20$(echo "$v" | tr 'A-Z' 'a-z')" README.md || badge_ok=0
done
if [ $badge_ok = 0 ]; then say ""; say "**The README badge disagrees with the committed certificate.**"; status=1; fi

say ""
if [ $status = 0 ]; then say "Verdict: **accepted.** Keycloak may proceed."; else say "Verdict: **refused.** Keycloak has some explaining to do."; fi
cat "$OUT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$OUT" >> "$GITHUB_STEP_SUMMARY"
exit $status
