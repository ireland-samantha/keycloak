(* Tarjan SCC and the referrers-first order on known graphs, then a property
   check against a transitive-closure oracle on random graphs. *)

open Harness
module Scc = Proof.Scc

let of_edges n edges =
  let succ = Array.make n [] in
  List.iter (fun (a, b) -> succ.(a) <- b :: succ.(a)) edges;
  Array.iteri (fun i l -> succ.(i) <- List.sort_uniq compare l) succ;
  fun v -> succ.(v)

let show_comps cs = "[" ^ String.concat "; " (List.map (fun c -> "{" ^ String.concat "," (List.map string_of_int c) ^ "}") cs) ^ "]"

let known () =
  check_eq "empty graph" show_comps [] (Scc.referrers_first 0 (of_edges 0 []));
  let single = of_edges 1 [] in
  check_eq "single vertex" show_comps [ [ 0 ] ] (Scc.referrers_first 1 single);
  check "single vertex is acyclic" (not (Scc.is_cyclic single [ 0 ]));
  let self = of_edges 1 [ (0, 0) ] in
  check "self-loop is cyclic" (Scc.is_cyclic self [ 0 ]);
  check_eq "chain 0->1->2, referrers first" show_comps [ [ 0 ]; [ 1 ]; [ 2 ] ]
    (Scc.referrers_first 3 (of_edges 3 [ (0, 1); (1, 2) ]));
  check_eq "chain 2->1->0, referrers first" show_comps [ [ 2 ]; [ 1 ]; [ 0 ] ]
    (Scc.referrers_first 3 (of_edges 3 [ (2, 1); (1, 0) ]));
  let cyc = of_edges 4 [ (0, 1); (1, 2); (2, 0); (2, 3) ] in
  check_eq "3-cycle feeding a sink" show_comps [ [ 0; 1; 2 ]; [ 3 ] ] (Scc.referrers_first 4 cyc);
  check "3-cycle is cyclic" (Scc.is_cyclic cyc [ 0; 1; 2 ]);
  (* The 8-vertex example of Cormen et al., fig. 22.9: a b c d e f g h = 0..7 *)
  let clrs =
    of_edges 8
      [ (0, 1); (1, 2); (1, 4); (1, 5); (2, 3); (2, 6); (3, 2); (3, 7); (4, 0); (4, 5); (5, 6); (6, 5); (6, 7); (7, 7) ]
  in
  check_eq "CLRS 22.9 components, referrers first" show_comps [ [ 0; 1; 4 ]; [ 2; 3 ]; [ 5; 6 ]; [ 7 ] ]
    (Scc.referrers_first 8 clrs);
  check "CLRS: {h} has a self-loop" (Scc.is_cyclic clrs [ 7 ]);
  (* Two disjoint cycles and an isolated vertex. *)
  let two = of_edges 5 [ (0, 1); (1, 0); (2, 3); (3, 2) ] in
  let comps = Scc.referrers_first 5 two in
  check_eq "two disjoint cycles and an isolated vertex" string_of_int 3 (List.length comps);
  check "each 2-cycle is one component" (List.mem [ 0; 1 ] comps && List.mem [ 2; 3 ] comps && List.mem [ 4 ] comps)

let property ~seed ~graphs =
  let rng = Random.State.make [| seed |] in
  for g = 1 to graphs do
    let n = 1 + Random.State.int rng 12 in
    let edges =
      List.concat (List.init n (fun a -> List.filter_map (fun b -> if Random.State.int rng 100 < 18 then Some (a, b) else None) (List.init n Fun.id)))
    in
    let succ = of_edges n edges in
    let reach = Array.init n (fun a -> Array.init n (fun b -> a = b)) in
    List.iter (fun (a, b) -> reach.(a).(b) <- true) edges;
    for k = 0 to n - 1 do
      for i = 0 to n - 1 do
        for j = 0 to n - 1 do
          if reach.(i).(k) && reach.(k).(j) then reach.(i).(j) <- true
        done
      done
    done;
    let comps = Scc.referrers_first n succ in
    let comp_of = Array.make n (-1) in
    List.iteri (fun k c -> List.iter (fun v -> comp_of.(v) <- k) c) comps;
    let name s = Printf.sprintf "random graph %d: %s" g s in
    check (name "components partition the vertices") (Array.for_all (fun c -> c >= 0) comp_of
      && List.length (List.concat comps) = n);
    for a = 0 to n - 1 do
      for b = 0 to n - 1 do
        let same = comp_of.(a) = comp_of.(b) in
        if same <> (reach.(a).(b) && reach.(b).(a)) then check (name (Printf.sprintf "%d,%d mutual reachability" a b)) false
      done
    done;
    check (name "every edge goes forward or stays inside a component")
      (List.for_all (fun (a, b) -> comp_of.(a) <= comp_of.(b)) edges);
    check (name "cyclic iff size > 1 or self-loop")
      (List.for_all (fun c -> Scc.is_cyclic succ c = (List.length c > 1 || List.exists (fun (a, b) -> a = b && List.mem a c) edges)) comps)
  done

let () =
  known ();
  property ~seed:20260929 ~graphs:300;
  finish "test_scc"
