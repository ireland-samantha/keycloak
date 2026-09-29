(* Cells of the verdict table of docs/proof-search.md that depend on at most one
   encoding. [Evaluate] composes them over a complete assignment (checker, brute
   force); [Search] composes them incrementally through demands. *)

open Encoding
open Obligation

(* Obligations whose verdict depends only on the owner's encoding. *)
let owner_dependent = function Closed | Open | Command | Query | Mutable -> true | _ -> false

let is_static (o : Obligation.t) = match o.member with Some m -> m.static | None -> false

let owner_verdict (o : Obligation.t) (owner : Encoding.t) : verdict =
  match o.kind with
  | Closed -> if owner = Variant then Proven else Refuted
  | Open -> ( match owner with Closures | Object | Module_type -> Proven | Record -> Unknown | Variant | Abstract -> Refuted)
  | Command | Query ->
      (* A static method is a module-level function whatever the owner's encoding. *)
      if is_static o then Proven else if owner = Record then Refuted else Proven
  | Mutable -> if is_static o then Proven else if owner = Variant then Refuted else Proven
  | _ -> invalid_arg ("Rules.owner_verdict: " ^ kind_to_string o.kind)

(* Verdicts that depend on no encoding at all. *)
let fixed_verdict ~leaves (o : Obligation.t) : verdict option =
  match o.subject with
  | Value t -> Some (if List.exists (function External_type _ -> true | _ -> false) (leaves t) then Unknown else Proven)
  | Null_evidence (_, No_evidence) -> Some Proven
  | Null_evidence (_, (Returns_null | Nullable_annotation _ | Nonnull_annotation _)) -> Some Strengthened
  | Dynamic_parts _ -> Some Unknown
  | Exception _ -> Some Proven
  | Supertype _ -> Some Proven
  | Constants _ | Open_because _ | Element _ | Key_value _ | Behaviour | Mutation _ | Bound _ -> None

(* The type whose values must be comparable for Unique / Keyed. *)
let compared_type (o : Obligation.t) =
  match o.subject with Element e -> Some e | Key_value (k, _) -> Some k | _ -> None

(* "Element or key is String, a primitive or an enum -> Set.Make or Map.Make" (doc line 125). A Set.Make /
   Map.Make exists for a String, a primitive or boxed scalar, or a slice type without type arguments
   (Ocaml_type.collection_module). Any other element or key, such as List<String>, String[], Set<String> or
   ? extends E, is carried as a list, which enforces no uniqueness, so Unique / Keyed is at best UNKNOWN. *)
let set_makeable ~arity (t : Jgraph.type_ref) =
  match t with
  | Primitive _ -> true
  | Class { resolution = Jdk; name; _ } -> List.mem (Jgraph.simple_name name) scalar_jdk
  | Class { resolution = Slice; name; args = []; _ } -> arity name = 0
  | _ -> false

(* The verdict a compared type starts from, before its leaves are looked at. *)
let compared_floor ~arity t = if set_makeable ~arity t then Proven else Unknown

(* Contribution of a leaf that is not a slice type. *)
let leaf_verdict = function
  | Scalar _ -> Proven
  | External_type _ | Dynamic_value _ | Var _ -> Unknown
  | Slice_type _ -> invalid_arg "Rules.leaf_verdict: slice leaf"

(* Bounded(T, P, B): a slice bound must be encoded Object; an Object bound is
   vacuous; any other bound (external, JDK) cannot be expressed. *)
type bound_target = Bound_fixed of verdict | Bound_node of string

let bound_target (b : Jgraph.type_ref) =
  match b with
  | Class { resolution = Slice; name; _ } -> Bound_node name
  | Class { resolution = Jdk; name = "java.lang.Object"; _ } -> Bound_fixed Proven
  | _ -> Bound_fixed Refuted

let bound_verdict enc = if enc = Object then Proven else Refuted
