(* The comparison experiment: for each scenario, the conventional check
   hasPermission(token subject, capability) computed from the same facts, the
   kernel decision, and which of the five questions each audit record
   answers. Reports differences; draws no conclusions. *)

open Authority

let sp = Printf.sprintf

(* A role confers a capability iff some ROOT grant in the ledger anchored on
   that role grants that capability. The subject's live roles are its entry
   in facts.principals. *)
let conferring_roles (r : Request.t) =
  match Facts.roles_of r.facts r.facts.subject with
  | None -> []
  | Some roles ->
      List.sort_uniq compare
        (List.filter_map
           (function
             | Grant.Anchored { terms; provenance = Grant.Root anchor }
               when Capability.equal terms.capability r.query.capability && Facts.holds roles anchor ->
                 Some (Grant.anchor_to_string anchor)
             | _ -> None)
           r.ledger.entries)

type answers = { who : bool; mandate : bool; capability : bool; effect : bool; provenance : bool }

let questions =
  [ ("who", fun a -> a.who); ("mandate", fun a -> a.mandate); ("capability", fun a -> a.capability);
    ("effect", fun a -> a.effect); ("provenance", fun a -> a.provenance) ]

let answers_to_string a =
  match List.filter_map (fun (n, answered) -> if answered a then Some n else None) questions with [] -> "-" | l -> String.concat ", " l

(* Conventional record: token subject, capability, resource, decision,
   conferring roles. It identifies the acting principal only when nobody acts
   for the subject; its roles are the origin only in the same case. *)
let conventional_answers (r : Request.t) roles =
  let direct = r.facts.actor_chain = [] in
  { who = direct; mandate = false; capability = true; effect = false; provenance = direct && roles <> [] }

(* Kernel record: the decision document. Provenance is authority.chain for an
   ALLOW and each candidate's provenance check otherwise. *)
let kernel_answers (d : Decision.t) =
  match d.about with
  | None -> { who = false; mandate = false; capability = false; effect = false; provenance = false }
  | Some a ->
      { who = true; mandate = Option.is_some a.query.mandate; capability = true; effect = Option.is_some a.query.effect;
        provenance = (match d.verdict with Decision.Allow _ -> true | _ -> d.evidence.candidates <> []) }

let run path (file : Scenario.file) =
  let rows =
    List.map
      (fun (s : Scenario.t) ->
        let d = Scenario.evaluate s in
        match Scenario.request s with
        | None -> (s, d, None)
        | Some r ->
            let roles = conferring_roles r in
            (s, d, Some (r, roles, (if roles = [] then "deny" else "allow"), conventional_answers r roles)))
      file.scenarios
  in
  let p = print_endline in
  p (sp "# Conventional check vs. kernel: %s" path);
  p "";
  p "- conventional: hasPermission(token subject, capability) from the same facts; allow iff one of the subject's live roles";
  p "  (facts.principals) anchors a ROOT grant in the ledger for the requested capability.";
  p "- conventional audit record: token subject, capability, resource, decision, conferring roles.";
  p "- kernel audit record: the decision document.";
  p "- a question is listed when the record alone answers it. who: the acting principal (conventional: only when the actor";
  p "  chain is empty). mandate, effect: named by the record. provenance: conventional: the conferring role, when allowed and";
  p "  the actor chain is empty; kernel: authority.chain for allow, otherwise each candidate's provenance check (none when";
  p "  there are no candidates).";
  p "";
  p "| scenario | subject | actor chain | conventional | conferring roles | kernel | kernel reason codes | conventional record answers | kernel record answers |";
  p "|---|---|---|---|---|---|---|---|---|";
  List.iter
    (fun ((s : Scenario.t), d, conv) ->
      let kernel = Decision.verdict_to_string d.Decision.verdict in
      let codes = match Scenario.codes d with [] -> "-" | l -> String.concat ", " (List.sort_uniq compare l) in
      match conv with
      | None -> p (sp "| %s | - | - | n/a (request does not decode) | - | %s | %s | - | %s |" s.name kernel codes (answers_to_string (kernel_answers d)))
      | Some ((r : Request.t), roles, c, ca) ->
          let chain = match r.facts.actor_chain with [] -> "-" | l -> String.concat ", " (List.map (fun (x : Principal.t) -> Id.Principal.to_string x.id) l) in
          p
            (sp "| %s | %s | %s | %s | %s | %s | %s | %s | %s |" s.name (Id.Principal.to_string r.facts.subject.id) chain c
               (match roles with [] -> "-" | l -> String.concat ", " l)
               kernel codes (answers_to_string ca) (answers_to_string (kernel_answers d))))
    rows;
  let decided = List.filter_map (fun (s, d, c) -> Option.map (fun (_, _, c, ca) -> (s, d, c, ca)) c) rows in
  let names l = match l with [] -> "none" | l -> String.concat ", " (List.map (fun ((s : Scenario.t), _, _, _) -> s.name) l) in
  let kernel_of (_, d, _, _) = Decision.verdict_to_string d.Decision.verdict in
  let differ = List.filter (fun ((_, _, c, _) as row) -> c <> kernel_of row) decided in
  let conv_allow_kernel_not = List.filter (fun ((_, _, c, _) as row) -> c = "allow" && kernel_of row <> "allow") decided in
  let kernel_allow_conv_not = List.filter (fun ((_, _, c, _) as row) -> c <> "allow" && kernel_of row = "allow") decided in
  p "";
  p (sp "- scenarios: %d; conventional check computed for %d (the rest do not decode)" (List.length rows) (List.length decided));
  p (sp "- decisions differ in %d: %s" (List.length differ) (names differ));
  p (sp "- conventional allow, kernel not allow: %d: %s" (List.length conv_allow_kernel_not) (names conv_allow_kernel_not));
  p (sp "- kernel allow, conventional not allow: %d: %s" (List.length kernel_allow_conv_not) (names kernel_allow_conv_not));
  let count f l = List.length (List.filter f l) in
  List.iter
    (fun (q, answered) ->
      p
        (sp "- records answering %s: conventional %d of %d, kernel %d of %d" q
           (count (fun (_, _, _, ca) -> answered ca) decided) (List.length decided)
           (count (fun (_, d, _) -> answered (kernel_answers d)) rows) (List.length rows)))
    questions
