(* Certificates: one verdict per obligation, the chosen encodings and the
   claimed cost, bound to one graph by its digest.

   [check] is the trusted part. It never searches: it re-derives the
   obligations from the graph, recomputes every verdict from the certificate's
   own encodings with [Evaluate], checks the structural constraints and
   recomputes the cost. The search statistics and the reasons are not trusted
   and not checked beyond being present. *)

open Encoding

let schema = "attempt-proof/certificate/v1"

type entry = {
  obligation : string;
  kind : string;
  owner : string;
  member : string option;
  line : int option;
  position : string option;
  verdict : verdict;
  ocaml : string option;  (** OCaml type of the position, for Represent and Nullability *)
  reason : string;
  conflicts : string list;  (** obligations that would get worse if the offending node were re-encoded *)
}

type search_stats = {
  components : int;
  cyclic_components : int;
  largest_component : int;
  states_explored : int;
  memo_hits : int;
  branches_pruned : int;
  infeasible_rejected : int;  (** encodings rejected by structural constraints while enumerating *)
}

type result_kind = Result_proven | Result_refuted | Result_unknown

type t = {
  graph_schema : string;
  graph_commit : string;
  graph_digest : string;
  result : result_kind;
  cost : cost;
  encodings : (string * Encoding.t) list;  (** slice ids, then external qualified names *)
  search : search_stats;
  entries : entry list;
}

let result_of_verdicts vs =
  if Array.exists (( = ) Refuted) vs then Result_refuted
  else if Array.exists (( = ) Unknown) vs then Result_unknown
  else Result_proven

let result_to_string = function Result_proven -> "proven" | Result_refuted -> "refuted" | Result_unknown -> "unknown"

let make (m : Model.t) ~digest (enc : Model.assignment) (verdicts : verdict array) (cost : cost) (search : search_stats) =
  let ctx = Ocaml_type.context m enc in
  let entries =
    Array.to_list
      (Array.mapi
         (fun i (o : Obligation.t) ->
           let ex = Explain.explain m enc verdicts i in
           {
             obligation = o.id;
             kind = Obligation.kind_to_string o.kind;
             owner = o.owner;
             member = Option.map (fun (r : Obligation.member_ref) -> r.key) o.member;
             line = Option.map (fun (r : Obligation.member_ref) -> r.line) o.member;
             position = o.position;
             verdict = verdicts.(i);
             ocaml = Ocaml_type.of_obligation ctx o;
             reason = ex.reason;
             conflicts = ex.conflicts;
           })
         m.obligations)
  in
  let encodings =
    Array.to_list (Array.mapi (fun i (jt : Jgraph.jtype) -> (jt.id, enc.(i))) m.nodes)
    @ List.map (fun (q, _) -> (q, Abstract)) m.externals
  in
  {
    graph_schema = Jgraph.schema;
    graph_commit = m.graph.commit;
    graph_digest = digest;
    result = result_of_verdicts verdicts;
    cost;
    encodings;
    search;
    entries;
  }

(* ---------- JSON ---------- *)

let to_json c : Tjson.t =
  let open Tjson in
  let opt_str = opt str in
  obj
    [
      ("schema", str schema);
      ("graph", obj [ ("schema", str c.graph_schema); ("commit", str c.graph_commit); ("digest", str c.graph_digest) ]);
      ("result", str (result_to_string c.result));
      ( "cost",
        obj [ ("refuted", int c.cost.refuted); ("unknown", int c.cost.unknown); ("complexity", int c.cost.complexity) ] );
      ( "encodings",
        list (fun (n, e) -> obj [ ("type", str n); ("encoding", str (Encoding.to_string e)) ]) c.encodings );
      ( "search",
        obj
          [
            ("components", int c.search.components);
            ("cyclic_components", int c.search.cyclic_components);
            ("largest_component", int c.search.largest_component);
            ("states_explored", int c.search.states_explored);
            ("memo_hits", int c.search.memo_hits);
            ("branches_pruned", int c.search.branches_pruned);
            ("infeasible_rejected", int c.search.infeasible_rejected);
          ] );
      ( "obligations",
        list
          (fun e ->
            obj
              [
                ("id", str e.obligation);
                ("kind", str e.kind);
                ("owner", str e.owner);
                ("member", opt_str e.member);
                ("line", opt int e.line);
                ("position", opt_str e.position);
                ("verdict", str (verdict_to_string e.verdict));
                ("ocaml", opt_str e.ocaml);
                ("reason", str e.reason);
                ("conflicts", list str e.conflicts);
              ])
          c.entries );
    ]

