### OCaml's review of Keycloak's authorization types

Reviewed: `what-if: authzen-typed-context.patch (applied to this tree's slice)` · baseline certificate: `6688a3d63f59e0c4a9131bfdd556c4312799f04e` · slice: 19 files

**Drift.** Keycloak's authorization types differ from the certified baseline. OCaml re-proved them;
the independent checker accepts the new certificate (`accepted: 758 obligations, cost (refuted 3, unknown 27, complexity 88), result refuted`).

| | verdicts |
|---|---|
| baseline | PROVEN 721 · STRENGTHENED 7 · UNKNOWN 29 · REFUTED 3 |
| reviewed | PROVEN 721 · STRENGTHENED 7 · UNKNOWN 27 · REFUTED 3 |

Obligations added: 0 · removed: 2

**Gone (2):** previously UNKNOWN or REFUTED; the Java declaration no longer raises them.

- `Dynamic:AuthZen.EvaluationRequest.context@type` (AuthZen.EvaluationRequest, line 84): Object: the Java type states no fact to preserve
- `Dynamic:AuthZen.Subject.properties@type` (AuthZen.Subject, line 68): Object: the Java type states no fact to preserve

Verdict: **accepted.** Keycloak may proceed.
