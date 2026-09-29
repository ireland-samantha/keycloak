(** Decisions and their evidence (authority-model.md "Outcome", wire-format.md
    "Decision"). [Allow] carries a [Mint.t], which only the library can build.

    [t] is private. Code outside the library reads a decision and matches on
    it, but cannot build one, not even as [{ d with verdict = ... }]. An
    [Authority.t] taken from a real ALLOW therefore cannot be placed in a
    decision about another request: the only decisions that exist are those
    [Evaluate] made, each around the request it decided. [make] requires a
    [Mint.seal], which only the library's private module [Mint] produces. *)

type reason_code =
  | Malformed_request
  | Request_too_large
  | Missing_mandate
  | Missing_effect
  | Unknown_principal
  | Principal_kind_mismatch
  | Unknown_mandate
  | Inconsistent_ledger
  | Inconsistent_facts
  | Prohibited
  | Insufficient_evidence
  | No_grant_for_capability
  | Failed of Check.name  (** a request or candidate check failed *)
  | Fault of Chain.fault_code  (** chain verification found this fault *)

type reason = { code : reason_code; message : string }
type status = Authorizes | Refuted | Undetermined
type candidate = { grant : Id.Grant.t; status : status; checks : Check.t list }

type prohibition_check = { prohibition : Id.Prohibition.t; outcome : Check.outcome; detail : string }
(** [Fail] means the prohibition applies to this request. *)

type evidence = {
  request_checks : Check.t list;
  prohibitions : prohibition_check list;
  candidates : candidate list;
  held : Capability.t list;  (** capabilities the acting principal holds; reported when there are no candidates *)
}

type verdict = Allow of Mint.t | Deny of reason Nonempty.t | Indeterminate of reason Nonempty.t

type about = { query : Request.query; subject : Principal.t; actor_chain : Principal.t list }
(** The request as the kernel understood it; [None] when it did not decode. *)

val acting : about -> Principal.t

type t = private { request_id : Id.Request.t option; about : about option; verdict : verdict; evidence : evidence }

val make : Mint.seal -> request_id:Id.Request.t option -> about:about option -> verdict:verdict -> evidence:evidence -> t
val reason_code_to_string : reason_code -> string
val verdict_to_string : verdict -> string
val reasons : t -> reason list
val status_to_string : status -> string
