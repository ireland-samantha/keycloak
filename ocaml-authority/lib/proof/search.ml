(* attempt_proof: memoized, backtracking, branch-and-bound search over the
   condensation of the type-reference graph (docs/proof-search.md, "Search").

   Components are assigned referrers first. When an obligation's verdict
   depends on a component that is not assigned yet, it becomes a *demand* on
   that component. The residual state is (k, pending), where [pending] holds,
   per unfinished obligation, the verdict it has already reached (its floor)
   and its demands on components >= k. That state determines the cost of every
   completion, so it is the memo key. *)

open Encoding

type req =
  | Comparable  (** a Set element or Map key, or a field of a record that must be comparable *)
  | Object_bound  (** the bound of a type parameter *)
  | Subtype_of of Encoding.t  (** supertype of a node assigned this encoding; costs complexity *)

type pending = { obl : int; floor : verdict; demands : (int * req) list  (** sorted, no duplicates *) }

(* How an obligation is scored, fixed before the search starts. *)
type plan =
  | Fixed of verdict
  | Owner of int
  | Comparable_leaves of Obligation.leaf list * verdict  (** leaves, and the floor of the compared type itself *)
  | Bound_on of int
  | Subtype_pair of int * int

type stats = {
  mutable states_explored : int;  (** states expanded (memo misses) *)
  mutable memo_hits : int;
  mutable branches_pruned : int;  (** choices cut by the bound before recursing *)
  mutable infeasible : int;  (** encodings rejected by structural constraints while enumerating *)
}

type outcome = {
  assignment : Model.assignment;
  verdicts : verdict array;  (** per obligation, as the search derived them *)
  cost : cost;
  stats : stats;
}

(* Solution of a residual state: choices and verdicts of everything decided at >= k. *)
type sub = { s_cost : cost; s_encs : (int * Encoding.t) list; s_verdicts : (int * verdict) list }
type entry = Exact of sub | At_least of cost

let plan_of (m : Model.t) (o : Obligation.t) =
  let node = Model.node m in
  if Rules.owner_dependent o.kind then Owner (node o.owner)
  else
    match Rules.fixed_verdict ~leaves:(Model.leaves m) o with
    | Some v -> (
        match o.subject with Supertype t -> Subtype_pair (node o.owner, node t) | _ -> Fixed v)
    | None -> (
        match (Rules.compared_type o, o.subject) with
        | Some t, _ -> Comparable_leaves (Model.leaves m t, Rules.compared_floor ~arity:m.arity t)
        | None, Bound (_, b) -> (
            match Rules.bound_target b with Rules.Bound_fixed v -> Fixed v | Rules.Bound_node id -> Bound_on (node id))
        | None, _ -> invalid_arg ("Search.plan_of: " ^ o.id))

let req_code = function
  | Comparable -> "c"
  | Object_bound -> "o"
  | Subtype_of e -> "s" ^ Encoding.to_string e

let state_key k (pending : pending list) =
  let b = Buffer.create 64 in
  Buffer.add_string b (string_of_int k);
  List.iter
    (fun p ->
      Printf.bprintf b "|%d:%d" p.obl (severity p.floor);
      List.iter (fun (v, r) -> Printf.bprintf b ",%d%s" v (req_code r)) p.demands)
    pending;
  Buffer.contents b

(* Every pending obligation will end at least at its floor. *)
let lower_bound pending = List.fold_left (fun acc p -> add acc (of_verdict p.floor)) zero pending

