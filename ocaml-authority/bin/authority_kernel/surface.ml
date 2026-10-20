(* Hypothesis W1: the finite request space of a scenario file and how many of
   its tuples the kernel allows. An RBAC encoding that reproduces the decision
   surface exactly needs one compound role per allowed tuple. *)

open Authority

let sp = Printf.sprintf
let unique eq l = List.rev (List.fold_left (fun acc x -> if List.exists (eq x) acc then acc else x :: acc) [] l)

let run path (file : Scenario.file) =
  let decode f j = match f (Tjson.Decode.root j) with Ok v -> v | Error (e : Tjson.Decode.error) -> failwith (sp "%s: %s" e.path e.message) in
  let ledger = decode Codec.ledger_of_json file.ledger and facts = decode Codec.facts_of_json file.default_facts in
  let requests = List.filter_map Scenario.request file.scenarios in
  let subjects = ledger.principals in
  let chains = unique (List.equal Principal.equal) (List.map (fun (r : Request.t) -> r.facts.actor_chain) requests) in
  let mandates = List.map (fun (m : Mandate.t) -> m.id) ledger.mandates in
  let capabilities =
    unique Capability.equal
      (List.map (fun e -> (Grant.terms e).capability) ledger.entries
      @ List.concat_map (fun (m : Mandate.t) -> Nonempty.to_list m.capabilities) ledger.mandates)
  in
  let resources = unique Id.Resource.equal (List.map (fun (r : Request.t) -> r.query.resource) requests) in
  let allow = ref 0 and deny = ref 0 and indeterminate = ref 0 and total = ref 0 in
  List.iter (fun subject ->
    List.iter (fun actor_chain ->
      List.iter (fun mandate ->
        List.iter (fun capability ->
          List.iter (fun resource ->
            List.iter (fun effect ->
              let query = { Request.mandate = Some mandate; capability; resource; effect = Some effect } in
              let r = { Request.request_id = None; query; facts = { facts with subject; actor_chain }; ledger } in
              incr total;
              match (Evaluate.evaluate r).verdict with
              | Decision.Allow _ -> incr allow
              | Deny _ -> incr deny
              | Indeterminate _ -> incr indeterminate)
            Effect.all) resources) capabilities) mandates) chains) subjects;
  let n l = List.length l in
  let objects = [ ("principals", n ledger.principals); ("mandates", n ledger.mandates); ("grants", n ledger.entries);
                  ("revocations", n ledger.revocations); ("prohibitions", n ledger.prohibitions) ] in
  let p = print_endline in
  p (sp "surface of %s at %s" path (Timestamp.to_string facts.evaluated_at));
  p (sp "subjects (ledger principals)      %d" (n subjects));
  p (sp "actor chains (in scenarios)       %d" (n chains));
  p (sp "mandates (ledger)                 %d" (n mandates));
  p (sp "capabilities (ledger)             %d" (n capabilities));
  p (sp "resources (in scenarios)          %d" (n resources));
  p (sp "effects                           %d" (n Effect.all));
  p (sp "request tuples                    %d" !total);
  p (sp "allow                             %d" !allow);
  p (sp "deny                              %d" !deny);
  p (sp "indeterminate                     %d" !indeterminate);
  p (sp "compound roles for exact RBAC     %d" !allow);
  p (sp "administered ledger objects       %d (%s)" (List.fold_left (fun a (_, k) -> a + k) 0 objects)
       (String.concat ", " (List.map (fun (name, k) -> sp "%s %d" name k) objects)))
