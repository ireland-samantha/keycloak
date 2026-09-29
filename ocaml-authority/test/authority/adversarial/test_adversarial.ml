(* Adversarial review of the authority semantics (lens: authority semantics).

   Every attack below asserts what docs/authority-model.md requires. A case
   that fails against the kernel is a real weakness. Weaknesses that are out
   of reach by construction (threat-model.md) or would need a design change
   are pinned by cases named "known_weakness_*": they assert the CURRENT,
   undesired behaviour, so that fixing it later is a visible, deliberate
   change.

   Every decision computed here, plus every scenario of the files given on
   the command line (demo.json, adversarial.json), is also checked against
   property oracles that re-derive the answer from the request without the
   kernel's code: evidence completeness (hypothesis S2), the binding of an
   ALLOW's authority to the request it answers, and determinism. *)

open Authority

let sp = Printf.sprintf
let failures = ref 0
let count = ref 0

let case name f =
  incr count;
  match f () with
  | () -> ()
  | exception e ->
      incr failures;
      Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e)

exception Assertion of string

let check what ok = if not ok then raise (Assertion what)
let expect_eq show what expected actual = if expected <> actual then raise (Assertion (sp "%s: expected %s, got %s" what (show expected) (show actual)))
let strings l = "[" ^ String.concat "; " l ^ "]"
let ok = function Ok x -> x | Error e -> failwith e
let ne l = Option.get (Nonempty.of_list l)

(* ---------- fixtures ---------- *)

let pid s = ok (Id.Principal.of_string s)
let user s = { Principal.kind = User; id = pid s }
let service s = { Principal.kind = Service; id = pid s }
let samantha = user "samantha"
let bob = user "bob"
let carol = user "carol"
let mallory = user "mallory"
let agent = service "research-agent"
let planner = service "planner-agent"
let summarizer = service "summarizer-agent"
let ghost = service "ghost-agent"
let gid s = ok (Id.Grant.of_string s)
let mid s = ok (Id.Mandate.of_string s)
let role s = ok (Id.Role.of_string s)
let client s = ok (Id.Client.of_string s)
let ts s = ok (Timestamp.of_string s)
let cap rt a = { Capability.resource_type = ok (Id.Resource_type.of_string rt); action = ok (Id.Action.of_string a) }
let read = cap "document" "read"
let generate = cap "document" "generate"
let publish = cap "document" "publish"
let index = cap "document" "index"
let res s = ok (Id.Resource.of_string s)
let author = Grant.Realm_role (role "report-author")
let publisher = Grant.Realm_role (role "document-publisher")
let reader = Grant.Client_role { client = client "document-service"; role = role "reader" }
let now = "2026-09-29T12:00:00Z"

let terms ?(capability = read) ?(target = Capability.Any_resource) ?(mandates = [ "generate-report" ]) ?(effects = [ Effect.Observe ])
    ?valid_from ?valid_until ?(depth = 0) id holder =
  { Grant.id = gid id; holder; capability; target; mandates = ne (List.map mid mandates); effects = ne effects;
    valid_from = Option.map ts valid_from; valid_until = Option.map ts valid_until; delegable_depth = depth }

let root ?(anchor = author) t = Grant.Anchored { terms = t; provenance = Root anchor }
let delegated ~by parent t = Grant.Anchored { terms = t; provenance = Delegated { parent = gid parent; delegator = by } }
let unanchored t = Grant.Unanchored { claimed = t }

let mandate ~effects id caps = { Mandate.id = mid id; purpose = id; capabilities = ne caps; effects = ne effects }

let mandates =
  [ mandate "generate-report" [ read; generate ] ~effects:[ Observe; Produce Organization ];
    mandate "publish-release" [ publish ] ~effects:[ Disclose Public ];
    (* the agent's own purpose ("A"), distinct from samantha's ("B") *)
    mandate "agent-maintenance" [ read; index ] ~effects:[ Observe ];
    mandate "security-audit" [ read ] ~effects:[ Observe ] ]

let registered = [ samantha; bob; carol; agent; planner; summarizer ]

let ledger ?(principals = registered) ?(revocations = []) ?(prohibitions = []) entries =
  { Ledger.principals; mandates; entries; revocations; prohibitions }

let revoke ?(at = "2026-07-01T00:00:00Z") id = { Ledger.grant = gid id; reason = "revoked by the test"; at = ts at }
let prohibit id holder effects = { Ledger.id = ok (Id.Prohibition.of_string id); holder; effects = ne effects; reason = "test" }

let roles ?(realm = []) ?(clients = []) p =
  { Facts.principal = p; realm_roles = List.map role realm; client_roles = List.map (fun (c, rs) -> (client c, List.map role rs)) clients }

let live_roles =
  [ roles ~realm:[ "report-author"; "document-publisher" ] samantha; roles ~realm:[ "report-author" ] bob;
    roles ~realm:[ "report-author" ] carol; roles ~clients:[ ("document-service", [ "reader" ]) ] agent; roles planner; roles summarizer ]

let facts ?(at = now) ?(subject = samantha) ?(chain = []) ?(principals = live_roles) () =
  { Facts.source = Fixture; realm = None; evaluated_at = ts at; subject; actor_chain = chain; principals }

let request ?(mandate = Some "generate-report") ?(capability = read) ?(resource = "q3-report") ?(effect = Some Effect.Observe)
    ?(facts = facts ()) l =
  { Request.request_id = None; facts; ledger = l; query = { mandate = Option.map mid mandate; capability; resource = res resource; effect } }

(* ---------- recording and expectations ---------- *)

(* Every decision computed by an attack, for the property oracles below. *)
let recorded : (string * Request.t * Decision.t) list ref = ref []

let decide name r =
  let d = Evaluate.evaluate r in
  recorded := (name, r, d) :: !recorded;
  d

let verdict (d : Decision.t) = Decision.verdict_to_string d.verdict
let codes (d : Decision.t) = List.map (fun (r : Decision.reason) -> Decision.reason_code_to_string r.code) (Decision.reasons d)

let allowed_grant (d : Decision.t) =
  match d.verdict with Allow a -> Some (Id.Grant.to_string (Authority.grant a).terms.id) | Deny _ | Indeterminate _ -> None

let status_of (d : Decision.t) g =
  List.find_map
    (fun (c : Decision.candidate) -> if Id.Grant.to_string c.grant = g then Some (Decision.status_to_string c.status) else None)
    d.evidence.candidates

(* The failed checks of candidate [g], with a failed provenance check
   expanded into the chain fault codes (re-derived with Chain.verify). *)
