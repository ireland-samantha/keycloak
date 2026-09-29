# Ablation: adversarial.json

Each column recomputes the outcome from the decision's own evidence with one dimension's checks ignored
(who: holder_is_actor, delegation_path_matches; mandate: mandate_permitted, mandate_covers_capability;
effect: effect_within_grant, effect_within_mandate, prohibitions; target: target_covers_resource;
provenance: chain verification). `allow` in a column means that dimension alone decided against the request.
Well-formedness INDETERMINATE decisions are decided before any check and are not ablated.

| scenario | decision | w/o who | w/o mandate | w/o effect | w/o target | w/o provenance | minimal sets that flip it |
|---|---|---|---|---|---|---|---|
| a01-cd-own-authority-own-purpose | allow | allow | allow | allow | allow | allow | (allowed) |
| a02-cd-own-token-samanthas-purpose | deny | allow | allow | - | - | - | {mandate}; {who} |
| a03-cd-for-samantha-her-purpose | allow | allow | allow | allow | allow | allow | (allowed) |
| a04-cd-for-samantha-agents-purpose | deny | allow | allow | - | - | - | {mandate}; {who} |
| a05-cd-pure-deputy | deny | allow | - | - | - | - | {who} |
| a06-cd-for-bob | allow | allow | allow | allow | allow | allow | (allowed) |
| a07-cd-no-cross-subject-substitution | deny | allow | - | - | allow | allow | {provenance}; {target}; {who} |
| a08-stale-expired-parent-live-child | deny | - | - | - | - | allow | {provenance} |
| a09-stale-child-starts-before-parent | deny | allow | - | - | - | allow | {provenance}; {who} |
| a10-stale-revoked-root-live-delegation | deny | - | - | - | - | allow | {provenance}; {who, target}; {who, mandate, effect} |
| a11-stale-revoked-middle-link | deny | allow | - | - | - | allow | {provenance}; {who} |
| a12-stale-anchor-removed-depth3 | deny | - | - | - | - | allow | {provenance}; {who, mandate} |
| a13-stale-future-dated-revocation | deny | allow | - | - | - | allow | {provenance}; {who} |
| a14-stale-exactly-valid-from | allow | allow | allow | allow | allow | allow | (allowed) |
| a15-stale-one-second-before-valid-from | deny | allow | - | - | - | allow | {provenance}; {who} |
| a16-stale-one-second-before-valid-until | allow | allow | allow | allow | allow | allow | (allowed) |
| a17-stale-exactly-valid-until | deny | allow | - | - | - | allow | {provenance}; {who} |
| a18-chain-depth2-matches | allow | allow | allow | allow | allow | allow | (allowed) |
| a19-chain-depth3-matches | allow | allow | allow | allow | allow | allow | (allowed) |
| a20-chain-reversed | deny | allow | - | - | - | - | {who} |
| a21-chain-skips-a-hop | deny | allow | - | - | - | - | {who} |
| a22-chain-depth-exceeded | deny | allow | - | - | - | allow | {provenance}; {who} |
| a23-chain-cycle | deny | - | - | - | - | - | {who, provenance} |
| a24-chain-unregistered-middle-named | indeterminate | - | - | - | - | - | (well-formedness) |
| a25-chain-unregistered-middle-omitted | deny | allow | - | - | - | - | {who} |
| a26-contra-live-and-revoked-twin | allow | allow | allow | allow | allow | allow | (allowed) |
| a27-contra-prohibition-beats-grant | deny | - | - | allow | - | - | {effect} |
| a28-contra-subject-prohibition-binds-actor | deny | - | - | allow | - | - | {effect} |
| a29-contra-org-prohibition-covers-public | deny | - | - | allow | - | - | {effect} |
| a30-contra-org-prohibition-leaves-self | allow | allow | allow | allow | allow | allow | (allowed) |
| a31-contra-prohibition-kind-confusion | deny | - | - | allow | - | - | {effect} |
| a32-esc-amplifying-children | deny | allow | - | - | - | allow | {provenance}; {who} |
| a33-esc-anchor-held-by-someone-else | deny | - | - | - | - | allow | {provenance} |
| a34-esc-under-unanchored-all-powerful-parent | indeterminate | - | - | - | - | allow | {provenance} |
| a35-up-unknown-actor | indeterminate | - | - | - | - | - | (well-formedness) |
| a36-up-service-id-as-user | indeterminate | - | - | - | - | - | (well-formedness) |
| a37-me-perfect-grant-without-provenance | indeterminate | - | - | - | - | allow | {provenance} |
| a38-me-root-holder-absent-from-facts | indeterminate | allow | - | - | - | allow | {provenance}; {who} |
| a39-mandate-purpose-limited | deny | - | allow | - | - | - | {mandate} |
| a40-mandate-narrowed | deny | - | allow | - | - | - | {mandate} |
| a41-mandate-effect-not-covered | deny | - | - | allow | - | - | {effect} |
| a42-known_weakness-downstream-effect | allow | allow | allow | allow | allow | allow | (allowed) |
| a43-known_weakness-underdeclared-effect | allow | allow | allow | allow | allow | allow | (allowed) |

- scenarios: 43; ablated: 40 (the rest are well-formedness INDETERMINATE); not allowed among them: 29
- the empty ablation reproduced every ablated verdict from evidence alone
- who alone decisive in 15: a02-cd-own-token-samanthas-purpose, a04-cd-for-samantha-agents-purpose, a05-cd-pure-deputy, a07-cd-no-cross-subject-substitution, a09-stale-child-starts-before-parent, a11-stale-revoked-middle-link, a13-stale-future-dated-revocation, a15-stale-one-second-before-valid-from, a17-stale-exactly-valid-until, a20-chain-reversed, a21-chain-skips-a-hop, a22-chain-depth-exceeded, a25-chain-unregistered-middle-omitted, a32-esc-amplifying-children, a38-me-root-holder-absent-from-facts
- mandate alone decisive in 4: a02-cd-own-token-samanthas-purpose, a04-cd-for-samantha-agents-purpose, a39-mandate-purpose-limited, a40-mandate-narrowed
- effect alone decisive in 5: a27-contra-prohibition-beats-grant, a28-contra-subject-prohibition-binds-actor, a29-contra-org-prohibition-covers-public, a31-contra-prohibition-kind-confusion, a41-mandate-effect-not-covered
- target alone decisive in 1: a07-cd-no-cross-subject-substitution
- provenance alone decisive in 15: a07-cd-no-cross-subject-substitution, a08-stale-expired-parent-live-child, a09-stale-child-starts-before-parent, a10-stale-revoked-root-live-delegation, a11-stale-revoked-middle-link, a12-stale-anchor-removed-depth3, a13-stale-future-dated-revocation, a15-stale-one-second-before-valid-from, a17-stale-exactly-valid-until, a22-chain-depth-exceeded, a32-esc-amplifying-children, a33-esc-anchor-held-by-someone-else, a34-esc-under-unanchored-all-powerful-parent, a37-me-perfect-grant-without-provenance, a38-me-root-holder-absent-from-facts
