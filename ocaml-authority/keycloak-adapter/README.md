# Keycloak adapter: the `typed-authority` policy provider

A Keycloak Authorization Services policy provider. At each policy evaluation it projects Keycloak state
into a `typed-authority/request/v1` document (`../docs/wire-format.md`), runs the OCaml kernel
(`authority_kernel eval`) as a child process, and calls `Evaluation.grant()` only when the kernel's
decision is `"allow"`. The adapter makes no authorization decision of its own: every other outcome, and
every failure to get an answer, leaves the permission ungranted (fail closed) and is logged.

| class | role |
|---|---|
| `TypedAuthorityPolicyProviderFactory` | `PolicyProviderFactory<PolicyRepresentation>`, id `typed-authority`, group `Experimental`; reads the SPI options |
| `TypedAuthorityPolicyProvider` | `evaluate(Evaluation)`: one kernel request per scope, grant iff every scope is allowed |
| `Projection` | Keycloak state to request JSON |
| `Kernel` | child process: stdin/stdout, timeout, 4 MiB output cap, strict decision parsing, evidence files |

## Build

A standalone Maven project, not part of the Keycloak reactor. All Keycloak, Jackson and JBoss Logging
dependencies are `provided`. Their versions come from importing `keycloak-parent:${keycloak.version}`, so the
jar is compiled against exactly what that Keycloak ships. The jar contains only the adapter's classes and
`META-INF/services/org.keycloak.authorization.policy.provider.PolicyProviderFactory`.

```sh
mvn -B package                                  # against this fork: keycloak.version=999.0.0-SNAPSHOT (from ~/.m2)
mvn -B package -Dkeycloak.version=26.7.4        # against a released Keycloak from Maven Central
mvn -B test -Dtyped.authority.kernel=../_build/default/bin/authority_kernel/main.exe   # plus the real-kernel round trip
```

Output: `target/typed-authority-keycloak-adapter-0.1.0-SNAPSHOT.jar`, from the last build. Java release 17.
Classes compile into `target/classes-keycloak-${keycloak.version}`. Downloaded jars carry their server's
timestamps, so a shared class directory would not be recompiled after `keycloak.version` changes, and stale
classes would pass. The adapter uses no Keycloak API that 26.7.4 lacks. The RFC 8693 claim name `act` is
its own constant, because `IDToken.ACT` exists only in this fork.

## Configure

SPI scope `policy` / provider `typed-authority`:

| key | default | meaning |
|---|---|---|
| `kernel-path` | env `TYPED_AUTHORITY_KERNEL` | kernel executable, invoked as `<kernel-path> eval` |
| `timeout-ms` | `2000` | per request; on expiry the process is killed (`destroyForcibly`) |
| `evidence-dir` | unset | if set, every decision document is written there as `<request_id>.json` (the kernel's bytes, unmodified) |

This fork's spellings (`MicroProfileConfigProvider.MicroProfileScope` builds `kc.spi-policy--typed-authority--<key>`):

```sh
bin/kc.sh start-dev --spi-policy--typed-authority--kernel-path=/path/to/authority_kernel \
                    --spi-policy--typed-authority--evidence-dir=/var/lib/typed-authority/evidence
# environment:   KC_SPI_POLICY__TYPED_AUTHORITY__KERNEL_PATH=/path/to/authority_kernel
# keycloak.conf: spi-policy--typed-authority--timeout-ms=2000
```

Without a kernel path, the factory logs a warning at startup and every `typed-authority` policy fails closed.

## Deploy

1. Copy the jar into the distribution's `providers/` directory (`bin/kc.sh start` re-augments automatically;
   with `--optimized`, run `bin/kc.sh build` first).
2. Create a policy of type `typed-authority` on a resource server. The ledger (`typed-authority/ledger/v1`) is
   the policy's `config.ledger`, a JSON document stored as a string:

   ```json
   { "name": "typed-authority-kernel", "type": "typed-authority", "logic": "POSITIVE",
     "config": { "ledger": "{\"schema\":\"typed-authority/ledger/v1\", ...}" } }
   ```

   Realm import, `POST .../authz/resource-server/policy` and `POST .../policy/typed-authority` all keep the
   config map. For a provider typed on `PolicyRepresentation`, `RepresentationToModel.toModel` stores
   `representation.getConfig()` and then calls `onImport` (never `onCreate` or `onUpdate`). The typed read
   `GET .../policy/typed-authority/{id}` goes through the factory's `toRepresentation`, which copies the
   config.