open Tjson.Decode

let str_field name c = let* v = field name c in string v
let int_field name c = let* v = field name c in int v

let opt_field dec name c =
  let* v = field_opt name c in
  match v with None -> Ok None | Some v -> Result.map Option.some (dec v)

let of_json (json : Tjson.t) : (t, string) result =
  let r =
    let c = root json in
    let* _ = obj ~allowed:[ "schema"; "graph"; "result"; "cost"; "encodings"; "search"; "obligations" ] c in
    let* s = str_field "schema" c in
    let* () = if s = schema then Ok () else fail c ("expected schema " ^ schema) in
    let* g = field "graph" c in
    let* _ = obj ~allowed:[ "schema"; "commit"; "digest" ] g in
    let* graph_schema = str_field "schema" g in
    let* graph_commit = str_field "commit" g in
    let* graph_digest = str_field "digest" g in
    let* rc = field "result" c in
    let* rs = string rc in
    let* result =
      match rs with
      | "proven" -> Ok Result_proven
      | "refuted" -> Ok Result_refuted
      | "unknown" -> Ok Result_unknown
      | _ -> fail rc ("unknown result " ^ rs)
    in
    let* co = field "cost" c in
    let* _ = obj ~allowed:[ "refuted"; "unknown"; "complexity" ] co in
    let* refuted = int_field "refuted" co in
    let* unknown = int_field "unknown" co in
    let* complexity = int_field "complexity" co in
    let* encs = field "encodings" c in
    let* encodings =
      map_list
        (fun e ->
          let* _ = obj ~allowed:[ "type"; "encoding" ] e in
          let* n = str_field "type" e in
          let* ec = field "encoding" e in
          let* es = string ec in
          match Encoding.of_string es with Some x -> Ok (n, x) | None -> fail ec ("unknown encoding " ^ es))
        encs
    in
    let* se = field "search" c in
    let* _ =
      obj
        ~allowed:
          [ "components"; "cyclic_components"; "largest_component"; "states_explored"; "memo_hits"; "branches_pruned";
            "infeasible_rejected" ]
        se
    in
    let* components = int_field "components" se in
    let* cyclic_components = int_field "cyclic_components" se in
    let* largest_component = int_field "largest_component" se in
    let* states_explored = int_field "states_explored" se in
    let* memo_hits = int_field "memo_hits" se in
    let* branches_pruned = int_field "branches_pruned" se in
    let* infeasible_rejected = int_field "infeasible_rejected" se in
    let* obls = field "obligations" c in
    let* entries =
      map_list
        (fun e ->
          let* _ =
            obj
              ~allowed:[ "id"; "kind"; "owner"; "member"; "line"; "position"; "verdict"; "ocaml"; "reason"; "conflicts" ]
              e
          in
          let* obligation = str_field "id" e in
          let* kind = str_field "kind" e in
          let* owner = str_field "owner" e in
          let* member = opt_field string "member" e in
          let* line = opt_field int "line" e in
          let* position = opt_field string "position" e in
          let* vc = field "verdict" e in
          let* vs = string vc in
          let* verdict =
            match Encoding.verdict_of_string vs with Some v -> Ok v | None -> fail vc ("unknown verdict " ^ vs)
          in
          let* ocaml = opt_field string "ocaml" e in
          let* reason = str_field "reason" e in
          let* cf = field "conflicts" e in
          let* conflicts = map_list string cf in
          Ok { obligation; kind; owner; member; line; position; verdict; ocaml; reason; conflicts })
        obls
    in
    Ok
      {
        graph_schema;
        graph_commit;
        graph_digest;
        result;
        cost = { refuted; unknown; complexity };
        encodings;
        search =
          { components; cyclic_components; largest_component; states_explored; memo_hits; branches_pruned; infeasible_rejected };
        entries;
      }
  in
  match r with Ok c -> Ok c | Error e -> Error (e.path ^ ": " ^ e.message)

let of_string text =
  match Tjson.parse text with
  | Error e -> Error (Printf.sprintf "JSON error at offset %d: %s" e.offset e.message)
  | Ok json -> of_json json

(* ---------- checking ---------- *)

type accepted = { obligations : int; cost : cost; counts : (verdict * int) list; result : result_kind }

let counts vs = List.map (fun v -> (v, List.length (List.filter (( = ) v) vs))) all_verdicts

