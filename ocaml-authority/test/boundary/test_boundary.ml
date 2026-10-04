(* Adversarial tests of the kernel's side of the trust boundary: the strict
   JSON parser (lib/json), the wire codec (lib/authority/codec.ml) and the
   CLI's stdin handling (bin/authority_kernel). Each case is an attack; the
   run fails if any case raises or any assertion fails.

   Arguments: the base request (examples/requests/02-delegated-generate.json,
   which the kernel allows) and the kernel executable. *)

open Authority
module J = Tjson

let failures = ref 0
let count = ref 0

let case name f =
  incr count;
  match f () with
  | () -> ()
  | exception e ->
      incr failures;
      Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string e)

exception Assertion of string

let check what ok = if not ok then raise (Assertion what)
let fail fmt = Printf.ksprintf (fun m -> raise (Assertion m)) fmt

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

(* Replaces the first occurrence of [sub] in [s]. *)
let replace sub by s =
  let n = String.length sub in
  let rec find i = if i + n > String.length s then failwith ("not found: " ^ sub) else if String.sub s i n = sub then i else find (i + 1) in
  let i = find 0 in
  String.sub s 0 i ^ by ^ String.sub s (i + n) (String.length s - i - n)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let base = String.trim (read_file Sys.argv.(1))
let kernel = Sys.argv.(2)
let verdict (d : Decision.t) = Decision.verdict_to_string d.verdict
let codes (d : Decision.t) = List.map (fun (r : Decision.reason) -> Decision.reason_code_to_string r.code) (Decision.reasons d)
let message (d : Decision.t) = String.concat "; " (List.map (fun (r : Decision.reason) -> r.message) (Decision.reasons d))
let show d = Printf.sprintf "%s [%s] %s" (verdict d) (String.concat ", " (codes d)) (message d)

let expect_malformed ?fragment what input =
  let d = Evaluate.run input in
  if codes d <> [ "malformed_request" ] || verdict d <> "indeterminate" then fail "%s: expected malformed_request, got %s" what (show d);
  match fragment with
  | Some f when not (contains (message d) f) -> fail "%s: message %S lacks %S" what (message d) f
  | _ -> ()

let expect_decodes what input =
  match Codec.parse_request input with Ok _ -> () | Error m -> fail "%s: expected to decode, got %s" what m

let () =
  case "baseline: the base request decodes and is allowed" (fun () ->
      let d = Evaluate.run base in
      check (show d) (verdict d = "allow"))

(* ---------- tree surgery on the base request ---------- *)

let base_json = match J.parse base with Ok v -> v | Error e -> failwith (Printf.sprintf "base: byte %d: %s" e.offset e.message)

type step = K of string | I of int

