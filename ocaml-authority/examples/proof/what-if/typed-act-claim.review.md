### OCaml's review of Keycloak's authorization types

Reviewed: `what-if: typed-act-claim.patch (applied to this tree's slice)` · baseline certificate: `6688a3d63f59e0c4a9131bfdd556c4312799f04e` · slice: 19 files

**Drift.** Keycloak's authorization types differ from the certified baseline. OCaml re-proved them;
the independent checker accepts the new certificate (`accepted: 768 obligations, cost (refuted 3, unknown 29, complexity 90), result refuted`).

| | verdicts |
|---|---|
| baseline | PROVEN 721 · STRENGTHENED 7 · UNKNOWN 29 · REFUTED 3 |
| reviewed | PROVEN 728 · STRENGTHENED 8 · UNKNOWN 29 · REFUTED 3 |

Obligations added: 8 · removed: 0

**Added (8):**

- PROVEN `Represent:JsonWebToken.getAct()@return`
- STRENGTHENED `Nullability:JsonWebToken.getAct()@return`
- PROVEN `Represent:JsonWebToken.Actor.sub@type`
- PROVEN `Nullability:JsonWebToken.Actor.sub@type`
- PROVEN `Represent:JsonWebToken.Actor.clientId@type`
- PROVEN `Nullability:JsonWebToken.Actor.clientId@type`
- PROVEN `Represent:JsonWebToken.Actor.act@type`
- PROVEN `Nullability:JsonWebToken.Actor.act@type`

New type `JsonWebToken.Actor`, as OCaml would carry it:

```ocaml
type json_web_token_actor = {
  sub : string option;  (* sub JsonWebToken.java:274 | PROVEN Represent, Nullability *)
  client_id : string option;  (* clientId JsonWebToken.java:274 | PROVEN Represent, Nullability *)
  act : json_web_token_actor option;  (* act JsonWebToken.java:274 | PROVEN Represent, Nullability *)
}
```

Verdict: **accepted.** Keycloak may proceed.
