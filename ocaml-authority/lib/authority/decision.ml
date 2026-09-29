(* Decisions and their evidence (authority-model.md "Outcome", wire-format.md
   "Decision"). [Allow] carries a [Mint.t], which only the library can build. *)

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

(* [Fail] means the prohibition applies to this request. *)
type prohibition_check = { prohibition : Id.Prohibition.t; outcome : Check.outcome; detail : string }

type evidence = {
  request_checks : Check.t list;
  prohibitions : prohibition_check list;
  candidates : candidate list;
  held : Capability.t list;  (** capabilities the acting principal holds; reported when there are no candidates *)
}

type verdict = Allow of Mint.t | Deny of reason Nonempty.t | Indeterminate of reason Nonempty.t

(* The request as the kernel understood it; [None] when it did not decode. *)
type about = { query : Request.query; subject : Principal.t; actor_chain : Principal.t list }

let acting a = match a.actor_chain with x :: _ -> x | [] -> a.subject

type t = { request_id : Id.Request.t option; about : about option; verdict : verdict; evidence : evidence }

let reason_code_to_string = function
  | Malformed_request -> "malformed_request"
  | Request_too_large -> "request_too_large"
  | Missing_mandate -> "missing_mandate"
  | Missing_effect -> "missing_effect"
  | Unknown_principal -> "unknown_principal"
  | Principal_kind_mismatch -> "principal_kind_mismatch"
  | Unknown_mandate -> "unknown_mandate"
  | Inconsistent_ledger -> "inconsistent_ledger"
  | Inconsistent_facts -> "inconsistent_facts"
  | Prohibited -> "prohibited"
  | Insufficient_evidence -> "insufficient_evidence"
  | No_grant_for_capability -> "no_grant_for_capability"
  | Failed name -> Check.name_to_string name
  | Fault code -> Chain.fault_code_to_string code

let verdict_to_string = function Allow _ -> "allow" | Deny _ -> "deny" | Indeterminate _ -> "indeterminate"
let reasons d = match d.verdict with Allow _ -> [] | Deny rs | Indeterminate rs -> Nonempty.to_list rs
let status_to_string = function Authorizes -> "authorizes" | Refuted -> "refuted" | Undetermined -> "undetermined"
