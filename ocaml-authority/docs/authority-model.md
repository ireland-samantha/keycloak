# Authority model

This document is normative: `lib/authority` implements it, and the tests in
`test/authority` check it. The wire encoding is in `wire-format.md`.

## The question the kernel answers

A conventional check answers *does P hold permission X?* The kernel answers
five questions and returns the answers as data:

| question                               | model element |
|----------------------------------------|---------------|
| Who is acting?                         | **principal**: the acting principal, plus the subject whose authority is exercised and the RFC 8693 actor chain between them |
| Under what mandate?                    | **mandate**: a named purpose that bounds which capabilities may be invoked and which effects may be caused |
| What capability are they invoking?     | **capability**: an action on a resource type, applied to one resource |
| What effect are they trying to cause?  | **effect**: the declared intended consequence, ordered by reach |
| Where did that authority originate?    | **provenance**: a chain of grants ending in a root anchored in live Keycloak state |

## Elements

### Principal

```
principal  = { kind : User | Service ; id }
```

`User` ids are Keycloak usernames. `Service` ids are the `client_id` of a
service-account client. Ids are validated: 1–128 characters from
`[A-Za-z0-9._:@-]`. Each identifier kind is a distinct OCaml type: a
principal id cannot be passed where a mandate id is expected.

A request names:

- `subject`: whose authority is being exercised (the token `sub`).
- `actor_chain`: the RFC 8693 `act` chain, current actor first. It is empty
  when the subject acts directly.
- the **acting principal**: the head of `actor_chain`, or `subject` when the
  chain is empty.

### Effect

```
audience = Self < Organization < Public          (total order: reach)
effect   = Observe
         | Produce  of audience    (create a new artifact visible to audience)
         | Disclose of audience    (make an existing resource visible to audience)
         | Administer              (change configuration or authority of the system)
```

The effect order is partial:

- `Observe ≤ Observe` and `Administer ≤ Administer`.
- `Produce a ≤ Produce b` iff `a ≤ b`, and likewise for `Disclose`.
- Effects of different kinds are incomparable.

An **effect bound** is a non-empty list of maxima. Effect `e` is within bound
`B` iff there is some `m` in `B` with `e ≤ m`.

The order is generic by design. Deciding a scenario must never need a
scenario-specific effect rule (hypothesis W3).

### Capability and target

```
capability = { resource_type ; action }        e.g. document:publish
target     = Any_resource | Resource of resource_id
```

A target `Resource r` covers only `r`. `Any_resource` covers every resource of
the grant's resource type. For delegation attenuation, `t1 ⊆ t2` iff
`t2 = Any_resource` or `t1 = t2`.

### Mandate

```
mandate = { id ; purpose : string ;
            capabilities : capability nonempty ;
            effects      : effect bound }
```

A mandate is declared once in the ledger. It is claimed per request, arriving
from Keycloak as a pushed claim. It bounds the request independently of any
grant: the requested capability must be one of `capabilities`, and the
requested effect must be within `effects`.

### Grant and provenance

```
grant = { id ; holder : principal ; capability ; target ;
          mandates : mandate_id nonempty ;       (* grant usable only under these *)
          effects  : effect bound ;              (* grant's own effect ceiling *)
          valid_from : timestamp option ; valid_until : timestamp option ;
          delegable_depth : int ;                (* 0 = cannot be delegated *)
          provenance : provenance }

provenance = Root      of anchor
           | Delegated of { parent : grant_id ; delegator : principal }

anchor = Realm_role  of role
       | Client_role of { client : client_id ; role : role }
```

A grant **always** has provenance. A ledger entry that arrives without
provenance decodes to a separate type, `unanchored`. The type checker then
stops it from reaching chain verification, and it can never support an ALLOW.
Missing provenance is therefore a state the model can talk about, but one that
cannot authorize anything.

A **root** grant's authority originates in Keycloak. Its holder must
currently hold the anchoring role according to the live role mappings
projected by the adapter. The ledger does not store the role mapping; it only
refers to it. Removing the role in Keycloak invalidates the root grant and
every grant delegated from it, with no ledger edit (hypothesis S5).

### Revocation and prohibition

```
revocation  = { grant : grant_id ; reason ; at : timestamp }
prohibition = { id ; holder : principal ; effects : effect nonempty ; reason }
```

A revoked grant is invalid, and so is every grant delegated from it. The
revocation's `at` is informational: it is reported in the evidence but not
compared with the evaluation time. A mistyped or future `at` cannot keep a
grant alive (it fails closed). Scheduled expiry is expressed with
`valid_until`, not with a revocation.

A prohibition forbids its holder from causing any effect at or above one of
its listed effects (same kind, audience at least as wide). Prohibitions are
deny-overrides. They apply when the holder is the subject or anyone in the
actor chain, so delegated authority cannot escape a restriction on the
delegator. Prohibitions carry no provenance check, because honoring an
unverified deny is always safe. For the same reason a prohibition's holder is
matched by **id** alone. A prohibition naming the right id with the wrong
kind still applies. Principal ids are unique across kinds in a well-formed
ledger. (Found by the adversarial review: matching on kind as well let a
kind-confused prohibition fail open.)

## Chain verification

Chain verification is a function from a grant to one of three results:
`verified_chain` (an abstract type only `Chain.verify` can produce),
`invalid` (a non-empty list of faults), or `unverifiable` (a non-empty list of
reasons).

The chain is resolved from the grant up to its root. For each link from
child `c` to parent `p`, all of the following must hold:

