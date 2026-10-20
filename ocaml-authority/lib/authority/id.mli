(** Identifiers. Each kind is a distinct type, so a mandate id cannot be passed
    where a principal id is expected. A value exists only after validation:
    1-128 characters from [[A-Za-z0-9._:@-]]. *)

module type S = sig
  type t = private string

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Make (_ : sig
  val kind : string
end) : S

module Principal : S
module Mandate : S
module Grant : S
module Prohibition : S
module Resource : S
module Resource_type : S
module Action : S
module Role : S
module Client : S
module Request : S
