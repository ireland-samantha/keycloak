(* expect: This expression has type Authority.Grant.unanchored *)
(* expect: but an expression was expected of type Authority__.Grant.t = Authority.Grant.t *)
(* S3: a ledger entry that arrived without provenance cannot reach chain
   verification. *)

let verify ledger facts (u : Authority.Grant.unanchored) = Authority.Chain.verify ledger facts u
