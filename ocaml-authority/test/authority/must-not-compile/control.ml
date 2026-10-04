(* expect: compiles *)
(* The same flags accept correct use of the API the other snippets misuse, so
   their failures are not caused by a missing include path. *)

let principal =
  match Authority.Id.Principal.of_string "samantha" with
  | Ok id -> { Authority.Principal.kind = User; id }
  | Error e -> failwith e

let anchored (terms : Authority.Grant.terms) : Authority.Grant.t =
  { terms; provenance = Root (Realm_role (Result.get_ok (Authority.Id.Role.of_string "report-author"))) }

let verify ledger facts (g : Authority.Grant.t) = Authority.Chain.verify ledger facts g

let allowed_grant (d : Authority.Decision.t) =
  match d.verdict with Allow a -> Some (Authority.grant a) | Deny _ | Indeterminate _ -> None

let run input = Authority.Evaluate.run input
