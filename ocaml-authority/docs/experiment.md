# Experiment: results against the pre-registered hypotheses

`hypothesis.md` was committed in `c7106ebe`, before any code. This document
scores every condition listed there, by identifier, using measurements
anyone can reproduce from this repository (commands in `verification.md`).
Observations that were not pre-registered are in a separate section at the
end and are labelled as such.

## Setup

| | |
|---|---|
| Keycloak | this fork at `6688a3d63f59e0c4a9131bfdd556c4312799f04e` (`999.0.0-SNAPSHOT`), built from source, run in dev mode |
| Features | `token-exchange-delegation`, `parameterized-scopes`, `admin-fine-grained-authz:v2` |
| OCaml / dune | 4.14.1 / 3.14.0, stdlib only |
| Java / Maven | OpenJDK 21.0.10 / 3.9.11; adapter compiled for release 17 |

Three decision procedures are compared on the same inputs:

- **A.** A conventional role policy with roles read from the token. This is
  Keycloak's default, `fetchRoles=false`.
- **A′.** The same role policy with `fetchRoles=true`, so roles are the live
  mappings.
- **B.** The typed-authority policy backed by the OCaml kernel.

The inputs come in three sets:

- **Fixture.** `examples/scenarios/demo.json` has 13 scenarios at a fixed
  evaluation time, `2026-09-29T12:00:00Z`. Their outputs are captured in
  `examples/scenarios/expected/` and checked by `dune test`.
- **Live.** `examples/keycloak/run-demo.sh` sends 12 requests through a real
  Keycloak using real tokens:
  - a consented login
  - an RFC 8693 delegated exchange
  - UMA decisions with pushed claims

  The output is in `examples/keycloak/demo-output/`. A, A′ and B are three
  resource servers in the same realm, so every request is decided three
  times with identical tokens and claims.
- **Adversarial.** `examples/scenarios/adversarial.json` has 43 scenarios.
  The attack tests are listed in `adversarial-review.md`.

For the comparison to be fair, the RBAC resource servers were given a role
policy for every role the kernel's ledger anchors on. The token-roles
baseline also had to be made to work at all. Keycloak imports a
consent-required client with `fullScopeAllowed = false`, so Samantha's
tokens initially carried no roles. We set it to `true` rather than let A
lose by misconfiguration.

## H1: typed authority at the IAM boundary

### S1: distinguishing power. **Supported.**

Threshold: at least two scenarios where the conventional check says ALLOW
and the kernel does not, with evidence naming the relationship.

| set | conventional ALLOW, kernel not ALLOW |
|---|---|
| fixture (`compare.md`) | 6 of 13: 04, 05, 07, 08, 10, 11 |
| live, A (token roles) | 5 of 12: 04, 05, 07, 09, 14 |
| live, A′ (live roles) | 4 of 12: 04, 05, 07, 14 |

All three predicted cases occurred, with these kernel reason codes:

- **Right capability, wrong effect** (04): `effect_within_mandate`,
  `effect_within_grant`.
- **Confused deputy** (08): the agent's own grant fails only
  `delegation_path_matches`.
- **Expired delegation** (05): `expired`.

In the fixture, 10 and 11 are INDETERMINATE:

- 10 has a principal missing from the ledger.
- 11 declares no effect.

They count toward the threshold, but they reflect the kernel refusing to
decide, not a different judgement.

### S2: evidence completeness. **Supported for ALLOW; not met to the letter for DENY.**

Every ALLOW's decision document answers all five questions and carries the
full chain to a Keycloak anchor:

- in the fixture: 01, 02 and 12 (`compare.md`, column "kernel record answers")
- in the live run: 01, 02, 12 and 15 (`demo-output/*.decision.json`)

Completeness was also tested mechanically. `authority_kernel ablate`
recomputes each verdict from the evidence alone and fails if it cannot. It
reproduced all 11 ablatable fixture verdicts. The other two were
well-formedness INDETERMINATE, decided before any check runs.

The adversarial review checked the DENY half of S2 over 131 decisions:
every candidate of a DENY must carry at least one failed check. It holds for
every DENY except those caused by a prohibition. Of the 131 decisions the
oracle checks, 10 are prohibition DENYs: 4 adversarial scenarios and 6
synthetic cases. Each lists candidates that would otherwise authorize, with
status `authorizes` and no failed check. The reason for the DENY is recorded
once, at request level, in `evidence.prohibitions`. A reader is not left
without an explanation, but the pre-registered wording is "per candidate",
and by that wording S2 fails for those 10 decisions. We did not change the
evidence format to pass it after the fact.

