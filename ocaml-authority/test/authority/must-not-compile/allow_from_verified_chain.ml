(* expect: This expression has type Authority.Chain.verified *)
(* S3: a verified chain alone is not an authority; Allow needs Authority.t,
   which also records the passing checks. *)

let forge (v : Authority.Chain.verified) : Authority.Decision.verdict = Allow v
