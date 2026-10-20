(* Mandate and effect are optional on the wire; their absence is an
   INDETERMINATE well-formedness failure, never a default. *)
type query = {
  mandate : Id.Mandate.t option;
  capability : Capability.t;
  resource : Id.Resource.t;
  effect : Effect.t option;
}

type t = { request_id : Id.Request.t option; query : query; facts : Facts.t; ledger : Ledger.t }
