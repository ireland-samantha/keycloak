(* expect: This expression has type Authority.Id.Mandate.t *)
(* expect: but an expression was expected of type Authority__.Id.Principal.t = Authority.Id.Principal.t *)
(* S3: an identifier of one kind where another kind is expected. *)

let principal (m : Authority.Id.Mandate.t) : Authority.Principal.t = { kind = User; id = m }
