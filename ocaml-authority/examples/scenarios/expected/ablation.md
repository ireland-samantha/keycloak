# Ablation: demo.json

Each column recomputes the outcome from the decision's own evidence with one dimension's checks ignored
(who: holder_is_actor, delegation_path_matches; mandate: mandate_permitted, mandate_covers_capability;
effect: effect_within_grant, effect_within_mandate, prohibitions; target: target_covers_resource;
provenance: chain verification). `allow` in a column means that dimension alone decided against the request.
Well-formedness INDETERMINATE decisions are decided before any check and are not ablated.

| scenario | decision | w/o who | w/o mandate | w/o effect | w/o target | w/o provenance | minimal sets that flip it |
|---|---|---|---|---|---|---|---|
| 01-direct-read | allow | allow | allow | allow | allow | allow | (allowed) |
| 02-delegated-generate | allow | allow | allow | allow | allow | allow | (allowed) |
| 03-capability-denied | deny | - | - | - | - | - | none: no candidate for the capability |
| 04-wrong-effect | deny | - | - | allow | - | - | {effect} |
| 05-expired-delegation | deny | allow | - | - | - | allow | {provenance}; {who} |
| 06-missing-provenance | indeterminate | - | - | - | - | allow | {provenance} |
| 07-mandate-capability-mismatch | deny | - | - | - | - | - | {who, mandate, effect} |
| 08-confused-deputy | deny | allow | - | - | - | allow | {provenance}; {who} |
| 09-anchor-role-removed | deny | - | - | - | - | allow | {provenance} |
| 10-unknown-principal | indeterminate | - | - | - | - | - | (well-formedness) |
| 11-missing-effect | indeterminate | - | - | - | - | - | (well-formedness) |
| 12-direct-publish | allow | allow | allow | allow | allow | allow | (allowed) |
| 13-delegation-without-exchange | deny | allow | - | - | - | - | {who} |

- scenarios: 13; ablated: 11 (the rest are well-formedness INDETERMINATE); not allowed among them: 8
- the empty ablation reproduced every ablated verdict from evidence alone
- who alone decisive in 3: 05-expired-delegation, 08-confused-deputy, 13-delegation-without-exchange
- mandate alone decisive in 0: -
- effect alone decisive in 1: 04-wrong-effect
- target alone decisive in 0: -
- provenance alone decisive in 4: 05-expired-delegation, 06-missing-provenance, 08-confused-deputy, 09-anchor-role-removed
