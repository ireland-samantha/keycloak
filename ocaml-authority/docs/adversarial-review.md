# Adversarial review

After the MVP worked, three reviewers attacked it in parallel, each through a
different lens:

- **authority semantics**: the kernel's decisions
- **the trust boundary**: JSON, the Java adapter, the process protocol, and
  Keycloak's own claims
- **`attempt_proof`**: its soundness, and whether its verdicts can be
  trusted

The rules were the same for all three:

1. Write the test first, and record whether the unmodified code failed.
2. Fix only what the documented design already promises.
3. Pin everything else with a test named `known_weakness_*` and list it
   here.
4. Never weaken an existing test.

| lens | findings | fixed | open | held |
|---|---:|---:|---:|---:|
| authority semantics | 20 | 3 | 5 | 12 |
| trust boundary | 20 | 7 | 5 | 8 |
| `attempt_proof` | 37 | 11 | 16 | 10 |

"Held" means the attack was tried and the design already handled it. The
tests are listed at the end. The counts are the reviewers' own. One more open
residual was found by the lead while checking the boundary fix; it is
listed under open weaknesses.

No attack produced a kernel ALLOW that the documented model forbids, **after
the fixes below**. Two attacks produced one before them:

- a kind-confused prohibition, in the kernel
- a forged `act` claim, at the boundary

Both are fixed.

---

## What broke, and was fixed

### Boundary: a protocol mapper can forge a delegation (high)

Keycloak writes the RFC 8693 `act` claim during a delegated token exchange.
Nothing reserves the claim name, though. A realm protocol mapper named `act`
puts the same shape into an ordinary login token. Two examples:

- a hardcoded-claim mapper
- a user-attribute mapper over a user-editable attribute

The adapter projected any `act` as an actor chain. Live, against this fork,
Samantha's ordinary token with a mapper-written
`act = {sub: <research-agent>, client_id: research-agent}` was answered
`{"result": true}` for the agent's delegated grant.

**Fix** (`keycloak-adapter`, `Projection.actorIds`): `act` is projected only
from tokens that the token-exchange flow itself issued. Such tokens are
recognisable by their `jti`, which encodes the transient token-exchange
session. Anything else carrying `act` fails closed, and the kernel is not
called.

**Verification:** `keycloak-adapter/verify-act-boundary.sh` replays both
cases live:

- Mapper-forged `act` is no longer a delegation.
- A genuine delegated token still is.

**Caveat:** the gate depends on how Keycloak encodes `jti` internally. That
is a projection detail with no stable contract, and it is listed in
`limitations.md`.

### Boundary: impersonation looks like delegation (medium)

The fork also writes `act` when an administrator impersonates a user:
`{sub: <admin>, preferred_username}`. Before the fix, an admin impersonating
Samantha was projected as "admin acting for Samantha under delegation".

**Fix:** the same `jti` gate. Impersonation tokens carrying `act` now fail
closed. The wire format has no way to say "impersonation", and dropping
`act` would falsify *who acts*.

### Kernel: a prohibition could fail open (medium)

Prohibitions matched their holder by kind *and* id. A prohibition written
`{type: user, id: ops-bot}` did not bind the service `ops-bot`, so the kernel
allowed an action the ledger meant to forbid.

**Fix:** holders are matched by id alone. Honoring an unverified deny is
always safe, and ids are unique across kinds in a well-formed ledger.
`authority-model.md` now states this.

### Kernel: an authority could be moved into another decision (medium)

`Decision.t` had public fields. Code outside the kernel could take the
`Authority.t` from a real ALLOW (a read) and write
`{ other_decision with verdict = Allow a }` about an `administer` request.
The codec would then print a well-formed ALLOW.

**Fix:** `Decision.t` is a `private` record. Its only constructor needs a
seal from the library's private module. Three new must-not-compile checks
cover:

- a forged decision built from scratch
- a real authority re-wrapped in a foreign decision
- a call to `make` without the seal

### JSON: duplicate-key detection was quadratic (medium)

A confidential client controls `claim_token`, which is up to 128 KiB. A
pushed claim holding an object with ~12,800 distinct keys reaches the kernel
as `query.mandate`. A 1 MiB object with 96k keys took **90 s of CPU**.

**Fix:** keys are tracked in a balanced set, O(n log n). It cannot be
hash-flooded, and the result is unchanged.

### Low-severity boundary fixes

