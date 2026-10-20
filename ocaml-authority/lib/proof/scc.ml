(* Tarjan's strongly connected components over vertices [0 .. n-1].

   [tarjan] returns components in Tarjan's emission order: a component is
   emitted only after every component reachable from it, so the list is a
   reverse topological order of the condensation (sinks first). Vertices inside
   a component are sorted. With a deterministic [succ], the result is
   deterministic. *)

let tarjan n (succ : int -> int list) : int list list =
  let index = Array.make n (-1) in
  let low = Array.make n 0 in
  let on_stack = Array.make n false in
  let stack = ref [] in
  let next = ref 0 in
  let out = ref [] in
  let rec visit v =
    index.(v) <- !next;
    low.(v) <- !next;
    incr next;
    stack := v :: !stack;
    on_stack.(v) <- true;
    List.iter
      (fun w ->
        if index.(w) < 0 then begin
          visit w;
          low.(v) <- min low.(v) low.(w)
        end
        else if on_stack.(w) then low.(v) <- min low.(v) index.(w))
      (succ v);
    if low.(v) = index.(v) then begin
      let rec pop acc =
        match !stack with
        | w :: rest ->
            stack := rest;
            on_stack.(w) <- false;
            if w = v then w :: acc else pop (w :: acc)
        | [] -> invalid_arg "Scc.tarjan: stack underflow"
      in
      out := List.sort compare (pop []) :: !out
    end
  in
  for v = 0 to n - 1 do
    if index.(v) < 0 then visit v
  done;
  List.rev !out

(* Topological order of the condensation with referrers first: if some vertex
   of A has an edge into B (A <> B), A comes before B. *)
let referrers_first n succ = List.rev (tarjan n succ)

(* A component is cyclic if it has more than one vertex or a self-edge. *)
let is_cyclic succ = function [ v ] -> List.mem v (succ v) | _ -> true
