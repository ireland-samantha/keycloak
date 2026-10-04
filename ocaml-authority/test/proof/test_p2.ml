(* Hypothesis P2 (docs/hypothesis.md): the dynamic programming is real.

   (a) On randomized small graphs the DP's cost equals exhaustive enumeration.
       The DP scores incrementally through demands; brute force scores complete
       assignments with Evaluate, the checker's global reading of the rules.
       The DP's own per-obligation verdicts must also equal Evaluate's.
   (b) On a constructed graph, greedy per-node choice yields strictly more
       REFUTED obligations than the DP.
   (d) Memoization hits on the real slice.
   (c), the checker rejecting mutated certificates, is in test_certificate. *)

open Harness
open Gb
open Proof

let seed = 20260929

let random_graph = Random_graphs.random_graph

let dp_equals_brute_force ~graphs =
  let rng = Random.State.make [| seed |] in
  let assignments = ref 0 and states = ref 0 and hits = ref 0 and pruned = ref 0 and obligations = ref 0 in
  let with_subtypes = ref 0 and with_bounds = ref 0 and cyclic = ref 0 and with_open = ref 0 and multi = ref 0 in
  for k = 1 to graphs do
    let n = 1 + Random.State.int rng 7 in
    let g = random_graph rng n in
    let m = Model.build g in
    let dp = Search.run m in
    let _, bf_cost, count = Baselines.brute_force m in
    let name s = Printf.sprintf "random graph %d (%d nodes): %s" k n s in
    check_eq (name "DP cost = brute-force optimum") Encoding.cost_to_string bf_cost dp.cost;
    let global = Evaluate.verdicts m dp.assignment in
    check (name "DP verdicts = global evaluation of the DP's assignment") (global = dp.verdicts);
    check_eq (name "DP cost = global cost of the DP's assignment") Encoding.cost_to_string
      (Evaluate.cost m dp.assignment global) dp.cost;
    check (name "DP assignment is structurally valid") (Evaluate.structural_errors m dp.assignment = []);
    assignments := !assignments + count;
    states := !states + dp.stats.states_explored;
    hits := !hits + dp.stats.memo_hits;
    pruned := !pruned + dp.stats.branches_pruned;
    obligations := !obligations + Array.length m.obligations;
    if Array.exists (fun (o : Obligation.t) -> o.kind = Obligation.Subtype) m.obligations then incr with_subtypes;
    if Array.exists (fun (o : Obligation.t) -> o.kind = Obligation.Bounded) m.obligations then incr with_bounds;
    if Model.cyclic_count m > 0 then incr cyclic;
    if Model.largest_component m > 1 then incr multi;
    if Array.exists (fun (o : Obligation.t) -> o.kind = Obligation.Open) m.obligations then incr with_open
  done;
  Printf.printf
    "P2(a): %d random graphs (seed %d, 1-7 nodes, %d obligations; %d with Subtype, %d with Bounded, %d with Open, %d with a cyclic component, %d with a component of 2+ types)\n"
    graphs seed !obligations !with_subtypes !with_bounds !with_open !cyclic !multi;
  Printf.printf "P2(a): brute force scored %d assignments; the DP explored %d states, %d memo hits, %d branches pruned\n"
    !assignments !states !hits !pruned

let greedy_is_worse () =
  (* A bound forces Ctx to be an object type, and a Set forces HookProvider to be
     comparable. Locally, Ctx prefers Record (cheaper) and HookProvider prefers
     Closures (Open is PROVEN only for behavioural encodings). *)
  let g =
    graph
      [
        jtype ~type_params:[ ("D", [ slice "Ctx" ]) ] "Decider" [ command ~params:[ param "d" (var "D") ] "decide" ];
        jtype "Ctx" [ getter "getName" string_ ];
        jtype "HookProvider" [ getter "getName" string_ ];
        jtype "Registry" [ getter "getHooks" (set_ (slice "HookProvider")) ];
      ]
  in
  let m = Model.build g in
  let dp = Search.run m in
  let greedy = Baselines.greedy m in
  let gcost = Baselines.score m greedy in
  let _, bf, _ = Baselines.brute_force m in
  Printf.printf "P2(b): constructed graph: DP %s, greedy %s, brute force %s\n" (Encoding.cost_to_string dp.cost)
    (Encoding.cost_to_string gcost) (Encoding.cost_to_string bf);
  check "P2(b): greedy has strictly more REFUTED than the DP" (gcost.refuted > dp.cost.refuted);
  check_eq "P2(b): DP refutes nothing here" string_of_int 0 dp.cost.refuted;
  check_eq "P2(b): DP = brute force" Encoding.cost_to_string bf dp.cost

let real_slice () =
  let g, digest = real_graph () in
  let m = Model.build g in
  let dp = Search.run m in
  let greedy = Baselines.score m (Baselines.greedy m) in
  Printf.printf "P2(d): real slice: %d components, %d states explored, %d memo hits, %d branches pruned\n"
    (Array.length m.components) dp.stats.states_explored dp.stats.memo_hits dp.stats.branches_pruned;
  Printf.printf "P2(b) on the real slice: DP %s, greedy %s\n" (Encoding.cost_to_string dp.cost)
    (Encoding.cost_to_string greedy);
  check "P2(d): memo hits > 0 on the real slice" (dp.stats.memo_hits > 0);
  check "real slice: DP verdicts = global evaluation" (Evaluate.verdicts m dp.assignment = dp.verdicts);
  check "real slice: greedy has strictly more REFUTED than the DP" (greedy.refuted > dp.cost.refuted);
  (* Deterministic: a second run reproduces the certificate exactly. *)
  let cert () = Attempt.parts (Attempt.attempt_proof g ~digest) |> snd |> Certificate.to_json |> Tjson.to_string in
  check "real slice: attempt_proof is deterministic" (cert () = cert ())

let () =
  dp_equals_brute_force ~graphs:250;
  greedy_is_worse ();
  real_slice ();
  finish "test_p2"
