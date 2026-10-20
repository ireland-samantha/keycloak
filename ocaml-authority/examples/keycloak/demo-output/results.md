| scenario | token | permission | mandate | effect | RBAC (token roles) | RBAC (live roles) | kernel via Keycloak | kernel decision | reason codes |
|---|---|---|---|---|---|---|---|---|---|
| 01-direct-read | agent | q3-report#read | generate-report | observe | true | true | true | allow |  |
| 02-delegated-generate | delegated | q3-report#generate | generate-report | produce:organization | true | true | true | allow |  |
| 03-capability-denied | agent | realm-config#administer | operate-realm | administer | access_denied | access_denied | access_denied | deny | no_grant_for_capability |
| 04-wrong-effect | delegated | q3-report#generate | generate-report | produce:public | true | true | access_denied | deny | effect_within_mandate, holder_is_actor, delegation_path_matches, effect_within_grant |
| 05-expired-delegation | delegated | q3-report#read | generate-report | observe | true | true | access_denied | deny | holder_is_actor, delegation_path_matches, expired |
| 06-missing-provenance | agent | q3-report#publish | publish-release | disclose:public | access_denied | access_denied | access_denied | indeterminate | insufficient_evidence |
| 07-mandate-capability-mismatch | delegated | q3-report#publish | generate-report | disclose:public | true | true | access_denied | deny | mandate_covers_capability, effect_within_mandate, holder_is_actor, delegation_path_matches, mandate_permitted |
| 12-direct-publish | samantha | q3-report#publish | publish-release | disclose:public | true | true | true | allow |  |
| 13-delegation-without-exchange | agent | q3-report#generate | generate-report | produce:organization | access_denied | access_denied | access_denied | deny | delegation_path_matches |
| 14-agent-administers-for-samantha | delegated | realm-config#administer | generate-report | administer | true | true | access_denied | deny | mandate_covers_capability, effect_within_mandate, holder_is_actor, delegation_path_matches, mandate_permitted |
| 09-anchor-role-removed | delegated | q3-report#generate | generate-report | produce:organization | true | access_denied | access_denied | deny | holder_is_actor, delegation_path_matches, anchor_missing |
| 15-anchor-role-restored | delegated | q3-report#generate | generate-report | produce:organization | true | true | true | allow |  |
