(* The emitter's output must compile. For random graphs, the DP's assignment
   and one random feasible assignment (which reaches Object and Module_type,
   rarely optimal) are emitted and compiled with ocamlc under the warning set
   dune uses for this project. The committed slice is compiled by
   examples/proof/dune. *)

open Harness
open Proof

let warnings = "@1..3@5..28@30..39@43@46..47@49..57@61..62@67@69@40-41-42-44-45-48-58-59-60-66-70"

let compiles name source =
  let base = Printf.sprintf "emit_%s" name in
  Out_channel.with_open_bin (base ^ ".ml") (fun oc -> output_string oc source);
  let cmd = Printf.sprintf "ocamlc -c -w %s -strict-sequence -strict-formats %s.ml 2> %s.err" warnings base base in
  let ok = Sys.command cmd = 0 in
  if not ok then Printf.printf "ocamlc failed on %s.ml:\n%s\n" base (read_file (base ^ ".err"));
  ok

let emit_for m enc =
  let vs = Evaluate.verdicts m enc in
  let stats : Certificate.search_stats =
    { components = 0; cyclic_components = 0; largest_component = 0; states_explored = 0; memo_hits = 0; branches_pruned = 0;
      infeasible_rejected = 0 }
  in
  let cert = Certificate.make m ~digest:"test" enc vs (Evaluate.cost m enc vs) stats in
  Emit.emit ~source_name:"random" m enc cert

let () =
  let rng = Random.State.make [| 20260929 + 1 |] in
  let compiled = ref 0 and recursive_groups = ref 0 and encodings = Hashtbl.create 8 in
  let has_rec source =
    let needle = "module rec " in
    let n = String.length needle in
    let rec go i = i + n <= String.length source && (String.sub source i n = needle || go (i + 1)) in
    go 0
  in
  for k = 1 to 120 do
    let g = Random_graphs.random_graph ~max_members:5 rng (1 + Random.State.int rng 7) in
    let m = Model.build g in
    let dp = (Search.run m).assignment in
    let random = Array.mapi (fun v _ -> let fs = Model.feasible m v in List.nth fs (Random.State.int rng (List.length fs))) m.nodes in
    List.iter
      (fun (label, enc) ->
        Array.iter (fun e -> Hashtbl.replace encodings e ()) enc;
        let name = Printf.sprintf "%d_%s" k label in
        let source = emit_for m enc in
        if has_rec source then incr recursive_groups;
        let ok = compiles name source in
        if ok then incr compiled;
        check ("emitted OCaml compiles: " ^ name) ok)
      [ ("dp", dp); ("random", random) ]
  done;
  let seen = Hashtbl.fold (fun e () acc -> Encoding.label e :: acc) encodings [] |> List.sort compare in
  Printf.printf "emitter: %d of %d random type graphs compiled (%d with a recursive Set/Map module group); encodings used: %s\n"
    !compiled (2 * 120) !recursive_groups (String.concat ", " seen);
  check "the recursive Set/Map path was exercised" (!recursive_groups > 0);
  check "every searchable encoding was emitted at least once"
    (List.for_all (fun e -> Hashtbl.mem encodings e) Encoding.searchable);
  finish "test_emit"