Well-formedness INDETERMINATE decisions answer fewer questions by
construction. Scenario 11 has no effect to report.

### S3: invalid states made unrepresentable. **Supported.**

Threshold: at least three states. Eleven snippets in
`test/authority/must-not-compile/` are type-checked against the interface
the library exports. The build requires each to be rejected with a stated
compiler error, and requires a control snippet to compile. Mutation checks
show the test is not vacuous. The rejected states:

| snippet | what cannot be written |
|---|---|
| `allow_via_interface.ml`, `allow_via_private_module.ml`, `allow_from_verified_chain.ml` | an ALLOW without an authority minted by the kernel |
| `forge_verified_chain.ml` | a verified chain not produced by `Chain.verify` |
| `grant_without_provenance.ml` | a grant with no provenance |
| `unanchored_to_verify.ml` | chain verification of an unanchored entry |
| `mandate_id_as_principal_id.ml`, `string_as_principal_id.ml` | identifier confusion |
| `allow_in_foreign_decision.ml`, `decision_from_scratch.ml`, `decision_make_without_seal.ml` | an authority minted for one request placed in a decision about another; a decision not built by the kernel |

The last three were added after the adversarial review found the gap they
close. At first `Decision.t` had public fields, so
`{ other with verdict = Allow a }` type-checked. It is now a private record,
constructible only with a seal from the library's private module.

### S4: thin adapter. **Not met.**

Threshold: at most 400 non-blank, non-comment lines, and no authorization
decision in Java.

| stage | NCLOC |
|---|---:|
| first working version | 423 |
| after simplifying `Projection` (not reformatting) | 397 |
| after the adversarial review's boundary fixes | **404** (command in `verification.md`) |

The boundary fixes that pushed it over were:

- The `act` gate, which trusts `act` only on tokens issued by the
  token-exchange flow.
- Strict reading of the kernel's decision.

Both are security glue Java has to do, because the trustworthiness of `act`
is not expressed anywhere Keycloak's types can carry it. The adapter still
makes no authorization decision: it calls `grant()` only when every scope is
`"allow"`, and fails closed otherwise. The size threshold is missed by four
lines, and we record it as missed.

### S5: Keycloak-anchored provenance. **Supported.**

In the live run (scenarios 09 and 15), Samantha's `report-author` role was
removed and then restored through the Admin API. The ledger was not
touched, and the same delegated token was reused throughout:

| step | kernel | reason |
|---|---|---|
| role removed | DENY | `anchor_missing` |
| role restored | ALLOW | — |

A (token roles) allowed both requests, because the token still carried the
role. A′ (live roles) behaved like the kernel. S5 is therefore a
property the kernel shares with a correctly configured `fetchRoles=true`
role policy. It is not a property RBAC lacks.

### W1: merely renamed RBAC. **Not triggered, by a small margin.**

`authority_kernel surface` enumerates 768 request tuples at the fixture
time:

| tuples | count |
|---|---:|
| ALLOW | 18 |
| DENY | 555 |
| INDETERMINATE | 195 |

Tuples are the ledger's principals × the observed actor chains × mandates ×
capabilities × resources × the 8 effects.

Reproducing that surface exactly with compound roles needs 18 roles, one per
allowed tuple. The ledger has 13 administered objects: 2 principals, 3
mandates and 8 grants. The pre-registered condition (compound RBAC with no
more administered objects than the ledger) is therefore not met.

We do not read much into 18 versus 13:

- 18 is an upper bound; role hierarchies could compress it.
- The count is taken at one instant. Validity windows would require
  re-administering the roles over time.
- At this scale the two are close.

The differences that do not reduce to counting are structural:

- attenuation checked link by link
- validity windows
- anchors re-read at every decision
- the delegation path matched against Keycloak's `act` chain

### W2: glue dominates. **Triggered, marginally.**

The pre-registered condition was "the adapter exceeds 400 NCLOC, or has to
reimplement authority logic in Java". It has 404 lines (see S4), so the
condition is met, though only just.

No authority logic moved into Java. The glue that grew is the part that
decides whether Keycloak's own delegation evidence can be believed. The
adapter README enumerates 47 glue sites; most resolve principals and roles.

### W3: effects need application-specific interpretation. **Not triggered.**

- **Scenario-specific effect rules:** zero. Every effect decision in the
  fixture, the live run and the adversarial set uses the generic order,
  effect kind × audience reach.
