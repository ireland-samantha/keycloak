# Hypotheses (pre-registered)

This file was written and committed before any kernel, adapter or solver code
existed. It is not edited after implementation except to append the
"Outcome" section in `experiment.md`, which refers back here by identifier.
If a later document appears to redefine success, this file wins.

Baseline commit of the Keycloak fork: `6688a3d63f59e0c4a9131bfdd556c4312799f04e`.

There are two linked hypotheses. H1 concerns the runtime authority kernel.
H2 concerns the `attempt_proof` search that projects Keycloak's Java
authorization types into OCaml types.

---

## H1: typed authority at the IAM boundary

> A small typed authority kernel can make certain authorization relationships
> more explicit and auditable than conventional permission checks alone.

"Conventional permission check" means `hasPermission(principal, capability)`
computed from the same Keycloak state: the principal holds a role (directly,
through a group, or through a composite role) that confers the capability.

"Authority evaluation" means evaluating
`{ principal; mandate; capability; effect; provenance }` in the OCaml kernel.

### What would support H1

- **S1: distinguishing power.** In the demonstration and adversarial
  scenarios, at least two cases exist where the conventional check says
  ALLOW, the kernel says DENY or INDETERMINATE, and the kernel's evidence
  names the relationship that made the difference. Predicted cases:
  - right capability, wrong intended effect
  - confused deputy: an agent's own authority used on someone else's behalf
  - expired delegation
- **S2: evidence completeness.** Every ALLOW's evidence, read without
  re-running anything, answers all five questions: who acts, under what
  mandate, which capability, which effect, and where the authority
  originated (the full grant chain back to a Keycloak-anchored root). Every
  DENY names at least one failed check per candidate grant it considered.
  Threshold: 100% of decisions in the scenario set.
- **S3: invalid states made unrepresentable.** At least three states that a
  stringly-typed implementation could represent are rejected by the OCaml
  compiler rather than at runtime. Candidates:
  - an ALLOW that carries no verified provenance
  - a usable grant that has no provenance
  - an identifier of one kind passed where another kind is expected
- **S4: thin adapter.** The Java adapter that projects Keycloak state into
  the normalized request stays at or below **400 non-blank, non-comment
  lines** of main code, and makes no authorization decision itself beyond
  failing closed on errors.
- **S5: Keycloak-anchored provenance.** Root authority is anchored in live
  Keycloak state (role mappings), and delegation is anchored in a
  Keycloak-verified token exchange (`act` claim). Removing a role in
  Keycloak must change a kernel decision without anyone editing the kernel's
  ledger.

### What would weaken H1

- **W1: merely renamed RBAC.** A compound-role RBAC encoding reproduces
  every kernel decision in the scenario set, with no more administered
  objects than the kernel's ledger. Each compound role combines mandate,
  capability, effect and delegation into one role name. If that happens,
  the typed model adds structure to the evidence but no decision-relevant
  distinction per administered object. The comparison is part of the
  experiment and is reported either way.
- **W2: glue dominates.** The adapter exceeds 400 NCLOC, or has to
  reimplement authority logic in Java.
- **W3: effects need application-specific interpretation.** Some scenario
  can only be decided by a rule specific to that scenario or application,
  rather than by the generic effect order (effect kind × audience reach).
  Every such rule is counted and reported.
- **W4: provenance is decorative.** Provenance is the decisive reason in
  fewer than two scenarios. Decisive means that disabling the provenance
  checks would flip the decision.
- **W5: Keycloak cannot be projected through a supported SPI.** Essential
  inputs cannot be obtained from the `PolicyProvider` SPI without patching
  Keycloak core. The essential inputs are: the acting principal, the
  delegation chain, the resource, the scope, and live role mappings.
- **W6: not understandable by one person.** The kernel library
  (`lib/authority`) exceeds **1500 lines** of OCaml, excluding the JSON
  codec and tests.

---

## H2: `attempt_proof`, where OCaml types audit Java types

> A memoized proof search over a slice of Keycloak's Java authorization
> source graph can find a minimum-cost OCaml type graph whose static
> guarantees cover the obligations the Java graph induces. The obligations
> it cannot discharge point at the places where Keycloak's authorization
> semantics live outside its static type graph.

Search goal, stated as one sentence: find the minimum-complexity OCaml type
graph whose static guarantees cover the obligations extracted from the Java
source graph. The OCaml graph may be stricter than Java where the Java source
gives evidence for it. It may never be weaker.

Every obligation gets exactly one verdict:

| verdict      | meaning |
|--------------|---------|
| PROVEN       | the OCaml encoding carries exactly the fact the Java declaration states |
| STRENGTHENED | the OCaml encoding statically enforces a fact that Java leaves to runtime or convention, and the Java source contains evidence for that fact |
| UNKNOWN      | discharging it depends on facts absent from the source graph (dynamic `Object` values, raw types, implementation-defined `equals`, types outside the slice) |
| REFUTED      | no encoding in the catalogue carries the fact without weakening; a counterexample is produced |

The Java slice is Keycloak Authorization Services: the model, identity,
evaluation and provider SPI, the decision and strategy enums, the AuthZEN
records, and `JsonWebToken`. `docs/proof-search.md` lists the exact files.

### What would support H2

- **P1: checkable result.** The search terminates on the real slice. An
  independent certificate checker, which re-derives obligations and checks
  each claimed verdict without searching, accepts the certificate. The
  emitted OCaml type graph compiles.
- **P2: the dynamic programming is real.** Both of the following hold:
  - memoization hits more than zero times on the real slice
  - on randomized small graphs the DP's cost equals the brute-force optimum

  In addition, at least one constructed graph must exist on which greedy
  per-node choice yields strictly more REFUTED obligations than the DP.
- **P3: the flashlight works.** Every place where the hand-written Java
  adapter has to parse strings, cast dynamic values, or look outside the
  slice is a "glue site". At least **75%** of glue sites correspond to an
  obligation the solver marked UNKNOWN or REFUTED.

### What would weaken H2

- **Q1: nothing learned.** On the real slice, every obligation is PROVEN, or
  every obligation is UNKNOWN/REFUTED.
- **Q2: false comfort.** At least **50%** of adapter glue sites correspond to
  obligations the solver marked PROVEN. That would mean authorization
  semantics hide inside values that are structurally well-typed, such as
  strings inside `Map<String, Collection<String>>`. A type-level proof search
  cannot see such semantics by construction.
- **Q3: DP is decoration.** Memoization never hits on the real slice.

### Prediction made before implementation

We expect Q2 to be at least partly triggered. The delegation chain (`act`),
the mandate and the intended effect all reach a `PolicyProvider` as strings
inside `Attributes`, and `Attributes` is well-typed at the Java level. If
this prediction holds, it is a limitation of type-graph projection, and it
will be reported as such. It will not be patched over by adding
string-content heuristics to the solver after the fact. Any such heuristic
would be a new, separately labelled experiment.

---

## Out of scope for both hypotheses

- Performance. No latency or throughput numbers will be reported.
- Production security. The prototype makes no such claims.
- Whether authority evaluation is "better" than RBAC in general. The
  comparison reports concrete differences on concrete scenarios.