let failing_of (r : Request.t) (d : Decision.t) g =
  match List.find_opt (fun (c : Decision.candidate) -> Id.Grant.to_string c.grant = g) d.evidence.candidates with
  | None -> raise (Assertion (g ^ " is not a candidate"))
  | Some c ->
      let expand () =
        match List.find_opt (fun e -> Id.Grant.equal (Grant.terms e).id c.grant) r.ledger.entries with
        | Some (Grant.Anchored grant) -> (
            match Chain.verify r.ledger r.facts grant with
            | Chain.Invalid fs -> List.map (fun (x : _ Chain.finding) -> Chain.fault_code_to_string x.code) (Nonempty.to_list fs)
            | Verified _ | Unverifiable _ -> [ "provenance" ])
        | Some (Grant.Unanchored _) | None -> [ "provenance" ]
      in
      List.sort_uniq compare
        (List.concat_map
           (fun (k : Check.t) ->
             if k.outcome <> Check.Fail then [] else if k.name = Check.Provenance then expand () else [ Check.name_to_string k.name ])
           c.checks)

(* [reasons] must appear among the decision's reason codes (as in the
   scenario files); [only] must be exactly the set of distinct codes;
   [refutes = (g, codes)]: exactly [codes] fail for candidate [g]. *)
let expect ?grant ?(reasons = []) ?only ?refutes ?(statuses = []) name r v =
  case name (fun () ->
      let d = decide name r in
      let got = codes d in
      if verdict d <> v then raise (Assertion (sp "verdict: expected %s, got %s %s" v (verdict d) (strings got)));
      List.iter (fun c -> if not (List.mem c got) then raise (Assertion (sp "reason %s not among %s" c (strings got)))) reasons;
      (match only with
      | Some cs -> expect_eq strings "distinct reason codes" (List.sort_uniq compare cs) (List.sort_uniq compare got)
      | None -> ());
      (match refutes with
      | Some (g, cs) -> expect_eq strings ("failed checks of " ^ g) (List.sort_uniq compare cs) (failing_of r d g)
      | None -> ());
      (match grant with Some g -> expect_eq (Option.value ~default:"(none)") "allowing grant" (Some g) (allowed_grant d) | None -> ());
      List.iter (fun (g, s) -> expect_eq (Option.value ~default:"(not a candidate)") ("status of " ^ g) (Some s) (status_of d g)) statuses)

(* ======================================================================
   1. Confused deputy. research-agent holds its own read authority for
      purpose A (agent-maintenance) and a delegation from samantha for
      purpose B (generate-report); bob also delegated to it. Every
      combination of whose grant, which token path and which mandate.
   ====================================================================== *)

let cd_entries =
  [ root ~anchor:author (terms ~depth:1 "g-sam-read" samantha);
    root ~anchor:reader (terms ~mandates:[ "agent-maintenance" ] "g-agent-own-read" agent);
    root ~anchor:reader (terms ~capability:index ~mandates:[ "agent-maintenance" ] "g-agent-own-index" agent);
    delegated ~by:samantha "g-sam-read" (terms ~target:(Resource (res "q3-report")) "d-agent-read-sam" agent);
    root ~anchor:author (terms ~depth:1 "g-bob-read" bob);
    delegated ~by:bob "g-bob-read" (terms ~target:(Resource (res "q3-report")) "d-agent-read-bob" agent) ]

let cd ?revocations () = ledger ?revocations cd_entries
let direct = facts ~subject:agent ()
let for_sam = facts ~subject:samantha ~chain:[ agent ] ()
let for_bob = facts ~subject:bob ~chain:[ agent ] ()

let () =
  expect "confused-deputy: own token, own purpose A, own grant" (request ~mandate:(Some "agent-maintenance") ~facts:direct (cd ()))
    "allow" ~grant:"g-agent-own-read";
  expect "confused-deputy: own token, samantha's purpose B" (request ~facts:direct (cd ())) "deny"
    ~only:[ "mandate_permitted"; "delegation_path_matches" ]
    ~statuses:[ ("g-agent-own-read", "refuted"); ("d-agent-read-sam", "refuted"); ("d-agent-read-bob", "refuted") ];
  expect "confused-deputy: acting for samantha, purpose B, her delegation" (request ~facts:for_sam (cd ())) "allow"
    ~grant:"d-agent-read-sam"
    ~statuses:[ ("g-sam-read", "refuted"); ("g-agent-own-read", "refuted"); ("d-agent-read-bob", "refuted") ];
  expect "confused-deputy: acting for samantha, the agent's purpose A" (request ~mandate:(Some "agent-maintenance") ~facts:for_sam (cd ()))
    "deny" ~reasons:[ "delegation_path_matches"; "mandate_permitted" ]
    ~statuses:[ ("g-agent-own-read", "refuted"); ("d-agent-read-sam", "refuted"); ("g-sam-read", "refuted") ];
  expect "confused-deputy: acting for samantha, a capability only the agent holds (pure deputy)"
    (request ~mandate:(Some "agent-maintenance") ~capability:index ~facts:for_sam (cd ()))
    "deny" ~only:[ "delegation_path_matches" ];
  expect "confused-deputy: acting for bob uses bob's delegation, never samantha's" (request ~facts:for_bob (cd ())) "allow"
    ~grant:"d-agent-read-bob" ~statuses:[ ("d-agent-read-sam", "refuted") ];
  expect "confused-deputy: bob's delegation revoked; samantha's does not substitute"
    (request ~facts:for_bob (cd ~revocations:[ revoke "d-agent-read-bob" ] ())) "deny" ~reasons:[ "revoked"; "delegation_path_matches" ]
    ~statuses:[ ("d-agent-read-sam", "refuted"); ("g-bob-read", "refuted") ];
  expect "confused-deputy: samantha directly, under the agent's purpose A" (request ~mandate:(Some "agent-maintenance") (cd ())) "deny"
    ~only:[ "mandate_permitted" ];
  expect "confused-deputy: the subject's own root grant while an agent acts (holder is not the actor)"
    (request ~facts:for_sam (ledger [ List.hd cd_entries ])) "deny" ~only:[ "holder_is_actor"; "delegation_path_matches" ]

(* ======================================================================
   2. Stale grants.
   ====================================================================== *)

let sam_root ?valid_from ?valid_until () = root (terms ?valid_from ?valid_until ~depth:1 "g-sam-read" samantha)
let sam_child ?valid_from ?valid_until () = delegated ~by:samantha "g-sam-read" (terms ?valid_from ?valid_until ~target:(Resource (res "q3-report")) "d-agent-read" agent)

