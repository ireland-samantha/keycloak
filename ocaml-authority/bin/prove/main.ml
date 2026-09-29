(* prove GRAPH.json [--certificate OUT.json] [--emit OUT.ml] [--report]
   prove --check GRAPH.json CERT.json

   The first form runs attempt_proof on a java-source-graph/v1 file. The second
   runs only the certificate checker. Exit status: 0 on success (a refutation is
   a result, not a failure), 1 if the checker rejects, 2 on usage or input errors. *)

open Proof

let usage =
  "usage: prove GRAPH.json [--certificate OUT.json] [--emit OUT.ml] [--report]\n       prove --check GRAPH.json CERT.json"

let die code fmt = Printf.ksprintf (fun s -> prerr_endline s; exit code) fmt

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all with Sys_error e -> die 2 "prove: %s" e

let write_file path contents =
  try Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
  with Sys_error e -> die 2 "prove: %s" e

let load_graph path =
  match Jgraph.of_string (read_file path) with Ok x -> x | Error e -> die 2 "prove: %s: %s" path e

let check graph_path cert_path =
  let g, digest = load_graph graph_path in
  let cert = match Certificate.of_string (read_file cert_path) with Ok c -> c | Error e -> die 2 "prove: %s: %s" cert_path e in
  match Certificate.check g ~digest cert with
  | Ok a ->
      Printf.printf "accepted: %d obligations, cost %s, result %s\n" a.obligations (Encoding.cost_to_string a.cost)
        (Certificate.result_to_string a.result);
      List.iter (fun (v, n) -> Printf.printf "  %-13s %d\n" (Encoding.verdict_to_string v) n) a.counts
  | Error errs ->
      let n = List.length errs in
      Printf.printf "rejected: %d error%s\n" n (if n = 1 then "" else "s");
      List.iter (fun e -> Printf.printf "  %s\n" e) errs;
      exit 1

let prove graph_path ~certificate ~emit ~report =
  let g, digest = load_graph graph_path in
  let source_name = Filename.basename graph_path in
  let model = Model.build g in
  let result = Attempt.attempt_proof ~model g ~digest in
  let graph, cert = Attempt.parts result in
  Option.iter (fun path -> write_file path (Tjson.to_string_pretty (Certificate.to_json cert) ^ "\n")) certificate;
  Option.iter (fun path -> write_file path (Emit.emit ~source_name model graph.assignment cert ^ "\n")) emit;
  if report then
    print_string (Report.render ~source_name model graph.assignment cert ~check:(Certificate.check g ~digest cert))
  else
    let counts = Certificate.counts (List.map (fun (e : Certificate.entry) -> e.verdict) cert.entries) in
    Printf.printf "%s: %s, cost %s; %s\n" source_name
      (String.uppercase_ascii (Certificate.result_to_string cert.result))
      (Encoding.cost_to_string cert.cost)
      (String.concat ", " (List.map (fun (v, n) -> Printf.sprintf "%s %d" (Encoding.verdict_to_string v) n) counts))

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--check"; graph; cert ] -> check graph cert
  | graph :: rest when String.length graph > 0 && graph.[0] <> '-' ->
      let rec opts cert emit report = function
        | [] -> (cert, emit, report)
        | "--certificate" :: path :: rest -> opts (Some path) emit report rest
        | "--emit" :: path :: rest -> opts cert (Some path) report rest
        | "--report" :: rest -> opts cert emit true rest
        | arg :: _ -> die 2 "prove: unexpected argument %s\n%s" arg usage
      in
      let certificate, emit, report = opts None None false rest in
      prove graph ~certificate ~emit ~report
  | _ -> die 2 "%s" usage
