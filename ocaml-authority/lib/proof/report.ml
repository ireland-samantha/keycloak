(* Plain-text report of one attempt_proof run. Every number is read from the
   model, the certificate or the checker; nothing is typed in by hand. *)

open Encoding

let pad n s = if String.length s >= n then s else s ^ String.make (n - String.length s) ' '
let lpad n s = if String.length s >= n then s else String.make (n - String.length s) ' ' ^ s

let render ~source_name (m : Model.t) (enc : Model.assignment) (cert : Certificate.t)
    ~(check : (Certificate.accepted, string list) result) : string =
  let b = Buffer.create 16384 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  let g = m.graph in
  let count_kind k = Array.fold_left (fun acc (jt : Jgraph.jtype) -> if jt.kind = k then acc + 1 else acc) 0 m.nodes in
  line "attempt_proof report";
  line "====================";
  line "";
  line "graph        %s (%s)" source_name Jgraph.schema;
  line "commit       %s" g.commit;
  line "digest       %s" cert.graph_digest;
  line "extractor    %s, %s name resolution, %d source files" g.extractor g.resolution_mode (List.length g.files);
  line "slice        %d types: %d interfaces, %d classes, %d enums, %d records; %d external types"
    (Array.length m.nodes) (count_kind Jgraph.Interface) (count_kind Jgraph.Class_decl) (count_kind Jgraph.Enum)
    (count_kind Jgraph.Record_decl) (List.length m.externals);
  line "obligations  %d" (List.length cert.entries);
  line "";
  line "result       %s" (String.uppercase_ascii (Certificate.result_to_string cert.result));
  line "cost         %s" (cost_to_string cert.cost);
  (match check with
  | Ok a -> line "checker      accepted: %d obligations re-derived, verdicts and cost recomputed" a.obligations
  | Error errs ->
      line "checker      REJECTED (%d error%s)" (List.length errs) (if List.length errs = 1 then "" else "s");
      List.iter (fun e -> line "  %s" e) errs);
  line "";
  line "Verdicts";
  let verdicts = List.map (fun (e : Certificate.entry) -> e.verdict) cert.entries in
  List.iter
    (fun (v, n) -> line "  %s %s" (pad 14 (verdict_to_string v)) (lpad 5 (string_of_int n)))
    (Certificate.counts verdicts);
  line "  %s %s" (pad 14 "total") (lpad 5 (string_of_int (List.length verdicts)));
  line "";
  line "Verdicts by obligation kind";
  line "  %s %s %s %s %s" (pad 12 "kind") (lpad 7 "PROVEN") (lpad 13 "STRENGTHENED") (lpad 8 "UNKNOWN") (lpad 8 "REFUTED");
  List.iter
    (fun k ->
      let name = Obligation.kind_to_string k in
      let of_kind = List.filter (fun (e : Certificate.entry) -> e.kind = name) cert.entries in
      if of_kind <> [] then
        let n v = string_of_int (List.length (List.filter (fun (e : Certificate.entry) -> e.verdict = v) of_kind)) in
        line "  %s %s %s %s %s" (pad 12 name) (lpad 7 (n Proven)) (lpad 13 (n Strengthened)) (lpad 8 (n Unknown))
          (lpad 8 (n Refuted)))
    Obligation.all_kinds;
  line "";
  line "Search (attempt_proof)";
  let cyclic_names =
    Array.to_list m.components
    |> List.mapi (fun k c -> (k, c))
    |> List.filter (fun (k, _) -> m.cyclic.(k))
    |> List.concat_map (fun (_, c) -> Array.to_list (Array.map (fun v -> m.nodes.(v).id) c))
  in
  let largest = Model.largest_component m in
  let largest_names =
    Array.to_list m.components
    |> List.filter (fun c -> Array.length c = largest)
    |> List.map (fun c -> "{" ^ String.concat ", " (Array.to_list (Array.map (fun v -> m.nodes.(v).id) c)) ^ "}")
  in
  line "  components (SCCs)     %d" cert.search.components;
  line "  cyclic components     %d%s" cert.search.cyclic_components
    (if cyclic_names = [] then "" else " (" ^ String.concat ", " cyclic_names ^ ")");
  line "  largest component     %d node%s%s" cert.search.largest_component (if largest = 1 then "" else "s")
    (if largest > 1 then ": " ^ String.concat ", " largest_names else " (every component is a single type)");
  line "  states explored       %d" cert.search.states_explored;
  line "  memo hits             %d" cert.search.memo_hits;
  line "  branches pruned       %d" cert.search.branches_pruned;
  line "  infeasible rejected   %d (Module_type inside a cyclic component)" cert.search.infeasible_rejected;
  let greedy = Baselines.greedy m in
  let gcost = Baselines.score m greedy in
  line "  greedy per-node       %s" (cost_to_string gcost);
  line "";
  line "Encodings (search order: referrers first)";
  line "  %s %s %s %s" (lpad 3 "#") (pad 30 "type") (pad 10 "kind") "encoding";
  Array.iteri
    (fun k c ->
      Array.iter
        (fun v ->
          let jt = m.nodes.(v) in
          line "  %s %s %s %s%s" (lpad 3 (string_of_int (k + 1))) (pad 30 jt.id) (pad 10 (Jgraph.kind_to_string jt.kind))
            (label enc.(v))
            (if m.cyclic.(k) then "  (cyclic)" else ""))
        c)
    m.components;
  line "";
  line "External types (Abstract)";
  List.iter (fun (q, _) -> line "  %s" q) m.externals;
  let by_id = Hashtbl.create 1024 in
  Array.iter (fun (o : Obligation.t) -> Hashtbl.replace by_id o.id o) m.obligations;
  let listing v title =
    let es = List.filter (fun (e : Certificate.entry) -> e.verdict = v) cert.entries in
    line "";
    line "%s (%d)" title (List.length es);
    List.iter
      (fun (e : Certificate.entry) ->
        let o = Hashtbl.find by_id e.obligation in
        let jt = Model.jtype m o.owner in
        let line_no = match e.line with Some l -> l | None -> jt.line in
        line "  %s" e.obligation;
        line "    at      %s:%d" jt.file line_no;
        line "    subject %s" (Obligation.describe o);
        line "    %s %s" (if v = Refuted then "counterexample:" else "reason:") e.reason;
        if e.conflicts <> [] then line "    conflicts: %s" (String.concat ", " e.conflicts))
      es
  in
  listing Refuted "REFUTED obligations";
  listing Unknown "UNKNOWN obligations";
  Buffer.contents b