(* carol -> planner-agent -> summarizer-agent -> research-agent *)
let chain3 =
  [ root (terms ~depth:3 "g-carol-read" carol);
    delegated ~by:carol "g-carol-read" (terms ~depth:2 "d-planner-read" planner);
    delegated ~by:planner "d-planner-read" (terms ~depth:1 "d-summarizer-read" summarizer);
    delegated ~by:summarizer "d-summarizer-read" (terms ~target:(Resource (res "q3-report")) "d-agent-read3" agent) ]

let via3 ?at ?principals chain = facts ?at ?principals ~subject:carol ~chain ()
let full3 = [ agent; summarizer; planner ]

let () =
  expect "stale-grant: expired parent, unexpired child"
    (request ~facts:for_sam (ledger [ sam_root ~valid_until:"2026-09-01T00:00:00Z" (); sam_child ~valid_until:"2026-12-31T00:00:00Z" () ]))
    "deny" ~reasons:[ "expired"; "validity_extended" ] ~refutes:("d-agent-read", [ "expired"; "validity_extended" ]);
  expect "stale-grant: child valid_from before the parent's valid_from"
    (request ~facts:for_sam (ledger [ sam_root ~valid_from:"2026-06-01T00:00:00Z" (); sam_child ~valid_from:"2026-05-01T00:00:00Z" () ]))
    "deny" ~refutes:("d-agent-read", [ "validity_extended" ]);
  expect "stale-grant: revoked root with a live delegation"
    (request ~facts:for_sam (ledger ~revocations:[ revoke "g-sam-read" ] [ sam_root (); sam_child () ])) "deny" ~refutes:("d-agent-read", [ "revoked" ]);
  expect "stale-grant: revoked middle link of a depth-3 chain" (request ~facts:(via3 full3) (ledger ~revocations:[ revoke "d-planner-read" ] chain3))
    "deny" ~refutes:("d-agent-read3", [ "revoked" ]);
  expect "stale-grant: anchor role removed below a depth-3 chain"
    (request ~facts:(via3 ~principals:(roles carol :: List.tl (List.tl (List.tl live_roles))) full3) (ledger chain3))
    "deny" ~refutes:("d-agent-read3", [ "anchor_missing" ]);
  expect "stale-grant: a revocation dated in the future already revokes (at is not consulted)"
    (request ~facts:for_sam (ledger ~revocations:[ revoke ~at:"2027-01-01T00:00:00Z" "d-agent-read" ] [ sam_root (); sam_child () ]))
    "deny" ~refutes:("d-agent-read", [ "revoked" ]);
  expect "stale-grant: revoking an unrelated sibling does not reach this chain"
    (request ~facts:for_sam
       (ledger ~revocations:[ revoke "d-agent-sibling" ]
          [ sam_root (); sam_child ();
            delegated ~by:samantha "g-sam-read" (terms ~target:(Resource (res "q4-report")) "d-agent-sibling" agent) ]))
    "allow" ~grant:"d-agent-read";
  (* boundary instants: a window [2026-09-01, 2026-10-01) on both links *)
  let window at = request ~facts:(facts ~at ~subject:samantha ~chain:[ agent ] ())
      (ledger [ sam_root ~valid_from:"2026-09-01T00:00:00Z" ~valid_until:"2026-10-01T00:00:00Z" ();
                sam_child ~valid_from:"2026-09-01T00:00:00Z" ~valid_until:"2026-10-01T00:00:00Z" () ]) in
  expect "stale-grant: exactly valid_from is valid" (window "2026-09-01T00:00:00Z") "allow";
  expect "stale-grant: one second before valid_from" (window "2026-08-31T23:59:59Z") "deny" ~refutes:("d-agent-read", [ "not_yet_valid" ]);
  expect "stale-grant: one second before valid_until is valid" (window "2026-09-30T23:59:59Z") "allow";
  expect "stale-grant: exactly valid_until is expired" (window "2026-10-01T00:00:00Z") "deny" ~refutes:("d-agent-read", [ "expired" ])

(* ======================================================================
   3. Delegation chains: depth 2 and 3, matching, reversed, skipping or
      adding a hop; depth limits; cycles; an unregistered middle holder.
   ====================================================================== *)