| finding | fix |
|---|---|
| Parser error messages copied raw input bytes, so a decision about garbage input was not valid UTF-8 | non-printable bytes are rendered as `byte 0xNN` |
| The adapter accepted `"allow"` with no `authority`, or with `reasons` present | an allow must carry an `authority` object and an empty `reasons` array |
| The adapter's Jackson decoding of the kernel's output accepted a BOM, UTF-16/32 and overlong UTF-8 that `tjson` rejects | stdout is decoded strictly as UTF-8 first |
| For a request over 1 MiB, the kernel's `request_too_large` verdict was lost when stdin closed early (EPIPE) | evidence is written before the stdin write completes |

### Low-severity kernel fix

`principal_kind_mismatch` depended on the order of the ledger when one id
was registered twice. Now every ledger principal with the id is compared.

### `attempt_proof`: 11 fixes

- **A crash on legal Java.** Overloads such as
  `<T extends Policy> register(T)` / `<T extends Scope> register(T)` crashed
  `prove` with a duplicate obligation id. It now disambiguates by erasure
  only when keys collide.
- **Four places where a verdict contradicted the documented rule table.**
  - `Set<List<String>>`, `Set<String[]>` and `Set<? extends E>` were
    PROVEN unique, although the emitted type was a plain list.
  - `List<? super Integer>` was emitted as `int list`.
  - A throwing getter in a Record was emitted without
    `(_, exn) result`.
  - A setter whose type differs from its getter's had its value carried
    nowhere.
- **Emitted OCaml that did not compile.** The triggers were:
  - a generic getter in a Record
  - enum constants `_HIDDEN`, `$DOLLAR`, and `Low` next to `low`
  - non-ASCII identifiers
- **Extractor fixes:**
  - An inner class's use of an outer type parameter named like a slice
    type (`<Mode>`) resolved to the slice type.
  - `return (String) null`, `-> null` and `yield null` were not seen as
    null returns.
  - `"..."` inside a comment made a method varargs.
  - An external type sharing a slice type's simple name made the checker
    reject the prover's own certificate.
- **Certificate check:** a wrong or missing source `line` was accepted.

None of these changed the real Keycloak slice. After the fixes, its graph,
certificate, emitted `.ml` and report are byte-identical.

---

## Open weaknesses

Each item below is pinned by a test that asserts the *current, undesired*
behaviour, so a future fix has to update the test on purpose.

### Out of reach by construction

| weakness | lens | why it stays open |
|---|---|---|
| **Under-declared effect escapes a prohibition.** An agent prohibited from `disclose:public` publishes but declares `disclose:self`. The grant, mandate and prohibition all pass. | semantics | Effect honesty (threat model A1). Closing it needs a per-capability effect *floor*, a model change. |
| **Downstream effects are invisible.** "Generate the report" is allowed; the generator's real consequence is public disclosure. One request carries one effect. | semantics | A1 again. It would need declared effect sets or effect composition. |
| **The mandate is a pushed claim.** A purpose-limited grant stops a client that honestly claims the wrong purpose. It does not stop one that claims the right one. | semantics | Binding the mandate at consent or issuance is future work. |
| **Residual `act` forgery through a standard token exchange.** The `jti` gate recognises "issued by the token exchange on a transient session", not "issued by *delegation*". A standard exchange of a transient or offline session's token also issues on a transient session. An admin-configured `act` mapper on the exchanging client would therefore pass the gate. The lead found this by reading code after the review; it was not reproduced live. | boundary | The token carries no field that distinguishes delegation from a standard exchange. Reserving `act`/`may_act` against mappers is a Keycloak-side change. |
| **Nested `act` from the actor's own token.** Keycloak nests the actor token's `act` verbatim, and a mapper on the actor's own client can pre-seed it. The outer token is genuine, so the `jti` gate passes. | boundary | The actor token is not visible to the policy. It needs a Keycloak-side change. |
| **User principals are usernames.** A deleted-and-recreated or renamed user inherits the ledger's grants for that name. | boundary | Design: the wire format would need Keycloak's stable user id. |
| **`attempt_proof` trusts declared types.** An unchecked cast, a JSON document in a `String`, heap pollution through a raw type, and unchecked generic arrays all come out PROVEN. `LiesDemo` shows each lie at runtime. | proof | By construction. This is the H2 result; see `flashlight.md`. |
| **The checker accepts suboptimal certificates.** REFUTED is certified relative to the certificate's own encodings. A greedy assignment's certificate is accepted, with more REFUTED verdicts. | proof | Adding a local-optimality check is possible, but it is not in the design. |

### Accepted limitations of this prototype

