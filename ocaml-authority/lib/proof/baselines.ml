(* Reference strategies for hypothesis P2. Both score complete assignments with
   [Evaluate], the checker's global reading of the rule table. *)

open Encoding

let score m enc = Evaluate.cost m enc (Evaluate.verdicts m enc)

(* Each node takes its locally cheapest feasible encoding: its own complexity
   plus the verdicts of obligations that depend only on its own encoding.
   Demands placed by referrers are not seen. Ties keep enumeration order. *)
let greedy (m : Model.t) : Model.assignment =
  let owned = Array.make (Array.length m.nodes) [] in
  Array.iter
    (fun (o : Obligation.t) ->
      if Rules.owner_dependent o.kind then
        let v = Model.node m o.owner in
        owned.(v) <- o :: owned.(v))
    m.obligations;
  Array.mapi
    (fun v _ ->
      let local e =
        List.fold_left (fun acc o -> add acc (of_verdict (Rules.owner_verdict o e))) (of_complexity (complexity e)) owned.(v)
      in
      match Model.feasible m v with
      | [] -> invalid_arg ("Baselines.greedy: no feasible encoding for " ^ m.nodes.(v).id)
      | first :: rest ->
          List.fold_left (fun best e -> if compare_cost (local e) (local best) < 0 then e else best) first rest)
    m.nodes

(* Exhaustive enumeration of every feasible assignment. Returns the first
   optimal assignment in enumeration order, its cost and how many were scored. *)
let brute_force (m : Model.t) : Model.assignment * cost * int =
  let n = Array.length m.nodes in
  let enc = Array.make n Abstract in
  let best = ref None and count = ref 0 in
  let rec go v =
    if v = n then begin
      incr count;
      let c = score m enc in
      match !best with
      | Some (_, bc) when compare_cost c bc >= 0 -> ()
      | _ -> best := Some (Array.copy enc, c)
    end
    else
      List.iter
        (fun e ->
          enc.(v) <- e;
          go (v + 1))
        (Model.feasible m v)
  in
  go 0;
  match !best with
  | Some (a, c) -> (a, c, !count)
  | None -> invalid_arg "Baselines.brute_force: no feasible assignment"