let () =
  let l = ledger chain3 in
  expect "delegation-chain: depth 2, actor chain matches" (request ~facts:(via3 [ summarizer; planner ]) l) "allow" ~grant:"d-summarizer-read";
  expect "delegation-chain: depth 3, actor chain matches" (request ~facts:(via3 full3) l) "allow" ~grant:"d-agent-read3";
  expect "delegation-chain: depth 2, actor chain reversed" (request ~facts:(via3 [ planner; summarizer ]) l) "deny"
    ~refutes:("d-planner-read", [ "delegation_path_matches" ]);
  expect "delegation-chain: depth 3, actor chain reversed" (request ~facts:(via3 [ planner; summarizer; agent ]) l) "deny"
    ~refutes:("d-planner-read", [ "delegation_path_matches" ]);
  expect "delegation-chain: depth 3, token skips the middle hop" (request ~facts:(via3 [ agent; planner ]) l) "deny"
    ~refutes:("d-agent-read3", [ "delegation_path_matches" ]);
  expect "delegation-chain: depth 2, token skips the first hop" (request ~facts:(via3 [ summarizer ]) l) "deny"
    ~refutes:("d-summarizer-read", [ "delegation_path_matches" ]);
  expect "delegation-chain: token adds a hop the ledger does not have"
    (request ~facts:(facts ~subject:samantha ~chain:[ agent; planner ] ()) (ledger [ sam_root (); sam_child () ])) "deny"
    ~refutes:("d-agent-read", [ "delegation_path_matches" ]);
  let depth ~root_depth ~mid_depth =
    ledger
      [ root (terms ~depth:root_depth "g-carol-read" carol);
        delegated ~by:carol "g-carol-read" (terms ~depth:mid_depth "d-planner-read" planner);
        delegated ~by:planner "d-planner-read" (terms "d-summarizer-read" summarizer) ]
  in
  let depth2 = via3 [ summarizer; planner ] in
  expect "delegation-chain: root depth 1 cannot reach a grandchild" (request ~facts:depth2 (depth ~root_depth:1 ~mid_depth:0)) "deny"
    ~refutes:("d-summarizer-read", [ "delegation_depth_exceeded" ]);
  expect "delegation-chain: a child may not keep its parent's depth" (request ~facts:depth2 (depth ~root_depth:2 ~mid_depth:2)) "deny"
    ~refutes:("d-summarizer-read", [ "delegation_depth_exceeded" ]);
  expect "delegation-chain: root depth 2, child 1, grandchild 0 is exactly enough" (request ~facts:depth2 (depth ~root_depth:2 ~mid_depth:1))
    "allow";
  let cycle =
    ledger
      [ delegated ~by:summarizer "d-cycle-b" (terms ~depth:5 "d-cycle-a" planner);
        delegated ~by:planner "d-cycle-a" (terms ~depth:5 "d-cycle-b" summarizer) ]
  in
  expect "delegation-chain: cycle A -> B -> A" (request ~facts:(facts ~subject:summarizer ~chain:[ planner ] ()) cycle) "deny" ~reasons:[ "cycle" ]
    ~refutes:("d-cycle-a", [ "cycle"; "delegation_depth_exceeded" ]);
  expect "delegation-chain: a grant that is its own parent"
    (request ~facts:(facts ~subject:planner ()) (ledger [ delegated ~by:planner "d-self" (terms ~depth:3 "d-self" planner) ]))
    "deny" ~only:[ "cycle" ];
  (* carol -> ghost-agent -> research-agent; ghost-agent is not in ledger.principals *)
  let ghostly =
    ledger
      [ root (terms ~depth:2 "g-carol-read" carol);
        delegated ~by:carol "g-carol-read" (terms ~depth:1 "d-ghost-read" ghost);
        delegated ~by:ghost "d-ghost-read" (terms "d-agent-via-ghost" agent) ]
  in
  expect "delegation-chain: unregistered middle holder named in the token" (request ~facts:(via3 [ agent; ghost ]) ghostly) "indeterminate"
    ~only:[ "unknown_principal" ];
  expect "delegation-chain: unregistered middle holder omitted from the token" (request ~facts:(via3 [ agent ]) ghostly) "deny"
    ~refutes:("d-agent-via-ghost", [ "delegation_path_matches" ]);
  let long n =
    ledger
      (List.init n (fun i ->
           let holder = if i mod 2 = 0 then samantha else agent and prev = if i mod 2 = 1 then samantha else agent in
           let t = terms ~depth:(n - 1 - i) (sp "g%02d" i) holder in
           if i = 0 then root t else delegated ~by:prev (sp "g%02d" (i - 1)) t))
  in
  expect "delegation-chain: 18 links (over max_links)"
    (request ~facts:(facts ~subject:agent ()) (long (Chain.max_links + 2))) "deny" ~reasons:[ "chain_too_long" ]
    ~refutes:("g17", [ "chain_too_long" ])

(* ======================================================================
   4. Contradictory grants and prohibitions.
   ====================================================================== *)

let pub_root = root ~anchor:publisher (terms ~capability:publish ~mandates:[ "publish-release" ] ~effects:[ Disclose Public ] "g-sam-publish" samantha)

let publishing ?(facts = facts ()) ?prohibitions ?(entries = [ pub_root ]) e =
  request ~mandate:(Some "publish-release") ~capability:publish ~effect:(Some e) ~facts (ledger ?prohibitions entries)

let () =
  expect "contradictory-grants: one grant authorizes, a twin is revoked (permissive union)"
    (request (ledger ~revocations:[ revoke "g-a-read" ] [ root (terms "g-a-read" samantha); root (terms "g-b-read" samantha) ]))
    "allow" ~grant:"g-b-read" ~statuses:[ ("g-a-read", "refuted") ];
  expect "contradictory-grants: a prohibition beats a valid grant"
    (request ~facts:for_sam (ledger ~prohibitions:[ prohibit "p-agent-observe" agent [ Observe ] ] [ sam_root (); sam_child () ]))
    "deny" ~only:[ "prohibited" ];
  expect "contradictory-grants: a prohibition held by the subject binds its actor"
    (request ~facts:for_sam (ledger ~prohibitions:[ prohibit "p-sam-observe" samantha [ Observe ] ] [ sam_root (); sam_child () ]))
    "deny" ~only:[ "prohibited" ];
  expect "contradictory-grants: a prohibition held by a middle actor of a depth-3 chain"
    (request ~facts:(via3 full3) (ledger ~prohibitions:[ prohibit "p-planner-observe" planner [ Observe ] ] chain3))
    "deny" ~only:[ "prohibited" ];
  expect "contradictory-grants: prohibition on disclose:organization covers disclose:public"
    (publishing ~prohibitions:[ prohibit "p-sam-org" samantha [ Disclose Organization ] ] (Disclose Public)) "deny" ~only:[ "prohibited" ];
  expect "contradictory-grants: prohibition on disclose:organization leaves disclose:self"
    (publishing ~prohibitions:[ prohibit "p-sam-org" samantha [ Disclose Organization ] ] (Disclose Self)) "allow";
  expect "contradictory-grants: a prohibition on an unregistered principal binds nobody here"
    (publishing ~prohibitions:[ prohibit "p-mallory" mallory [ Disclose Self ] ] (Disclose Public)) "allow";
  (* The ledger registers research-agent as a service. A prohibition written
     with the user kind names the same ledger principal (ids are unique across
     kinds, see inconsistent_ledger). Deny-overrides must not be dropped over
     a kind label: "honoring an unverified deny is always safe". *)
  expect "contradictory-grants: prohibition holder named with the wrong kind still binds (deny-overrides)"
    (request ~facts:for_sam (ledger ~prohibitions:[ prohibit "p-agent-kind" (user "research-agent") [ Observe ] ] [ sam_root (); sam_child () ]))
    "deny" ~only:[ "prohibited" ];
  expect "contradictory-grants: duplicate grant ids (one revoked, one not)"
    (request (ledger ~revocations:[ revoke "g-dup" ] [ root (terms "g-dup" samantha); root (terms ~target:(Resource (res "q3-report")) "g-dup" samantha) ]))
    "indeterminate" ~only:[ "inconsistent_ledger" ];
  expect "contradictory-grants: two revocations of one grant with different dates"
    (request ~facts:for_sam
       (ledger ~revocations:[ revoke ~at:"2027-01-01T00:00:00Z" "d-agent-read"; revoke ~at:"2020-01-01T00:00:00Z" "d-agent-read" ]
          [ sam_root (); sam_child () ]))
    "deny" ~refutes:("d-agent-read", [ "revoked" ])

(* ======================================================================
   5. Privilege escalation through delegation.
   ====================================================================== *)

