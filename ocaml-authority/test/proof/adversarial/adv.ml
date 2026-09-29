(* Shared harness for the adversarial suites of attempt_proof.

   Three kinds of checks:
   - [check]: a property that must hold (a held attack, or a fixed bug).
   - [known_weakness]: an attack that succeeds by construction. The test pins
     the weak behaviour as observed, so it passes while the weakness is open
     and fails, asking for an update, if the behaviour changes.
   - [report]: a verdict printed for the record.

   The Java-based suites run the real extractor, tools/java-graph/JavaGraph.java,
   located by walking up from the build directory to the source tree. *)

open Proof

let failures = ref 0
let passed = ref 0
let weaknesses = ref 0

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

let known_weakness name ~detail pinned =
  if pinned then begin
    incr passed;
    incr weaknesses;
    Printf.printf "OPEN %s: %s\n%!" name detail
  end
  else begin
    incr failures;
    Printf.printf "FAIL %s: the pinned weakness no longer reproduces (%s); update the test and the review\n%!" name
      detail
  end

let report fmt = Printf.printf (fmt ^^ "\n%!")

let finish suite =
  Printf.printf "%s: %d checks passed (%d pin an open weakness), %d failed\n" suite !passed !weaknesses !failures;
  if !failures > 0 then exit 1

let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  go 0

(* ---------- the source tree and the JDK ---------- *)

let source_root =
  lazy
    (let rec up dir =
       if Sys.file_exists (Filename.concat dir "tools/java-graph/JavaGraph.java") then dir
       else
         let parent = Filename.dirname dir in
         if parent = dir then failwith "adversarial: cannot find tools/java-graph/JavaGraph.java above the build directory"
         else up parent
     in
     up (Sys.getcwd ()))

let run_quiet cmd log = Sys.command (Printf.sprintf "%s > %s 2>&1" cmd log) = 0

(* The extractor, compiled once per test process into its own directory. *)
let extractor =
  lazy
    (let dir = "jg-" ^ Filename.remove_extension (Filename.basename Sys.executable_name) in
     let src = Filename.concat (Lazy.force source_root) "tools/java-graph/JavaGraph.java" in
     let log = dir ^ ".log" in
     if not (run_quiet (Printf.sprintf "rm -rf %s && mkdir -p %s && javac -d %s %s" dir dir dir (Filename.quote src)) log) then
       failwith ("adversarial: javac failed on JavaGraph.java (a JDK is required):\n" ^ read_file log);
     dir)

(* Run the real extractor on [files] (paths relative to this directory). *)
let extract_result ~name files : (Jgraph.t * string, string) result =
  let classes = Lazy.force extractor in
  let out = name ^ ".graph.json" and log = name ^ ".extract.log" in
  let cmd =
    Printf.sprintf "java -cp %s JavaGraph --root . --commit adversarial --out %s %s" classes out
      (String.concat " " (List.map Filename.quote files))
  in
  if not (run_quiet cmd log) then Error (read_file log)
  else match Jgraph.of_string (read_file out) with Ok x -> Ok x | Error e -> Error ("decode: " ^ e)

let extract ~name files =
  match extract_result ~name files with Ok x -> x | Error e -> failwith ("extractor failed on " ^ name ^ ":\n" ^ e)

let java_files dir =
  Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".java") |> List.sort compare
  |> List.map (Filename.concat dir)

(* Compile Java fixtures and run a main class; returns stdout+stderr. *)
let run_java ~name ~files ~main =
  let dir = name ^ "-classes" and log = name ^ ".java.log" in
  let files = String.concat " " (List.map Filename.quote files) in
  if not (run_quiet (Printf.sprintf "rm -rf %s && mkdir -p %s && javac -encoding UTF-8 -Xlint:none -d %s %s" dir dir dir files) log)
  then failwith ("javac failed on the " ^ name ^ " fixtures:\n" ^ read_file log);
  ignore (run_quiet (Printf.sprintf "java -cp %s %s" dir main) log);
  read_file log

let javac_accepts ~name files =
  let dir = name ^ "-javac" and log = name ^ ".javac.log" in
  run_quiet
    (Printf.sprintf "rm -rf %s && mkdir -p %s && javac -encoding UTF-8 -Xlint:none -d %s %s" dir dir dir
       (String.concat " " (List.map Filename.quote files)))
    log

(* ---------- running attempt_proof ---------- *)

type run = {
  model : Model.t;
  cert : Certificate.t;
  digest : string;
  graph : Jgraph.t;
  entry : string -> Certificate.entry option;
  verdict : string -> Encoding.verdict option;
  encoding : string -> Encoding.t;
}

let prove (g, digest) =
  let model = Model.build g in
  let result = Attempt.attempt_proof ~model g ~digest in
  let _, cert = Attempt.parts result in
  let entry id = List.find_opt (fun (e : Certificate.entry) -> e.obligation = id) cert.entries in
  {
    model;
    cert;
    digest;
    graph = g;
    entry;
    verdict = (fun id -> Option.map (fun (e : Certificate.entry) -> e.verdict) (entry id));
    encoding = (fun id -> (Attempt.parts result |> fst).assignment.(Model.node model id));
  }

let show_verdict = function None -> "(no such obligation)" | Some v -> Encoding.verdict_to_string v
let show_opt = function None -> "none" | Some s -> s

(* Print and check one verdict. *)
let expect r name id expected =
  let got = r.verdict id in
  report "  %-13s %s" (show_verdict got) id;
  check_eq (name ^ ": " ^ id) show_verdict (Some expected) got

let ocaml_of r id = Option.bind (r.entry id) (fun (e : Certificate.entry) -> e.ocaml)

(* Every obligation of [owner] (optionally only one member), printed. *)
let dump r ?member owner =
  List.iter
    (fun (e : Certificate.entry) ->
      if e.owner = owner && (member = None || e.member = member) then
        report "  %-13s %s%s" (Encoding.verdict_to_string e.verdict) e.obligation
          (match e.ocaml with Some t -> "  : " ^ t | None -> ""))
    r.cert.entries

(* ---------- compiling emitted OCaml ---------- *)

(* The warning set dune uses for this project (see test/proof/test_emit.ml). *)
let warnings = "@1..3@5..28@30..39@43@46..47@49..57@61..62@67@69@40-41-42-44-45-48-58-59-60-66-70"

let emit_source r = Emit.emit ~source_name:"adversarial" r.model (Array.init (Array.length r.model.nodes) (fun v -> r.encoding r.model.nodes.(v).id)) r.cert

let ocaml_compiles ~name source =
  let base = "adv_emit_" ^ name in
  write_file (base ^ ".ml") source;
  let ok =
    run_quiet (Printf.sprintf "ocamlc -c -w %s -strict-sequence -strict-formats %s.ml" warnings base) (base ^ ".err")
  in
  (ok, if ok then "" else read_file (base ^ ".err"))
