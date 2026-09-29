# Flashlight: the pre-registered P3 / Q2 measurement

This file measures hypothesis H2's **P3** ("the flashlight works") and **Q2** ("false comfort") from
`hypothesis.md`. It was written by an adversarial reviewer. The procedure section below was written and
saved before the per-site table was built. It was not changed afterwards.

## 1. Procedure (fixed before computing)

Inputs, pinned to commit `a62035c9f5952185cac0818b7527575632e16e69` (HEAD when this review started):

- **Sites.** The "Glue sites" table of `keycloak-adapter/README.md`: 44 numbered rows. They are taken
  exactly as listed, with no sites added or removed and no row merged or split. A row that is not glue under
  the README's own P/C/O definition is kept and flagged in a note.
- **Verdicts.** `examples/proof/certificate.json` as committed (graph digest
  `md5:d208acaa0dae3ac1ef242a2d5191d28b`, file md5 `c1a2a1e99ad045806f06b688c239a3ff`). If a fix made during
  this review regenerates the certificate, the table is recomputed on the regenerated certificate and
  reported next to the first. The pre-registered reading is the one on the committed certificate.
- **Slice.** The 36 types of `examples/proof/keycloak-authz.graph.json`. A member is *in the slice* iff its
  declaring type is one of them.

Step 1: the consumed member(s) of each site.

- **R1.** If the README's "enters through" cell names Java members, those members are the consumed
  members, verbatim. Members that appear only in the "what it does" cell are not added.
- **R2.** If the cell names a value the adapter derives (for example "the `act` string", "parsed `act`",
  "pushed claim value", "decision", "kernel stdout", "option strings" or "`config.ledger` string"), that value
  is traced backwards to the Java API member that handed it to the adapter. The trace passes through the
  adapter's own code (locals, parameters, its own methods), through JDK collection access (`Map.get`,
  iteration), and through parsing or conversion the adapter performs itself (Jackson
  `readTree`/`get`/`path`/`textValue`, `String.indexOf`/`substring`, `instanceof`). The member it stops at is
  the consumed member. An I/O or environment member that originates a value (`Process.getInputStream`,
  `System.getenv`, `Config.Scope.get`) is such a member.
- **R3.** A cell that names both a member and a derived value gets both.

Step 2: the relevant obligations of an in-slice consumed member. These are the certificate entries with
`owner` = the declaring type, `member` = the member key, and `position` = the consumed value position `P`
or a position nested under it (`P/...`). `P` is `return` when the site consumes a method's result and
`type` when it consumes a field. Positionless obligations (`Query`, `Command`, `Mutable`, `Checked`,
`Bounded`) and parameter positions are not value positions a site consumes, so they are excluded.

Step 3: the class of each site.

- If at least one consumed member is in the slice:
  - **(a) NON-PROVEN** if any relevant obligation of any in-slice consumed member is UNKNOWN or REFUTED.
  - **(b) PROVEN** otherwise, meaning all relevant obligations are PROVEN or STRENGTHENED.
- If no consumed member is in the slice: **(c) NO OBLIGATION**.

A site that consumes both in-slice and outside-slice members is decided by its in-slice members.

Step 4: the numbers.

- `P3 = |a| / 44`. P3 is supported iff this is at least 75%.
- `Q2 = |b| / 44`. Q2 is triggered iff this is at least 50%.
- Secondary view, labelled as such: the same shares over in-slice sites only, `|a| / (|a|+|b|)` and
  `|b| / (|a|+|b|)`.

The per-site mapping (site, file:line, kind, consumed members, positions) is data in
`test/proof/adversarial/glue-sites.tsv`. `test/proof/adversarial/flashlight.ml` reads it together with the
committed certificate, prints the table below and checks the counts, so every number here comes from a run.
The README rows in the TSV are a verbatim copy of the README at `a62035c9`. They can be checked with
`git show a62035c9:ocaml-authority/keycloak-adapter/README.md`.

Disclosure: the README table, including its "enters through" column, was read before this procedure was
written, since it is the input. No per-site class was written down before this section was saved.

## 2. Result

