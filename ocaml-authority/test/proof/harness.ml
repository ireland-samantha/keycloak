(* Minimal test harness: named checks, a failure count, non-zero exit on failure. *)

let failures = ref 0
let passed = ref 0

let check name ok =
  if ok then incr passed
  else begin
    incr failures;
    Printf.printf "FAIL %s\n%!" name
  end

let check_eq name show expected actual =
  if expected = actual then incr passed
  else begin
    incr failures;
    Printf.printf "FAIL %s: expected %s, got %s\n%!" name (show expected) (show actual)
  end

let finish suite =
  Printf.printf "%s: %d checks passed, %d failed\n" suite !passed !failures;
  if !failures > 0 then exit 1

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* The committed slice, as a test dependency. *)
let real_graph_path = "../../examples/proof/keycloak-authz.graph.json"

let real_graph () =
  match Proof.Jgraph.of_string (read_file real_graph_path) with
  | Ok x -> x
  | Error e -> failwith ("cannot load the committed graph: " ^ e)
