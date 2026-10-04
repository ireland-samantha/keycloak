### OCaml's review of Keycloak's authorization types

Reviewed: `what-if: scope-gains-behaviour.patch (applied to this tree's slice)` · baseline certificate: `6688a3d63f59e0c4a9131bfdd556c4312799f04e` · slice: 19 files

**Drift.** Keycloak's authorization types differ from the certified baseline. OCaml re-proved them;
the independent checker accepts the new certificate (`accepted: 763 obligations, cost (refuted 4, unknown 29, complexity 88), result refuted`).

| | verdicts |
|---|---|
| baseline | PROVEN 721 · STRENGTHENED 7 · UNKNOWN 29 · REFUTED 3 |
| reviewed | PROVEN 723 · STRENGTHENED 7 · UNKNOWN 29 · REFUTED 4 |

Obligations added: 3 · removed: 0

**Newly REFUTED (1):** no OCaml encoding in the catalogue carries these without weakening.

- `Command:Scope.copyDisplayTo(Scope)` (Scope, line 96): a record cannot carry behaviour: Scope must be able to carry behaviour because Scope.copyDisplayTo(Scope) is behaviour, but as Closures: Policy.getScopes() : Set<Scope> needs a comparable element; Resource.updateScopes(Set) [param:scopes] : Set<Scope> needs a comparable element

**Added (3):**

- PROVEN `Represent:Scope.copyDisplayTo(Scope)@param:other`
- PROVEN `Nullability:Scope.copyDisplayTo(Scope)@param:other`
- REFUTED `Command:Scope.copyDisplayTo(Scope)`

Verdict: **refused.** Keycloak has some explaining to do.