let () =
  let esc child = request ~facts:for_sam (ledger [ sam_root (); child ]) in
  let child ?(by = samantha) ?(parent = "g-sam-read") ?capability ?target ?mandates ?effects ?valid_until ?depth () =
    delegated ~by parent
      (terms ?capability ?mandates ?effects ?valid_until ?depth ~target:(Option.value ~default:(Capability.Resource (res "q3-report")) target) "d-agent-read" agent)
  in
  expect "privilege-escalation: child effects wider than the parent's" (esc (child ~effects:[ Observe; Produce Public ] ())) "deny"
    ~refutes:("d-agent-read", [ "effect_amplified" ]);
  expect "privilege-escalation: child target any below a single-resource parent"
    (request ~facts:for_sam
       (ledger [ root (terms ~depth:1 ~target:(Resource (res "q3-report")) "g-sam-read" samantha); child ~target:Any_resource () ]))
    "deny" ~refutes:("d-agent-read", [ "target_amplified" ]);
  expect "privilege-escalation: child adds a mandate, used under the added one"
    (request ~mandate:(Some "security-audit") ~facts:for_sam (ledger [ sam_root (); child ~mandates:[ "generate-report"; "security-audit" ] () ]))
    "deny" ~refutes:("d-agent-read", [ "mandate_amplified" ]);
  expect "privilege-escalation: child adds a mandate, used under the parent's (whole link invalid)"
    (esc (child ~mandates:[ "generate-report"; "security-audit" ] ())) "deny" ~refutes:("d-agent-read", [ "mandate_amplified" ]);
  expect "privilege-escalation: delegator is not the parent's holder (agent delegates to itself)" (esc (child ~by:agent ())) "deny"
    ~refutes:("d-agent-read", [ "forged_delegation" ]);
  expect "privilege-escalation: self-delegation is never usable"
    (request (ledger [ sam_root (); delegated ~by:samantha "g-sam-read" (terms "d-sam-self" samantha) ]))
    "allow" ~grant:"g-sam-read" ~statuses:[ ("d-sam-self", "refuted") ];
  expect "privilege-escalation: root whose anchor role is held by someone else"
    (request ~facts:direct (ledger [ root ~anchor:author (terms "g-agent-author" agent) ])) "deny" ~only:[ "anchor_missing" ];
  expect "privilege-escalation: delegated grant under a parent of another capability"
    (request ~facts:for_sam
       (ledger [ root (terms ~capability:generate ~depth:1 "g-sam-read" samantha); child () ]))
    "deny" ~only:[ "capability_amplified" ];
  expect "privilege-escalation: parent with delegable_depth 0"
    (request ~facts:for_sam (ledger [ root (terms "g-sam-read" samantha); child () ])) "deny"
    ~refutes:("d-agent-read", [ "delegation_depth_exceeded" ]);
  expect "privilege-escalation: child outlives its parent"
    (request ~facts:for_sam (ledger [ sam_root ~valid_until:"2026-12-01T00:00:00Z" (); child ~valid_until:"2027-12-01T00:00:00Z" () ]))
    "deny" ~refutes:("d-agent-read", [ "validity_extended" ]);
  expect "privilege-escalation: anchored child below an unanchored, all-powerful parent"
    (request ~facts:for_sam
       (ledger
          [ unanchored (terms ~mandates:[ "generate-report"; "security-audit" ] ~effects:[ Observe; Administer ] ~depth:9 "g-sam-read" samantha);
            child () ]))
    "indeterminate" ~only:[ "insufficient_evidence" ]

(* ======================================================================
   6. Unknown principals and kind confusion.
   ====================================================================== *)

let () =
  let l = ledger [ sam_root (); sam_child () ] in
  expect "unknown-principal: actor unknown" (request ~facts:(facts ~subject:samantha ~chain:[ ghost ] ()) l) "indeterminate"
    ~only:[ "unknown_principal" ];
  expect "unknown-principal: subject unknown" (request ~facts:(facts ~subject:mallory ~chain:[ agent ] ()) l) "indeterminate"
    ~only:[ "unknown_principal" ];
  expect "unknown-principal: the ledger registers one id as both user and service"
    (request ~facts:direct (ledger ~principals:(user "research-agent" :: registered) [ root ~anchor:reader (terms "g-agent-own-read" agent) ]))
    "indeterminate" ~reasons:[ "inconsistent_ledger" ];
  expect "unknown-principal: the token names a service id as a user"
    (request ~facts:(facts ~subject:(user "research-agent") ()) (ledger [ root ~anchor:reader (terms "g-agent-own-read" agent) ]))
    "indeterminate" ~only:[ "principal_kind_mismatch" ];
  expect "unknown-principal: role facts list a service id as a user"
    (request ~facts:(facts ~principals:(roles (user "research-agent") :: live_roles) ()) l) "indeterminate"
    ~reasons:[ "principal_kind_mismatch" ];
  expect "unknown-principal: grant holder written with the wrong kind is not even a candidate (fails closed)"
    (request ~facts:direct (ledger [ root ~anchor:reader (terms "g-agent-kind" (user "research-agent")) ])) "deny"
    ~only:[ "no_grant_for_capability" ]

(* ======================================================================
   7. Missing evidence.
   ====================================================================== *)

let () =
  expect "missing-evidence: grant without provenance, otherwise perfect"
    (request ~facts:direct (ledger [ unanchored (terms "u-agent-read" agent) ])) "indeterminate" ~only:[ "insufficient_evidence" ];
  expect "missing-evidence: unanchored ancestor"
    (request ~facts:for_sam (ledger [ unanchored (terms ~depth:1 "g-sam-read" samantha); sam_child () ])) "indeterminate"
    ~only:[ "insufficient_evidence" ];
  expect "missing-evidence: root holder missing from facts.principals"
    (request ~facts:(facts ~subject:samantha ~chain:[ agent ] ~principals:(List.tl live_roles) ()) (ledger [ sam_root (); sam_child () ]))
    "indeterminate" ~only:[ "insufficient_evidence" ];
  expect "missing-evidence: an unanchored twin does not block an anchored grant"
    (request (ledger [ unanchored (terms "u-sam-read" samantha); sam_root () ])) "allow" ~grant:"g-sam-read"
    ~statuses:[ ("u-sam-read", "undetermined") ]

(* ======================================================================
   8. Mandate against capability and effect.
   ====================================================================== *)