let rec update steps f v =
  match (steps, v) with
  | [], v -> f v
  | K k :: rest, J.Object kvs -> J.Object (List.map (fun (k', x) -> if k' = k then (k', update rest f x) else (k', x)) kvs)
  | I i :: rest, J.Array xs -> J.Array (List.mapi (fun j x -> if j = i then update rest f x else x) xs)
  | _ -> failwith "update: no such path"

let rec nodes prefix v =
  (List.rev prefix, v)
  ::
  (match v with
  | J.Object kvs -> List.concat_map (fun (k, x) -> nodes (K k :: prefix) x) kvs
  | J.Array xs -> List.concat (List.mapi (fun i x -> nodes (I i :: prefix) x) xs)
  | _ -> [])

let all_nodes = nodes [] base_json
let path_string steps = "$" ^ String.concat "" (List.map (function K k -> "." ^ k | I i -> Printf.sprintf "[%d]" i) steps)
let kind = function J.Null -> 0 | Bool _ -> 1 | Number _ -> 2 | String _ -> 3 | Array _ -> 4 | Object _ -> 5
let replacements = [ J.Null; Bool true; Number "0"; String "x"; Array []; Object [] ]

(* The grant whose delegable_depth governs the base request's delegation. *)
let grant_index id =
  let rec go i = function
    | [] -> failwith ("no grant " ^ id)
    | (J.Object kvs) :: rest -> if List.assoc_opt "id" kvs = Some (J.String id) then i else go (i + 1) rest
    | _ :: rest -> go (i + 1) rest
  in
  match base_json with
  | J.Object kvs -> (
      match List.assoc "ledger" kvs with J.Object l -> (match List.assoc "grants" l with J.Array gs -> go 0 gs | _ -> assert false) | _ -> assert false)
  | _ -> assert false

let with_depth lexeme =
  let i = grant_index "g-samantha-generate" in
  J.to_string (update [ K "ledger"; K "grants"; I i; K "delegable_depth" ] (fun _ -> J.Number lexeme) base_json)

let with_value steps v = J.to_string (update steps (fun _ -> v) base_json)

(* ---------- malformed requests ---------- *)

let () =
  case "malformed: every proper prefix of the request is malformed, never allowed" (fun () ->
      for i = 0 to String.length base - 1 do
        let d = Evaluate.run (String.sub base 0 i) in
        if codes d <> [ "malformed_request" ] then fail "prefix of %d bytes: %s" i (show d)
      done);
  (* Every node, replaced by a value of every other JSON kind. A non-null
     value of the wrong kind must be malformed. null is tolerated only where
     the codec documents an optional field. *)
  case "malformed: a wrong JSON type at any node is malformed_request" (fun () ->
      List.iter
        (fun (steps, v) ->
          List.iter
            (fun r ->
              if kind r <> kind v && r <> J.Null then expect_malformed (path_string steps ^ " := " ^ J.to_string r) (with_value steps r))
            replacements)
        all_nodes);
  case "malformed: null is tolerated only on optional fields (absent = null)" (fun () ->
      let optional = [ "request_id"; "mandate"; "effect"; "realm"; "valid_from"; "valid_until"; "delegable_depth"; "provenance"; "revocations"; "prohibitions" ] in
      List.iter
        (fun (steps, v) ->
          if v <> J.Null && steps <> [] then
            match Codec.parse_request (with_value steps J.Null) with
            | Error _ -> ()
            | Ok _ -> (
                match List.rev steps with
                | K k :: _ when List.mem k optional -> ()
                | _ -> fail "%s := null decodes, but the field is not optional" (path_string steps)))
        all_nodes);
  case "malformed: an extra field in any object is malformed_request" (fun () ->
      List.iter
        (fun (steps, v) ->
          match v with
          | J.Object _ ->
              let extra = J.to_string (update steps (function J.Object kvs -> J.Object (kvs @ [ ("zz_extra", J.Number "1") ]) | x -> x) base_json) in
              expect_malformed (path_string steps ^ " + zz_extra") extra
          | _ -> ())
        all_nodes);
  case "malformed: nesting is bounded (64 levels parse, 66 do not)" (fun () ->
      let nest n = String.make n '[' ^ String.make n ']' in
      check "64 levels parse" (Result.is_ok (J.parse (nest 64)));
      check "66 levels are rejected" (Result.is_error (J.parse (nest 66))));
  case "malformed: 500k levels of nesting (1 MB) are rejected without a stack overflow" (fun () ->
      let n = 500_000 in
      expect_malformed ~fragment:"maximum nesting depth" "deep array" (String.make n '[' ^ String.make n ']');
      expect_malformed ~fragment:"maximum nesting depth" "deep value in facts.realm"
        (replace {|"realm": "typed-authority-demo"|} ({|"realm": |} ^ String.make 100_000 '[' ^ String.make 100_000 ']') base));
  case "malformed: 1 MiB + 1 byte is request_too_large, exactly 1 MiB is decided" (fun () ->
      let pad n = base ^ String.make (n - String.length base) ' ' in
      check "1 MiB + 1" (codes (Evaluate.run (pad (Evaluate.max_request_bytes + 1))) = [ "request_too_large" ]);
      check "1 MiB" (verdict (Evaluate.run (pad Evaluate.max_request_bytes)) = "allow"));
  case "malformed: NUL bytes" (fun () ->
      expect_malformed ~fragment:"unescaped control character" "raw NUL in a string" (replace "for internal review" "for internal\000review" base);
      expect_malformed "raw NUL between tokens" (replace {|"schema":|} "\000\"schema\":" base);
      expect_malformed "raw NUL after the document" (base ^ "\000");
      expect_malformed ~fragment:"$.facts.subject.id" "\\u0000 in a principal id" (replace {|"id": "samantha"|} {|"id": "saman\u0000tha"|} base);
      (* In free text, \u0000 is a character like any other: it decodes and is re-encoded escaped. *)
      let r = Result.get_ok (Codec.parse_request (replace "for internal review" {|for internal\u0000review|} base)) in
      check "re-encoded as \\u0000" (contains (J.to_string (Codec.request_to_json r)) {|internal\u0000review|}));
  case "malformed: invalid, overlong and surrogate UTF-8 in a string" (fun () ->
      List.iter
        (fun (name, bytes) -> expect_malformed ~fragment:"byte " ("UTF-8 " ^ name) (replace "for internal review" ("for internal " ^ bytes ^ " review") base))
        [ ("continuation byte as lead", "\x80");
          ("0xFF", "\xFF");
          ("0xFE", "\xFE");
          ("truncated 2-byte", "\xC3");
          ("truncated 3-byte", "\xE2\x82");
          ("bad continuation", "\xC3\x28");
          ("overlong '/' (C0 AF)", "\xC0\xAF");
          ("overlong NUL (C0 80)", "\xC0\x80");
          ("overlong (C1 BF)", "\xC1\xBF");
          ("overlong 3-byte (E0 80 AF)", "\xE0\x80\xAF");
          ("overlong 4-byte (F0 80 80 AF)", "\xF0\x80\x80\xAF");
          ("encoded high surrogate (ED A0 80)", "\xED\xA0\x80");
          ("encoded low surrogate (ED BF BF)", "\xED\xBF\xBF");
          ("above U+10FFFF (F4 90 80 80)", "\xF4\x90\x80\x80");
          ("lead F5", "\xF5\x80\x80\x80");
          ("lead F8", "\xF8\x88\x80\x80\x80") ];
      (* truncated at the very end of the input, where no closing quote follows *)
      expect_malformed "truncated sequence at end of input" "{\"a\":\"\xE2\x82";
      List.iter
        (fun (name, bytes) -> expect_decodes ("UTF-8 " ^ name) (replace "for internal review" ("for internal " ^ bytes ^ " review") base))
        [ ("e acute", "\xC3\xA9"); ("U+FFFF", "\xEF\xBF\xBF"); ("emoji", "\xF0\x9F\x98\x80"); ("U+10FFFF", "\xF4\x8F\xBF\xBF"); ("BOM inside a string", "\xEF\xBB\xBF") ]);
  case "malformed: lone surrogates in \\u escapes" (fun () ->
      List.iter
        (fun esc -> expect_malformed ~fragment:"surrogate" ("escape " ^ esc) (replace "for internal review" ("for internal " ^ esc ^ " review") base))
        [ {|\ud800|}; {|\udbff|}; {|\udc00|}; {|\udfff|}; {|\ud800A|}; {|\ud800\ud800|}; {|\udc00\ud800|} ];
      expect_malformed "high surrogate escape at the end of the input" {|{"a":"\ud800|};
      expect_decodes "a valid surrogate pair" (replace "for internal review" {|for internal 😀 review|} base));
  case "malformed: delegable_depth numbers" (fun () ->
      List.iter
        (fun lexeme -> expect_malformed ~fragment:"delegable_depth" ("delegable_depth " ^ lexeme) (with_depth lexeme))
        [ "99999999999999999999"; "4611686018427387904"; "-1"; "-4611686018427387904"; "1e2"; "1E2"; "1e0"; "1.0"; "100.0"; "1e400"; "0.5" ];
      expect_malformed "delegable_depth as a string" (with_value [ K "ledger"; K "grants"; I (grant_index "g-samantha-generate"); K "delegable_depth" ] (J.String "1"));
      check "max_int decodes and allows" (verdict (Evaluate.run (with_depth "4611686018427387903")) = "allow");
      (* -0 is the integer 0: the parent can no longer delegate. *)
      let d = Evaluate.run (with_depth "-0") in
      check ("-0 is 0: " ^ show d) (verdict d = "deny" && List.mem "delegation_depth_exceeded" (codes d)));
  case "malformed: timestamps" (fun () ->
      let at s = replace {|"evaluated_at": "2026-09-29T12:00:00Z"|} (Printf.sprintf {|"evaluated_at": "%s"|} s) base in
      List.iter
        (fun s -> expect_malformed ~fragment:"$.facts.evaluated_at" ("timestamp " ^ s) (at s))
        [ "2026-02-29T00:00:00Z"; "2100-02-29T00:00:00Z"; "2026-09-29T24:00:00Z"; "2026-12-31T23:59:60Z"; "2026-09-29T12:00:00z";
          "2026-09-29t12:00:00Z"; "2026-09-29T12:00:00+00:00"; "2026-09-29T12:00:00.000Z"; "2026-09-29T12:00Z"; "2026-9-29T12:00:00Z";
          " 2026-09-29T12:00:00Z"; "2026-09-29 12:00:00Z"; "+2026-09-29T12:00:00Z"; "-026-09-29T12:00:00Z"; "+10000-01-01T00:00:00Z";
          "2026-00-10T00:00:00Z"; "2026-13-01T00:00:00Z"; "2026-04-31T00:00:00Z"; "2026-09-00T00:00:00Z"; "2026-09-29T12:60:00Z";
          "\xD9\xA2026-09-29T12:00:00Z"; "" ];
      List.iter
        (fun s ->
          expect_decodes ("timestamp " ^ s) (at s);
          match Timestamp.of_string s with
          | Ok t -> check ("round trip " ^ s) (Timestamp.to_string t = s)
          | Error m -> fail "%s: %s" s m)
        [ "2028-02-29T00:00:00Z"; "2000-02-29T12:00:00Z"; "2026-12-31T23:59:59Z"; "0000-01-01T00:00:00Z"; "9999-12-31T23:59:59Z" ];
      (* A JSON escape is the character it denotes. *)
      expect_decodes "escaped digit" (at {|2026-09-29T12:00:00Z|}));
  case "malformed: identifiers" (fun () ->
      let resource s = replace {|"resource": "q3-report"|} (Printf.sprintf {|"resource": "%s"|} s) base in
      expect_decodes "128 characters" (resource (String.make 128 'r'));
      expect_malformed ~fragment:"129 characters" "129 characters" (resource (String.make 129 'r'));
      List.iter
        (fun s -> expect_malformed ~fragment:"$.query.resource" ("resource id " ^ s) (resource s))
        [ ""; "q3 report"; "q3-report "; "q3\\treport"; "q3\\u0000report"; "q3/report"; "q3#report"; "q\xD0\xB03-report"; "q3-r\xC3\xA9port"; "q3-report\\n" ];
      expect_decodes "every allowed punctuation character" (resource "a.b_c:d@e-f"));
  case "malformed: a BOM before the document is malformed" (fun () -> expect_malformed "UTF-8 BOM" ("\xEF\xBB\xBF" ^ base))

(* ---------- parser differentials: the same bytes, as tjson reads them ----------
   The adapter never hands raw ledger text to the kernel: it parses the policy
   config with Jackson and re-serialises the tree. For each input below the
   kernel sees either Jackson's re-serialisation (when Jackson accepts) or the
   raw text as a JSON string (when Jackson rejects). The Java side of this
   table is ParserDifferentialTest; both must agree on "reject" or on the same
   meaning. *)

let ledger_text = match base_json with J.Object kvs -> J.to_string (List.assoc "ledger" kvs) | _ -> assert false
let with_raw_ledger text = replace ledger_text text (J.to_string base_json)

let () =
  let compact = J.to_string base_json in
  let raw name ledger = (name, with_raw_ledger ledger) in
  let differential =
    [ raw "duplicate top-level key" (replace {|"grants":|} {|"grants":[],"grants":|} ledger_text);
      raw "duplicate key inside a grant" (replace {|"id":"g-samantha-generate"|} {|"id":"g-samantha-generate","id":"g-samantha-read"|} ledger_text);
      raw "duplicate key spelled with an escape" (replace {|"grants":|} {|"grants":[],"grants":|} ledger_text);
      raw "trailing comma" (replace {|"prohibitions":[]|} {|"prohibitions":[],|} ledger_text);
      raw "comment" (replace {|"prohibitions":[]|} {|"prohibitions":[] /* none */|} ledger_text);
      raw "NaN" (replace {|"delegable_depth":1|} {|"delegable_depth":NaN|} ledger_text);
      raw "Infinity" (replace {|"delegable_depth":1|} {|"delegable_depth":Infinity|} ledger_text);
      raw "leading zero" (replace {|"delegable_depth":1|} {|"delegable_depth":01|} ledger_text);
      raw "single quotes" (replace {|"prohibitions"|} {|'prohibitions'|} ledger_text);
      raw "BOM before the ledger" ("\xEF\xBB\xBF" ^ ledger_text);
      raw "vertical tab as whitespace" (replace {|"prohibitions":|} "\"prohibitions\":\x0B" ledger_text);
      raw "NBSP as whitespace" (replace {|"prohibitions":|} "\"prohibitions\":\xC2\xA0" ledger_text) ]
  in
  case "differential: tjson rejects every ambiguous or non-standard ledger text" (fun () ->
      List.iter (fun (name, input) -> expect_malformed name input) differential);
  (* 1e2: Jackson reads a DoubleNode and writes 100.0; -0 becomes 0; 1E400 becomes "Infinity". *)
  case "differential: numbers mean the same before and after Jackson's re-serialisation" (fun () ->
      let depth lexeme = with_raw_ledger (replace {|"delegable_depth":1|} ("\"delegable_depth\":" ^ lexeme) ledger_text) in
      List.iter
        (fun (raw, jackson) ->
          let a = Evaluate.run (depth raw) and b = Evaluate.run (depth jackson) in
          if codes a <> codes b || verdict a <> verdict b then fail "%s: %s but Jackson's %s: %s" raw (show a) jackson (show b))
        [ ("1e2", "100.0"); ("1E2", "100.0"); ("1.0", "1.0"); ("-0", "0"); ("1e400", {|"Infinity"|}); ("99999999999999999999", "99999999999999999999") ]);
  (* Jackson, as the adapter configures it, rejects every one of these too. *)
  case "differential: non-standard number lexemes are rejected" (fun () ->
      List.iter
        (fun lexeme -> expect_malformed ("lexeme " ^ lexeme) (with_raw_ledger (replace {|"delegable_depth":1|} ("\"delegable_depth\":" ^ lexeme) ledger_text)))
        [ "+1"; ".5"; "1."; "1e"; "1e+"; "0x10"; "1_000"; "-Infinity"; "--1"; "- 1"; "00" ]);
  case "differential: \\u0000 in a ledger id is rejected on both sides" (fun () ->
      expect_malformed ~fragment:"id" "NUL in grant id" (with_raw_ledger (replace {|"id":"g-samantha-generate"|} {|"id":"g-samantha\u0000-generate"|} ledger_text)));
  case "differential: a lone surrogate that Jackson re-serialises as \\uD800 is rejected" (fun () ->
      expect_malformed ~fragment:"surrogate" "Jackson's \\uD800" (with_raw_ledger (replace {|"purpose":"Produce|} {|"purpose":"\uD800Produce|} ledger_text)));
  case "differential: the compact re-serialisation is decided like the original" (fun () ->
      check "same verdict" (verdict (Evaluate.run compact) = verdict (Evaluate.run base)))

(* ---------- resource use ---------- *)

let many_keys_request n =
  let b = Buffer.create (n * 10) in
  Buffer.add_string b {|{"schema":"typed-authority/request/v1","query":{"mandate":{|};
  for i = 0 to n - 1 do
    if i > 0 then Buffer.add_char b ',';
    Printf.bprintf b {|"k%d":0|} i
  done;
  Buffer.add_string b {|},"capability":{"resource_type":"document","action":"read"},"resource":"q3-report"},"facts":{},"ledger":{}}|};
  Buffer.contents b

let () =
  (* A confidential client controls the pushed claims, and the adapter
     forwards a non-string claim value (an object) as JSON. Duplicate-key
     detection must not be quadratic in the number of keys, or a request just
     under 1 MiB keeps the kernel busy far beyond the adapter's 2 s timeout. *)
  case "resources: a 1 MiB object with ~96k distinct keys is rejected within 2 s" (fun () ->
      let input = many_keys_request 96_000 in
      check "input is under 1 MiB" (String.length input <= Evaluate.max_request_bytes);
      let t0 = Sys.time () in
      let d = Evaluate.run input in
      let dt = Sys.time () -. t0 in
      check (show d) (codes d = [ "malformed_request" ]);
      if dt > 2.0 then fail "took %.1f s of CPU" dt)

(* The decision document is JSON, so it must be valid UTF-8 whatever the
   request was: tjson (a strict reader) must accept every decision the kernel
   writes, including those answering garbage. *)
let () =
  case "output: every decision document is strict JSON (valid UTF-8), even for garbage input" (fun () ->
      List.iter
        (fun (name, input) ->
          let doc = J.to_string_pretty (Codec.decision_to_json (Evaluate.run input)) in
          match J.parse doc with Ok _ -> () | Error e -> fail "%s: decision is not strict JSON: byte %d: %s" name e.offset e.message)
        [ ("0xFF where a value starts", "\xFF");
          ("0xFE 0xFF (UTF-16 BOM)", "\xFE\xFF\x00{\x00}");
          ("e acute where ':' is expected", "{\"a\" \xC3\xA9}");
          ("lone 0xC3 where ':' is expected", "{\"a\" \xC3}");
          ("0x80 where a value starts", "[\x80]");
          ("NUL where a value starts", "\x00");
          ("non-ASCII after the document", base ^ "\xE2\x80\xA8") ])

(* ---------- the CLI's stdin path ---------- *)

let run_cli input =
  let inp = Filename.temp_file "boundary" ".in" and out = Filename.temp_file "boundary" ".out" in
  Out_channel.with_open_bin inp (fun oc -> output_string oc input);
  let status = Sys.command (Printf.sprintf "%s eval < %s > %s 2>/dev/null" (Filename.quote kernel) (Filename.quote inp) (Filename.quote out)) in
  let output = read_file out in
  Sys.remove inp;
  Sys.remove out;
  (status, output)

let field name = function J.Object kvs -> List.assoc_opt name kvs | _ -> None

let () =
  case "cli: 1 MiB + 1 byte and 3 MiB on stdin: exit 0, one decision, request_too_large" (fun () ->
      List.iter
        (fun n ->
          let status, output = run_cli (base ^ String.make (n - String.length base) ' ') in
          check (Printf.sprintf "%d bytes: exit %d" n status) (status = 0);
          match J.parse output with
          | Error e -> fail "%d bytes: output does not parse: %s" n e.message
          | Ok doc -> (
              check "decision indeterminate" (field "decision" doc = Some (J.String "indeterminate"));
              check "request_id null" (field "request_id" doc = Some J.Null);
              match field "reasons" doc with
              | Some (J.Array [ r ]) -> check "request_too_large" (field "code" r = Some (J.String "request_too_large"))
              | _ -> fail "%d bytes: reasons" n))
        [ Evaluate.max_request_bytes + 1; 3 * Evaluate.max_request_bytes ]);
  case "cli: garbage on stdin: exit 0 with a malformed_request decision" (fun () ->
      List.iter
        (fun input ->
          let status, output = run_cli input in
          check "exit 0" (status = 0);
          match J.parse output with
          | Ok doc -> check "indeterminate" (field "decision" doc = Some (J.String "indeterminate"))
          | Error e -> fail "output does not parse: %s" e.message)
        [ ""; "\000\000\000"; "\xFF\xFE{\x00}\x00"; base ^ base; String.sub base 0 100 ])

let () =
  Printf.printf "test_boundary: %d tests, %d failed\n" !count !failures;
  if !failures > 0 then exit 1