3. Reference the policy from a permission (e.g. a resource permission with `applyPolicies`), as
   `../examples/keycloak/realm-template.json` does.

Keycloak stores the ledger but never interprets it. The adapter parses it strictly with Jackson
(`STRICT_DUPLICATE_DETECTION`, `FAIL_ON_TRAILING_TOKENS`) and embeds the tree. Text that does not parse,
including the empty string, is embedded as a JSON string, so the kernel reports `malformed_request`.

## Sending the mandate and the intended effect (UMA pushed claims)

The mandate and the effect are UMA pushed claims. The client sends an UMA grant with a `claim_token` in the
`urn:ietf:params:oauth:token-type:jwt` format: base64url of a JSON object whose values are lists of strings.

```sh
claims=$(printf '%s' '{"mandate":["generate-report"],"effect":["produce:organization"]}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d grant_type=urn:ietf:params:oauth:grant-type:uma-ticket -d audience=document-service \
  -d 'permission=q3-report#generate' -d response_mode=decision \
  -d claim_token_format=urn:ietf:params:oauth:token-type:jwt -d "claim_token=$claims" \
  "$KC/realms/$REALM/protocol/openid-connect/token"
```

- `effect` is `observe`, `administer`, `produce:<audience>` or `disclose:<audience>`. The adapter splits it at
  the first `:` into `{"kind","audience"}` without validating either part; the kernel validates.
- Exactly one value is forwarded as a scalar. Several values are forwarded as a JSON array, which the kernel
  rejects (`malformed_request`). No value (claim absent or `[]`) omits the field, and the kernel answers
  `missing_mandate` or `missing_effect`.
- Values must be lists. `AuthorizationTokenService` decodes the claim token into `Map<String, List<String>>`
  through an unchecked cast. A scalar such as `{"mandate":"generate-report"}` makes Keycloak itself throw
  `ClassCastException` at `ResourcePermission.<init>` (ResourcePermission.java:72, via
  `AuthorizationTokenService.addPermission`), and the token endpoint answers `server_error` before any policy
  runs. Non-string list elements (`[7]`, `[null]`, `[{...}]`) do reach the adapter and are forwarded as JSON.
- Public clients cannot push claims without a ticket (HTTP 403 from `AuthorizationTokenService`).

## What is projected

| request field | Keycloak source |
|---|---|
| `request_id` | random UUID |
| `query.capability` | `{resource_type: Resource.getType(), action: Scope.getName()}`, one request per scope of `evaluation.getPermission()` |
| `query.resource` | `Resource.getName()` (a permission with no resource projects `null`, and the kernel rejects it) |
| `query.mandate`, `query.effect` | context attributes `mandate`, `effect` (the UMA pushed claims) |
| `facts.source`, `facts.realm` | `"keycloak"`, `AuthorizationProvider.getRealm().getName()` |
| `facts.evaluated_at` | UTC now, whole seconds, `Z` (injected `java.time.Clock`) |
| `facts.subject` | `Identity.getId()` resolved to a user: `{"service", clientId}` for a service account, else `{"user", username}` |
| `facts.actor_chain` | identity attribute `act`: the RFC 8693 chain `{"sub", "act": {...}}`, current actor first, each `sub` resolved like the subject; only on a token the delegation exchange issued (identity attribute `jti` = `tr` + `rt`/`lt` + `te:`...; see below) |
| `facts.principals` | for the subject and each actor: **live** effective roles from `RoleUtils.getDeepUserRoleMappings` (direct, composite and group-inherited, including parent groups), split into `realm_roles` and `client_roles` by role container |
| `ledger` | policy config `ledger` |

Roles come from the live user model, not from the token. A delegated token's `realm_access` carries every
role of the subject, while `facts.principals` lists what each principal holds now; removing a role in
Keycloak changes the next decision (hypothesis S5).

The SPI's own `Evaluation.getRealm()` (`policy.evaluation.Realm`) returns direct role mappings only, with no
composites and no groups, so the adapter resolves effective roles through `KeycloakSession`/`UserModel`
(`RoleUtils.getDeepUserRoleMappings`) instead.

