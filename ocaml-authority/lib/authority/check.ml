(* The named checks of authority-model.md, Evaluation steps 2 and 3. *)
type name =
  | Holder_is_actor
  | Delegation_path_matches
  | Target_covers_resource
  | Mandate_permitted
  | Effect_within_grant
  | Mandate_covers_capability
  | Effect_within_mandate
  | Provenance

type outcome = Pass | Fail | Unknown
type t = { name : name; outcome : outcome; detail : string }

let of_bool name ok ~pass ~fail = if ok then { name; outcome = Pass; detail = pass } else { name; outcome = Fail; detail = fail }
let unknown name detail = { name; outcome = Unknown; detail }

let name_to_string = function
  | Holder_is_actor -> "holder_is_actor"
  | Delegation_path_matches -> "delegation_path_matches"
  | Target_covers_resource -> "target_covers_resource"
  | Mandate_permitted -> "mandate_permitted"
  | Effect_within_grant -> "effect_within_grant"
  | Mandate_covers_capability -> "mandate_covers_capability"
  | Effect_within_mandate -> "effect_within_mandate"
  | Provenance -> "provenance"

let outcome_to_string = function Pass -> "pass" | Fail -> "fail" | Unknown -> "unknown"
