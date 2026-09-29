(* expect: Some record fields are undefined: provenance *)
(* S3: a usable grant without provenance. *)

let grant (terms : Authority.Grant.terms) : Authority.Grant.t = { terms }
