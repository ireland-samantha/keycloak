(* Human-readable rendering of a decision (eval --text). *)

open Authority

let sp = Printf.sprintf

let effect = function
  | Effect.Observe -> "observe"
  | Administer -> "administer"
  | Produce a -> "produce -> " ^ Effect.audience_to_string a
  | Disclose a -> "disclose -> " ^ Effect.audience_to_string a

let principal (a : Decision.about) =
  match a.actor_chain with
  | [] -> Principal.to_string a.subject
  | acting :: via ->
      sp "%s acting for %s%s" (Principal.to_string acting) (Principal.to_string a.subject)
        (match via with [] -> "" | l -> " via " ^ String.concat ", " (List.map Principal.to_string l))

let provenance = function
  | Grant.Root a -> "root: " ^ Grant.anchor_to_string a
  | Grant.Delegated { parent; delegator } ->
      sp "delegated by %s from %s" (Principal.to_string delegator) (Id.Grant.to_string parent)

let render (d : Decision.t) =
  let b = Buffer.create 1024 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  line "%s" (String.uppercase_ascii (Decision.verdict_to_string d.verdict));
  (match d.about with
  | None -> line "request:    not decoded"
  | Some a ->
      line "principal:  %s" (principal a);
      line "mandate:    %s" (match a.query.mandate with Some m -> Id.Mandate.to_string m | None -> "(none claimed)");
      line "capability: %s on %s" (Capability.to_string a.query.capability) (Id.Resource.to_string a.query.resource);
      line "effect:     %s" (match a.query.effect with Some e -> effect e | None -> "(none declared)"));
  (match d.verdict with
  | Allow auth ->
      line "authority:";
      List.iter
        (fun (g : Grant.t) ->
          line "  %-22s %-26s %s" (Id.Grant.to_string g.terms.id) (Principal.to_string g.terms.holder) (provenance g.provenance))
        (Nonempty.to_list (Chain.links (Authority.chain auth)));
      line "  anchor: %s" (Authority.anchor_statement auth);
      line "checks:     all %d passed" (List.length (Authority.checks auth))
  | Deny rs | Indeterminate rs ->
      line "reason:";
      List.iter (fun (r : Decision.reason) -> line "  %s" r.message) (Nonempty.to_list rs));
  (match d.evidence.candidates with
  | [] -> ()
  | cs ->
      line "candidates:";
      List.iter
        (fun (c : Decision.candidate) ->
          let open_checks =
            List.filter_map
              (fun (k : Check.t) ->
                match k.outcome with
                | Check.Pass -> None
                | o -> Some (sp "%s %s" (Check.name_to_string k.name) (Check.outcome_to_string o)))
              c.checks
          in
          let status = Decision.status_to_string c.status and grant = Id.Grant.to_string c.grant in
          match open_checks with
          | [] -> line "  %-22s %s" grant status
          | l -> line "  %-22s %-13s %s" grant status (String.concat ", " l))
        cs);
  Buffer.contents b