| check | fault if violated |
|-------|-------------------|
| `p` exists in the ledger | `missing_parent` |
| `p` is anchored (has provenance) | *unverifiable*: `unanchored_ancestor` |
| `c.delegator = p.holder` | `forged_delegation` |
| `p.delegable_depth ≥ 1` and `c.delegable_depth ≤ p.delegable_depth − 1` | `delegation_depth_exceeded` |
| `c.capability = p.capability` | `capability_amplified` |
| `c.target ⊆ p.target` | `target_amplified` |
| `c.mandates ⊆ p.mandates` | `mandate_amplified` |
| every effect of `c` is within `p.effects` | `effect_amplified` |
| `c`'s validity window ⊆ `p`'s | `validity_extended` |

No grant may appear twice in a chain (`cycle`). Chains are at most 16 links
(`chain_too_long`).

In addition, for every grant in the chain:

- not revoked, else `revoked`
- `valid_from ≤ now < valid_until`, else `not_yet_valid` / `expired`

For the root, the holder must hold the anchor role in `facts.principals`. The
root holder may be absent from the facts entirely. That makes the chain
*unverifiable* (`no_role_facts`), not invalid: the kernel does not know.

## Evaluation

The kernel is a pure function:

    evaluate : request -> decision

The evaluation time is part of the request (`facts.evaluated_at`). The kernel
never reads a clock.

### 1. Well-formedness → INDETERMINATE

Each of the following yields INDETERMINATE with the listed reason code:

| condition | reason code |
|-----------|-------------|
| the request does not decode | `malformed_request`, with the JSON path |
| the request is larger than 1 MiB | `request_too_large` |
| no mandate claimed | `missing_mandate` |
| no effect declared | `missing_effect` |
| subject or any actor not in `ledger.principals` | `unknown_principal` |
| a principal's kind in the facts differs from the ledger | `principal_kind_mismatch` |
| claimed mandate not declared in the ledger | `unknown_mandate` |
| duplicate grant, mandate or prohibition ids | `inconsistent_ledger` |
| the actor chain repeats a principal or contains the subject | `inconsistent_facts` |

An action with no declared effect cannot be authorized. That is the point of
the model, so it is INDETERMINATE rather than a default.

### 2. Request-level checks

These checks do not depend on any grant:

- `mandate_covers_capability`: the capability is in `mandate.capabilities`
- `effect_within_mandate`: the effect is within `mandate.effects`

### 3. Candidates

Candidates are all ledger entries, anchored or not, whose capability equals
the requested capability, held by the acting principal or by the subject.
Each candidate is assessed against every check below. Checks are not
short-circuited, so the evidence is complete.

| check | passes iff |
|-------|------------|
| `holder_is_actor` | the holder is the acting principal |
| `delegation_path_matches` | the ledger's delegation path equals Keycloak's actor chain. Chain `root(h0) → h1 → … → hn` gives path `[h0; h1; …; hn]`. Token `sub = s, act = a1{act = a2{…ak}}` gives path `[s; ak; …; a1]`. |
| `target_covers_resource` | the grant's target covers the requested resource |
| `mandate_permitted` | the claimed mandate is in `grant.mandates` |
| `effect_within_grant` | the requested effect is within `grant.effects` |
| `mandate_covers_capability`, `effect_within_mandate` | copied from step 2 |
| `provenance` | chain verification result |

`delegation_path_matches` is the confused-deputy rule. An agent's own authority
cannot be used while it acts for someone else, because its own grants have
path `[agent]` while the token says `[samantha; agent]`. Conversely,
authority delegated to the agent cannot be used without a token proving the
agent is currently acting for the delegator.

A candidate's status is one of:

- `authorizes`: all checks pass and the chain is verified.
- `refuted`: any check fails definitively, or the chain is invalid.
- `undetermined`: every check other than `provenance` passes, and the chain
  is unverifiable or the entry is unanchored.

### 4. Outcome

The outcome is the first matching rule:

1. Any well-formedness failure → **INDETERMINATE**.
2. A prohibition applies → **DENY** (`prohibited`).
3. Some candidate authorizes → **ALLOW**, carrying an `Authority.t`. The
   candidate is chosen deterministically: shortest chain first, then lowest
   grant id.
4. Some candidate is undetermined → **INDETERMINATE** (`insufficient_evidence`).
5. Otherwise → **DENY**. The reasons summarise the failed checks. With no
   candidates at all, the reason is `no_grant_for_capability`, and the
   evidence lists the capabilities the acting principal does hold.

`Authority.t` is abstract. The only function that constructs it is internal to
the library and requires a `verified_chain` plus the passing checks.
`Allow of Authority.t` therefore cannot be built anywhere else, not even by
the kernel's own CLI.

`Decision.t` is a `private` record. Its fields can be read and matched
outside the library, but it can only be constructed by `Evaluate`, through a
seal the private module issues. An authority minted for one request cannot
be placed into a decision about another. (Found by the adversarial review:
with public fields, `{ other_decision with verdict = Allow a }` type-checked.)

A DENY caused by a prohibition lists the prohibition under
`evidence.prohibitions` with outcome `fail`. The candidates it overrode keep
their own status, which may be `authorizes`. The reason for the DENY is at
request level, not per candidate.

## What the model deliberately does not do

- It does not verify that the declared effect is the effect that actually
  happens. Effect honesty is the caller's responsibility; see
  `threat-model.md`.
- It does not interpret resource contents or application semantics.
- It does not issue, sign or verify tokens. Keycloak does that; see
  `architecture.md`.
