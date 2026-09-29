(** Typed authority kernel: docs/authority-model.md and docs/wire-format.md.

    This is the library interface. [Mint], which holds the only constructor
    of {!t}, is a private module and is not reachable from here. *)

module Id = Id
module Nonempty = Nonempty
module Timestamp = Timestamp
module Effect = Effect
module Principal = Principal
module Capability = Capability
module Mandate = Mandate
module Grant = Grant
module Ledger = Ledger
module Facts = Facts
module Request = Request
module Check = Check
module Chain = Chain
module Decision = Decision
module Codec = Codec
module Evaluate = Evaluate

type t = Mint.t
(** The authority carried by [Decision.Allow]: a verified chain plus the
    checks that passed for it. Abstract; it cannot be built outside the
    library. *)

val chain : t -> Chain.verified
val grant : t -> Grant.t
val checks : t -> Check.t list
val source : t -> Facts.source
val anchor_statement : t -> string
