(* authority_kernel: see the usage text. `eval` is the adapter's entry point:
   it exits 0 whenever it wrote a decision, INDETERMINATE included. A non-zero
   exit means the kernel itself failed, which the adapter treats as DENY. *)

open Authority

let usage =
  "usage:\n\
  \  authority_kernel eval [--text] [FILE]             decide one request (stdin without FILE)\n\
  \  authority_kernel scenarios FILE [--check] [--text] evaluate a scenario file\n\
  \  authority_kernel compare FILE                     conventional check vs. kernel, Markdown\n\
  \  authority_kernel surface FILE                     request space and allowed tuples (W1)\n\
  \  authority_kernel ablate FILE                      which dimension decided each scenario (W4)\n\
  \  authority_kernel request FILE NAME                the request document scenario NAME sends\n"

let die fmt = Printf.ksprintf (fun m -> prerr_endline ("authority_kernel: " ^ m); exit 2) fmt

(* Reads at most [limit] + 1 bytes: enough to tell that the input is too large
   without holding an unbounded input in memory. *)
let read_bounded ic limit =
  let buf = Buffer.create 65536 and chunk = Bytes.create 65536 in
  let rec go () =
    if Buffer.length buf <= limit then
      let n = input ic chunk 0 (min (Bytes.length chunk) (limit + 1 - Buffer.length buf)) in
      if n > 0 then (Buffer.add_subbytes buf chunk 0 n; go ())
  in
  go ();
  Buffer.contents buf

let render ~text d = if text then Explain.render d else Tjson.to_string_pretty (Codec.decision_to_json d) ^ "\n"

let eval ~text file =
  let limit = Evaluate.max_request_bytes in
  let input =
    match file with
    | None -> set_binary_mode_in stdin true; read_bounded stdin limit
    | Some path -> (try In_channel.with_open_bin path (fun ic -> read_bounded ic limit) with Sys_error m -> die "%s" m)
  in
  print_string (render ~text (Evaluate.run input))

let load path = match Scenario.load path with Ok f -> f | Error m -> die "%s" m

let scenarios ~check ~text path =
  let file = load path in
  let results = List.map (fun (s : Scenario.t) -> (s, Scenario.evaluate s)) file.scenarios in
  List.iter
    (fun ((s : Scenario.t), d) ->
      let status = if Scenario.meets s d then "ok" else "FAIL" in
      let verdict = Decision.verdict_to_string d.Decision.verdict in
      let expected = if Scenario.meets s d then "" else Printf.sprintf "  (expected %s [%s])" s.expect (String.concat ", " s.expect_reasons) in
      if text then Printf.printf "== %s: %s\n%s   %s\n%s%s\n\n" s.name verdict s.description status (render ~text:true d) expected
      else Printf.printf "%-4s %-34s %-13s %s%s\n" status s.name verdict (String.concat ", " (Scenario.codes d)) expected)
    results;
  let failed = List.length (List.filter (fun (s, d) -> not (Scenario.meets s d)) results) in
  Printf.printf "%d scenarios, %d as expected, %d not\n" (List.length results) (List.length results - failed) failed;
  if check && failed > 0 then exit 1

let request path name =
  let file = load path in
  match List.find_opt (fun (s : Scenario.t) -> s.name = name) file.scenarios with
  | Some s -> print_string (Tjson.to_string_pretty s.request ^ "\n")
  | None -> die "%s: no scenario named %S" path name

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "eval" ] -> eval ~text:false None
  | [ "eval"; "--text" ] -> eval ~text:true None
  | [ "eval"; "--text"; file ] | [ "eval"; file; "--text" ] -> eval ~text:true (Some file)
  | [ "eval"; file ] -> eval ~text:false (Some file)
  | "scenarios" :: file :: flags when List.for_all (fun f -> f = "--check" || f = "--text") flags ->
      scenarios ~check:(List.mem "--check" flags) ~text:(List.mem "--text" flags) file
  | [ "compare"; file ] -> Compare.run file (load file)
  | [ "surface"; file ] -> Surface.run file (load file)
  | [ "ablate"; file ] -> Ablate.run file (load file)
  | [ "request"; file; name ] -> request file name
  | _ -> prerr_string usage; exit 2
