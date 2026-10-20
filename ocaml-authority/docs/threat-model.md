# Threat model

Scope: the prototype as built in this repository. It makes no production
security claim. The purpose here is to be explicit about what the kernel
defends, what it trusts, and what it cannot see. The concrete attacks tried
against it are in `adversarial-review.md`.

## Assets

- **The decision.** An ALLOW must only be produced when an anchored,
  unexpired, unrevoked, non-amplified chain of grants authorizes this acting
  principal, under this mandate, to invoke this capability for this effect.
- **The evidence.** It must be complete and faithful. An auditor reading a
  decision document must not be misled about why it was made.

## Parties

| party | trusted for | not trusted for |
|---|---|---|
| Keycloak | Authentication, token integrity and expiry, delegation consent and `act` chains, the resource and scope registry, live role mappings, storing the ledger unmodified | Nothing it doesn't state; it has no notion of mandate or effect |
| Realm administrator | Role mappings and the ledger contents (they can write both) | — a malicious admin is out of scope |
| Java adapter | Faithful projection of Keycloak state into the request | Deciding anything (it only fails closed) |
| OCaml kernel | The decision function | Knowing what really happens after an ALLOW |
| Requesting client (PEP / agent) | Declaring its mandate and intended effect **honestly** | Everything else. It controls pushed claims, request timing and resource choice. |
| Resource owner (Samantha) | Consenting to delegation in Keycloak | — |

## Assumptions (if any fails, the kernel's guarantees fail)

- **A1: effect honesty.** The declared effect is the effect the action will
  have. The kernel checks the declaration. It cannot check reality. An agent
  that declares `produce:organization` and then emails the report to the
  world has lied outside the kernel's view. `adversarial-review.md` has a
  test that documents this gap.
- **A2: faithful projection.** The adapter reports the actor chain Keycloak
  verified and the role mappings Keycloak holds right now. A bug here is
  invisible to the kernel.
- **A3: ledger integrity.** Keycloak stores the ledger unmodified, and only
  administrators can edit it.
- **A4: time.** `facts.evaluated_at` is the adapter's clock. The kernel
  cannot detect a wrong clock.

## Threats the design addresses

| threat | mechanism | where |
|---|---|---|
| Confused deputy: an agent uses its own authority while acting for someone else | `delegation_path_matches` requires the ledger path to equal Keycloak's verified `act` chain | `authority-model.md` §3 |
| Exercising delegated authority without an active delegation | Same check in the other direction: a delegated grant needs a token proving the agent is acting for the delegator now | same |
| Privilege amplification through delegation | Attenuation checks on every link: capability, target, mandate, effect, validity, depth | chain verification |
| Forged delegation (the agent delegates to itself from someone else's grant) | `forged_delegation`: the delegator must be the parent's holder | chain verification |
| Stale grants (role removed, delegation expired, grant revoked) | Roots are anchored in **live** role mappings, not token claims. Expiry and revocation are checked on every link. | S5; demo scenario 09 |
| Right capability, wrong purpose or effect | The mandate bounds capabilities and effects independently of grants. The grant bounds effects too. | `effect_within_mandate`, `effect_within_grant` |
| Undeclared intent | Missing mandate or effect → INDETERMINATE, never a default | well-formedness |
| Parser differential between Java and OCaml | The adapter parses the ledger with Jackson in strict duplicate-detection mode and re-serialises it, so for the ledger Jackson's strictness is what counts. `tjson` rejects duplicate keys, unknown fields, invalid UTF-8 and excessive nesting in the request as a whole. The adapter reads the kernel's output as strict UTF-8. | `wire-format.md`, `adversarial-review.md` |
| Forged or overloaded `act`: a protocol mapper named `act`, or admin impersonation | The adapter projects `act` only from tokens issued by the token exchange (recognised by `jti`); anything else carrying `act` fails closed | `adversarial-review.md` |
| Hash-flooding or quadratic parsing through client-controlled pushed claims | Duplicate-key detection is O(n log n) with a balanced set; there is a 1 MiB request cap | `adversarial-review.md` |
| Kernel failure used to get access | Every non-allow outcome, including crash or timeout, results in no grant | adapter |
| ALLOW minted without evidence | `Authority.t` is abstract, and its constructor is private to the library; `Allow` without a verified chain does not type-check | S3; `test/authority/must-not-compile` |

## Threats out of reach by construction

- **Downstream effects.** An authorized operation can trigger further effects
  (A1). Unless those are separately requested and decided, the kernel never
  sees them.
- **Semantics hidden in strings.** Mandate names and effect kinds are
  compared structurally. Nothing checks that "generate-report" means the same
  thing to the agent as to the ledger author.
- **Collusion between principals** who each hold part of a capability.
- **Denial of service** by a large or slow ledger. There is a size cap and
  a timeout, but no fairness or quota.
- **Side channels.** Evidence is detailed. Returning it to an untrusted
  caller would reveal the ledger's structure. The adapter writes evidence to
  the server log and an evidence directory, not to the client.
