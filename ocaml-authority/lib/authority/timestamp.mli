(** Instants with one-second resolution. The only accepted text form is
    strict RFC 3339 in UTC with a literal [Z] and no fraction:
    [YYYY-MM-DDThh:mm:ssZ]. Leap seconds ([ss = 60]) are rejected. The kernel
    never reads a clock; every instant comes from the request. *)

type t

val of_string : string -> (t, string) result
val to_string : t -> string

val to_unix : t -> int
(** Seconds since 1970-01-01T00:00:00Z. *)

val compare : t -> t -> int
