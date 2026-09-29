(* Attack 3: checker soundness. Can a certificate be crafted that
   Certificate.check ACCEPTS but that is wrong? Mostly on the real slice, whose
   committed certificate is the baseline; 3e uses fixtures/emit through the real
   extractor. *)

open Adv
open Proof
open Proof.Encoding

let graph_path = "../../../examples/proof/keycloak-authz.graph.json"
let cert_path = "../../../examples/proof/certificate.json"

let accepted g ~digest c = match Certificate.check g ~digest c with Ok _ -> true | Error _ -> false
let errors g ~digest c = match Certificate.check g ~digest c with Ok _ -> [] | Error e -> e

let find_index p l =
  let rec go i = function [] -> -1 | x :: rest -> if p x then i else go (i + 1) rest in
  go 0 l

let replace (c : Certificate.t) i f = { c with entries = List.mapi (fun j e -> if i = j then f e else e) c.entries }
let entry_index (c : Certificate.t) id = find_index (fun (e : Certificate.entry) -> e.obligation = id) c.entries

let () =
  let text = read_file graph_path in
  let g, digest = match Jgraph.of_string text with Ok x -> x | Error e -> failwith e in
  let committed = match Certificate.of_string (read_file cert_path) with Ok c -> c | Error e -> failwith e in
  check "baseline: the committed certificate is accepted" (accepted g ~digest committed);
  let rejects name c =
    let errs = errors g ~digest c in
    report "  %s: %s" name (if errs = [] then "ACCEPTED" else "rejected (" ^ List.hd errs ^ ")");
    check ("3: " ^ name ^ " is rejected") (errs <> [])
  in

  (* 3a: an OCaml type string that does not match the encoding. *)
  report "3a OCaml type strings";
  let i = entry_index committed "Represent:Policy.getScopes()@return" in
  rejects "Set<Scope> carried as 'scope list' although Scope_set.t is emitted"
    (replace committed i (fun e -> { e with ocaml = Some "scope list" }));
  let i = entry_index committed "Nullability:Policy.getName()@return" in
  rejects "'string  option' (extra space)" (replace committed i (fun e -> { e with ocaml = Some "string  option" }));
  rejects "bare 'string' for a value without @Nonnull" (replace committed i (fun e -> { e with ocaml = Some "string" }));
  let i = entry_index committed "Keyed:Policy.getConfig()@return" in
  rejects "an OCaml type on a Keyed obligation" (replace committed i (fun e -> { e with ocaml = Some "string String_map.t" }));

  (* 3b: a verdict that is right but attached to the wrong obligation id. *)
  report "3b right verdict, wrong obligation";
  let a = entry_index committed "Represent:Policy.getName()@return" in
  let b = entry_index committed "Represent:Policy.getDescription()@return" in
  let ea = List.nth committed.entries a and eb = List.nth committed.entries b in
  rejects "ids of two PROVEN string Represent entries swapped"
    (replace (replace committed a (fun e -> { e with obligation = eb.obligation })) b (fun e -> { e with obligation = ea.obligation }));
  let r = entry_index committed "Represent:Policy.getScopes()@return" in
  let n = entry_index committed "Nullability:Policy.getScopes()@return" in
  let er = List.nth committed.entries r and en = List.nth committed.entries n in
  rejects "the ids of Represent and Nullability of one position swapped (both PROVEN)"
    (replace (replace committed r (fun e -> { e with obligation = en.obligation })) n (fun e -> { e with obligation = er.obligation }));
  rejects "an obligation's line moved to another member's line"
    (replace committed a (fun e -> { e with line = Option.map (fun l -> l + 1) e.line }));
  rejects "an obligation's line removed" (replace committed a (fun e -> { e with line = None }));
  (* What the checker does not check, by its own header comment: reasons, conflicts, search statistics. *)
  let refuted = entry_index committed "Unique:Policy.getAssociatedPolicies()@return" in
  let wrong_reason =
    replace committed refuted (fun e ->
        { e with reason = "Policy is final and has no behaviour"; conflicts = [ "Closed:Logic" ] })
  in
  known_weakness "known_weakness_counterexample_not_checked"
    ~detail:"a REFUTED entry with a false counterexample ('Policy is final and has no behaviour') and a bogus conflict list is accepted"
    (accepted g ~digest wrong_reason);
  let no_memo = { committed with search = { committed.search with memo_hits = 0; states_explored = 1 } } in
  known_weakness "known_weakness_search_statistics_not_checked"
    ~detail:"memo_hits 0 and states_explored 1 are accepted: the P2(d)/Q3 numbers in a certificate are claims, re-measured only by test_p2"
    (accepted g ~digest no_memo);

  (* 3c: a reordered obligation list or encoding list. *)
  report "3c reordering";
  let reversed = { committed with entries = List.rev committed.entries; encodings = List.rev committed.encodings } in
  check "3c reversed obligations and encodings are accepted" (accepted g ~digest reversed);
  check "3c and mean the same: every id keeps its verdict"
    (List.for_all
       (fun (e : Certificate.entry) ->
         List.exists (fun (x : Certificate.entry) -> x.obligation = e.obligation && x.verdict = e.verdict) committed.entries)
       reversed.entries);

  (* 3d: is the digest over a canonical form? *)
  report "3d graph digest";
  let json = match Tjson.parse ~max_depth:128 text with Ok j -> j | Error _ -> failwith "parse" in
  let reordered_keys =
    match json with Tjson.Object [ s; src; t ] -> Tjson.to_string (Tjson.Object [ src; s; t ]) | _ -> failwith "shape"
  in
  let reordered_types =
    match json with
    | Tjson.Object [ s; src; ("types", Tjson.Array ts) ] -> Tjson.to_string (Tjson.Object [ s; src; ("types", Tjson.Array (List.rev ts)) ])
    | _ -> failwith "shape"
  in
  let compact = Tjson.to_string json in
  let load t = match Jgraph.of_string t with Ok x -> x | Error e -> failwith e in
  let g1, d1 = load reordered_keys and g2, d2 = load reordered_types and _, d3 = load compact in
  report "  committed %s; keys reordered %s; types reordered %s; whitespace removed %s" digest d1 d2 d3;
  check "3d key order: same decoded graph" (g1 = g);
  check "3d type order: same decoded graph" (g2 = g);
  check "3d whitespace does not change the digest" (d3 = digest);
  check "3d key order changes the digest (not canonical: a false reject, never a false accept)" (d1 <> digest);
  check "3d type order changes the digest (not canonical)" (d2 <> digest);
  check "3d the committed certificate is rejected for the key-reordered graph" (not (accepted g1 ~digest:d1 committed));
  (match Jgraph.of_string "{\"schema\": \"java-source-graph/v1\", \"schema\": \"x\"}" with
  | Ok _ -> check "3d duplicate keys in a graph are rejected" false
  | Error e -> check ("3d duplicate keys in a graph are rejected: " ^ e) (contains e "duplicate key"));
  (match Certificate.of_string "{\"schema\": \"attempt-proof/certificate/v1\", \"schema\": \"x\"}" with
  | Ok _ -> check "3d duplicate keys in a certificate are rejected" false
  | Error e -> check ("3d duplicate keys in a certificate are rejected: " ^ e) (contains e "duplicate key"));
  known_weakness "known_weakness_digest_is_md5"
    ~detail:"the graph digest is MD5 of the compact JSON; MD5 is not collision-resistant, so it binds a certificate to a graph only against accidents"
    (String.length digest > 4 && String.sub digest 0 4 = "md5:");

  (* 3f: the checker verifies consistency, not optimality. *)
  report "3f suboptimal certificates";
  let m = Model.build g in
  let certificate_for enc =
    let vs = Evaluate.verdicts m enc in
    Certificate.make m ~digest enc vs (Evaluate.cost m enc vs) committed.search
  in
  let greedy = certificate_for (Baselines.greedy m) in
  let bounded = "Bounded:Decision@<D extends Evaluation>" in
  let v c id = Option.map (fun (e : Certificate.entry) -> e.verdict) (List.find_opt (fun (e : Certificate.entry) -> e.obligation = id) c.Certificate.entries) in
  report "  greedy certificate: cost %s, %s %s; committed: %s" (cost_to_string greedy.cost) bounded (show_verdict (v greedy bounded))
    (show_verdict (v committed bounded));
  let policy_record =
    let enc = Array.map (fun (jt : Jgraph.jtype) -> List.assoc jt.id committed.encodings) m.nodes in
    enc.(Model.node m "Policy") <- Record;
    certificate_for enc
  in
  report "  Policy as Record: cost %s, Command:Policy.addScope(Scope) %s" (cost_to_string policy_record.cost)
    (show_verdict (v policy_record "Command:Policy.addScope(Scope)"));
  known_weakness "known_weakness_checker_accepts_suboptimal_certificate"
    ~detail:
      "certificates for the greedy assignment (Bounded:Decision REFUTED) and for Policy as Record (8 commands REFUTED) are accepted; REFUTED is defined as 'no encoding in the catalogue carries the fact', which the committed certificate disproves for both"
    (accepted g ~digest greedy && accepted g ~digest policy_record
    && v greedy bounded = Some Refuted
    && v committed bounded = Some Proven
    && v policy_record "Command:Policy.addScope(Scope)" = Some Refuted
    && v committed "Command:Policy.addScope(Scope)" = Some Proven);

  (* 3e: an encoding that is feasible per the rules but emits OCaml that does not compile. *)
  report "3e emitted OCaml for fixtures/emit";
  let files = java_files "fixtures/emit" in
  check "3e fixtures are legal Java (javac)" (javac_accepts ~name:"emit" files);
  let r = prove (extract ~name:"emit-checker" files) in
  report "  encodings: %s"
    (String.concat ", " (List.map (fun (n, e) -> n ^ " " ^ label e) (List.filter (fun (n, _) -> Model.is_slice r.model n) r.cert.encodings)));
  check "3e the checker accepts the fixtures' certificate" (accepted r.graph ~digest:r.digest r.cert);
  let source = emit_source r in
  let ok, err = ocaml_compiles ~name:"emit" source in
  if not ok then report "  ocamlc:\n%s" err;
  check "3e the emitted type graph compiles (Notes <T> T getNote() as Record; enum Level {LOW, Low, low, _HIDDEN, $DOLLAR}; getÄrger(); _Hidden)" ok;
  (* Each feature alone, so a failure names its cause. *)
  List.iter
    (fun (name, files) ->
      let r = prove (extract ~name:("emit-" ^ name) files) in
      let ok, err = ocaml_compiles ~name (emit_source r) in
      if not ok then report "  %s: %s" name (String.trim err);
      check ("3e emitted OCaml compiles: " ^ name) ok)
    [
      ("generic_getter_record", [ "fixtures/emit/Notes.java" ]);
      ("enum_constants", [ "fixtures/emit/Level.java" ]);
      ("non_ascii_member", [ "fixtures/emit/Labels.java" ]);
      ("leading_underscore_type", [ "fixtures/emit/Hidden.java"; "fixtures/emit/HiddenUser.java" ]);
    ];
  let level_constructors =
    List.length (List.filter (fun l -> String.length l > 4 && String.sub l 0 4 = "  | ") (String.split_on_char '\n' source))
  in
  check_eq "3e five distinct enum constants, five constructors" string_of_int 5 level_constructors;
  finish "test_checker"
