(* expect: Cannot create values of the private type Authority.Decision.t *)
(* Decision/authority binding (adversarial review). An Authority.t taken from
   a real ALLOW must not be placeable in a Decision.t about another request:
   before Decision.t was made private, [{ other with verdict = Allow a }]
   type-checked and Codec.decision_to_json rendered it as a well-formed
   "allow" for a capability the authority never covered. *)

let rebind (other : Authority.Decision.t) (a : Authority.t) : Authority.Decision.t = { other with verdict = Allow a }