## Failing closed

No grant, with a log line saying why, when: the permission has no scope (there is no action to ask about);
the subject or an actor does not resolve to a user or service account; the `act` attribute is not one JSON
text holding a chain of objects with string `sub`; the identity carries `act` but its `jti` is not that of a
token-exchange token on a transient session (see "Where `act` comes from"); no kernel is configured; the kernel cannot be started;
no decision arrives within `timeout-ms`; stdout exceeds 4 MiB; the exit status is non-zero (even with an
allow document on stdout); stdout is not one strict JSON document in strict UTF-8 (duplicate keys, trailing
content, a byte order mark, UTF-16/32 and overlong or surrogate UTF-8 forms are errors); an `"allow"` document
has no `authority` object or a `reasons` member other than `[]` (wire-format.md: authority iff allow, reasons iff
not); the document's `schema` is not `typed-authority/decision/v1`, or its `request_id` is not the one
sent (JSON `null` is accepted on a non-allow decision: that is how the kernel answers a request it could not
decode, e.g. `malformed_request` for a multi-valued mandate, and the verdict is then kept as evidence);
writing the evidence file fails; the decision is anything but `"allow"` for any scope; any other
exception. stderr is drained continuously, and its first 2 KiB are logged when the exit status is non-zero.

A `PolicyProvider` can only grant the whole `ResourcePermission`; there is no per-scope grant from inside a
policy. Hence the rule: every scope must be allowed.

The evidence file is written as soon as a strict decision document for this request arrives, before the adapter
checks that the kernel consumed the whole request: a kernel that answers `request_too_large` stops reading, the
rest of the write fails with a broken pipe (no grant), and its verdict is still on file.

### Where `act` comes from

`act` is an ordinary token claim. In this fork three things write it: `TokenExchangeDelegationProvider` (RFC 8693
delegation: a copy of the subject token's `may_act`, with the actor token's own `act` nested), admin impersonation
(`TokenManager.setActClaimFromImpersonator`: `{sub: impersonator id, preferred_username}`), and any protocol mapper
whose claim name is `act` (it is not among `OIDCAttributeMapperHelper`'s non-modifiable claims; `KeycloakIdentity`
flattens an object, a JSON string and a one-element array to the same attribute). The delegation exchange always
issues on a new transient user session through the token-exchange grant, and `DefaultTokenContextEncoderProvider`
encodes both in the token id (`jti` = session type `tr`, token type `rt` or `lt`, grant type `te`, `:`, raw id),
which mappers cannot set. The adapter projects `act` only on such a token; `./verify-act-boundary.sh` shows a
mapper-made `act` on a login token and an impersonation token refused, and a genuine delegated token allowed.

Not covered (see `BoundaryAttackTest`, `known_weakness_*`): the exchange nests the actor token's `act` verbatim,
so a mapper on the actor's own client can forge the inner links of a genuine delegated token; and AuthZEN
identities are user attributes plus PEP-supplied `subject.properties`, which can carry both `act` and `jti`.

Each decision is logged at INFO:
`typed-authority policy 'typed-authority-kernel' request <uuid>: document:read on q3-report -> deny [no_grant_for_capability]`.

## Tests

`mvn -B test`: JUnit 5, with fakes built from `java.lang.reflect.Proxy` (`Fakes`, `DemoRealm`). An
unstubbed non-default method throws, so the fakes also document which Keycloak state the adapter reads.

- `ProjectionTest`: direct identity; delegated identity with a two-deep `act` chain (also in the exact shape
  `TokenExchangeDelegationProvider` writes); service-account resolution, including the resource-server case
  where `Identity.getId()` is the client id; missing, multi-valued, non-string and null pushed claims; effect
  splitting; ledger that parses, has duplicate keys, is truncated, has trailing content, is empty, or is absent.
- `FailClosedTest`: shell scripts in `target/kernel-stubs` stand in for the kernel. Allow grants; deny,
  indeterminate, timeout, non-zero exit, garbage, empty, oversize (a valid allow padded past 4 MiB), wrong
  `request_id`, allow with `request_id` null, missing schema, duplicate `decision` key, trailing content, missing
  executable, projection failure, and a partial multi-scope allow do not; 1 MiB of stderr is drained; evidence
  files hold the kernel's bytes, including a `malformed_request` verdict with `request_id` null.
