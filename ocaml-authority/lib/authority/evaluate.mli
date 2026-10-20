(** Evaluation (authority-model.md, "Evaluation"). A pure function of the
    request: the evaluation time is [facts.evaluated_at] and no clock is read.
    Checks are never short-circuited, so evidence is complete for every
    outcome, including INDETERMINATE for requests that decode. *)

val max_request_bytes : int
(** 1 MiB. *)

val evaluate : Request.t -> Decision.t

val run : string -> Decision.t
(** Size limit, strict decoding, then [evaluate]. A request that is too large
    or does not decode yields INDETERMINATE; this function does not raise. *)
