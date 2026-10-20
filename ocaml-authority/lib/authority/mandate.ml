(* A named purpose. It bounds a request independently of any grant: the
   capability must be listed and the effect must be within [effects]. *)
type t = {
  id : Id.Mandate.t;
  purpose : string;
  capabilities : Capability.t Nonempty.t;
  effects : Effect.bound;
}