- **Caveat:** we chose the vocabulary (4 kinds, 3 audiences) to fit this
  story. W3 stays untested for effects the vocabulary cannot express, such
  as "sends money", "irreversible", or "touches personal data".

### W4: provenance is decorative. **Not triggered.**

Threshold: provenance decisive in at least 2 scenarios.
`authority_kernel ablate` ignores the provenance checks and recomputes
from evidence:

| scenario | provenance alone flips it |
|---|:-:|
| 05, expired delegation | yes |
| 06, missing provenance | yes |
| 08, confused deputy | yes |
| 09, anchor removed | yes |

That makes 4 scenarios. In 05 and 08, the `who` dimension alone would also
have flipped the decision, so those two are doubly defended.

### W5: Keycloak cannot be projected through a supported SPI. **Not triggered, with a caveat.**

Every essential input was obtained without patching Keycloak:

- the acting principal
- the delegation chain
- the resource and scope
- live role mappings

Live effective roles (composites and groups included) were not available
through the Authorization Services types themselves. The adapter reads them
through `KeycloakSession` and `UserModel`, which the `Evaluation` exposes.
The resource and scope came through the SPI types directly.

### W6: not understandable by one person. **Not triggered.**

- **`lib/authority`:** 1443 lines of `.ml` and `.mli` (`wc -l`), under the
  1500 threshold. It was 1369 before the adversarial fixes.
- **Around it:** a JSON codec (`lib/json`) of 463 lines and the CLI.

## H2: `attempt_proof`

The real slice has 19 files, 36 types and 760 obligations:

| verdict | count |
|---|---:|
| PROVEN | 721 |
| STRENGTHENED | 7 |
| UNKNOWN | 29 |
| REFUTED | 3 |

Source: `examples/proof/report.txt`.

### P1: checkable result. **Supported.**

- `prove --check` accepts the certificate. It re-derives all 760
  obligations and recomputes each verdict and the cost.
- The emitted `keycloak_authz_types.ml` compiles as part of `dune test`.

### P2: the dynamic programming is real. **Supported, with a qualification.**

- **(a)** On 250 random graphs (seed 20260929, 1–7 types) the DP cost equals
  brute force, which scored 64,242 assignments. The DP explored 1,363
  states, with 1,509 memo hits and 2,631 prunes.
- **(b)** On a constructed graph, greedy per-type choice leaves 2 REFUTED and
  the DP leaves 0. On the real slice the counts are 4 and 3.
- **(c)** The checker rejects all 2,280 single-verdict mutations.
- **(d)** Memo hits on the real slice: 27, across 36 states.

The qualification: the real slice condenses to 36 single-type components
(the 7 cycles are self-loops). Multi-type components and subtype demands are
exercised only by the random graphs. On real Keycloak code the search is
shallow.

### P3: the flashlight works. **Not supported.**

Threshold: at least 75% of the adapter's glue sites correspond to an
UNKNOWN or REFUTED obligation. The procedure is fixed in `flashlight.md` §1
before any counting. Measured on the 44 glue sites the adapter README listed
at `a62035c9`:

| class | sites | share |
|---|---:|---:|
| (a) non-PROVEN obligation | 1 | 2.3% |
| (b) all obligations PROVEN or STRENGTHENED | 19 | 43.2% |
| (c) no obligation: outside the slice | 24 | 54.5% |

P3 is 2.3%. The one class-(a) site reads `Evaluation.getAuthorizationProvider()`,
whose type is external to the slice. The search found almost nothing the
adapter actually had to work around.

### Q2: false comfort. **Not triggered on the pre-registered reading; triggered on the in-slice reading.**

Q2 is 43.2% of all glue sites, below the 50% threshold. It stays below 50%
only because more than half the glue sites lie outside the slice, where the
solver has no opinion at all. Among the 20 sites that are inside the slice,
19 (95%) are PROVEN.

The prediction written into `hypothesis.md` before implementation held
exactly. All 13 sites that carry the delegation chain, the mandate or the
effect are PROVEN:

- `act` arrives as a JSON string inside `Attributes`.
- The pushed claims arrive through `Map<String, List<String>>`, built by an
  unchecked cast.

