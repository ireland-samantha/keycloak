(* P2(c) and P1: the checker accepts real certificates, and rejects a
   certificate after any single verdict is altered, as well as other tampering. *)

open Harness
open Proof

let committed_cert_path = "../../examples/proof/certificate.json"

let rejected g ~digest c = match Certificate.check g ~digest c with Ok _ -> false | Error _ -> true

let replace_entry (c : Certificate.t) i f = { c with entries = List.mapi (fun j e -> if i = j then f e else e) c.entries }

let () =
  let g, digest = real_graph () in
  let fresh = Attempt.parts (Attempt.attempt_proof g ~digest) |> snd in
  (* acceptance *)
  (match Certificate.check g ~digest fresh with
  | Ok a -> check_eq "fresh certificate accepted, all obligations" string_of_int (List.length fresh.entries) a.obligations
  | Error errs -> check ("fresh certificate accepted: " ^ String.concat "; " errs) false);
  let committed =
    match Certificate.of_string (read_file committed_cert_path) with Ok c -> c | Error e -> failwith e
  in
  (match Certificate.check g ~digest committed with
  | Ok _ -> check "committed certificate accepted" true
  | Error errs -> check ("committed certificate accepted: " ^ String.concat "; " errs) false);
  check "committed certificate = fresh run"
    (Tjson.to_string (Certificate.to_json committed) = Tjson.to_string (Certificate.to_json fresh));
  (* JSON round trip *)
  (match Certificate.of_string (Tjson.to_string_pretty (Certificate.to_json fresh)) with
  | Ok c -> check "certificate JSON round trip" (c = fresh)
  | Error e -> check ("certificate JSON round trip: " ^ e) false);
  (* every single-verdict mutation is rejected *)
  let mutations = ref 0 and caught = ref 0 in
  List.iteri
    (fun i (e : Certificate.entry) ->
      List.iter
        (fun v ->
          if v <> e.verdict then begin
            incr mutations;
            let c = replace_entry fresh i (fun e -> { e with verdict = v; reason = "mutated" }) in
            if rejected g ~digest c then incr caught
            else check (Printf.sprintf "mutation %s -> %s rejected" e.obligation (Encoding.verdict_to_string v)) false
          end)
        Encoding.all_verdicts)
    fresh.entries;
  Printf.printf "P2(c): %d of %d single-verdict mutations rejected (%d obligations x 3 other verdicts)\n" !caught
    !mutations (List.length fresh.entries);
  check "P2(c): every single-verdict mutation rejected" (!caught = !mutations && !mutations = 3 * List.length fresh.entries);
  (* every single-encoding change is rejected *)
  let m = Model.build g in
  let enc_mut = ref 0 and enc_caught = ref 0 in
  List.iter
    (fun (name, e) ->
      if Model.is_slice m name then
        List.iter
          (fun e' ->
            if e' <> e then begin
              incr enc_mut;
              let c = { fresh with encodings = List.map (fun (n, x) -> if n = name then (n, e') else (n, x)) fresh.encodings } in
              if rejected g ~digest c then incr enc_caught
              else check (Printf.sprintf "encoding %s -> %s rejected" name (Encoding.label e')) false
            end)
          Encoding.searchable)
    fresh.encodings;
  Printf.printf "checker: %d of %d single-encoding changes rejected\n" !enc_caught !enc_mut;
  check "every single-encoding change rejected" (!enc_caught = !enc_mut);
  (* other tampering *)
  check "dropped obligation rejected" (rejected g ~digest { fresh with entries = List.tl fresh.entries });
  check "duplicated obligation rejected" (rejected g ~digest { fresh with entries = List.hd fresh.entries :: fresh.entries });
  check "unknown obligation rejected"
    (rejected g ~digest (replace_entry fresh 0 (fun e -> { e with obligation = e.obligation ^ "x" })));
  check "wrong digest rejected" (rejected g ~digest:"md5:0" fresh);
  check "wrong commit rejected" (rejected g ~digest { fresh with graph_commit = "0000000" });
  check "tampered cost rejected" (rejected g ~digest { fresh with cost = { fresh.cost with unknown = fresh.cost.unknown - 1 } });
  check "tampered result rejected" (rejected g ~digest { fresh with result = Certificate.Result_proven });
  check "missing encoding rejected" (rejected g ~digest { fresh with encodings = List.tl fresh.encodings });
  check "non-Abstract external rejected"
    (rejected g ~digest
       { fresh with encodings = List.map (fun (q, e) -> if Model.is_slice m q then (q, e) else (q, Encoding.Record)) fresh.encodings });
  let refuted_idx =
    let rec find i = function [] -> -1 | (e : Certificate.entry) :: rest -> if e.verdict = Encoding.Refuted then i else find (i + 1) rest in
    find 0 fresh.entries
  in
  check "REFUTED without a counterexample rejected"
    (rejected g ~digest (replace_entry fresh refuted_idx (fun e -> { e with reason = "" })));
  let represent_idx =
    let rec find i = function [] -> -1 | (e : Certificate.entry) :: rest -> if e.kind = "Represent" then i else find (i + 1) rest in
    find 0 fresh.entries
  in
  check "tampered OCaml type rejected"
    (rejected g ~digest (replace_entry fresh represent_idx (fun e -> { e with ocaml = Some "int" })));
  finish "test_certificate"
