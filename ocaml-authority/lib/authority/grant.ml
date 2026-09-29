type anchor = Realm_role of Id.Role.t | Client_role of { client : Id.Client.t; role : Id.Role.t }

type provenance =
  | Root of anchor  (** authority originates in a live Keycloak role mapping *)
  | Delegated of { parent : Id.Grant.t; delegator : Principal.t }

type terms = {
  id : Id.Grant.t;
  holder : Principal.t;
  capability : Capability.t;
  target : Capability.target;
  mandates : Id.Mandate.t Nonempty.t;  (** usable only under these *)
  effects : Effect.bound;  (** the grant's own effect ceiling *)
  valid_from : Timestamp.t option;
  valid_until : Timestamp.t option;
  delegable_depth : int;  (** 0 = cannot be delegated *)
}

(* A grant always has provenance: a record without it does not type-check. *)
type t = { terms : terms; provenance : provenance }

(* A ledger entry that arrived without provenance. Its terms are claims only;
   Chain.verify takes a [t], so an [unanchored] can never be verified. *)
type unanchored = { claimed : terms }

type entry = Anchored of t | Unanchored of unanchored

let terms = function Anchored g -> g.terms | Unanchored u -> u.claimed

let anchor_to_string = function
  | Realm_role r -> "realm role " ^ Id.Role.to_string r
  | Client_role { client; role } -> Printf.sprintf "client role %s:%s" (Id.Client.to_string client) (Id.Role.to_string role)
