(* expect: Cannot create values of the private type Authority.Decision.t *)
(* Decision/authority binding (adversarial review): a Decision.t cannot be
   written as a record literal outside the library either, so an ALLOW
   document cannot be assembled around a borrowed Authority.t. *)

let forge (a : Authority.t) (about : Authority.Decision.about) : Authority.Decision.t =
  { request_id = None; about = Some about; verdict = Allow a;
    evidence = { request_checks = []; prohibitions = []; candidates = []; held = [] } }
