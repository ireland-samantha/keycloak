(* Reasons for verdicts, and counterexamples for refutations that come from a
   trade-off. Everything here is computed from a complete assignment with
   [Evaluate]; a counterexample names the obligations that would get worse if
   the offending node were re-encoded to meet the demand. *)

open Encoding
open Obligation

type t = { reason : string; conflicts : string list  (** obligation ids *) }

let where (o : Obligation.t) = match o.member with None -> o.owner | Some m -> o.owner ^ "." ^ m.key

(* What a conflicting obligation needs, in a few words. *)
let need (o : Obligation.t) =
  match o.kind with
  | Command | Query -> where o ^ " needs a closure"
  | Open -> ( match o.subject with Open_because why -> o.owner ^ " is open (" ^ why ^ ")" | _ -> o.owner ^ " is open")
  | Unique | Keyed -> describe o ^ " needs a comparable " ^ (match o.kind with Unique -> "element" | _ -> "key")
  | Bounded -> (
      match o.subject with
      | Bound (p, b) -> where o ^ " <" ^ p ^ " extends " ^ Jgraph.render b ^ "> needs an object type"
      | _ -> where o)
  | Mutable -> where o ^ " needs a mutable field or setter"
  | Closed -> o.owner ^ " is a closed enum"
  | Represent | Nullability | Checked | Subtype | Dynamic -> o.id

let list_needs (m : Model.t) ids =
  let shown = List.filteri (fun i _ -> i < 4) ids in
  let text = String.concat "; " (List.map (fun i -> need m.obligations.(i)) shown) in
  let more = List.length ids - List.length shown in
  if more > 0 then Printf.sprintf "%s; and %d more" text more else text

(* Obligations whose verdict gets worse if node [v] takes encoding [e]. *)
let worsened (m : Model.t) enc (verdicts : verdict array) v e =
  let enc' = Array.copy enc in
  enc'.(v) <- e;
  let vs = Evaluate.verdicts m enc' in
  let out = ref [] in
  Array.iteri (fun i x -> if severity x > severity verdicts.(i) then out := i :: !out) vs;
  List.rev !out

(* Among the feasible alternatives for [v] that satisfy [ok], the one that
   worsens the fewest obligations; ties keep enumeration order. *)
let best_alternative m enc verdicts v ok =
  List.filter (fun e -> e <> enc.(v) && ok e) (Model.feasible m v)
  |> List.map (fun e -> (e, worsened m enc verdicts v e))
  |> List.stable_sort (fun (_, a) (_, b) -> compare (List.length a) (List.length b))
  |> function [] -> None | best :: _ -> Some best

(* First node that is not comparable on the way from [leaves] through record fields, with the path. *)
let incomparable_culprit (m : Model.t) enc leaves =
  let visited = Hashtbl.create 8 in
  let rec leaf path = function
    | Slice_type id -> (
        let i = Model.node m id in
        match comparability enc.(i) with
        | Comparable -> None
        | Not_comparable -> Some (i, List.rev path)
        | Comparable_if_fields ->
            if Hashtbl.mem visited i then None
            else begin
              Hashtbl.add visited i ();
              List.find_map (leaf (id :: path))
                (List.concat_map (Model.leaves m) (Obligation.carried_types m.nodes.(i)))
            end)
    | _ -> None
  in
  List.find_map (leaf []) leaves

let unknown_parts (m : Model.t) enc leaves =
  let visited = Hashtbl.create 8 in
  let parts = ref [] in
  let add s = if not (List.mem s !parts) then parts := s :: !parts in
  let rec leaf = function
    | Scalar _ -> ()
    | External_type q -> add (Jgraph.simple_name q ^ " is outside the slice")
    | Dynamic_value d -> add (d ^ " is dynamic")
    | Var v -> add ("type parameter " ^ v ^ " has no known equality")
    | Slice_type id -> (
        let i = Model.node m id in
        match comparability enc.(i) with
        | Comparable_if_fields when not (Hashtbl.mem visited i) ->
            Hashtbl.add visited i ();
            add ("Java equals of " ^ id ^ " is implementation-defined; structural compare may differ");
            List.iter leaf (List.concat_map (Model.leaves m) (Obligation.carried_types m.nodes.(i)))
        | _ -> ())
  in
  List.iter leaf leaves;
  String.concat "; " (List.rev !parts)

let encoding_of m enc id = enc.(Model.node m id)

