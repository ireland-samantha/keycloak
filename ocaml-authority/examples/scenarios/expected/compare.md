# Conventional check vs. kernel: demo.json

- conventional: hasPermission(token subject, capability) from the same facts; allow iff one of the subject's live roles
  (facts.principals) anchors a ROOT grant in the ledger for the requested capability.
- conventional audit record: token subject, capability, resource, decision, conferring roles.
- kernel audit record: the decision document.
- a question is listed when the record alone answers it. who: the acting principal (conventional: only when the actor
  chain is empty). mandate, effect: named by the record. provenance: conventional: the conferring role, when allowed and
  the actor chain is empty; kernel: authority.chain for allow, otherwise each candidate's provenance check (none when
  there are no candidates).

| scenario | subject | actor chain | conventional | conferring roles | kernel | kernel reason codes | conventional record answers | kernel record answers |
|---|---|---|---|---|---|---|---|---|
| 01-direct-read | research-agent | - | allow | client role document-service:reader | allow | - | who, capability, provenance | who, mandate, capability, effect, provenance |
| 02-delegated-generate | samantha | research-agent | allow | realm role report-author | allow | - | capability | who, mandate, capability, effect, provenance |
| 03-capability-denied | research-agent | - | deny | - | deny | no_grant_for_capability | who, capability | who, mandate, capability, effect |
| 04-wrong-effect | samantha | research-agent | allow | realm role report-author | deny | delegation_path_matches, effect_within_grant, effect_within_mandate, holder_is_actor | capability | who, mandate, capability, effect, provenance |
| 05-expired-delegation | samantha | research-agent | allow | realm role report-author | deny | delegation_path_matches, expired, holder_is_actor | capability | who, mandate, capability, effect, provenance |
| 06-missing-provenance | research-agent | - | deny | - | indeterminate | insufficient_evidence | who, capability | who, mandate, capability, effect, provenance |
| 07-mandate-capability-mismatch | samantha | research-agent | allow | realm role document-publisher | deny | delegation_path_matches, effect_within_mandate, holder_is_actor, mandate_covers_capability, mandate_permitted | capability | who, mandate, capability, effect, provenance |
| 08-confused-deputy | samantha | research-agent | allow | realm role report-author | deny | delegation_path_matches, holder_is_actor, not_yet_valid | capability | who, mandate, capability, effect, provenance |
| 09-anchor-role-removed | samantha | research-agent | deny | - | deny | anchor_missing, delegation_path_matches, holder_is_actor | capability | who, mandate, capability, effect, provenance |
| 10-unknown-principal | mallory | - | allow | realm role report-author | indeterminate | unknown_principal | who, capability, provenance | who, mandate, capability, effect |
| 11-missing-effect | research-agent | - | allow | client role document-service:reader | indeterminate | missing_effect | who, capability, provenance | who, mandate, capability, provenance |
| 12-direct-publish | samantha | - | allow | realm role document-publisher | allow | - | who, capability, provenance | who, mandate, capability, effect, provenance |
| 13-delegation-without-exchange | research-agent | - | deny | - | deny | delegation_path_matches | who, capability | who, mandate, capability, effect, provenance |

- scenarios: 13; conventional check computed for 13 (the rest do not decode)
- decisions differ in 7: 04-wrong-effect, 05-expired-delegation, 06-missing-provenance, 07-mandate-capability-mismatch, 08-confused-deputy, 10-unknown-principal, 11-missing-effect
- conventional allow, kernel not allow: 6: 04-wrong-effect, 05-expired-delegation, 07-mandate-capability-mismatch, 08-confused-deputy, 10-unknown-principal, 11-missing-effect
- kernel allow, conventional not allow: 0: none
- records answering who: conventional 7 of 13, kernel 13 of 13
- records answering mandate: conventional 0 of 13, kernel 13 of 13
- records answering capability: conventional 13 of 13, kernel 13 of 13
- records answering effect: conventional 0 of 13, kernel 12 of 13
- records answering provenance: conventional 4 of 13, kernel 11 of 13
