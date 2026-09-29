# Wire format

Deliberately boring: one JSON document in, one JSON document out, over a
child process's stdin and stdout. The same format is used by the Java adapter,
by the fixtures in `examples/`, and by the tests.

Parsing is strict (`lib/json/tjson.ml`):

- duplicate keys are rejected
- unknown fields are rejected (`efect` must not be silently ignored)
- timestamps are RFC 3339 UTC with a literal `Z`, second precision:
  `2026-09-29T12:00:00Z`
- identifiers match `[A-Za-z0-9._:@-]{1,128}`

## Request: `typed-authority/request/v1`

```json
{
  "schema": "typed-authority/request/v1",
  "request_id": "demo-02-delegated-generate",
  "query": {
    "mandate": "generate-report",
    "capability": { "resource_type": "document", "action": "generate" },
    "resource": "q3-report",
    "effect": { "kind": "produce", "audience": "organization" }
  },
  "facts": {
    "source": "keycloak",
    "realm": "typed-authority-demo",
    "evaluated_at": "2026-09-29T12:00:00Z",
    "subject": { "type": "user", "id": "samantha" },
    "actor_chain": [ { "type": "service", "id": "research-agent" } ],
    "principals": [
      { "type": "user", "id": "samantha",
        "realm_roles": ["report-author", "document-publisher"],
        "client_roles": { "document-service": [] } },
      { "type": "service", "id": "research-agent",
        "realm_roles": [],
        "client_roles": { "document-service": ["reader"] } }
    ]
  },
  "ledger": { "...": "see below" }
}
```

| field | required | notes |
|-------|----------|-------|
| `query.mandate` | no on the wire | absent → INDETERMINATE `missing_mandate` |
| `query.effect` | no on the wire | absent → INDETERMINATE `missing_effect` |
| `query.capability`, `query.resource` | yes | from Keycloak's `ResourcePermission` |
| `facts.source` | yes | `"keycloak"` (projected by the adapter) or `"fixture"` (hand-written) |
| `facts.subject` | yes | token `sub`, resolved to username or service `client_id` |
| `facts.actor_chain` | yes, may be `[]` | RFC 8693 `act` chain, current actor first |
| `facts.principals` | yes, may be `[]` | **live** role mappings the adapter resolved. Omitting a principal makes chains rooted at it unverifiable. |

Effect encodings:

```json
{ "kind": "observe" }
{ "kind": "produce",  "audience": "self" | "organization" | "public" }
{ "kind": "disclose", "audience": "self" | "organization" | "public" }
{ "kind": "administer" }
```

`observe` and `administer` must not carry an audience. `produce` and
`disclose` must carry one. Anything else is `malformed_request`.

## Ledger: `typed-authority/ledger/v1`

Stored in Keycloak as the `ledger` entry of the typed-authority policy's
configuration. Keycloak stores it but never interprets it.

```json
{
  "schema": "typed-authority/ledger/v1",
  "principals": [ { "type": "user", "id": "samantha" },
                  { "type": "service", "id": "research-agent" } ],
  "mandates": [
    { "id": "generate-report",
      "purpose": "Produce the quarterly report for internal review",
      "capabilities": [ { "resource_type": "document", "action": "read" },
                        { "resource_type": "document", "action": "generate" } ],
      "effects": [ { "kind": "observe" },
                   { "kind": "produce", "audience": "organization" } ] }
  ],
  "grants": [
    { "id": "g-samantha-generate",
      "holder": { "type": "user", "id": "samantha" },
      "capability": { "resource_type": "document", "action": "generate" },
      "target": "any",
      "mandates": ["generate-report"],
      "effects": [ { "kind": "produce", "audience": "organization" } ],
      "delegable_depth": 1,
      "provenance": { "kind": "root", "anchor": { "realm_role": "report-author" } } },
    { "id": "d-agent-generate",
      "holder": { "type": "service", "id": "research-agent" },
      "capability": { "resource_type": "document", "action": "generate" },
      "target": { "resource": "q3-report" },
      "mandates": ["generate-report"],
      "effects": [ { "kind": "produce", "audience": "organization" } ],
      "valid_until": "2026-12-31T23:59:59Z",
      "provenance": { "kind": "delegated", "parent": "g-samantha-generate",
                      "delegator": { "type": "user", "id": "samantha" } } }
  ],
  "revocations": [ { "grant": "g-old", "reason": "rotated", "at": "2026-07-01T00:00:00Z" } ],
  "prohibitions": [
    { "id": "p-agent-no-public-disclosure",
      "holder": { "type": "service", "id": "research-agent" },
      "effects": [ { "kind": "disclose", "audience": "public" } ],
      "reason": "automated agents never publish externally" }
  ]
}
```

Details:

- `target` is `"any"` or `{ "resource": "<id>" }`.
- Anchors are `{ "realm_role": "<role>" }` or
  `{ "client_role": { "client": "<client_id>", "role": "<role>" } }`.
- `valid_from`, `valid_until` and `delegable_depth` are optional.
  `delegable_depth` defaults to `0`.
- `revocations` and `prohibitions` are optional and default to `[]`.
- `provenance` absent or `null` is the one tolerated omission. The entry
  decodes as *unanchored* and can never authorize.

## Decision: `typed-authority/decision/v1`

```json
{
  "schema": "typed-authority/decision/v1",
  "request_id": "demo-02-delegated-generate",
  "decision": "allow",
  "acting": { "type": "service", "id": "research-agent" },
  "subject": { "type": "user", "id": "samantha" },
  "actor_chain": [ { "type": "service", "id": "research-agent" } ],
  "mandate": "generate-report",
  "capability": { "resource_type": "document", "action": "generate" },
  "resource": "q3-report",
  "effect": { "kind": "produce", "audience": "organization" },
  "authority": {
    "grant": "d-agent-generate",
    "chain": [
      { "grant": "g-samantha-generate", "holder": { "type": "user", "id": "samantha" },
        "provenance": { "kind": "root", "anchor": { "realm_role": "report-author" } } },
      { "grant": "d-agent-generate", "holder": { "type": "service", "id": "research-agent" },
        "provenance": { "kind": "delegated", "parent": "g-samantha-generate",
                        "delegator": { "type": "user", "id": "samantha" } } }
    ],
    "anchor": "samantha holds realm role report-author (facts.source = keycloak)"
  },
  "reasons": [],
  "evidence": {
    "request_checks": [
      { "check": "mandate_covers_capability", "outcome": "pass", "detail": "..." },
      { "check": "effect_within_mandate", "outcome": "pass", "detail": "..." }
    ],
    "prohibitions": [],
    "candidates": [
      { "grant": "d-agent-generate", "status": "authorizes",
        "checks": [ { "check": "holder_is_actor", "outcome": "pass", "detail": "..." } ] }
    ]
  }
}
```

The fields fall into three groups:

- The five questions are always answered at the top level: `acting`,
  `subject`, `actor_chain`, `mandate`, `capability`, `resource`, `effect`.
  A field is `null` only when the request did not supply it.
- `authority` is present iff `decision = "allow"`.
- `reasons` is non-empty iff `decision ≠ "allow"`. Each reason is
  `{ "code": ..., "message": ... }`. Codes come from `authority-model.md`
  and from the check names.

Each check's `outcome` is `"pass"`, `"fail"` or `"unknown"`.

The kernel CLI exits 0 whenever it wrote a decision document, including
INDETERMINATE for malformed input. A non-zero exit means the kernel itself
failed, and the adapter treats it as DENY.
