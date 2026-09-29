open Decision

let sp = Printf.sprintf
let max_request_bytes = 1_048_576
let reason code fmt = Printf.ksprintf (fun message -> { code; message }) fmt
let unique eq l = List.rev (List.fold_left (fun acc x -> if List.exists (eq x) acc then acc else x :: acc) [] l)

(* Each element that occurs more than once, reported once. *)
let duplicates eq l =
  let rec go seen dups = function
    | [] -> List.rev dups
    | x :: xs ->
        let dup = List.exists (eq x) seen && not (List.exists (eq x) dups) in
        go (x :: seen) (if dup then x :: dups else dups) xs
  in
  go [] [] l

(* Step 1. Every failure is reported, not only the first. *)
let well_formedness (r : Request.t) =
  let l = r.ledger and f = r.facts and q = r.query and pstr = Principal.to_string in
  let fact_principals = List.map (fun (x : Facts.roles) -> x.principal) f.principals in
  let in_request = unique Principal.equal (f.subject :: f.actor_chain) in
  let registered (p : Principal.t) = Ledger.find_principal l p.id in
  let dup what to_string ids = List.map (fun i -> reason Inconsistent_ledger "duplicate %s id %s" what (to_string i)) ids in
  List.concat
    [ (if Option.is_none q.mandate then [ reason Missing_mandate "no mandate claimed" ] else []);
      (if Option.is_none q.effect then [ reason Missing_effect "no effect declared; an action without one cannot be authorized" ]
       else []);
      List.filter_map
        (fun p -> if Option.is_some (registered p) then None else Some (reason Unknown_principal "%s is not in ledger.principals" (pstr p)))
        in_request;
      (* Every ledger entry with the id, not the first one: with a ledger that
         registers an id twice the reasons must not depend on ledger order. *)
      List.concat_map
        (fun (p : Principal.t) ->
          List.filter_map
            (fun (x : Principal.t) ->
              if Id.Principal.equal x.id p.id && x.kind <> p.kind then
                Some (reason Principal_kind_mismatch "the facts name %s; the ledger has %s" (pstr p) (pstr x))
              else None)
            l.principals)
        (unique Principal.equal (in_request @ fact_principals));
      (match q.mandate with
      | Some m when Option.is_none (Ledger.find_mandate l m) ->
          [ reason Unknown_mandate "mandate %s is not declared in the ledger" (Id.Mandate.to_string m) ]
      | _ -> []);
      dup "principal" Id.Principal.to_string (duplicates Id.Principal.equal (List.map (fun (p : Principal.t) -> p.id) l.principals));
      dup "mandate" Id.Mandate.to_string (duplicates Id.Mandate.equal (List.map (fun (m : Mandate.t) -> m.id) l.mandates));
      dup "grant" Id.Grant.to_string (duplicates Id.Grant.equal (List.map (fun e -> (Grant.terms e).id) l.entries));
      dup "prohibition" Id.Prohibition.to_string
        (duplicates Id.Prohibition.equal (List.map (fun (p : Ledger.prohibition) -> p.id) l.prohibitions));
      List.map (fun p -> reason Inconsistent_facts "the actor chain names %s more than once" (pstr p)) (duplicates Principal.same_id f.actor_chain);
      (if List.exists (Principal.same_id f.subject) f.actor_chain then
         [ reason Inconsistent_facts "the actor chain contains the subject %s" (pstr f.subject) ]
       else []);
      List.map (fun p -> reason Inconsistent_facts "facts.principals lists %s more than once" (pstr p)) (duplicates Principal.same_id fact_principals) ]

