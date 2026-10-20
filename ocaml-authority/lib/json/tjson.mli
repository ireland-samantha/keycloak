(** Strict JSON for a trust boundary.

    Deliberately small and stdlib-only so the whole wire path of the kernel can
    be read in one sitting. Stricter than most parsers on purpose:

    - duplicate object keys are rejected (Jackson keeps the last one; a parser
      differential between the Java adapter and the kernel is an attack surface),
      in O(n log n) for an object of n keys: the keys of a pushed claim are
      client-controlled
    - error messages never copy input bytes that are not printable ASCII, so a
      decision about any input is valid UTF-8
    - nesting depth is bounded
    - strings must be valid UTF-8; lone surrogates in [\u] escapes are rejected
    - nothing but whitespace may follow the top-level value *)

type t =
  | Null
  | Bool of bool
  | Number of string  (** the validated JSON lexeme, e.g. ["-12"], ["1.5e3"] *)
  | String of string  (** UTF-8 *)
  | Array of t list
  | Object of (string * t) list  (** keys are unique; source order preserved *)

type parse_error = { offset : int; message : string }

val parse : ?max_depth:int -> string -> (t, parse_error) result
(** [max_depth] defaults to 64. *)

val to_string : t -> string
(** Compact, deterministic (object order as constructed). *)

val to_string_pretty : t -> string
(** Two-space indented, deterministic. *)

(** Path-aware decoding. Errors name the JSON path that was wrong, so a
    malformed request produces evidence a human can act on. *)
module Decode : sig
  type error = { path : string; message : string }

  type 'a r = ('a, error) result

  type cursor
  (** A JSON value together with the path it was reached by. *)

  val root : t -> cursor
  val path : cursor -> string
  val value : cursor -> t
  val fail : cursor -> string -> 'a r

  val obj : ?allowed:string list -> cursor -> (string * cursor) list r
  (** Fails if the value is not an object. When [allowed] is given, any key
      outside it is an error (typos must not be silently ignored). *)

  val field : string -> cursor -> cursor r
  (** Required field of an object. [null] counts as present. *)

  val field_opt : string -> cursor -> cursor option r
  (** Absent or [null] -> [None]. *)

  val string : cursor -> string r
  val bool : cursor -> bool r
  val int : cursor -> int r
  (** Integers only; rejects fractions, exponents and out-of-range values. *)

  val list : cursor -> cursor list r
  val map_list : (cursor -> 'a r) -> cursor -> 'a list r

  val ( let* ) : 'a r -> ('a -> 'b r) -> 'b r
  val ( let+ ) : 'a r -> ('a -> 'b) -> 'b r
end

(** Construction helpers for encoders. *)
val obj : (string * t) list -> t

val str : string -> t
val int : int -> t
val list : ('a -> t) -> 'a list -> t
val opt : ('a -> t) -> 'a option -> t
