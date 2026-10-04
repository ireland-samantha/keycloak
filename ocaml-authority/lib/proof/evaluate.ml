(* Global evaluation of every obligation against a complete assignment. This is
   the checker's reading of the rule table: no demands, no memo, no order. *)

open Encoding

let comparable_verdict (m : Model.t) (enc : Model.assignment) (leaves : Obligation.leaf list) : verdict =
  let visited = Hashtbl.create 8 in
  let v = ref Proven in
  let rec leaf = function
    | Obligation.Slice_type id -> (
        let i = Model.node m id in
        match comparability enc.(i) with
        | Comparable -> ()
        | Not_comparable -> v := worst !v Refuted
        | Comparable_if_fields ->
            (* Java equals is implementation-defined: at best UNKNOWN, and a
               record is comparable only if every field is. *)
            v := worst !v Unknown;
            if not (Hashtbl.mem visited i) then begin
              Hashtbl.add visited i ();
              List.iter leaf (List.concat_map (Model.leaves m) (Obligation.carried_types m.nodes.(i)))
            end)
    | l -> v := worst !v (Rules.leaf_verdict l)
  in
  List.iter leaf leaves;
  !v

let verdict (m : Model.t) (enc : Model.assignment) (o : Obligation.t) : verdict =
  if Rules.owner_dependent o.kind then Rules.owner_verdict o enc.(Model.node m o.owner)
  else
    match Rules.fixed_verdict ~leaves:(Model.leaves m) o with
    | Some v -> v
    | None -> (
        match (Rules.compared_type o, o.subject) with
        | Some t, _ -> worst (Rules.compared_floor ~arity:m.arity t) (comparable_verdict m enc (Model.leaves m t))
        | None, Bound (_, b) -> (
            match Rules.bound_target b with
            | Rules.Bound_fixed v -> v
            | Rules.Bound_node id -> Rules.bound_verdict enc.(Model.node m id))
        | None, _ -> invalid_arg ("Evaluate.verdict: " ^ o.id))

let verdicts m enc = Array.map (verdict m enc) m.obligations

let complexity (m : Model.t) (enc : Model.assignment) =
  let nodes = Array.fold_left (fun acc e -> acc + Encoding.complexity e) 0 enc in
  let subtypes =
    Array.fold_left
      (fun acc (o : Obligation.t) ->
        match o.subject with
        | Supertype t -> acc + subtype_complexity enc.(Model.node m o.owner) enc.(Model.node m t)
        | _ -> acc)
      0 m.obligations
  in
  nodes + subtypes + Model.external_complexity m

let cost m enc (vs : verdict array) =
  Array.fold_left (fun acc v -> add acc (of_verdict v)) (of_complexity (complexity m enc)) vs

(* Structural constraints of the encoding table. *)
let structural_errors (m : Model.t) (enc : Model.assignment) =
  let errs = ref [] in
  Array.iteri
    (fun i e ->
      let jt = m.nodes.(i) in
      if not (List.mem e (Encoding.allowed jt.kind)) then
        errs := Printf.sprintf "%s: %s is not allowed for a %s" jt.id (label e) (Jgraph.kind_to_string jt.kind) :: !errs
      else if m.cyclic.(m.component_of.(i)) && not (allowed_in_cycle e) then
        errs := Printf.sprintf "%s: %s inside a cyclic component" jt.id (label e) :: !errs)
    enc;
  List.rev !errs