(* Step 2: checks that depend on no grant. *)
let request_checks (q : Request.query) (mandate : Mandate.t option) =
  match mandate with
  | None ->
      let why = match q.mandate with None -> "no mandate claimed" | Some m -> sp "mandate %s is not declared in the ledger" (Id.Mandate.to_string m) in
      [ Check.unknown Check.Mandate_covers_capability why; Check.unknown Check.Effect_within_mandate why ]
  | Some m ->
      let mid = Id.Mandate.to_string m.id and cap = Capability.to_string q.capability in
      [ Check.of_bool Check.Mandate_covers_capability
          (Nonempty.exists (Capability.equal q.capability) m.capabilities)
          ~pass:(sp "mandate %s covers %s" mid cap)
          ~fail:(sp "mandate %s covers %s - not %s" mid (Capability.list_to_string (Nonempty.to_list m.capabilities)) cap);
        (match q.effect with
        | None -> Check.unknown Check.Effect_within_mandate "no effect declared"
        | Some e ->
            let bound = Effect.list_to_string m.effects and e' = Effect.to_string e in
            Check.of_bool Check.Effect_within_mandate (Effect.within e m.effects)
              ~pass:(sp "%s is within mandate %s effects %s" e' mid bound)
              ~fail:(sp "mandate %s bounds effects to %s - not %s" mid bound e')) ]

(* Prohibitions bind the subject and everyone in the actor chain, so
   delegated authority cannot escape a restriction on the delegator. The
   holder is matched by id alone: ledger principal ids are unique across
   kinds, and a deny must not be dropped because its holder was written with
   the wrong kind (honoring an unverified deny is always safe). *)
let prohibition_checks (r : Request.t) =
  let bound = Facts.token_path r.facts in
  List.filter_map
    (fun (p : Ledger.prohibition) ->
      if not (List.exists (Principal.same_id p.holder) bound) then None
      else
        let outcome, detail =
          match r.query.effect with
          | None -> (Check.Unknown, "no effect declared")
          | Some e -> (
              match List.find_opt (fun pe -> Effect.leq pe e) (Nonempty.to_list p.effects) with
              | Some pe ->
                  ( Check.Fail,
                    sp "%s may not cause %s or wider (%s); requested %s" (Principal.to_string p.holder) (Effect.to_string pe)
                      p.reason (Effect.to_string e) )
              | None -> (Check.Pass, sp "%s is not at or above %s" (Effect.to_string e) (Effect.list_to_string p.effects)))
        in
        Some { prohibition = p.id; outcome; detail })
    r.ledger.prohibitions

(* What one candidate contributes to the outcome. *)
type contribution = Authority of Mint.t * int (* chain length *) | Refutation of reason Nonempty.t | Gap of reason

(* Step 3: one candidate, every check. *)
let assess (r : Request.t) req_checks entry =
  let f = r.facts and q = r.query and t = Grant.terms entry in
  let g = Id.Grant.to_string t.id and acting = Facts.acting f and pstr = Principal.to_string in
  let token = Facts.token_path f in
  let holder_is_actor =
    Check.of_bool Check.Holder_is_actor (Principal.equal t.holder acting)
      ~pass:(sp "holder %s is the acting principal" (pstr t.holder))
      ~fail:(sp "holder %s is not the acting principal %s" (pstr t.holder) (pstr acting))
  in
  let path_matches =
    match Chain.delegation_path r.ledger entry with
    | None -> Check.unknown Check.Delegation_path_matches "the ledger's delegation path cannot be resolved"
    | Some path ->
        let ledger_path = Principal.path_to_string path and token_path = Principal.path_to_string token in
        Check.of_bool Check.Delegation_path_matches (List.equal Principal.equal path token)
          ~pass:(sp "ledger path %s matches token path %s" ledger_path token_path)
          ~fail:(sp "ledger path %s differs from token path %s" ledger_path token_path)
  in
  let target =
    let tg = Capability.target_to_string t.target and res = Id.Resource.to_string q.resource in
    Check.of_bool Check.Target_covers_resource (Capability.covers t.target q.resource)
      ~pass:(sp "target %s covers %s" tg res) ~fail:(sp "target %s does not cover %s" tg res)
  in
  let permitted =
    match q.mandate with
    | None -> Check.unknown Check.Mandate_permitted "no mandate claimed"
    | Some m ->
        let usable = String.concat ", " (List.map Id.Mandate.to_string (Nonempty.to_list t.mandates)) in
        Check.of_bool Check.Mandate_permitted (Nonempty.exists (Id.Mandate.equal m) t.mandates)
          ~pass:(sp "usable under %s" (Id.Mandate.to_string m))
          ~fail:(sp "usable only under %s - not %s" usable (Id.Mandate.to_string m))
  in
  let within =
    match q.effect with
    | None -> Check.unknown Check.Effect_within_grant "no effect declared"
    | Some e ->
        let bound = Effect.list_to_string t.effects and e' = Effect.to_string e in
        Check.of_bool Check.Effect_within_grant (Effect.within e t.effects)
          ~pass:(sp "%s is within grant effects %s" e' bound) ~fail:(sp "grant bounds effects to %s - not %s" bound e')
  in
  let chain = match entry with Grant.Anchored grant -> Some (Chain.verify r.ledger f grant) | Grant.Unanchored _ -> None in
  let findings to_string l =
    String.concat "; " (List.map (fun (x : _ Chain.finding) -> sp "%s: %s" (to_string x.code) x.detail) (Nonempty.to_list l))
  in
  let provenance =
    match chain with
    | None -> Check.unknown Check.Provenance "the ledger entry has no provenance (unanchored) and can never authorize"
    | Some (Chain.Verified v) -> { Check.name = Provenance; outcome = Pass; detail = "verified " ^ Chain.describe v }
    | Some (Chain.Invalid faults) -> { Check.name = Provenance; outcome = Fail; detail = findings Chain.fault_code_to_string faults }
    | Some (Chain.Unverifiable gaps) -> Check.unknown Check.Provenance (findings Chain.gap_code_to_string gaps)
  in
  let checks = [ holder_is_actor; path_matches; target; permitted; within ] @ req_checks @ [ provenance ] in
  (* Request-level checks keep their unprefixed message so the DENY summary
     lists them once. *)
  let failure (c : Check.t) =
    match (c.name, chain) with
    | Check.Provenance, Some (Chain.Invalid faults) ->
        let message (x : _ Chain.finding) = if Id.Grant.equal x.grant t.id then x.detail else sp "%s: %s" g x.detail in
        List.map (fun (x : _ Chain.finding) -> { code = Fault x.code; message = message x }) (Nonempty.to_list faults)
    | (Check.Mandate_covers_capability | Check.Effect_within_mandate), _ -> [ { code = Failed c.name; message = c.detail } ]
    | _ -> [ { code = Failed c.name; message = sp "%s: %s" g c.detail } ]
  in
  let gap () =
    let open_checks = List.filter (fun (c : Check.t) -> c.outcome <> Check.Pass) checks in
    reason Insufficient_evidence "%s: %s" g
      (String.concat "; " (List.map (fun (c : Check.t) -> sp "%s: %s" (Check.name_to_string c.name) c.detail) open_checks))
  in
  let contribution =
    match (List.concat_map failure (List.filter (fun (c : Check.t) -> c.outcome = Check.Fail) checks), chain) with
    | x :: xs, _ -> Refutation (Nonempty.make x xs)
    | [], Some (Chain.Verified v) -> (
        match Mint.mint v checks f.source with Some a -> Authority (a, Nonempty.length (Chain.links v)) | None -> Gap (gap ()))
    | [], _ -> Gap (gap ())
  in
  let status = match contribution with Authority _ -> Authorizes | Refutation _ -> Refuted | Gap _ -> Undetermined in
  ({ grant = t.id; status; checks }, contribution)

let no_grant (r : Request.t) held =
  let acting = Facts.acting r.facts and subject = r.facts.subject in
  let holders =
    if Principal.equal acting subject then Principal.to_string acting
    else sp "%s or %s" (Principal.to_string acting) (Principal.to_string subject)
  in
  reason No_grant_for_capability "no grant for %s is held by %s; the ledger's entries for %s cover %s"
    (Capability.to_string r.query.capability) holders (Principal.to_string acting)
    (match held with [] -> "no capability" | l -> Capability.list_to_string l)

(* Step 4: the first matching rule decides. *)
let evaluate (r : Request.t) =
  let q = r.query and f = r.facts in
  let acting = Facts.acting f in
  let req_checks = request_checks q (Option.bind q.mandate (Ledger.find_mandate r.ledger)) in
  let held_by p e = Principal.equal (Grant.terms e).holder p in
  let is_candidate e = Capability.equal (Grant.terms e).capability q.capability && (held_by acting e || held_by f.subject e) in
  let assessed = List.map (assess r req_checks) (List.filter is_candidate r.ledger.entries) in
  let prohibitions = prohibition_checks r in
  let held = unique Capability.equal (List.filter_map (fun e -> if held_by acting e then Some (Grant.terms e).capability else None) r.ledger.entries) in
  let pick f = List.filter_map (fun (c, k) -> f c k) assessed in
  let verdict =
    match well_formedness r with
    | w :: ws -> Indeterminate (Nonempty.make w ws)
    | [] -> (
        let applies (p : prohibition_check) = p.outcome = Check.Fail in
        match List.filter applies prohibitions with
        | p :: ps ->
            let why (p : prohibition_check) = reason Prohibited "%s: %s" (Id.Prohibition.to_string p.prohibition) p.detail in
            Deny (Nonempty.map why (Nonempty.make p ps))
        | [] -> (
            (* shortest chain first, then lowest grant id *)
            let rank (l1, g1, _) (l2, g2, _) = match Int.compare l1 l2 with 0 -> Id.Grant.compare g1 g2 | n -> n in
            let authorities = pick (fun c k -> match k with Authority (a, len) -> Some (len, c.grant, a) | _ -> None) in
            match List.sort rank authorities with
            | (_, _, a) :: _ -> Allow a
            | [] -> (
                match pick (fun _ k -> match k with Gap g -> Some g | _ -> None) with
                | g :: gs -> Indeterminate (Nonempty.make g gs)
                | [] -> (
                    let request_failures =
                      List.filter_map
                        (fun (c : Check.t) -> if c.outcome = Check.Fail then Some { code = Failed c.name; message = c.detail } else None)
                        req_checks
                    in
                    match pick (fun _ k -> match k with Refutation rs -> Some rs | _ -> None) with
                    | [] -> Deny (Nonempty.make (no_grant r held) request_failures)
                    | rs :: rss -> Deny (Nonempty.dedup (Nonempty.prepend request_failures (Nonempty.concat rs rss)))))))
  in
  let about = { query = q; subject = f.subject; actor_chain = f.actor_chain } in
  make Mint.seal ~request_id:r.request_id ~about:(Some about) ~verdict
    ~evidence:{ request_checks = req_checks; prohibitions; candidates = List.map fst assessed; held }

let undecodable code message =
  make Mint.seal ~request_id:None ~about:None ~verdict:(Indeterminate (Nonempty.singleton { code; message }))
    ~evidence:{ request_checks = []; prohibitions = []; candidates = []; held = [] }

let run input =
  if String.length input > max_request_bytes then
    undecodable Request_too_large (sp "the request exceeds %d bytes (1 MiB)" max_request_bytes)
  else match Codec.parse_request input with Error m -> undecodable Malformed_request m | Ok r -> evaluate r
