(** JSON encoding of docs/wire-format.md. Decoding is strict: unknown fields,
    duplicate keys, invalid identifiers and invalid timestamps are errors that
    name the offending JSON path. *)

val request_schema : string
val ledger_schema : string
val decision_schema : string

val parse_request : string -> (Request.t, string) result
(** The error names a byte offset (not JSON) or a JSON path (not a request). *)

val request_of_json : Tjson.t -> Request.t Tjson.Decode.r
val ledger_of_json : Tjson.Decode.cursor -> Ledger.t Tjson.Decode.r
val facts_of_json : Tjson.Decode.cursor -> Facts.t Tjson.Decode.r
val request_to_json : Request.t -> Tjson.t
val decision_to_json : Decision.t -> Tjson.t
