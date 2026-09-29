(* expect: This expression has type string *)
(* expect: but an expression was expected of type Authority__.Id.Principal.t = Authority.Id.Principal.t *)
(* S3: an unvalidated string where an identifier is expected. *)

let principal : Authority.Principal.t = { kind = User; id = "samantha" }