let () =
  expect "mandate-capability-mismatch: mandate covers the capability, not the effect"
    (request ~capability:generate ~effect:(Some (Produce Public))
       (ledger [ root (terms ~capability:generate ~effects:[ Produce Public ] "g-sam-generate" samantha) ]))
    "deny" ~only:[ "effect_within_mandate" ];
  expect "mandate-capability-mismatch: mandate covers the effect, not the capability (mandate narrowed after the grant)"
    (request ~mandate:(Some "agent-maintenance") ~capability:generate ~facts:direct
       (ledger [ root ~anchor:reader (terms ~capability:generate ~mandates:[ "agent-maintenance" ] "g-agent-generate" agent) ]))
    "deny" ~only:[ "mandate_covers_capability" ];
  expect "mandate-capability-mismatch: purpose-limited grant claimed under another fitting mandate"
    (request ~mandate:(Some "security-audit") ~facts:direct (ledger [ root ~anchor:reader (terms "g-agent-read" agent) ]))
    "deny" ~only:[ "mandate_permitted" ];
  expect "mandate-capability-mismatch: undeclared mandate" (request ~mandate:(Some "exfiltrate-data") (ledger [ sam_root () ]))
    "indeterminate" ~only:[ "unknown_mandate" ];
  (* The same purpose-limited grant, with the mandate the grant was issued
     for: the claim is the requester's own (limitations.md). *)
  expect "known_weakness_mandate_is_a_pushed_claim: the same agent simply claims the permitted mandate"
    (request ~mandate:(Some "generate-report") ~facts:direct (ledger [ root ~anchor:reader (terms "g-agent-read" agent) ]))
    "allow" ~grant:"g-agent-read"

(* ======================================================================
   9. Authorized operation, unauthorized downstream effect.
   ====================================================================== *)

let () =
  let gen_root = root (terms ~capability:generate ~effects:[ Produce Organization ] ~depth:1 "g-sam-generate" samantha) in
  let gen_child =
    delegated ~by:samantha "g-sam-generate"
      (terms ~capability:generate ~effects:[ Produce Organization ] ~target:(Resource (res "q3-report")) "d-agent-generate" agent)
  in
  let no_public = prohibit "p-agent-no-public" agent [ Disclose Public ] in
  (* "generate report" is allowed as produce:organization. If the real
     consequence is that the report is published (e.g. the generator writes
     into a public bucket), the kernel cannot tell: a request carries exactly
     one declared effect, and there is no field for downstream effects. *)
  expect "known_weakness_downstream_effect_invisible: generate allowed although its real consequence is disclose:public"
    (request ~capability:generate ~effect:(Some (Produce Organization)) ~facts:for_sam (ledger ~prohibitions:[ no_public ] [ gen_root; gen_child ]))
    "allow" ~grant:"d-agent-generate";
  expect "downstream-effect: declared honestly, the same step is prohibited"
    (request ~capability:generate ~effect:(Some (Disclose Public)) ~facts:for_sam (ledger ~prohibitions:[ no_public ] [ gen_root; gen_child ]))
    "deny" ~reasons:[ "prohibited" ];
  (* A capability carries no effect floor: document:publish can be declared
     as disclose:self, which is within the grant, within the mandate and
     below the prohibition. The prohibition "automated agents never publish
     externally" is escaped by under-declaring (threat-model A1). *)
  let agent_publish =
    root ~anchor:reader (terms ~capability:publish ~mandates:[ "publish-release" ] ~effects:[ Disclose Public ] "g-agent-publish" agent)
  in
  expect "known_weakness_underdeclared_effect_evades_prohibition: publish declared as disclose:self"
    (publishing ~facts:direct ~prohibitions:[ no_public ] ~entries:[ agent_publish ] (Disclose Self)) "allow" ~grant:"g-agent-publish";
  expect "downstream-effect: publish declared as disclose:public is prohibited"
    (publishing ~facts:direct ~prohibitions:[ no_public ] ~entries:[ agent_publish ] (Disclose Public)) "deny" ~only:[ "prohibited" ];
  (* The only multi-effect encoding one could try is an array; it is not a
     request (wire-format.md: one effect object). *)
  case "downstream-effect: a request cannot declare two effects" (fun () ->
      let r = request ~capability:generate ~effect:(Some (Produce Organization)) ~facts:for_sam (ledger [ gen_root; gen_child ]) in
      let text = Tjson.to_string (Codec.request_to_json r) in
      let needle = {|"effect":{"kind":"produce","audience":"organization"}|} in
      let i = let n = String.length needle in let rec go i = if String.sub text i n = needle then i else go (i + 1) in go 0 in
      let two = String.sub text 0 i ^ {|"effect":[{"kind":"produce","audience":"organization"},{"kind":"disclose","audience":"public"}]|}
                ^ String.sub text (i + String.length needle) (String.length text - i - String.length needle) in
      expect_eq strings "codes" [ "malformed_request" ] (codes (Evaluate.run two)))

(* ======================================================================
   10. Decision/authority binding (runtime half; the static half is
       test/authority/must-not-compile/allow_in_foreign_decision.ml,
       decision_from_scratch.ml and decision_make_without_seal.ml: Decision.t
       is private and its constructor needs Mint.seal). Checked on every
       ALLOW by the "binding:" assertions of the oracle below.
   ====================================================================== *)

(* ======================================================================
   Property oracles over every decision: the recorded ones and the scenario
   files. They re-derive facts from the request, not from kernel code.
   ====================================================================== *)

let token_path (f : Facts.t) = f.subject :: List.rev f.actor_chain
let all_check_names = [ "holder_is_actor"; "delegation_path_matches"; "target_covers_resource"; "mandate_permitted"; "effect_within_grant";
                        "mandate_covers_capability"; "effect_within_mandate"; "provenance" ]

let find_terms (l : Ledger.t) g = List.find_map (fun e -> let t = Grant.terms e in if Id.Grant.equal t.id g then Some t else None) l.entries

(* Independent restatement of the model's link and grant rules. *)
let window_ok (t : Grant.terms) now =
  (match t.valid_from with Some f -> Timestamp.compare f now <= 0 | None -> true)
  && match t.valid_until with Some u -> Timestamp.compare now u < 0 | None -> true

let link_ok (p : Grant.terms) (c : Grant.terms) =
  let within_opt ~lo inner outer = match (outer, inner) with None, _ -> true | Some _, None -> false | Some o, Some i -> if lo then Timestamp.compare i o >= 0 else Timestamp.compare i o <= 0 in
  p.delegable_depth >= 1 && c.delegable_depth < p.delegable_depth
  && Capability.equal c.capability p.capability
  && Capability.target_subset c.target p.target
  && List.for_all (fun m -> List.exists (Id.Mandate.equal m) (Nonempty.to_list p.mandates)) (Nonempty.to_list c.mandates)
  && List.for_all (fun e -> Effect.within e p.effects) (Nonempty.to_list c.effects)
  && within_opt ~lo:true c.valid_from p.valid_from && within_opt ~lo:false c.valid_until p.valid_until

(* S2 for ALLOW, plus binding: the authority answers all five questions and
   authorizes exactly this request. *)
let allow_oracle (r : Request.t) (d : Decision.t) a =
  let about = match d.about with Some a -> a | None -> raise (Assertion "allow without about") in
  let q = r.query and f = r.facts in
  check "who: about.subject is the token subject" (Principal.equal about.subject f.subject);
  check "who: about.actor_chain is the token's" (List.equal Principal.equal about.actor_chain f.actor_chain);
  let m = match about.query.mandate with Some m -> m | None -> raise (Assertion "mandate: none named") in
  let e = match about.query.effect with Some e -> e | None -> raise (Assertion "effect: none named") in
  check "capability: about names the request's" (Capability.equal about.query.capability q.capability && Id.Resource.equal about.query.resource q.resource);
  let v = Authority.chain a in
  let links = Nonempty.to_list (Chain.links v) in
  let leaf = Authority.grant a in
  (* provenance: root first, anchored in a role the root holder holds live *)
  (match (List.hd links).provenance with
  | Grant.Root anchor ->
      check "provenance: root anchor is the one reported" (anchor = Chain.anchor v);
      check "provenance: root holder holds the anchor in facts.principals"
        (match Facts.roles_of f (List.hd links).terms.holder with Some roles -> Facts.holds roles anchor | None -> false)
  | Grant.Delegated _ -> raise (Assertion "provenance: chain does not start at a root"));
  let rec pairs = function
    | (p : Grant.t) :: ((c : Grant.t) :: _ as rest) ->
        (match c.provenance with
        | Grant.Delegated { parent; delegator } ->
            check "provenance: each link names its parent" (Id.Grant.equal parent p.terms.id);
            check "provenance: each delegator is the parent's holder" (Principal.equal delegator p.terms.holder)
        | Grant.Root _ -> raise (Assertion "provenance: a root below the root"));
        check (sp "provenance: link %s -> %s attenuates" (Id.Grant.to_string p.terms.id) (Id.Grant.to_string c.terms.id)) (link_ok p.terms c.terms);
        pairs rest
    | _ -> ()
  in
  pairs links;
  List.iter
    (fun (g : Grant.t) ->
      check "provenance: every link is in the ledger" (find_terms r.ledger g.terms.id = Some g.terms);
      check "provenance: every link is within its window" (window_ok g.terms f.evaluated_at);
      check "provenance: no link is revoked" (not (List.exists (fun (x : Ledger.revocation) -> Id.Grant.equal x.grant g.terms.id) r.ledger.revocations)))
    links;
  (* binding: this authority covers this request, not another one *)
  check "binding: leaf holder is the acting principal" (Principal.equal leaf.terms.holder (Decision.acting about));
  check "binding: ledger path equals token path" (List.equal Principal.equal (List.map (fun (g : Grant.t) -> g.terms.holder) links) (token_path f));
  check "binding: leaf capability is the requested one" (Capability.equal leaf.terms.capability q.capability);
  check "binding: leaf target covers the resource" (Capability.covers leaf.terms.target q.resource);
  check "binding: mandate usable for the leaf" (Nonempty.exists (Id.Mandate.equal m) leaf.terms.mandates);
  check "binding: effect within the leaf's bound" (Effect.within e leaf.terms.effects);
  (match Ledger.find_mandate r.ledger m with
  | Some md ->
      check "binding: mandate covers the capability" (Nonempty.exists (Capability.equal q.capability) md.capabilities);
      check "binding: effect within the mandate" (Effect.within e md.effects)
  | None -> raise (Assertion "binding: mandate not declared"));
  check "binding: no prohibition on anyone in the token path covers the effect"
    (not (List.exists (fun (p : Ledger.prohibition) ->
         List.exists (Principal.same_id p.holder) (token_path f) && Nonempty.exists (fun pe -> Effect.leq pe e) p.effects) r.ledger.prohibitions));
  expect_eq strings "evidence: the authority's checks" all_check_names
    (List.map (fun (c : Check.t) -> Check.name_to_string c.name) (Authority.checks a));
  check "evidence: every check of the authority passed" (List.for_all (fun (c : Check.t) -> c.outcome = Check.Pass) (Authority.checks a));
  check "evidence: the leaf is a candidate that authorizes"
    (List.exists (fun (c : Decision.candidate) -> Id.Grant.equal c.grant leaf.terms.id && c.status = Decision.Authorizes) d.evidence.candidates);
  let root_holder = Id.Principal.to_string (List.hd links).terms.holder.id in
  check "evidence: the anchor statement names the root holder"
    (String.length (Authority.anchor_statement a) > String.length root_holder
    && String.sub (Authority.anchor_statement a) 0 (String.length root_holder + 1) = root_holder ^ " ")

let has_fail (c : Decision.candidate) = List.exists (fun (k : Check.t) -> k.outcome = Check.Fail) c.checks

(* The candidate set is exactly the model's: capability equal, held by the
   acting principal or the subject, in ledger order. *)
let candidates_oracle (r : Request.t) (d : Decision.t) =
  let acting = Facts.acting r.facts in
  let expected =
    List.filter_map
      (fun e ->
        let t = Grant.terms e in
        if Capability.equal t.capability r.query.capability && (Principal.equal t.holder acting || Principal.equal t.holder r.facts.subject)
        then Some (Id.Grant.to_string t.id) else None)
      r.ledger.entries
  in
  expect_eq strings "candidates" expected (List.map (fun (c : Decision.candidate) -> Id.Grant.to_string c.grant) d.evidence.candidates);
  List.iter
    (fun (c : Decision.candidate) ->
      expect_eq strings (sp "checks of %s" (Id.Grant.to_string c.grant)) all_check_names
        (List.map (fun (k : Check.t) -> Check.name_to_string k.name) c.checks);
      let s = c.status and f = has_fail c and u = List.exists (fun (k : Check.t) -> k.outcome = Check.Unknown) c.checks in
      check (sp "status of %s agrees with its checks" (Id.Grant.to_string c.grant))
        (match s with Decision.Refuted -> f | Undetermined -> (not f) && u | Authorizes -> (not f) && not u))
    d.evidence.candidates

let prohibited (d : Decision.t) = List.exists (fun (p : Decision.prohibition_check) -> p.outcome = Check.Fail) d.evidence.prohibitions

(* S2 for DENY and INDETERMINATE. *)
let non_allow_oracle (d : Decision.t) =
  let cs = codes d in
  match d.verdict with
  | Allow _ -> ()
  | Deny _ ->
      if prohibited d then check "deny: prohibited named" (List.mem "prohibited" cs)
      else if d.evidence.candidates = [] then check "deny: no candidate -> no_grant_for_capability" (List.mem "no_grant_for_capability" cs)
      else
        List.iter
          (fun (c : Decision.candidate) -> check (sp "deny: candidate %s has a failed check" (Id.Grant.to_string c.grant)) (has_fail c && c.status = Refuted))
          d.evidence.candidates
  | Indeterminate _ ->
      if List.for_all (( = ) "insufficient_evidence") cs then begin
        check "indeterminate: no candidate authorizes" (List.for_all (fun (c : Decision.candidate) -> c.status <> Authorizes) d.evidence.candidates);
        check "indeterminate: some candidate is undetermined" (List.exists (fun (c : Decision.candidate) -> c.status = Undetermined) d.evidence.candidates)
      end

(* The literal S2 reading: "every DENY names at least one failed check per
   candidate grant it considered". *)
let strict_s2 (d : Decision.t) =
  match d.verdict with Deny _ -> List.for_all has_fail d.evidence.candidates | Allow _ | Indeterminate _ -> true

let json d = Tjson.to_string (Codec.decision_to_json d)

(* Same content in another order: entries, principals, mandates,
   revocations, prohibitions and role facts reversed. *)
let permute (r : Request.t) =
  let l = r.ledger in
  { r with
    ledger = { principals = List.rev l.principals; mandates = List.rev l.mandates; entries = List.rev l.entries;
               revocations = List.rev l.revocations; prohibitions = List.rev l.prohibitions };
    facts = { r.facts with principals = List.rev r.facts.principals } }

let candidate_set (d : Decision.t) =
  List.sort compare (List.map (fun (c : Decision.candidate) -> (Id.Grant.to_string c.grant, Decision.status_to_string c.status)) d.evidence.candidates)

(* ---------- scenario files ---------- *)

let scenario_requests path =
  let fail m = failwith (sp "%s: %s" path m) in
  let json = match Tjson.parse (In_channel.with_open_bin path In_channel.input_all) with Ok j -> j | Error e -> fail e.message in
  let field_opt k = function Tjson.Object kvs -> List.assoc_opt k kvs | _ -> fail "expected an object" in
  let field k j = match field_opt k j with Some v -> v | None -> fail ("missing " ^ k) in
  let merge d o =
    match (d, o) with
    | Tjson.Object d, Tjson.Object o ->
        Tjson.Object (List.map (fun (k, v) -> (k, Option.value ~default:v (List.assoc_opt k o))) d @ List.filter (fun (k, _) -> not (List.mem_assoc k d)) o)
    | _, o -> o
  in
  let stem = Filename.remove_extension (Filename.basename path) in
  let defaults = field "facts" (field "defaults" json) in
  List.map
    (fun s ->
      let name = match field "name" s with Tjson.String n -> n | _ -> fail "name" in
      let facts = match field_opt "facts" s with None -> defaults | Some o -> merge defaults o in
      let doc =
        Tjson.obj
          [ ("schema", Tjson.str Codec.request_schema); ("request_id", Tjson.str (stem ^ "-" ^ name)); ("query", field "query" s);
            ("facts", facts); ("ledger", field "ledger" json) ]
      in
      (stem ^ "/" ^ name, Tjson.to_string doc))
    (match field "scenarios" json with Tjson.Array l -> l | _ -> fail "scenarios")

let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let from_files =
    List.concat_map
      (fun path ->
        List.filter_map
          (fun (name, text) ->
            let d = Evaluate.run text in
            case (name ^ ": the document decision equals the in-memory one") (fun () ->
                match Codec.parse_request text with
                | Ok r -> check "same" (json d = json (Evaluate.evaluate r))
                | Error _ -> check "undecodable is malformed" (codes d = [ "malformed_request" ]));
            match Codec.parse_request text with Ok r -> Some (name, r, d) | Error _ -> None)
          (scenario_requests path))
      files
  in
  let all = List.rev !recorded @ from_files in
  List.iter
    (fun (name, (r : Request.t), (d : Decision.t)) ->
      case ("evidence: " ^ name) (fun () ->
          (match d.about with Some _ -> candidates_oracle r d | None -> ());
          (match d.verdict with Allow a -> allow_oracle r d a | Deny _ | Indeterminate _ -> non_allow_oracle d));
      case ("determinism: same request twice, byte-identical: " ^ name) (fun () ->
          check "identical" (json d = json (Evaluate.evaluate r)));
      case ("determinism: permuted ledger, same decision: " ^ name) (fun () ->
          let p = Evaluate.evaluate (permute r) in
          expect_eq Fun.id "verdict" (verdict d) (verdict p);
          expect_eq strings "reason codes (as a set)" (List.sort_uniq compare (codes d)) (List.sort_uniq compare (codes p));
          expect_eq (Option.value ~default:"-") "allowing grant" (allowed_grant d) (allowed_grant p);
          check "candidates and statuses (as a set)" (candidate_set d = candidate_set p)))
    all;
  (* Pinned: evidence order follows ledger order, so a permuted ledger gives
     an equivalent but not byte-identical document. *)
  let differing = List.filter (fun (_, r, d) -> json d <> json (Evaluate.evaluate (permute r))) all in
  case "known_weakness_evidence_order_follows_ledger_order: some permuted ledgers change the document bytes" (fun () ->
      check "some differ" (differing <> []));
  (* Pinned: a DENY by prohibition lists the overridden candidates as
     "authorizes" with no failed check of their own; the failed check is
     evidence.prohibitions (request level), not per candidate. *)
  let strict_violations = List.filter (fun (_, _, d) -> not (strict_s2 d)) all in
  case "known_weakness_prohibited_deny_has_candidates_without_failed_check: only prohibition denies break literal S2" (fun () ->
      check "some exist" (strict_violations <> []);
      List.iter (fun (n, _, d) -> check (n ^ " is a prohibition deny") (prohibited d)) strict_violations);
  let allows = List.length (List.filter (fun (_, _, (d : Decision.t)) -> match d.verdict with Allow _ -> true | _ -> false) all) in
  Printf.printf "oracles: %d decisions (%d from scenario files), %d allow; %d documents change bytes under permutation; %d prohibition denies break literal S2\n"
    (List.length all) (List.length from_files) allows (List.length differing) (List.length strict_violations);
  List.iter (fun (n, _, _) -> Printf.printf "  literal-S2 exception: %s\n" n) strict_violations;
  Printf.printf "%d tests, %d failed\n" !count !failures;
  if !failures > 0 then exit 1