- `FactoryTest`: id, group, service registration, typed representation carries the config, SPI keys
  `kernel-path`, `timeout-ms` and `evidence-dir` take effect.
- `BoundaryAttackTest` (adversarial review of the trust boundary): where `act` comes from (genuine delegated
  token, mapper-made `act` on login/client-credentials/refresh tokens, impersonation, nested `act` from the actor
  token, `act`/`jti` as user attributes); the shapes pushed claims can have when they reach a policy and those
  Keycloak rejects first (`ResourcePermission`); the process protocol (partial output then hang, two documents,
  allow without `authority` or with `reasons`, other spellings, nested duplicate keys, 16 MiB of stderr, BOM,
  UTF-16/32 and overlong UTF-8, a grandchild holding stdout); nothing but `grant()` reaches the evaluation; what
  Jackson makes of ambiguous ledger text (`test/boundary` feeds the same inputs to the kernel).
- `BoundaryRoundTripTest`: the same inputs through the real kernel: ambiguous and re-spelled ledgers, pushed-claim
  type confusion, a claim-sized object with 12.8k keys (decided within 1 s), an oversize request, a role name
  outside the identifier syntax. Skipped unless `-Dtyped.authority.kernel` names an executable.
- `KernelRoundTripTest`: the real kernel on scenario-01-like (agent's own token reads q3-report: allow
  through `g-agent-read`) and scenario-05-like (delegated token, expired delegation: deny) states, plus S5
  (the same delegated request, allowed and then denied after samantha loses the group that carries
  `report-author`). Scenarios 01 and 05 run against `src/test/resources/roundtrip-ledger.json` and, when
  present, against the committed `../examples/scenarios/demo.json` ledger; S5 runs against the former. Skipped
  unless `-Dtyped.authority.kernel` names an executable.

`./verify-live.sh` starts a private Keycloak from this fork's distribution (port 18080, under `target/live`)
with a recording stand-in kernel. It checks the SPI option spelling, config persistence through realm import,
create, update, read and export, and the requests projected for a client-credentials token and a
token-exchange delegated token, and it probes non-list pushed claims. With `REAL_KERNEL=<authority_kernel>`
the stand-in passes each request on to the real kernel, so the whole chain runs: the agent's own read is
allowed (`g-agent-read`), and the delegated read is denied (`expired`).

`REAL_KERNEL=<authority_kernel> ./verify-act-boundary.sh` (port 18380, under `target/live-boundary`; `ADAPTER_JAR`
selects another build) runs five tokens through a live Keycloak and the real kernel: a genuine delegated token,
samantha's login token carrying `act` from a hardcoded-claim mapper (JSON and String types), an impersonation
token, and a delegated token whose actor token carried a mapper-made `act`.

## Size (hypothesis S4)

Non-blank, non-comment lines of main Java, with `package` and `import` lines counted as code (397 when this
README was written; 404 after the boundary review added the `act` provenance check (+4) and the strict decision
reading (+3); budget 400):

```sh
awk 'FNR==1{inb=0} { l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l) } inb { if (l ~ /\*\//) { inb=0; sub(/.*\*\//,"",l); gsub(/^[ \t]+/,"",l) } else next } l ~ /^\/\*/ { if (l !~ /\*\//) inb=1; next } l=="" || l ~ /^\/\// { next } { t++ } END { print t }' $(find src/main/java -name '*.java')
```

## Glue sites

Input to hypotheses P3 and Q2. A glue site is a line of main code that does at least one of:

- **P**: parses or interprets a string.
- **C**: casts or tests the runtime type of a value whose static type does not state it.
- **O**: reads Keycloak state, or a Keycloak type, outside the slice listed in `../docs/proof-search.md`.

**K** marks a string-keyed read from an in-slice map (`Attributes.toMap()`, `Policy.getConfig()`). By
type it is none of the above, but the value is parsed or cast on the next glue line. K rows are listed so
they can be counted either way.

"Enters through" names the Java member by which the value reaches the adapter.

