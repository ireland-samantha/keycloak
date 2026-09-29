(* expect: This expression has type Authority.Grant.t but an expression was expected of type Authority.Chain.verified *)
(* S3: Chain.verified is abstract; only Chain.verify produces one. *)

let forge (g : Authority.Grant.t) : Authority.Chain.result = Verified g
