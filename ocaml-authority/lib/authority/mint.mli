(** The only constructor of [Authority.t]. This module is private to the
    library (see ./dune), so no code outside lib/authority can name it. *)

type t

val mint : Chain.verified -> Check.t list -> Facts.source -> t option
(** [Some] only if the checks include [Provenance] and every check passes. *)

val chain : t -> Chain.verified
val checks : t -> Check.t list
val source : t -> Facts.source

val anchor_statement : t -> string
(** e.g. ["samantha holds realm role report-author (facts.source = keycloak)"] *)