Computed by `dune test --build-dir=_build-attack-proof test/proof/adversarial` (`flashlight.ml`), which fails
if the block below differs from its output.

<!-- flashlight:begin -->
### Per-site table

| # | file:line | kind | rule | consumed member(s) | relevant obligations: verdict | class |
|---|---|---|---|---|---|---|
| 1 | Projection.java:62 | O | R1 | `Evaluation.getAuthorizationProvider()` | `Nullability:Evaluation.getAuthorizationProvider()@return`: PROVEN; `Represent:Evaluation.getAuthorizationProvider()@return`: UNKNOWN | (a) NON-PROVEN |
| 2 | Projection.java:63 | O | R1 | `AuthorizationProvider.getKeycloakSession()` (outside) | none | (c) NO OBLIGATION |
| 3 | Projection.java:64 | O | R1 | `AuthorizationProvider.getRealm()` (outside) | none | (c) NO OBLIGATION |
| 4 | Projection.java:74 | O | R1 | `RealmModel.getName()` (outside) | none | (c) NO OBLIGATION |
| 5 | Projection.java:80 | K | R1 | `Policy.getConfig()` | `Keyed:Policy.getConfig()@return`: PROVEN; `Nullability:Policy.getConfig()@return`: PROVEN; `Represent:Policy.getConfig()@return`: PROVEN | (b) PROVEN |
| 6 | Projection.java:89 | K, C | R1 | `EvaluationContext.getAttributes()` | `Nullability:EvaluationContext.getAttributes()@return`: PROVEN; `Represent:EvaluationContext.getAttributes()@return`: PROVEN | (b) PROVEN |
| 7 | Projection.java:94 | K | R1 | `EvaluationContext.getAttributes()` | `Nullability:EvaluationContext.getAttributes()@return`: PROVEN; `Represent:EvaluationContext.getAttributes()@return`: PROVEN | (b) PROVEN |
| 8 | Projection.java:113 | O | R1 | `RoleUtils.getDeepUserRoleMappings(UserModel)` (outside) | none | (c) NO OBLIGATION |
| 9 | Projection.java:114 | C, O | R1 | `RoleModel.getContainer()` (outside) | none | (c) NO OBLIGATION |
| 10 | Projection.java:115 | O | R1 | `RoleModel.getName()` (outside) | none | (c) NO OBLIGATION |
| 11 | Projection.java:116 | C | R1 | `RoleModel.getContainer()` (outside) | none | (c) NO OBLIGATION |
| 12 | Projection.java:117 | O | R1 | `RoleModel.getName()` (outside) | none | (c) NO OBLIGATION |
| 13 | Projection.java:129 | O, P | R3 | `Attributes.toMap()`; `Identity.getId()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Nullability:Identity.getId()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN; `Represent:Identity.getId()@return`: PROVEN | (b) PROVEN |
| 14 | Projection.java:132 | O, P | R1 | `Identity.getId()` | `Nullability:Identity.getId()@return`: PROVEN; `Represent:Identity.getId()@return`: PROVEN | (b) PROVEN |
| 15 | Projection.java:133 | O | R1 | `UserProvider.getServiceAccount(ClientModel)` (outside) | none | (c) NO OBLIGATION |
| 16 | Projection.java:138 | O, P | R1 | `UserModel.getServiceAccountClientLink()` (outside) | none | (c) NO OBLIGATION |
| 17 | Projection.java:140 | O | R1 | `UserModel.getUsername()` (outside) | none | (c) NO OBLIGATION |
| 18 | Projection.java:142 | O | R1 | `RealmModel.getClientById(String)` (outside) | none | (c) NO OBLIGATION |
| 19 | Projection.java:146 | O | R1 | `ClientModel.getClientId()` (outside) | none | (c) NO OBLIGATION |
| 20 | Projection.java:151 | K | R1 | `Identity.getAttributes()` | `Nullability:Identity.getAttributes()@return`: PROVEN; `Represent:Identity.getAttributes()@return`: PROVEN | (b) PROVEN |
| 21 | Projection.java:155 | C | R1 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 22 | Projection.java:159 | P | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 23 | Projection.java:160 | C | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 24 | Projection.java:163 | P | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 25 | Projection.java:174 | K | R1 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 26 | Projection.java:176 | C | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 27 | Projection.java:178 | C | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 28 | Projection.java:190 | C | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 29 | Projection.java:191 | C | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 30 | Projection.java:193–195 | P | R2 | `Attributes.toMap()` | `Keyed:Attributes.toMap()@return`: PROVEN; `Nullability:Attributes.toMap()@return`: PROVEN; `Represent:Attributes.toMap()@return`: PROVEN | (b) PROVEN |
| 31 | Projection.java:204 | P | R2 | `Policy.getConfig()` | `Keyed:Policy.getConfig()@return`: PROVEN; `Nullability:Policy.getConfig()@return`: PROVEN; `Represent:Policy.getConfig()@return`: PROVEN | (b) PROVEN |
| 32 | Projection.java:205 | C | R2 | `Policy.getConfig()` | `Keyed:Policy.getConfig()@return`: PROVEN; `Nullability:Policy.getConfig()@return`: PROVEN; `Represent:Policy.getConfig()@return`: PROVEN | (b) PROVEN |
| 33 | Kernel.java:106 | P | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 34 | Kernel.java:110 | P, C | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 35 | Kernel.java:111 | P | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 36 | Kernel.java:113 | P, C | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 37 | TypedAuthorityPolicyProvider.java:40 | P | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 38 | TypedAuthorityPolicyProvider.java:42 | P | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 39 | TypedAuthorityPolicyProvider.java:46 | P | R2 | `Process.getInputStream()` (outside) | none | (c) NO OBLIGATION |
| 40 | TypedAuthorityPolicyProviderFactory.java:39 | O, P | R1 | `Config.Scope.get(String,String)` (outside); `System.getenv(String)` (outside) | none | (c) NO OBLIGATION |
| 41 | TypedAuthorityPolicyProviderFactory.java:40 | O | R1 | `Config.Scope.get(String)` (outside) | none | (c) NO OBLIGATION |
| 42 | TypedAuthorityPolicyProviderFactory.java:41 | O, P | R1 | `Config.Scope.getLong(String,Long)` (outside) | none | (c) NO OBLIGATION |
| 43 | TypedAuthorityPolicyProviderFactory.java:46 | P | R2 | `Config.Scope.get(String)` (outside); `Config.Scope.get(String,String)` (outside); `System.getenv(String)` (outside) | none | (c) NO OBLIGATION |
| 44 | TypedAuthorityPolicyProviderFactory.java:63 | O | R1 | `Policy.getConfig()` | `Keyed:Policy.getConfig()@return`: PROVEN; `Nullability:Policy.getConfig()@return`: PROVEN; `Represent:Policy.getConfig()@return`: PROVEN | (b) PROVEN |

### Counts

| class | sites | share of all 44 sites | share of the 20 in-slice sites (secondary) |
|---|---:|---:|---:|
| (a) NON-PROVEN | 1 | 2.3% | 5.0% |
| (b) PROVEN | 19 | 43.2% | 95.0% |
| (c) NO OBLIGATION | 24 | 54.5% | not applicable |
| total | 44 | 100.0% | |

- **P3** = |a| / 44 = 1 / 44 = **2.3%**. The threshold is at least 75%. Not supported.
- **Q2** = |b| / 44 = 19 / 44 = **43.2%**. The threshold is at least 50%. Not triggered.
- Secondary view, over the 20 in-slice sites only: (a) 1 / 20 = 5.0%, and (b) 19 / 20 = 95.0%. Under this view, P3 is not supported and Q2 is triggered.
<!-- flashlight:end -->

## 3. Verdict on H2 (pre-registered reading, all 44 sites)

- **P3 is not supported.** 1 of 44 glue sites (2.3%) corresponds to an UNKNOWN or REFUTED obligation. The
  threshold is 75%. The one site is #1, `Evaluation.getAuthorizationProvider()`. Its `Represent` is UNKNOWN
  because `AuthorizationProvider` is outside the slice. That marks where the adapter leaves the slice, not
  where an authorization semantic lives.
- **Q2 is not triggered.** 19 of 44 glue sites (43.2%) correspond to obligations that are all PROVEN. The
  threshold is 50%.
- **Secondary view, not the pre-registered reading.** Over the 20 sites the solver has an obligation for, 19
  (95.0%) are PROVEN. The "false comfort" failure mode holds for almost every glue site the type graph
  reaches. The all-sites Q2 number stays under 50% only because 24 of the 44 sites consume members outside
  the slice, where the solver has no obligation at all (class c).
- **The prediction made before implementation.** It said the delegation chain, the mandate and the effect
  reach the provider as strings inside a well-typed `Attributes`. The README marks 13 sites as touching them
  (#6, #7, #20–#30), and all 13 are class (b). The mechanism is confirmed without exception. What does not
  reach the threshold is the pre-registered all-sites share.

## 4. Notes on the site list

- **Not glue under the README's own P/C/O definition:** #5, #7, #20 and #25 are "K only". The README says
  a K row "by type is none of the above". They are kept, as the procedure requires.
- **Glue by definition, but not Keycloak state:** #33–#39 parse the kernel's decision, and #40–#43 read the
  provider's own SPI options. They meet the P/O definition and stay in. They cannot carry obligations, since
  neither the kernel's stdout nor `Config.Scope` is in the slice.
- **Mixed sites:** no site consumes both in-slice and outside-slice members, so that tie-break in step 3 was
  never used. #13 is the only R3 site, and both of its members are in the slice.
- **Sensitivity (not the pre-registered reading).** The table below is computed by the same program and is
  checked the same way. "R2 in-slice sites counted as (c)" is the reading in which a derived value is
  attributed to the Jackson or JDK member called on the site's own line, instead of being traced back to the
  Keycloak member it came from. Under all three readings, P3 stays below 3%.

<!-- flashlight-sensitivity:begin -->
| reading | sites | (a) | (b) | (c) | P3 = a / sites | Q2 = b / sites |
|---|---:|---:|---:|---:|---:|---:|
| pre-registered (all 44 README rows) | 44 | 1 | 19 | 24 | 2.3% | 43.2% |
| without the K-only rows | 40 | 1 | 15 | 24 | 2.5% | 37.5% |
| R2 in-slice sites counted as (c) | 44 | 1 | 9 | 34 | 2.3% | 20.5% |
<!-- flashlight-sensitivity:end -->

## 5. What the solver could not see

Each item below is a semantic that lives inside a value whose declared type the certificate calls PROVEN.
Keycloak paths are relative to the fork's root. Keycloak and adapter (`Projection.java`) line numbers are
those of `a62035c9`, and the verdicts are those of `examples/proof/certificate.json`.

1. **The act chain is a JSON string in an `Attributes` entry.**
   - `TokenExchangeDelegationProvider.java:210-215` (`services/.../protocol/oidc/tokenexchange/`) builds
     `act` as a raw `Map` through an unchecked cast of the subject token's `may_act` claim (`:210`). It chains
     the actor's previous `act` (`:211-213`) and puts the result into `getOtherClaims()` (`:215`).
   - The solver does see this source: `Dynamic:JsonWebToken.getOtherClaims()@return` is UNKNOWN.
   - `KeycloakIdentity.java:100` (`services/.../authorization/common/`) serialises the token to a JSON tree.
     `:116` and `:128` store any JSON-object claim as its JSON text, `values.add(fieldValue.toString())`. The
     second constructor does the same at `:228-229`. `:190` and `:281` wrap the map with `Attributes.from`.
   - The adapter reads it through `Identity.getAttributes()` and `Attributes.toMap()`. All of these are
     PROVEN: `Represent:Identity.getAttributes()@return`, and `Represent`, `Nullability` and
     `Keyed:Attributes.toMap()@return` (`string list String_map.t`).
   - What lives in the string: the nesting of `act`, and `sub` values that are user ids or client internal
     ids. The adapter parses it at `Projection.java:151-165`.
   - So the UNKNOWN at the source is laundered into a PROVEN position by a flattening step in a file outside
     the slice.
2. **The claims map is built by an unchecked cast.**
   - `AuthorizationTokenService.java:127` (`services/.../authorization/authorization/`) reads
     `Map<String, List<String>> claimTokenClaims = JsonSerialization.readValue(..., Map.class)`. Then `:128`
     calls `putAll`, `:136` calls `request.setClaims(claims)`, `:489` reads `request.getClaims()`, and `:495`
     calls `new DefaultEvaluationContext(identity, claims, ...)`.
   - `DefaultEvaluationContext.java:63` copies the claims into a `Map<String, Collection<String>>`, and `:91`
     wraps it with `Attributes.from`.
   - The element type is never checked. Any JSON value arrives: the README's scalar case throws at
     `ResourcePermission.java:72` through `:619` and `:738-740` of the token service, and non-string list
     elements reach the adapter.
   - All of these are PROVEN: `Represent` and `Nullability:EvaluationContext.getAttributes()@return`,
     `Keyed:Attributes.toMap()@return`, `Keyed:ResourcePermission.getClaims()@return` and
     `Unique:ResourcePermission.getClaims()@return/1`.
   - The mandate is a free string. The effect's `kind:audience` structure is split at
     `Projection.java:193-195`.
3. **Pushed claims and Keycloak's own `kc.*` attributes share one string-keyed map.**
   - `DefaultEvaluationContext.java:63` copies the pushed claims first. Then `:65-83` put these keys:
     - `kc.time.date_time`, `kc.client.network.ip_address` and `kc.client.network.host`, always.
     - `kc.client.user_agent`, only when the header is present (`:69-73`).
     - `kc.realm.name` (`:75`).
     - `kc.client.id`, only for a `KeycloakIdentity` with an access token (`:77-83`).
   - A pushed claim with one of those names survives whenever the matching `put` does not run.
   - Which value wins is decided by statement order in a body outside the slice. `Keyed:Attributes.toMap()@return`
     is PROVEN either way.
4. **`Identity.getId()` has two meanings.** `KeycloakIdentity.java:184-188` (and `:272-276`) sets it to the
   client's internal id when a resource server presents its own service-account token, and to the user id
   otherwise. `Represent:Identity.getId()@return` is PROVEN (`string`). The adapter has to try both
   interpretations, at `Projection.java:129-133`.
5. **`Policy.getConfig()` values are documents.**
   - `RepresentationToModel.java:1440` (`server-spi-private/.../models/utils/`) stores a policy's config
     verbatim.
   - Keycloak itself keeps JSON arrays in config strings and parses them with a raw `Set.class`: `resources`
     at `:1399-1403`, `scopes` at `:1413-1417` and `applyPolicies` at `:1427-1431`.
   - The adapter's ledger is a JSON document in `config.ledger`, read at `Projection.java:80` and parsed at
     `:204`.
   - `Represent` and `Keyed:Policy.getConfig()@return` are PROVEN (`string String_map.t`).
6. **In-slice role queries mean less than their names say.**
   - `Represent:Realm.getUserRealmRoles(String)@return` and
     `Represent:Realm.getUserClientRoles(String,String)@return` are PROVEN (`string list`), as are all their
     other obligations.
   - In fact, `DefaultEvaluation.java:267-280` (`server-spi-private/.../authorization/policy/evaluation/`)
     builds both lists from direct role mappings only (`getRoleMappingsStream()`: no composites, no groups).
   - The adapter therefore reads roles outside the slice (`Projection.java:113`,
     `RoleUtils.getDeepUserRoleMappings`), which is why glue sites #8–#12 are class (c).

The adversarial suite shows the same blindness in miniature, on fixtures the extractor parses and javac
compiles. `test/proof/adversarial/test_false_proven.ml` pins `known_weakness_unchecked_cast_claims_map`,
`known_weakness_string_holds_json`, `known_weakness_raw_type_heap_pollution` and three more. Each one is a
PROVEN or STRENGTHENED verdict whose runtime lie `LiesDemo` demonstrates.
