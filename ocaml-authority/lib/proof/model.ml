(* The Java graph prepared for search and checking: slice nodes, the
   type-reference graph, its condensation, external types and obligations. *)

type t = {
  graph : Jgraph.t;
  nodes : Jgraph.jtype array;  (** slice types, sorted by id *)
  index : (string, int) Hashtbl.t;
  succ : int list array;  (** type-reference edges between slice nodes, sorted, may include self-edges *)
  components : int array array;  (** referrers first *)
  component_of : int array;
  cyclic : bool array;  (** per component *)
  externals : (string * int) list;  (** qualified name, arity; sorted *)
  obligations : Obligation.t array;  (** in derivation order *)
  arity : string -> int;
}

let node m id =
  match Hashtbl.find_opt m.index id with Some i -> i | None -> invalid_arg ("Model.node: not a slice type: " ^ id)

let jtype m id = m.nodes.(node m id)
let is_slice m id = Hashtbl.mem m.index id
let leaves m t = Obligation.leaves ~arity:m.arity t

let build (g : Jgraph.t) : t =
  let nodes = Array.of_list g.types in
  let n = Array.length nodes in
  let index = Hashtbl.create (2 * n) in
  Array.iteri (fun i (jt : Jgraph.jtype) -> Hashtbl.replace index jt.id i) nodes;
  let succ =
    Array.map
      (fun jt ->
        Obligation.referenced_types jt
        |> List.concat_map Obligation.slice_mentions
        |> List.map (Hashtbl.find index)
        |> List.sort_uniq compare)
      nodes
  in
  let comps = Scc.referrers_first n (fun v -> succ.(v)) in
  let components = Array.of_list (List.map Array.of_list comps) in
  let component_of = Array.make n (-1) in
  Array.iteri (fun k c -> Array.iter (fun v -> component_of.(v) <- k) c) components;
  let cyclic = Array.map (fun c -> Scc.is_cyclic (fun v -> succ.(v)) (Array.to_list c)) components in
  let externals =
    let tbl = Hashtbl.create 16 in
    Array.iter
      (fun jt ->
        List.iter
          (fun (name, ar) ->
            let prev = Option.value (Hashtbl.find_opt tbl name) ~default:0 in
            Hashtbl.replace tbl name (max prev ar))
          (List.concat_map Obligation.external_mentions (Obligation.referenced_types jt)))
      nodes;
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [] |> List.sort compare
  in
  let obligations = Array.of_list (Obligation.derive g) in
  let seen = Hashtbl.create 1024 in
  Array.iter
    (fun (o : Obligation.t) ->
      if Hashtbl.mem seen o.id then invalid_arg ("Model.build: duplicate obligation id " ^ o.id);
      Hashtbl.add seen o.id ())
    obligations;
  { graph = g; nodes; index; succ; components; component_of; cyclic; externals; obligations;
    arity = Obligation.arity_of g }

(* Encodings a node may take, given the structural constraints. *)
let feasible m v =
  let allowed = Encoding.allowed m.nodes.(v).kind in
  if m.cyclic.(m.component_of.(v)) then List.filter Encoding.allowed_in_cycle allowed else allowed

let largest_component m = Array.fold_left (fun acc c -> max acc (Array.length c)) 0 m.components
let cyclic_count m = Array.fold_left (fun acc c -> if c then acc + 1 else acc) 0 m.cyclic

(* A complete OCaml-side choice: one encoding per slice node (externals are
   always Abstract). *)
type assignment = Encoding.t array

let external_complexity m = List.length m.externals * Encoding.complexity Encoding.Abstract