The boundary review later added three sites (#45–#47):

- #45 and #46 read the token's `jti` from `Attributes` (PROVEN).
- #47 parses the kernel's output (outside the slice).

By our classification, not the reviewer's pinned procedure, 47 sites give
P3 = 1/47 = 2.1% and Q2 = 21/47 = 44.7%.

Sensitivity readings are in `flashlight.md` §4. P3 stays below 3% under
every reading.

### Q1: nothing learned. **Not triggered.**

- **Verdicts are mixed:** 721 / 7 / 29 / 3.
- **The REFUTED verdicts are substantive:**
  - `Set<Policy>` and `Set<Resource>` conflict with the behaviour those
    interfaces carry.
  - A generic bound reaches outside the slice.
- **The UNKNOWN verdicts mark real dynamic surfaces:**
  - AuthZEN's `context: Map<String,Object>`
  - `JsonWebToken.otherClaims`, where `act` lives

### Q3: DP is decoration. **Not triggered.**

The real slice produced 27 memo hits. As P2 notes, they come from sibling
encodings that leave the same residual demands, not from deep sharing.

## Observations not pre-registered

These surfaced while building and running the experiment. They are reported
because they bear on the research question. None of them was predicted in
`hypothesis.md`.

1. **In the demo, the mandate was never the sole deciding dimension.** The
   ablation over the fixture found no scenario where ignoring only the
   mandate checks flips the outcome. Scenario 07 is the brief's own example,
   "report generation ≠ public publication". There, the delegation path and
   the effect would have denied the request anyway: only ignoring who,
   mandate and effect together flips it.

   The adversarial reviewer then looked for realistic cases where the mandate
   decides alone. It found two:
   - a39: purpose limitation, a maintenance-read grant claimed for a
     security audit
   - a40: a mandate narrowed after grants were issued

   Both only stop a client that claims its mandate honestly, because the
   mandate is a pushed claim.
2. **RBAC on a delegated token inherits everything.** The delegated token
   carried all three of Samantha's realm roles
   (`demo-output/delegated-token-claims.json`). For role policies, the agent
   *is* Samantha. The kernel needed an explicit, attenuated delegation grant.
3. **Keycloak's declared types lie at runtime.** Pushed claims are decoded
   through an unchecked cast into `Map<String, List<String>>`. A scalar
   claim such as `{"mandate": "generate-report"}` makes Keycloak throw
   `ClassCastException` before any policy runs. The live run captures the
   response in `demo-output/scalar-claim-*`. The type graph marks the claims
   map PROVEN.
4. **Keycloak refuses pushed claims from public clients.** This is its own
   acknowledgement that pushed claims are client assertions. The same is
   true here of mandate and effect.
5. **A token carrying `may_act` is an exchange artefact.** It had no roles
   and its audience was only the actor. It could not have served as
   Samantha's general bearer token even had we wanted it to.
6. **`act` is not a reserved claim.** It is written for RFC 8693
   delegation. It is also written for admin impersonation, and by any
   protocol mapper an admin names `act`. Before the adversarial review, a
   mapper-forged `act` got an ALLOW through the live stack. The adapter now
   believes `act` only on tokens the token-exchange flow issued, recognised
   by their `jti` encoding. That is an internal convention of Keycloak, not a
   contract; see `adversarial-review.md`.

## Outcome summary

| id | condition | outcome |
|---|---|---|
| S1 | distinguishing power | supported: 6/13 fixture, 5/12 live vs token RBAC, 4/12 vs live RBAC |
| S2 | evidence completeness | ALLOW: supported (100%). DENY: not met to the letter (10 prohibition DENYs have overridden candidates with no failed check) |
| S3 | invalid states unrepresentable | supported: 11 compile-time rejections |
| S4 | adapter ≤ 400 NCLOC, no decisions | **not met**: 404 after the boundary fixes; no decisions in Java |
| S5 | Keycloak-anchored provenance | supported; shared with `fetchRoles=true` RBAC |
| W1 | renamed RBAC | not triggered: 18 compound roles vs 13 objects, a small margin |
| W2 | glue dominates | **triggered, marginally** (404 > 400) |
| W3 | application-specific effects | not triggered, for this vocabulary |
| W4 | provenance decorative | not triggered: decisive in 4 |
| W5 | no supported SPI | not triggered: roles read via `KeycloakSession` |
| W6 | kernel > 1500 lines | not triggered: 1443 |
| P1 | checkable result | supported |
| P2 | DP is real | supported; shallow on the real slice |
| P3 | flashlight ≥ 75% | **not supported**: 2.3% |
| Q1 | nothing learned | not triggered |
| Q2 | false comfort ≥ 50% | not triggered on the pre-registered reading (43.2%); 95% of in-slice glue sites are PROVEN |
| Q3 | DP decoration | not triggered: 27 memo hits |
