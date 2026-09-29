(* expect: Unbound module Authority__Mint *)
(* S3: an ALLOW without verified provenance. The only constructor of
   Authority.t lives in the library's private module Mint, whose .cmi is not
   visible outside lib/authority. *)

let forge verified checks : Authority.Decision.verdict =
  Allow (Authority__Mint.mint verified checks Authority.Facts.Fixture |> Option.get)