let explain (m : Model.t) (enc : Model.assignment) (verdicts : verdict array) (i : int) : t =
  let o = m.obligations.(i) in
  let v = verdicts.(i) in
  let plain reason = { reason; conflicts = [] } in
  let owner_enc () = encoding_of m enc o.owner in
  let tradeoff ~culprit ~requirement ~ok ~because =
    match best_alternative m enc verdicts culprit ok with
    | Some (e, ids) when ids <> [] ->
        {
          reason =
            Printf.sprintf "%s must be %s because %s, but as %s: %s" m.nodes.(culprit).id requirement because
              (label e) (list_needs m ids);
          conflicts = List.map (fun j -> m.obligations.(j).id) ids;
        }
    | Some (e, _) ->
        plain
          (Printf.sprintf "%s must be %s because %s; %s would satisfy it at a higher complexity" m.nodes.(culprit).id
             requirement because (label e))
    | None ->
        plain
          (Printf.sprintf "%s must be %s because %s, but no feasible encoding of %s is" m.nodes.(culprit).id requirement
             because m.nodes.(culprit).id)
  in
  match (o.kind, o.subject) with
  | Represent, Value t -> (
      match v with
      | Unknown ->
          let ext =
            List.filter_map (function External_type q -> Some q | _ -> None) (Model.leaves m t) |> List.sort_uniq compare
          in
          plain ("outside the slice (Abstract): " ^ String.concat ", " ext)
      | _ -> plain "carried by the chosen OCaml type")
  | Nullability, Null_evidence (_, ev) -> (
      match ev with
      | No_evidence -> plain "no evidence: option, as Java references are nullable by default"
      | Returns_null -> plain "returns the null literal: option makes that runtime fact static"
      | Nullable_annotation a -> plain ("@" ^ a ^ ": option")
      | Nonnull_annotation a -> plain ("@" ^ a ^ ": bare type"))
  | Closed, Constants cs -> plain (Printf.sprintf "variant of %d constants" (List.length cs))
  | Open, Open_because why -> (
      match v with
      | Unknown ->
          tradeoff ~culprit:(Model.node m o.owner) ~requirement:"open"
            ~because:(why ^ ", and a Record snapshot assumes getters are pure")
            ~ok:(fun e -> Rules.owner_verdict o e = Proven)
      | _ -> plain (label (owner_enc ()) ^ " admits third-party implementations (" ^ why ^ ")"))
  | (Command | Query), _ -> (
      match v with
      | Refuted ->
          let owner = Model.node m o.owner in
          if Model.feasible m owner = [ Record ] then
            plain
              (Printf.sprintf "a record cannot carry behaviour, and Record is the only encoding allowed for the %s %s"
                 (Jgraph.kind_to_string m.nodes.(owner).kind) o.owner)
          else
            let r =
              tradeoff ~culprit:owner ~requirement:"able to carry behaviour" ~because:(where o ^ " is behaviour")
                ~ok:(fun e -> Rules.owner_verdict o e = Proven)
            in
            { r with reason = "a record cannot carry behaviour: " ^ r.reason }
      | _ ->
          if Rules.is_static o then plain "static: module-level function"
          else
            plain
              (match owner_enc () with
              | Variant -> "function over the closed variant"
              | Closures -> "closure field"
              | Object -> "method"
              | Module_type -> "val of the module type"
              | Record | Abstract -> "carried"))
  | Mutable, Mutation how -> (
      match v with
      | Refuted -> plain "an enum constant cannot change"
      | _ ->
          if Rules.is_static o then plain "static: module-level mutable value"
          else
            plain
              (match (owner_enc (), how) with
              | Record, _ -> "mutable field"
              | Closures, `Setter -> "setter closure"
              | Closures, `Field -> "mutable field of the closure record"
              | Object, _ -> "setter method"
              | _ -> "setter"))
  | Checked, _ -> plain "(_, exn) result"
  | (Unique | Keyed), _ -> (
      let t = Option.get (Rules.compared_type o) in
      let leaves = Model.leaves m t in
      match v with
      | Refuted -> (
          match incomparable_culprit m enc leaves with
          | Some (c, path) ->
              let via = match path with [] -> "" | p -> " (reached through the fields of " ^ String.concat ", " p ^ ")" in
              tradeoff ~culprit:c ~requirement:"comparable" ~because:(describe o ^ via)
                ~ok:(fun e -> comparability e <> Not_comparable)
          | None -> plain "not comparable")
      | Unknown -> plain (unknown_parts m enc leaves)
      | _ -> plain (match o.kind with Unique -> "Set.Make over a comparable element" | _ -> "Map.Make over a comparable key"))
  | Bounded, Bound (p, b) -> (
      match (v, Rules.bound_target b) with
      | Refuted, Rules.Bound_fixed _ ->
          plain
            (Printf.sprintf "OCaml type parameters carry no bounds: %s is outside the slice (Abstract), so %s cannot be row-constrained"
               (Jgraph.render b) p)
      | Refuted, Rules.Bound_node id ->
          tradeoff ~culprit:(Model.node m id) ~requirement:"an object type"
            ~because:(Printf.sprintf "it bounds %s of %s" p (where o))
            ~ok:(fun e -> e = Object)
      | _, Rules.Bound_node id ->
          plain (Printf.sprintf "row-constrained parameter: '%s constraint '%s = < ..; methods of %s >" (String.lowercase_ascii p) (String.lowercase_ascii p) id)
      | _, Rules.Bound_fixed _ -> plain "Object bound: no constraint needed")
  | Subtype, Supertype t -> (
      match (owner_enc (), encoding_of m enc t) with
      | Object, Object -> plain "both Object: structural subtyping (complexity 0)"
      | Module_type, Module_type -> plain "both Module_type: include (complexity 1)"
      | a, b when a = b -> plain "same encoding: coercion function (complexity 2)"
      | _ -> plain "different encodings: conversion function (complexity 3)")
  | Dynamic, Dynamic_parts (_, parts) -> plain (String.concat ", " parts ^ ": the Java type states no fact to preserve")
  | _ -> plain ""
