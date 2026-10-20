(* The node encodings, verdicts and the lexicographic cost of docs/proof-search.md. *)

type t = Variant | Record | Closures | Object | Module_type | Abstract

(* Enumeration order of the search; it also breaks ties between equal costs. *)
let searchable = [ Variant; Record; Closures; Object; Module_type ]

let complexity = function
  | Variant -> 1
  | Record -> 2
  | Closures -> 3
  | Object -> 4
  | Module_type -> 5
  | Abstract -> 1

let to_string = function
  | Variant -> "variant"
  | Record -> "record"
  | Closures -> "closures"
  | Object -> "object"
  | Module_type -> "module_type"
  | Abstract -> "abstract"

let of_string = function
  | "variant" -> Some Variant
  | "record" -> Some Record
  | "closures" -> Some Closures
  | "object" -> Some Object
  | "module_type" -> Some Module_type
  | "abstract" -> Some Abstract
  | _ -> None

let label = function
  | Variant -> "Variant"
  | Record -> "Record"
  | Closures -> "Closures"
  | Object -> "Object"
  | Module_type -> "Module_type"
  | Abstract -> "Abstract"

(* "allowed for" column. Enums are only ever Variant; Java records only Record. *)
let allowed (kind : Jgraph.type_kind) =
  match kind with
  | Enum -> [ Variant ]
  | Record_decl -> [ Record ]
  | Class_decl -> [ Record; Closures; Object ]
  | Interface | Annotation_decl -> [ Record; Closures; Object; Module_type ]

let allowed_in_cycle = function Module_type -> false | _ -> true

(* "comparable" column, before looking at a record's fields. *)
type comparability = Comparable | Comparable_if_fields | Not_comparable

let comparability = function
  | Variant -> Comparable
  | Record -> Comparable_if_fields
  | Closures | Object | Module_type -> Not_comparable
  | Abstract -> Not_comparable

(* "Subtype" row: complexity of S <: T given both encodings. *)
let subtype_complexity s t =
  match (s, t) with
  | Object, Object -> 0
  | Module_type, Module_type -> 1
  | a, b when a = b -> 2
  | _ -> 3

type verdict = Proven | Strengthened | Unknown | Refuted

let verdict_to_string = function
  | Proven -> "PROVEN"
  | Strengthened -> "STRENGTHENED"
  | Unknown -> "UNKNOWN"
  | Refuted -> "REFUTED"

let verdict_of_string = function
  | "PROVEN" -> Some Proven
  | "STRENGTHENED" -> Some Strengthened
  | "UNKNOWN" -> Some Unknown
  | "REFUTED" -> Some Refuted
  | _ -> None

let all_verdicts = [ Proven; Strengthened; Unknown; Refuted ]
let severity = function Proven | Strengthened -> 0 | Unknown -> 1 | Refuted -> 2

(* Worse of two verdicts; on equal severity the first is kept. *)
let worst a b = if severity b > severity a then b else a

type cost = { refuted : int; unknown : int; complexity : int }

let zero = { refuted = 0; unknown = 0; complexity = 0 }
let infinite = { refuted = max_int / 4; unknown = max_int / 4; complexity = max_int / 4 }

let add a b =
  { refuted = a.refuted + b.refuted; unknown = a.unknown + b.unknown; complexity = a.complexity + b.complexity }

(* Lexicographic order on Z^3 is translation invariant, so [a + x < b] iff
   [x < b - a]; components of a difference may be negative. *)
let sub a b =
  { refuted = a.refuted - b.refuted; unknown = a.unknown - b.unknown; complexity = a.complexity - b.complexity }

let compare_cost a b = compare (a.refuted, a.unknown, a.complexity) (b.refuted, b.unknown, b.complexity)
let of_verdict = function Refuted -> { zero with refuted = 1 } | Unknown -> { zero with unknown = 1 } | _ -> zero
let of_complexity n = { zero with complexity = n }
let cost_to_string c = Printf.sprintf "(refuted %d, unknown %d, complexity %d)" c.refuted c.unknown c.complexity