| # | file:line | kind | enters through | what it does |
|---|---|---|---|---|
| 1 | Projection.java:62 | O | `Evaluation.getAuthorizationProvider()` | obtains `AuthorizationProvider` (server-spi-private, outside the slice), the adapter's only route to the session and the realm |
| 2 | Projection.java:63 | O | `AuthorizationProvider.getKeycloakSession()` | `KeycloakSession`, for user lookups |
| 3 | Projection.java:64 | O | `AuthorizationProvider.getRealm()` | `RealmModel`, for client lookups and `facts.realm` |
| 4 | Projection.java:74 | O | `RealmModel.getName()` | `facts.realm` |
| 5 | Projection.java:80 | K | `Policy.getConfig()` (`Map<String,String>`) | reads key `"ledger"`; the value is JSON text, parsed at #31 |
| 6 | Projection.java:89 | K, C | `EvaluationContext.getAttributes()` | selects pushed claim `"mandate"`; encoder `JSON::valueToTree` converts an element of unknown runtime class to JSON |
| 7 | Projection.java:94 | K | `EvaluationContext.getAttributes()` | selects pushed claim `"effect"`; encoder at #28–#30 |
| 8 | Projection.java:113 | O | `RoleUtils.getDeepUserRoleMappings(UserModel)` | live effective roles: the user's role mappings, group and parent-group mappings, composite expansion |
| 9 | Projection.java:114 | C, O | `RoleModel.getContainer()` | `instanceof ClientModel` decides client role vs realm role; `ClientModel.getClientId()` names the client |
| 10 | Projection.java:115 | O | `RoleModel.getName()` | client role name |
| 11 | Projection.java:116 | C | `RoleModel.getContainer()` | `instanceof RealmModel` |
| 12 | Projection.java:117 | O | `RoleModel.getName()` | realm role name |
| 13 | Projection.java:129 | O, P | `Identity.getId()` (String), act `sub` (#24) | `UserProvider.getUserById(realm, id)`: interprets the string as a user id |
| 14 | Projection.java:132 | O, P | `Identity.getId()` | `RealmModel.getClientById(id)`: re-interprets the same string as a client's internal id (`KeycloakIdentity.getId()` returns it when a resource server presents its own service-account token) |
| 15 | Projection.java:133 | O | `UserProvider.getServiceAccount(ClientModel)` | that client's service-account user |
| 16 | Projection.java:138 | O, P | `UserModel.getServiceAccountClientLink()` | null or not decides principal kind `user` vs `service`; the value is a client internal id |
| 17 | Projection.java:140 | O | `UserModel.getUsername()` | user principal id |
| 18 | Projection.java:142 | O | `RealmModel.getClientById(link)` | the service account's client |
| 19 | Projection.java:146 | O | `ClientModel.getClientId()` | service principal id |
| 20 | Projection.java:157 | K | `Identity.getAttributes()` | reads identity attribute `"act"` (the adapter's own constant: `IDToken.ACT` exists in this fork but not in Keycloak 26.7.4) |
| 21 | Projection.java:161 | C | `Attributes.toMap()` value (`Collection<String>`) | `instanceof Collection<?>`, `size() == 1`, element `instanceof String`: does not trust the declared type |
| 22 | Projection.java:165 | P | the `act` string | `JSON.readTree`: parses the RFC 8693 `act` claim, which `KeycloakIdentity` serialised from a JSON object into one string; follows nested `act` |
| 23 | Projection.java:166 | C | parsed `act` | `isObject()`, `path("sub").isTextual()`: runtime JSON shape checks |
| 24 | Projection.java:169 | P | parsed `act` | extracts `sub`, a user id interpreted at #13 |
| 25 | Projection.java:184 | K | `Attributes.toMap()` | reads the pushed claim by name; values arrive through `AuthorizationTokenService`'s unchecked cast to `Map<String, List<String>>` |
| 26 | Projection.java:186 | C | pushed claim value | `instanceof Collection<?>`: list, scalar (#27) or absent |
| 27 | Projection.java:188 | C | pushed claim value | a non-null non-collection is taken as one value (not reachable through the UMA token endpoint in this fork, see "Sending ...") |
| 28 | Projection.java:200 | C | pushed `effect` element | `instanceof String` |
| 29 | Projection.java:201 | C | pushed `effect` element | `JSON.valueToTree(value)` for a non-string element (runtime-class dispatch) |
| 30 | Projection.java:203–205 | P | pushed `effect` string | splits `kind:audience` at the first `:` |
| 31 | Projection.java:214 | P | `config.ledger` string | strict `JSON.readTree` of the ledger |
| 32 | Projection.java:215 | C | parsed ledger | `isMissingNode()`: empty or blank text is embedded as a string |
| 33 | Kernel.java:108 | P | kernel stdout | strict UTF-8 decoding, then strict `JSON.readTree` of the decision |
| 34 | Kernel.java:113 | P, C | decision | `schema` must equal `typed-authority/decision/v1`; `decision` must be a string |
| 35 | Kernel.java:114 | P | decision | `request_id` must equal the one sent ... |
| 36 | Kernel.java:116 | P, C | decision | ... or be JSON `null` on a decision other than `"allow"` (the kernel's answer to a request it could not decode) |
| 37 | TypedAuthorityPolicyProvider.java:40 | P | decision | reads the `decision` string |
| 38 | TypedAuthorityPolicyProvider.java:42 | P | decision | reads `reasons[].code` (log only) |
| 39 | TypedAuthorityPolicyProvider.java:46 | P | decision | `"allow".equals(verdict)`: the only string that can lead to `Evaluation.grant()` |
| 40 | TypedAuthorityPolicyProviderFactory.java:39 | O, P | `Config.Scope.get("kernel-path")`, `System.getenv` | kernel path option or env `TYPED_AUTHORITY_KERNEL` |
| 41 | TypedAuthorityPolicyProviderFactory.java:40 | O | `Config.Scope.get("evidence-dir")` | evidence directory option |
| 42 | TypedAuthorityPolicyProviderFactory.java:41 | O, P | `Config.Scope.getLong("timeout-ms")` | option string to `long` |
| 43 | TypedAuthorityPolicyProviderFactory.java:46 | P | option strings | `Path.of(kernel)`, `Path.of(evidence)` |
| 44 | TypedAuthorityPolicyProviderFactory.java:63 | O | `Policy.getConfig()` | copied into `PolicyRepresentation` (outside the slice) for the typed admin read |
| 45 | Projection.java:171 | K | `Identity.getAttributes()` | reads identity attribute `"jti"` (only when `act` is present); added by the boundary review |
| 46 | Projection.java:172 | P, O | the `jti` string | `matches("tr(rt\|lt)te:.+")`: interprets `DefaultTokenContextEncoderProvider`'s token-id encoding (session type, token type, grant type), a convention of `services`, outside the slice, to tell the delegation exchange's `act` from a mapper's or an impersonation's |
| 47 | Kernel.java:112, 118 | P, C | decision | an `"allow"` must carry an `authority` object and a `reasons` array that is empty (wire-format.md) |

Row counts: 47 rows (44 before the boundary review added #45–#47). A row can carry several kinds, so the kind
counts sum to more than 47. Rows carrying P: 19; C: 13; O: 20; K: 6; K only: 5 (#5, #7, #20, #25, #45). Rows that
touch the delegation chain, mandate or effect (the H2 prediction): #6, #7, #20–#30, #45, #46.

Not glue sites (in-slice reads copied verbatim): TypedAuthorityPolicyProvider.java:30 `Policy.getName()`, :33
`ResourcePermission.getScopes()`, :49 `Evaluation.grant()`; Projection.java:65 `EvaluationContext.getIdentity()`,
:67 `Identity.getId()` (interpreted at #13/#14), :68 `Identity.getAttributes()`, :80 `Evaluation.getPolicy()`,
:81 `ResourcePermission.getResource()`, :82 `EvaluationContext.getAttributes()`, :84 `ResourcePermission.getScopes()`,
:91 `Resource.getType()`, :92 `Scope.getName()`, :93 `Resource.getName()`. The adapter's own JSON
(Kernel.java:59, TypedAuthorityPolicyProvider.java:44–45) and the process boundary (Kernel.java:61–92) are
not Keycloak state.

Outside-slice types that appear only in signatures the SPI requires, with no state read:
`ProviderFactory.init(Config.Scope)` (Factory:38), `create(AuthorizationProvider)` (:51),
`create(KeycloakSession)` (:56), `toRepresentation(Policy, AuthorizationProvider)` returning
`PolicyRepresentation` (:61), `getRepresentationType()` (:68), `postInit(KeycloakSessionFactory)` (:88).