| weakness | lens | note |
|---|---|---|
| A role whose name is outside the kernel's id syntax (e.g. `Report Author`) makes every request of its holder `malformed_request` | boundary | Fails closed. A proposed fix (skip and log) would change what "faithful projection" means. |
| Through AuthZEN, `act` and `jti` could come from user attributes | boundary | The UMA path is the supported one (`architecture.md`). |
| In a DENY caused by a prohibition, overridden candidates show `authorizes` with no failed check | semantics | The reason is at request level (`evidence.prohibitions`). This fails the *literal* wording of S2; see `experiment.md`. |
| Evidence order follows ledger order | semantics | Decisions are permutation-invariant (tested over 131 decisions); only document bytes change. |
| Static imports, wildcard imports, inherited member types, `@Nonnull` matched by simple name, a lambda returning null behind `@Nonnull`, two top-level types sharing a simple name | proof | Parse-only extraction (`limitations.md`). |
| Counterexample text, search statistics and the MD5 digest are not independently checked | proof | They are claims in the certificate. `test_p2` re-measures the statistics. |
| A subtype encoded as `unit` still gets `Subtype` PROVEN | proof | A design gap in the rule table. |

### The adapter's size budget

The boundary fixes (the `act` gate and strict decision reading) took the
adapter from 397 to **404** non-blank, non-comment lines. The pre-registered
budget was 400 (S4/W2). The lines were not compressed to fit.
`experiment.md` scores S4 as not met.

---

## What held

| attack | result |
|---|---|
| **Confused deputy**, every combination of whose grant × which token path × which mandate (9 cases) | decided as the model requires |
| **Stale grants:** expired parent under a live child; child starting before its parent; revoked root or middle link; anchor removed under a depth-3 chain; revocation dated in the future | refuted with exactly the expected fault |
| **Delegation chains** at depth 2 and 3: reversed, skipped or added hops; depth off-by-one; cycles | only matching paths allow |
| **Privilege escalation:** wider effects, target, mandate or validity; forged delegator; self-delegation; excess depth; parent with a different capability | each refuted with exactly one fault code |
| **Contradictory grants:** a live twin next to a revoked one; prohibitions on subject, actor or middle actor | deny-overrides everywhere |
| **Missing evidence:** perfect-but-unanchored grant, unanchored ancestor, root holder absent from facts | INDETERMINATE, never ALLOW |
| **Determinism:** the same request twice, in memory and through the CLI (file and stdin) | byte-identical over 131 decisions |
| **Malformed input:** every byte prefix; wrong JSON kind at every node; unknown field in every object; 500k-deep nesting; NUL; overlong/invalid UTF-8; surrogates; huge or negative integers; impossible timestamps; 129-char ids | `malformed_request` naming the JSON path |
| **Java/OCaml parser differentials** on the ledger: duplicate keys, trailing commas, comments, NaN, BOM | Jackson rejects each, so the kernel receives the text as a string and reports `malformed_request` |
| **Pushed-claim type confusion:** scalar, object or null where Keycloak's type says a list | Keycloak throws before any policy runs (ClassCastException / NPE) |
| **Process protocol:** partial output then hang; two documents; `ALLOW`/`Allow`/`allowed`/`true`; allow + NUL; 16 MiB of stderr | never a grant; returns at the timeout |
| **Evidence leakage:** does anything reach the UMA client? | no; the provider only calls `grant()` |
| **`attempt_proof` checker tampering:** OCaml type strings, swapped ids, reordering, digest over key order | rejected, or semantically identical |

## The mandate, revisited

On the demo set, the mandate was never the only dimension that decided a
case (`experiment.md`). The semantics reviewer built cases where it is. The
ablation over `examples/scenarios/adversarial.json` finds mandate alone
decisive in 4 scenarios, and as the *only* minimal flip in 2:

- **a39: purpose limitation.** A maintenance-read grant is claimed for a
  security audit.
- **a40: a mandate narrowed after grants were issued.**

Both are realistic. Both also depend on the client claiming its mandate
honestly, because the mandate is a pushed claim (see open weaknesses).

## Where the tests are

| lens | tests | scenarios / fixtures | live check |
|---|---|---|---|
| semantics | `test/authority/adversarial/test_adversarial.ml`: 527 tests, including property oracles over 131 decisions | `examples/scenarios/adversarial.json`: 43 scenarios, ablation in `test/authority/adversarial/expected/ablation.md` | — |
| boundary | `test/boundary/test_boundary.ml` (25 tests); `keycloak-adapter/src/test/.../BoundaryAttackTest.java` (28) and `BoundaryRoundTripTest.java` (8) | — | `keycloak-adapter/verify-act-boundary.sh` |
| `attempt_proof` | `test/proof/adversarial/`: `test_false_proven`, `test_evasions`, `test_checker`, `test_rule_table`, `flashlight` (239 checks) | Java fixtures in `test/proof/adversarial/fixtures/` | — |
| must-not-compile | `test/authority/must-not-compile/`: 11 snippets and a control | — | — |
