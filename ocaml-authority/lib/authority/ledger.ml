type revocation = { grant : Id.Grant.t; reason : string; at : Timestamp.t }

(* Forbids [holder] every effect at or above one of [effects]. *)
type prohibition = { id : Id.Prohibition.t; holder : Principal.t; effects : Effect.t Nonempty.t; reason : string }

type t = {
  principals : Principal.t list;
  mandates : Mandate.t list;
  entries : Grant.entry list;
  revocations : revocation list;
  prohibitions : prohibition list;
}

let find_entry l id = List.find_opt (fun e -> Id.Grant.equal (Grant.terms e).id id) l.entries
let find_mandate l id = List.find_opt (fun (m : Mandate.t) -> Id.Mandate.equal m.id id) l.mandates
let find_principal l id = List.find_opt (fun (p : Principal.t) -> Id.Principal.equal p.id id) l.principals
let revocation l id = List.find_opt (fun r -> Id.Grant.equal r.grant id) l.revocations
