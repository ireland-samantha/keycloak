(* expect: Unbound module Authority__Mint *)
(* Decision/authority binding (adversarial review): the library's own
   constructor Decision.make needs a Mint.seal, and the seal lives in the
   private module Mint, whose .cmi is not visible outside lib/authority. *)

let forge (a : Authority.t) (about : Authority.Decision.about) : Authority.Decision.t =
  Authority.Decision.make Authority__Mint.seal ~request_id:None ~about:(Some about) ~verdict:(Allow a)
    ~evidence:{ request_checks = []; prohibitions = []; candidates = []; held = [] }
