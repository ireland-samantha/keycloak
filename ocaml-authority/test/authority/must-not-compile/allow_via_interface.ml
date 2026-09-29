(* expect: Unbound module Authority.Mint *)
(* S3: the library interface does not re-export the constructor either. *)

let forge verified checks : Authority.Decision.verdict =
  Allow (Authority.Mint.mint verified checks Authority.Facts.Fixture |> Option.get)