let check (g : Jgraph.t) ~digest (c : t) : (accepted, string list) result =
  let errors = ref [] in
  let err fmt = Printf.ksprintf (fun s -> errors := s :: !errors) fmt in
  if c.graph_schema <> Jgraph.schema then err "graph schema %s, expected %s" c.graph_schema Jgraph.schema;
  if c.graph_commit <> g.commit then err "certificate is for commit %s, graph is %s" c.graph_commit g.commit;
  if c.graph_digest <> digest then err "certificate is for graph %s, this graph is %s" c.graph_digest digest;
  let m = Model.build g in
  (* 1. the OCaml graph: exactly one encoding per slice type and per external *)
  let n = Array.length m.nodes in
  let enc = Array.make n Abstract in
  let assigned = Array.make n false in
  let externals_seen = Hashtbl.create 16 in
  List.iter
    (fun (name, e) ->
      if Model.is_slice m name then begin
        let v = Model.node m name in
        if assigned.(v) then err "%s is encoded twice" name;
        assigned.(v) <- true;
        enc.(v) <- e
      end
      else if List.mem_assoc name m.externals then begin
        if Hashtbl.mem externals_seen name then err "%s is encoded twice" name;
        Hashtbl.replace externals_seen name ();
        if e <> Abstract then err "external %s must be Abstract, not %s" name (label e)
      end
      else err "%s is neither a slice type nor an external type of this graph" name)
    c.encodings;
  Array.iteri (fun v b -> if not b then err "%s has no encoding" m.nodes.(v).id) assigned;
  List.iter (fun (q, _) -> if not (Hashtbl.mem externals_seen q) then err "external %s has no encoding" q) m.externals;
  (* 2. structural constraints *)
  List.iter (fun e -> err "%s" e) (Evaluate.structural_errors m enc);
  if !errors <> [] then Error (List.rev !errors)
  else begin
    (* 3. coverage: every derived obligation exactly once, and nothing else *)
    let by_id = Hashtbl.create 1024 in
    Array.iteri (fun i (o : Obligation.t) -> Hashtbl.replace by_id o.id i) m.obligations;
    let covered = Array.make (Array.length m.obligations) false in
    let ctx = Ocaml_type.context m enc in
    let vs = Evaluate.verdicts m enc in
    List.iter
      (fun e ->
        match Hashtbl.find_opt by_id e.obligation with
        | None -> err "%s is not an obligation of this graph" e.obligation
        | Some i ->
            let o = m.obligations.(i) in
            if covered.(i) then err "%s is covered twice" e.obligation;
            covered.(i) <- true;
            if e.kind <> Obligation.kind_to_string o.kind then err "%s: kind %s, expected %s" o.id e.kind (Obligation.kind_to_string o.kind);
            if e.owner <> o.owner then err "%s: owner %s, expected %s" o.id e.owner o.owner;
            let key = Option.map (fun (r : Obligation.member_ref) -> r.key) o.member in
            if e.member <> key then err "%s: member does not match the graph" o.id;
            (* The line is what a reader follows back to the source; it must be the member's. *)
            if e.line <> Option.map (fun (r : Obligation.member_ref) -> r.line) o.member then
              err "%s: line does not match the graph" o.id;
            if e.position <> o.position then err "%s: position does not match the graph" o.id;
            (* 4. the verdict, recomputed from the rule table *)
            if e.verdict <> vs.(i) then
              err "%s: certificate says %s, the rule table gives %s" o.id (verdict_to_string e.verdict) (verdict_to_string vs.(i));
            let ty = Ocaml_type.of_obligation ctx o in
            if e.ocaml <> ty then err "%s: OCaml type %s, expected %s" o.id (Option.value e.ocaml ~default:"none") (Option.value ty ~default:"none");
            if (e.verdict = Refuted || e.verdict = Unknown) && String.trim e.reason = "" then
              err "%s: %s without a reason" o.id (verdict_to_string e.verdict))
      c.entries;
    Array.iteri (fun i b -> if not b then err "%s is not covered" m.obligations.(i).id) covered;
    (* 5. cost and overall result *)
    let cost = Evaluate.cost m enc vs in
    if compare_cost cost c.cost <> 0 then err "claimed cost %s, recomputed %s" (cost_to_string c.cost) (cost_to_string cost);
    let result = result_of_verdicts vs in
    if result <> c.result then err "claimed result %s, recomputed %s" (result_to_string c.result) (result_to_string result);
    if !errors <> [] then Error (List.rev !errors)
    else Ok { obligations = Array.length vs; cost; counts = counts (Array.to_list vs); result }
  end