let run (m : Model.t) : outcome =
  let ncomp = Array.length m.components in
  let obls = m.obligations in
  let plans = Array.map (plan_of m) obls in
  let by_origin = Array.make ncomp [] in
  for o = Array.length obls - 1 downto 0 do
    let k = m.component_of.(Model.node m obls.(o).owner) in
    by_origin.(k) <- o :: by_origin.(k)
  done;
  let carried_leaves =
    Array.map (fun jt -> List.concat_map (Model.leaves m) (Obligation.carried_types jt)) m.nodes
  in
  let stats = { states_explored = 0; memo_hits = 0; branches_pruned = 0; infeasible = 0 } in
  let memo : (string, entry) Hashtbl.t = Hashtbl.create 1024 in

  (* Assign component [k] with [enc_of]: score what is decided here and move the
     rest forward as demands on later components. *)
  let step k (pending : pending list) (enc_of : int -> Encoding.t) =
    let in_k v = m.component_of.(v) = k in
    let cost =
      ref (of_complexity (Array.fold_left (fun acc v -> acc + complexity (enc_of v)) 0 m.components.(k)))
    in
    let finalized = ref [] in
    let next = ref [] in
    let finalize o v =
      finalized := (o, v) :: !finalized;
      cost := add !cost (of_verdict v)
    in
    let settle o floor demands =
      if demands = [] then finalize o floor
      else next := { obl = o; floor; demands = List.sort_uniq compare demands } :: !next
    in
    (* Comparability of node [v] of this component, for one obligation. *)
    let comparable floor demands visited =
      let rec visit v =
        if not (Hashtbl.mem visited v) then begin
          Hashtbl.add visited v ();
          match comparability (enc_of v) with
          | Comparable -> ()
          | Not_comparable -> floor := worst !floor Refuted
          | Comparable_if_fields ->
              floor := worst !floor Unknown;
              List.iter leaf carried_leaves.(v)
        end
      and leaf = function
        | Obligation.Slice_type id ->
            let w = Model.node m id in
            if in_k w then visit w else demands := (w, Comparable) :: !demands
        | l -> floor := worst !floor (Rules.leaf_verdict l)
      in
      (visit, leaf)
    in
    List.iter
      (fun o ->
        match plans.(o) with
        | Fixed v -> finalize o v
        | Owner n -> finalize o (Rules.owner_verdict obls.(o) (enc_of n))
        | Comparable_leaves (ls, floor0) ->
            let floor = ref floor0 and demands = ref [] in
            let _, leaf = comparable floor demands (Hashtbl.create 4) in
            List.iter leaf ls;
            settle o !floor !demands
        | Bound_on b ->
            if in_k b then finalize o (Rules.bound_verdict (enc_of b)) else settle o Proven [ (b, Object_bound) ]
        | Subtype_pair (s, t) ->
            if in_k t then begin
              cost := add !cost (of_complexity (subtype_complexity (enc_of s) (enc_of t)));
              finalize o Proven
            end
            else settle o Proven [ (t, Subtype_of (enc_of s)) ])
      by_origin.(k);
    List.iter
      (fun p ->
        let here, later = List.partition (fun (v, _) -> in_k v) p.demands in
        if here = [] then next := p :: !next
        else begin
          let floor = ref p.floor and demands = ref later in
          let visit, _ = comparable floor demands (Hashtbl.create 4) in
          List.iter
            (fun (v, r) ->
              match r with
              | Comparable -> visit v
              | Object_bound -> floor := worst !floor (Rules.bound_verdict (enc_of v))
              | Subtype_of s -> cost := add !cost (of_complexity (subtype_complexity s (enc_of v))))
            here;
          settle p.obl !floor !demands
        end)
      pending;
    let next = List.sort (fun a b -> compare a.obl b.obl) !next in
    (!cost, !finalized, next)
  in

  (* Encodings for the nodes of component [k], backtracking over infeasible ones. *)
  let choices k =
    let nodes = Array.to_list m.components.(k) in
    let cyclic = m.cyclic.(k) in
    let rec go = function
      | [] -> [ [] ]
      | v :: rest ->
          let tails = go rest in
          List.concat_map
            (fun e ->
              if cyclic && not (allowed_in_cycle e) then begin
                stats.infeasible <- stats.infeasible + 1;
                []
              end
              else List.map (fun tail -> (v, e) :: tail) tails)
            (Encoding.allowed m.nodes.(v).kind)
    in
    go nodes
  in

  (* The optimal completion of (k, pending) if it costs less than [budget]. *)
  let rec attempt_proof k pending budget : sub option =
    if k = ncomp then if compare_cost zero budget < 0 then Some { s_cost = zero; s_encs = []; s_verdicts = [] } else None
    else
      let key = state_key k pending in
      match Hashtbl.find_opt memo key with
      | Some (Exact s) ->
          stats.memo_hits <- stats.memo_hits + 1;
          if compare_cost s.s_cost budget < 0 then Some s else None
      | Some (At_least lb) when compare_cost lb budget >= 0 ->
          stats.memo_hits <- stats.memo_hits + 1;
          None
      | _ ->
          stats.states_explored <- stats.states_explored + 1;
          let scored =
            List.map
              (fun choice ->
                let enc_of v = List.assoc v choice in
                let local, finalized, next = step k pending enc_of in
                (choice, local, finalized, next, add local (lower_bound next)))
              (choices k)
          in
          (* Most promising first; the sort is stable, so ties keep enumeration order. *)
          let scored = List.stable_sort (fun (_, _, _, _, a) (_, _, _, _, b) -> compare_cost a b) scored in
          let best = ref None and bound = ref budget in
          List.iter
            (fun (choice, local, finalized, next, lower) ->
              if compare_cost lower !bound >= 0 then stats.branches_pruned <- stats.branches_pruned + 1
              else
                match attempt_proof (k + 1) next (sub !bound local) with
                | None -> ()
                | Some s ->
                    let total = add local s.s_cost in
                    if compare_cost total !bound < 0 then begin
                      bound := total;
                      best := Some { s_cost = total; s_encs = choice @ s.s_encs; s_verdicts = finalized @ s.s_verdicts }
                    end)
            scored;
          (* Exact: every choice was either searched or bounded away. Otherwise
             nothing completes below [budget], which is a lower bound. *)
          Hashtbl.replace memo key (match !best with Some s -> Exact s | None -> At_least budget);
          !best
  in
  match attempt_proof 0 [] infinite with
  | None -> invalid_arg "Search.run: no complete assignment (a node has no feasible encoding)"
  | Some s ->
      let assignment = Array.make (Array.length m.nodes) Abstract in
      List.iter (fun (v, e) -> assignment.(v) <- e) s.s_encs;
      let verdicts = Array.make (Array.length obls) Proven in
      let seen = Array.make (Array.length obls) false in
      List.iter
        (fun (o, v) ->
          if seen.(o) then invalid_arg ("Search.run: obligation decided twice: " ^ obls.(o).id);
          seen.(o) <- true;
          verdicts.(o) <- v)
        s.s_verdicts;
      Array.iteri (fun o b -> if not b then invalid_arg ("Search.run: obligation never decided: " ^ obls.(o).id)) seen;
      { assignment; verdicts; cost = add s.s_cost (of_complexity (Model.external_complexity m)); stats }
