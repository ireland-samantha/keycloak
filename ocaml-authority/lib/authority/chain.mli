(** Chain verification (authority-model.md, "Chain verification").

    [verify] resolves a grant up to its root and checks every link, every
    grant on the chain and the root's anchor against the live role facts. It
    does not stop at the first problem: every fault found is reported. *)

type fault_code =
  | Missing_parent
  | Forged_delegation
  | Delegation_depth_exceeded
  | Capability_amplified
  | Target_amplified
  | Mandate_amplified
  | Effect_amplified
  | Validity_extended
  | Cycle
  | Chain_too_long
  | Revoked
  | Not_yet_valid
  | Expired
  | Anchor_missing  (** the root holder is in the facts but does not hold the anchor role *)

type gap_code =
  | Unanchored_ancestor  (** an ancestor entry has no provenance *)
  | No_role_facts  (** the root holder is absent from [facts.principals] *)

type 'code finding = { code : 'code; grant : Id.Grant.t; detail : string }

type verified
(** Only [verify] produces a value of this type. *)

type result =
  | Verified of verified
  | Invalid of fault_code finding Nonempty.t
  | Unverifiable of gap_code finding Nonempty.t

val max_links : int
(** A chain holds at most this many grants, root included. *)

val verify : Ledger.t -> Facts.t -> Grant.t -> result

val links : verified -> Grant.t Nonempty.t
(** Root first; the last link is the grant that was verified. *)

val leaf : verified -> Grant.t
val root_holder : verified -> Principal.t
val anchor : verified -> Grant.anchor
val describe : verified -> string

val delegation_path : Ledger.t -> Grant.entry -> Principal.t list option
(** Holders from the root down: [root(h0) -> h1 -> ... -> hn] gives
    [[h0; ...; hn]]. An entry without provenance asserts no delegation and
    contributes its holder alone. [None] when the chain is broken (missing
    parent, cycle, too long). *)

val fault_code_to_string : fault_code -> string
val gap_code_to_string : gap_code -> string
