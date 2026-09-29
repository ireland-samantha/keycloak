(* Unit tests for lib/authority. Plain executable: each case is a named
   function; the run fails if any case raises or any assertion fails. *)

open Authority

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
let expect_eq show what expected actual = if expected <> actual then raise (Assertion (Printf.sprintf "%s: expected %s, got %s" what (show expected) (show actual)))
let strings l = "[" ^ String.concat "; " l ^ "]"
let ok = function Ok x -> x | Error e -> failwith e

(* ---------- fixtures ---------- *)

let pid s = ok (Id.Principal.of_string s)
let user s = { Principal.kind = User; id = pid s }
let service s = { Principal.kind = Service; id = pid s }
let samantha = user "samantha"
let agent = service "research-agent"
let gid s = ok (Id.Grant.of_string s)
let mid s = ok (Id.Mandate.of_string s)
let role s = ok (Id.Role.of_string s)
let ts s = ok (Timestamp.of_string s)
let cap rt a = { Capability.resource_type = ok (Id.Resource_type.of_string rt); action = ok (Id.Action.of_string a) }
let read = cap "document" "read"
let generate = cap "document" "generate"
let publish = cap "document" "publish"
let q3 = ok (Id.Resource.of_string "q3-report")
let author = Grant.Realm_role (role "report-author")
let now = "2026-09-29T12:00:00Z"

let terms ?(capability = read) ?(target = Capability.Any_resource) ?(mandates = [ "generate-report" ])
    ?(effects = [ Effect.Observe ]) ?valid_from ?valid_until ?(depth = 0) id holder =
  { Grant.id = gid id; holder; capability; target;
    mandates = Option.get (Nonempty.of_list (List.map mid mandates));
    effects = Option.get (Nonempty.of_list effects);
    valid_from = Option.map ts valid_from; valid_until = Option.map ts valid_until; delegable_depth = depth }

let root ?(anchor = author) t = { Grant.terms = t; provenance = Root anchor }
let delegated ?(by = samantha) parent t = { Grant.terms = t; provenance = Delegated { parent = gid parent; delegator = by } }

let mandate ?(effects = [ Effect.Observe; Produce Organization ]) id caps =
  { Mandate.id = mid id; purpose = id; capabilities = Option.get (Nonempty.of_list caps); effects = Option.get (Nonempty.of_list effects) }

let ledger ?(revocations = []) ?(prohibitions = []) ?(principals = [ samantha; agent ]) entries =
  { Ledger.principals; entries; revocations; prohibitions;
    mandates = [ mandate "generate-report" [ read; generate ]; mandate "publish-release" [ publish ] ~effects:[ Disclose Public ] ] }

let roles ?(realm = [ "report-author" ]) p = { Facts.principal = p; realm_roles = List.map role realm; client_roles = [] }

let facts ?(at = now) ?(subject = samantha) ?(actor_chain = []) ?(principals = [ roles samantha; roles ~realm:[] agent ]) () =
  { Facts.source = Fixture; realm = None; evaluated_at = ts at; subject; actor_chain; principals }

let request ?(mandate = Some "generate-report") ?(capability = read) ?(effect = Some Effect.Observe) ?(facts = facts ()) l =
  { Request.request_id = None; facts; ledger = l;
    query = { mandate = Option.map mid mandate; capability; resource = q3; effect } }

(* The baseline chain: samantha's root read grant, delegated to the agent. *)
let parent_terms = terms ~depth:1 "g-root" samantha
let child_terms = terms ~target:(Resource q3) "d-child" agent
let base_root = root parent_terms
let base_child = delegated "g-root" child_terms

let verify ?(facts = facts ()) ?(extra = []) ?revocations ~parent child =
  Chain.verify (ledger ?revocations (Grant.Anchored parent :: extra)) facts child

let fault_codes = function
  | Chain.Invalid fs -> List.map (fun (f : _ Chain.finding) -> Chain.fault_code_to_string f.code) (Nonempty.to_list fs)
  | Verified _ -> [ "verified" ]
  | Unverifiable gs -> List.map (fun (g : _ Chain.finding) -> "unverifiable:" ^ Chain.gap_code_to_string g.code) (Nonempty.to_list gs)

let expect_chain name result expected = case ("chain: " ^ name) (fun () -> expect_eq strings "fault codes" expected (fault_codes result))

let verdict (d : Decision.t) = Decision.verdict_to_string d.verdict
let codes (d : Decision.t) = List.map (fun (r : Decision.reason) -> Decision.reason_code_to_string r.code) (Decision.reasons d)
let expect_decision name r v cs =
  case ("decision: " ^ name) (fun () ->
      let d = Evaluate.evaluate r in
      expect_eq Fun.id "verdict" v (verdict d);
      expect_eq strings "reason codes" cs (codes d))

(* ---------- effect order ---------- *)

let () =
  let open Effect in
  let leq_cases =
    [ (Observe, Observe, true); (Administer, Administer, true); (Produce Self, Produce Public, true);
      (Produce Organization, Produce Organization, true); (Produce Public, Produce Organization, false);
      (Disclose Organization, Disclose Self, false); (Disclose Self, Disclose Public, true);
      (Observe, Produce Self, false); (Produce Self, Observe, false); (Produce Self, Disclose Public, false);
      (Disclose Self, Produce Public, false); (Administer, Observe, false); (Observe, Administer, false);
      (Produce Public, Administer, false) ]
  in
  List.iter
    (fun (a, b, expected) ->
      case (Printf.sprintf "effect: %s <= %s is %b" (to_string a) (to_string b) expected) (fun () ->
          expect_eq string_of_bool "leq" expected (leq a b)))
    leq_cases;
  case "effect: order is reflexive and antisymmetric over all 8 effects" (fun () ->
      List.iter (fun a -> List.iter (fun b -> check "antisymmetric" (not (leq a b && leq b a) || a = b)) all; check "reflexive" (leq a a)) all);
  case "effect: order is transitive over all 8 effects" (fun () ->
      List.iter (fun a -> List.iter (fun b -> List.iter (fun c -> check "transitive" (not (leq a b && leq b c) || leq a c)) all) all) all);
  case "effect: within a bound of several maxima" (fun () ->
      let bound = Nonempty.make Observe [ Produce Organization ] in
      check "observe" (within Observe bound);
      check "produce self" (within (Produce Self) bound);
      check "not produce public" (not (within (Produce Public) bound));
      check "not disclose self" (not (within (Disclose Self) bound)))

(* ---------- timestamps ---------- *)

let () =
  let accepts s unix = case ("timestamp: accepts " ^ s) (fun () ->
      let t = ts s in
      expect_eq string_of_int "unix seconds" unix (Timestamp.to_unix t);
      expect_eq Fun.id "round trip" s (Timestamp.to_string t))
  in
  let rejects s = case ("timestamp: rejects " ^ s) (fun () -> check "rejected" (Result.is_error (Timestamp.of_string s))) in
  (* reference values from `date -u -d ... +%s` *)
  accepts "2026-09-29T12:00:00Z" 1790683200;
  accepts "2000-02-29T23:59:59Z" 951868799;
  accepts "1970-01-01T00:00:00Z" 0;
  accepts "1969-12-31T23:59:59Z" (-1);
  accepts "0001-01-01T00:00:00Z" (-62135596800);
  accepts "9999-12-31T23:59:59Z" 253402300799;
  accepts "2024-02-29T00:00:00Z" 1709164800;
  accepts "2100-03-01T00:00:00Z" 4107542400;
  List.iter rejects
    [ "2026-02-30T00:00:00Z"; "2026-02-29T00:00:00Z"; "2100-02-29T00:00:00Z"; "2026-04-31T00:00:00Z"; "2026-13-01T00:00:00Z";
      "2026-00-10T00:00:00Z"; "2026-01-00T00:00:00Z"; "2026-09-29T24:00:00Z"; "2026-09-29T12:60:00Z"; "2026-09-29T12:00:60Z";
      "2026-09-29T12:00:00z"; "2026-09-29T12:00:00"; "2026-09-29 12:00:00Z"; "2026-09-29T12:00:00.5Z"; "2026-09-29T12:00:00+00:00";
      "2026-9-29T12:00:00Z"; "+026-09-29T12:00:00Z"; "2026-09-29T1a:00:00Z"; "" ];
  case "timestamp: every day of 1900-2100 round-trips and consecutive days are 86400 s apart" (fun () ->
      let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0 in
      let prev = ref None in
      for y = 1900 to 2100 do
        for m = 1 to 12 do
          let days = match m with 2 -> if is_leap y then 29 else 28 | 4 | 6 | 9 | 11 -> 30 | _ -> 31 in
          for d = 1 to days do
            let s = Printf.sprintf "%04d-%02d-%02dT00:00:00Z" y m d in
            let t = ts s in
            expect_eq Fun.id "round trip" s (Timestamp.to_string t);
            (match !prev with Some p -> expect_eq string_of_int ("step to " ^ s) 86400 (Timestamp.to_unix t - p) | None -> ());
            prev := Some (Timestamp.to_unix t)
          done
        done
      done)

(* ---------- identifiers ---------- *)

let () =
  let valid s = case (Printf.sprintf "id: accepts %S" s) (fun () -> check "accepted" (Result.is_ok (Id.Principal.of_string s))) in
  let invalid s = case (Printf.sprintf "id: rejects %S" (if String.length s > 20 then String.sub s 0 20 ^ "..." else s)) (fun () ->
      check "rejected" (Result.is_error (Id.Principal.of_string s))) in
  List.iter valid [ "samantha"; "a"; "research-agent"; "svc:reader@realm.example_1"; String.make 128 'x' ];
  List.iter invalid [ ""; String.make 129 'x'; "sam antha"; "a/b"; "a\"b"; "caf\xc3\xa9"; "a\nb"; "a%20b"; "{}" ];
  case "id: kinds share validation but not types (see must-not-compile for the type error)" (fun () ->
      check "mandate id" (Result.is_ok (Id.Mandate.of_string "generate-report"));
      check "error names the kind"
        (match Id.Mandate.of_string "bad id" with Error m -> String.length m > 0 && String.sub m 0 15 = "invalid mandate" | Ok _ -> false))

(* ---------- chain verification: one fault per test ---------- *)

let () =
  expect_chain "baseline delegation verifies" (verify ~parent:base_root base_child) [ "verified" ];
  expect_chain "root grant verifies" (verify ~parent:base_root base_root) [ "verified" ];
  expect_chain "missing_parent" (verify ~parent:base_root (delegated "g-absent" child_terms)) [ "missing_parent" ];
  expect_chain "unanchored_ancestor is unverifiable, not invalid"
    (Chain.verify (ledger [ Grant.Unanchored { claimed = parent_terms } ]) (facts ()) base_child)
    [ "unverifiable:unanchored_ancestor" ];
  expect_chain "forged_delegation" (verify ~parent:base_root (delegated ~by:agent "g-root" child_terms)) [ "forged_delegation" ];
  expect_chain "delegation_depth_exceeded: parent depth 0"
    (verify ~parent:(root { parent_terms with delegable_depth = 0 }) base_child) [ "delegation_depth_exceeded" ];
  expect_chain "delegation_depth_exceeded: child depth not below parent's"
    (verify ~parent:base_root (delegated "g-root" { child_terms with delegable_depth = 1 })) [ "delegation_depth_exceeded" ];
  expect_chain "capability_amplified"
    (verify ~parent:base_root (delegated "g-root" { child_terms with capability = generate })) [ "capability_amplified" ];
  expect_chain "target_amplified"
    (verify ~parent:(root { parent_terms with target = Resource q3 }) (delegated "g-root" { child_terms with target = Any_resource }))
    [ "target_amplified" ];
  expect_chain "mandate_amplified"
    (verify ~parent:base_root (delegated "g-root" (terms ~target:(Resource q3) ~mandates:[ "generate-report"; "publish-release" ] "d-child" agent)))
    [ "mandate_amplified" ];
  expect_chain "effect_amplified"
    (verify ~parent:base_root (delegated "g-root" (terms ~target:(Resource q3) ~effects:[ Effect.Observe; Produce Self ] "d-child" agent)))
    [ "effect_amplified" ];
  expect_chain "validity_extended: child has no end, parent does"
    (verify ~parent:(root { parent_terms with valid_until = Some (ts "2026-10-01T00:00:00Z") }) base_child)
    [ "validity_extended" ];
  expect_chain "validity_extended: child starts before parent"
    (verify
       ~parent:(root { parent_terms with valid_from = Some (ts "2026-01-01T00:00:00Z") })
       (delegated "g-root" { child_terms with valid_from = Some (ts "2025-12-31T23:59:59Z") }))
    [ "validity_extended" ];
  expect_chain "window inside parent's window verifies"
    (verify
       ~parent:(root { parent_terms with valid_from = Some (ts "2026-01-01T00:00:00Z"); valid_until = Some (ts "2027-01-01T00:00:00Z") })
       (delegated "g-root" { child_terms with valid_from = Some (ts "2026-02-01T00:00:00Z"); valid_until = Some (ts "2026-12-01T00:00:00Z") }))
    [ "verified" ];
  (let a = delegated ~by:samantha "g-b" (terms "g-a" agent) and b = delegated ~by:agent "g-a" (terms ~depth:1 "g-b" samantha) in
   expect_chain "cycle" (Chain.verify (ledger [ Grant.Anchored a; Grant.Anchored b ]) (facts ()) a) [ "cycle" ]);
  expect_chain "cycle: a grant that is its own parent"
    (Chain.verify (ledger []) (facts ()) (delegated ~by:agent "g-self" (terms "g-self" agent))) [ "cycle" ];
  (* g0 (root, depth n-1) -> g1 -> ... -> g(n-1), alternating holders *)
  let straight n =
    let holder i = if i mod 2 = 0 then samantha else agent in
    let grant i =
      let t = terms ~depth:(n - 1 - i) (Printf.sprintf "g%02d" i) (holder i) in
      if i = 0 then root t else delegated ~by:(holder (i - 1)) (Printf.sprintf "g%02d" (i - 1)) t
    in
    let grants = List.init n grant in
    Chain.verify (ledger (List.map (fun g -> Grant.Anchored g) grants)) (facts ()) (List.nth grants (n - 1))
  in
  expect_chain "a chain of max_links grants verifies" (straight Chain.max_links) [ "verified" ];
  expect_chain "chain_too_long" (straight (Chain.max_links + 1)) [ "chain_too_long" ];
  let revoke id = [ { Ledger.grant = gid id; reason = "rotated"; at = ts "2026-07-01T00:00:00Z" } ] in
  expect_chain "revoked: the grant itself" (verify ~revocations:(revoke "d-child") ~parent:base_root base_child) [ "revoked" ];
  expect_chain "revoked: an ancestor invalidates the chain" (verify ~revocations:(revoke "g-root") ~parent:base_root base_child) [ "revoked" ];
  expect_chain "not_yet_valid"
    (verify ~parent:base_root (delegated "g-root" { child_terms with valid_from = Some (ts "2026-10-01T00:00:00Z") })) [ "not_yet_valid" ];
  expect_chain "expired"
    (verify ~parent:base_root (delegated "g-root" { child_terms with valid_until = Some (ts "2026-09-01T00:00:00Z") })) [ "expired" ];
  expect_chain "expired: valid_until is exclusive"
    (verify ~parent:base_root (delegated "g-root" { child_terms with valid_until = Some (ts now) })) [ "expired" ];
  expect_chain "valid_from is inclusive"
    (verify ~parent:base_root (delegated "g-root" { child_terms with valid_from = Some (ts now) })) [ "verified" ];
  expect_chain "no_role_facts: root holder absent from facts is unverifiable"
    (verify ~facts:(facts ~principals:[ roles ~realm:[] agent ] ()) ~parent:base_root base_child) [ "unverifiable:no_role_facts" ];
  expect_chain "anchor_missing: root holder lacks the anchor role"
    (verify ~facts:(facts ~principals:[ roles ~realm:[ "document-publisher" ] samantha ] ()) ~parent:base_root base_child)
    [ "anchor_missing" ];
  expect_chain "a definitive fault outranks a gap"
    (verify ~facts:(facts ~principals:[] ()) ~parent:base_root (delegated "g-root" { child_terms with valid_until = Some (ts "2026-01-01T00:00:00Z") }))
    [ "expired" ];
  let reader = Grant.Client_role { client = ok (Id.Client.of_string "document-service"); role = role "reader" } in
  let with_client_role = { (roles ~realm:[] agent) with client_roles = [ (ok (Id.Client.of_string "document-service"), [ role "reader" ]) ] } in
  expect_chain "client role anchor verifies"
    (Chain.verify (ledger []) (facts ~principals:[ with_client_role ] ()) (root ~anchor:reader (terms "g-agent" agent))) [ "verified" ];
  expect_chain "client role of another client does not anchor"
    (Chain.verify (ledger []) (facts ~principals:[ { with_client_role with client_roles = [ (ok (Id.Client.of_string "other"), [ role "reader" ]) ] } ] ())
       (root ~anchor:reader (terms "g-agent" agent)))
    [ "anchor_missing" ];
  expect_chain "faults are not short-circuited"
    (verify ~parent:base_root
       (delegated ~by:agent "g-root" { child_terms with capability = generate; valid_until = Some (ts "2026-01-01T00:00:00Z") }))
    [ "expired"; "forged_delegation"; "capability_amplified" ]

(* ---------- decision rules and precedence ---------- *)

let delegated_ledger ?prohibitions ?revocations extra = ledger ?prohibitions ?revocations ([ Grant.Anchored base_root; Grant.Anchored base_child ] @ extra)
let for_samantha = facts ~actor_chain:[ agent ] ()
let prohibit ?(holder = samantha) id effects = { Ledger.id = ok (Id.Prohibition.of_string id); holder; effects = Option.get (Nonempty.of_list effects); reason = "test" }

let () =
  expect_decision "delegated read allows" (request ~facts:for_samantha (delegated_ledger [])) "allow" [];
  expect_decision "well-formedness outranks a prohibition"
    (request ~mandate:(Some "unknown-mandate") ~facts:for_samantha (delegated_ledger ~prohibitions:[ prohibit "p" [ Observe ] ] []))
    "indeterminate" [ "unknown_mandate" ];
  expect_decision "a prohibition outranks an authorizing candidate"
    (request ~facts:for_samantha (delegated_ledger ~prohibitions:[ prohibit ~holder:agent "p" [ Observe ] ] []))
    "deny" [ "prohibited" ];
  expect_decision "a prohibition on the subject binds the actor acting for it"
    (request ~facts:for_samantha (delegated_ledger ~prohibitions:[ prohibit ~holder:samantha "p" [ Observe ] ] []))
    "deny" [ "prohibited" ];
  expect_decision "a prohibition on an uninvolved principal does not apply"
    (request ~facts:for_samantha (delegated_ledger ~prohibitions:[ prohibit ~holder:(user "mallory") "p" [ Observe ] ] []))
    "allow" [];
  (let publish_ledger =
     ledger ~prohibitions:[ prohibit "p" [ Disclose Organization ] ]
       [ Grant.Anchored (root (terms ~capability:publish ~mandates:[ "publish-release" ] ~effects:[ Disclose Public ] "g-pub" samantha)) ]
   in
   let publishing e = request ~mandate:(Some "publish-release") ~capability:publish ~effect:(Some e) publish_ledger in
   expect_decision "prohibition covers wider audiences (disclose:public >= disclose:organization)" (publishing (Disclose Public)) "deny" [ "prohibited" ];
   expect_decision "prohibition does not cover narrower audiences (disclose:self)" (publishing (Disclose Self)) "allow" []);
  expect_decision "an authorizing candidate outranks an undetermined one"
    (request (ledger [ Grant.Unanchored { claimed = terms "u-sam" samantha }; Grant.Anchored base_root ]))
    "allow" [];
  expect_decision "an undetermined candidate outranks refuted ones"
    (request ~facts:(facts ~subject:agent ()) (ledger [ Grant.Unanchored { claimed = terms "u-agent" agent }; Grant.Anchored base_child ]))
    "indeterminate" [ "insufficient_evidence" ];
  expect_decision "no candidates: no_grant_for_capability"
    (request ~capability:generate ~effect:(Some (Produce Organization)) ~facts:(facts ~subject:agent ()) (ledger [ Grant.Anchored base_root ]))
    "deny" [ "no_grant_for_capability" ];
  expect_decision "unverifiable root: insufficient_evidence"
    (request (ledger [ Grant.Anchored base_root ]) ~facts:(facts ~principals:[] ()))
    "indeterminate" [ "insufficient_evidence" ];
  expect_decision "missing mandate" (request ~mandate:None (ledger [ Grant.Anchored base_root ])) "indeterminate" [ "missing_mandate" ];
  expect_decision "missing effect" (request ~effect:None (ledger [ Grant.Anchored base_root ])) "indeterminate" [ "missing_effect" ];
  expect_decision "every well-formedness failure is reported"
    (request ~mandate:None ~effect:None ~facts:(facts ~subject:(user "mallory") ()) (ledger [ Grant.Anchored base_root ]))
    "indeterminate" [ "missing_mandate"; "missing_effect"; "unknown_principal" ];
  expect_decision "principal_kind_mismatch"
    (request ~facts:(facts ~subject:(service "samantha") ~principals:[] ()) (ledger [ Grant.Anchored base_root ]))
    "indeterminate" [ "principal_kind_mismatch" ];
  expect_decision "inconsistent_ledger: duplicate grant ids"
    (request (ledger [ Grant.Anchored base_root; Grant.Unanchored { claimed = parent_terms } ])) "indeterminate" [ "inconsistent_ledger" ];
  expect_decision "inconsistent_facts: actor chain contains the subject"
    (request ~facts:(facts ~actor_chain:[ agent; samantha ] ()) (ledger [ Grant.Anchored base_root ])) "indeterminate" [ "inconsistent_facts" ];
  expect_decision "inconsistent_facts: actor chain repeats a principal"
    (request ~facts:(facts ~actor_chain:[ agent; agent ] ()) (ledger [ Grant.Anchored base_root ])) "indeterminate" [ "inconsistent_facts" ];
  expect_decision "confused deputy: the agent's own grant while acting for samantha"
    (request
       ~facts:(facts ~actor_chain:[ agent ] ~principals:[ roles samantha; roles ~realm:[ "report-author" ] agent ] ())
       (ledger [ Grant.Anchored (root (terms "g-agent" agent)) ]))
    "deny" [ "delegation_path_matches" ];
  expect_decision "delegated authority without the token proving delegation"
    (request ~facts:(facts ~subject:agent ()) (delegated_ledger [])) "deny" [ "delegation_path_matches" ];
  case "decision: ALLOW picks the lowest grant id among equally short chains" (fun () ->
      let r = request (ledger [ Grant.Anchored (root (terms "g-b" samantha)); Grant.Anchored (root (terms "g-a" samantha)) ]) in
      match (Evaluate.evaluate r).verdict with
      | Allow a -> expect_eq Fun.id "grant" "g-a" (Id.Grant.to_string (Authority.grant a).terms.id)
      | _ -> check "allow" false);
  case "decision: ALLOW carries the full chain back to the anchor" (fun () ->
      match (Evaluate.evaluate (request ~facts:for_samantha (delegated_ledger []))).verdict with
      | Allow a ->
          expect_eq strings "chain" [ "g-root"; "d-child" ]
            (List.map (fun (g : Grant.t) -> Id.Grant.to_string g.terms.id) (Nonempty.to_list (Chain.links (Authority.chain a))));
          check "anchor" (Authority.anchor_statement a = "samantha holds realm role report-author (facts.source = fixture)");
          check "all checks passed" (List.for_all (fun (c : Check.t) -> c.outcome = Pass) (Authority.checks a))
      | _ -> check "allow" false);
  case "decision: checks are not short-circuited; every candidate carries all 8" (fun () ->
      let d = Evaluate.evaluate (request ~mandate:(Some "publish-release") ~effect:(Some (Disclose Public)) ~facts:for_samantha (delegated_ledger [])) in
      check "candidates" (d.evidence.candidates <> []);
      List.iter (fun (c : Decision.candidate) -> expect_eq string_of_int "checks" 8 (List.length c.checks)) d.evidence.candidates;
      let fails = List.concat_map (fun (c : Decision.candidate) -> List.filter (fun (k : Check.t) -> k.outcome = Fail) c.checks) d.evidence.candidates in
      check "several failures per candidate" (List.length fails >= 4));
  case "decision: every refuted candidate has a failed check (S2)" (fun () ->
      let d = Evaluate.evaluate (request ~effect:(Some (Produce Public)) ~facts:for_samantha (delegated_ledger [])) in
      expect_eq Fun.id "verdict" "deny" (verdict d);
      List.iter
        (fun (c : Decision.candidate) -> check "failed check" (List.exists (fun (k : Check.t) -> k.outcome = Fail) c.checks))
        d.evidence.candidates);
  case "decision: evaluation is deterministic (same request, same document)" (fun () ->
      let r = request ~facts:for_samantha (delegated_ledger []) in
      let a = Tjson.to_string (Codec.decision_to_json (Evaluate.evaluate r)) and b = Tjson.to_string (Codec.decision_to_json (Evaluate.evaluate r)) in
      check "equal" (a = b))

(* ---------- codec ---------- *)

let wire_request =
  {|{
  "schema": "typed-authority/request/v1",
  "request_id": "demo-02-delegated-generate",
  "query": { "mandate": "generate-report",
             "capability": { "resource_type": "document", "action": "generate" },
             "resource": "q3-report",
             "effect": { "kind": "produce", "audience": "organization" } },
  "facts": { "source": "keycloak", "realm": "typed-authority-demo", "evaluated_at": "2026-09-29T12:00:00Z",
             "subject": { "type": "user", "id": "samantha" },
             "actor_chain": [ { "type": "service", "id": "research-agent" } ],
             "principals": [
               { "type": "user", "id": "samantha", "realm_roles": ["report-author"], "client_roles": { "document-service": [] } },
               { "type": "service", "id": "research-agent", "realm_roles": [], "client_roles": { "document-service": ["reader"] } } ] },
  "ledger": {
    "schema": "typed-authority/ledger/v1",
    "principals": [ { "type": "user", "id": "samantha" }, { "type": "service", "id": "research-agent" } ],
    "mandates": [ { "id": "generate-report", "purpose": "Produce the quarterly report",
                    "capabilities": [ { "resource_type": "document", "action": "generate" } ],
                    "effects": [ { "kind": "observe" }, { "kind": "produce", "audience": "organization" } ] } ],
    "grants": [
      { "id": "g-samantha-generate", "holder": { "type": "user", "id": "samantha" },
        "capability": { "resource_type": "document", "action": "generate" }, "target": "any",
        "mandates": ["generate-report"], "effects": [ { "kind": "produce", "audience": "organization" } ],
        "delegable_depth": 1, "provenance": { "kind": "root", "anchor": { "realm_role": "report-author" } } },
      { "id": "d-agent-generate", "holder": { "type": "service", "id": "research-agent" },
        "capability": { "resource_type": "document", "action": "generate" }, "target": { "resource": "q3-report" },
        "mandates": ["generate-report"], "effects": [ { "kind": "produce", "audience": "organization" } ],
        "valid_until": "2026-12-31T23:59:59Z",
        "provenance": { "kind": "delegated", "parent": "g-samantha-generate", "delegator": { "type": "user", "id": "samantha" } } },
      { "id": "u-agent-read", "holder": { "type": "service", "id": "research-agent" },
        "capability": { "resource_type": "document", "action": "read" }, "target": "any",
        "mandates": ["generate-report"], "effects": [ { "kind": "observe" } ], "provenance": null },
      { "id": "g-agent-read", "holder": { "type": "service", "id": "research-agent" },
        "capability": { "resource_type": "document", "action": "read" }, "target": "any",
        "mandates": ["generate-report"], "effects": [ { "kind": "observe" } ],
        "provenance": { "kind": "root", "anchor": { "client_role": { "client": "document-service", "role": "reader" } } } } ],
    "revocations": [ { "grant": "g-old", "reason": "rotated", "at": "2026-07-01T00:00:00Z" } ],
    "prohibitions": [ { "id": "p-agent-no-public-disclosure", "holder": { "type": "service", "id": "research-agent" },
                        "effects": [ { "kind": "disclose", "audience": "public" } ], "reason": "agents never publish externally" } ] }
}|}

(* Replaces the first occurrence of [sub] in [s]. *)
let replace sub by s =
  let n = String.length sub in
  let rec find i = if i + n > String.length s then failwith ("not found: " ^ sub) else if String.sub s i n = sub then i else find (i + 1) in
  let i = find 0 in
  String.sub s 0 i ^ by ^ String.sub s (i + n) (String.length s - i - n)

let malformed name input expected_fragment =
  case ("codec: rejects " ^ name) (fun () ->
      let d = Evaluate.run input in
      expect_eq Fun.id "verdict" "indeterminate" (verdict d);
      expect_eq strings "codes" [ "malformed_request" ] (codes d);
      let message = (List.hd (Decision.reasons d)).message in
      let contains s sub = let n = String.length sub in let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0 in
      if not (contains message expected_fragment) then raise (Assertion (Printf.sprintf "message %S lacks %S" message expected_fragment)))

let () =
  case "codec: the wire-format example decodes and allows" (fun () ->
      let r = ok (Codec.parse_request wire_request) in
      expect_eq string_of_int "entries" 4 (List.length r.ledger.entries);
      check "provenance null decodes as unanchored"
        (List.exists (function Grant.Unanchored u -> Id.Grant.to_string u.claimed.id = "u-agent-read" | _ -> false) r.ledger.entries);
      expect_eq Fun.id "verdict" "allow" (verdict (Evaluate.evaluate r)));
  case "codec: request round-trips (decode . encode = id)" (fun () ->
      let r = ok (Codec.parse_request wire_request) in
      let again = ok (Codec.parse_request (Tjson.to_string (Codec.request_to_json r))) in
      check "structurally equal" (r = again);
      check "encoding is stable" (Tjson.to_string (Codec.request_to_json r) = Tjson.to_string (Codec.request_to_json again)));
  case "codec: decision document: authority present iff allow, reasons non-empty iff not allow" (fun () ->
      let doc r = Codec.decision_to_json (Evaluate.evaluate r) in
      let fields = function Tjson.Object kvs -> kvs | _ -> [] in
      let allow = fields (doc (ok (Codec.parse_request wire_request))) in
      check "allow has authority" (List.mem_assoc "authority" allow);
      check "allow has empty reasons" (List.assoc "reasons" allow = Tjson.Array []);
      let deny = fields (doc (request ~effect:(Some (Produce Public)) ~facts:for_samantha (delegated_ledger []))) in
      check "deny has no authority" (not (List.mem_assoc "authority" deny));
      check "deny has reasons" (List.assoc "reasons" deny <> Tjson.Array []));
  malformed "an unknown field (efect)" (replace {|"effect": { "kind": "produce"|} {|"efect": { "kind": "produce"|} wire_request) "unknown field \"efect\"";
  malformed "a duplicate key" (replace {|"resource": "q3-report",|} {|"resource": "q3-report", "resource": "q4-report",|} wire_request) "duplicate key";
  malformed "observe with an audience" (replace {|{ "kind": "observe" }, { "kind": "produce"|} {|{ "kind": "observe", "audience": "self" }, { "kind": "produce"|} wire_request)
    "$.ledger.mandates[0].effects[0]: observe must not carry an audience";
  malformed "administer with a null audience" (replace {|"effect": { "kind": "produce", "audience": "organization" }|} {|"effect": { "kind": "administer", "audience": null }|} wire_request)
    "administer must not carry an audience";
  malformed "produce without an audience" (replace {|"effect": { "kind": "produce", "audience": "organization" }|} {|"effect": { "kind": "produce" }|} wire_request)
    "$.query.effect: missing required field \"audience\"";
  malformed "an unknown audience" (replace {|"audience": "organization" }|} {|"audience": "world" }|} wire_request) "$.query.effect.audience";
  malformed "an invalid identifier" (replace {|"id": "g-samantha-generate"|} {|"id": "g samantha"|} wire_request) "$.ledger.grants[0].id";
  malformed "an invalid date" (replace "2026-12-31T23:59:59Z" "2026-02-30T23:59:59Z" wire_request) "$.ledger.grants[1].valid_until";
  malformed "an empty mandates list" (replace {|"mandates": ["generate-report"], "effects": [ { "kind": "observe" } ], "provenance": null|} {|"mandates": [], "effects": [ { "kind": "observe" } ], "provenance": null|} wire_request)
    "$.ledger.grants[2].mandates: must be non-empty";
  malformed "a negative delegable_depth" (replace {|"delegable_depth": 1|} {|"delegable_depth": -1|} wire_request) "must be >= 0";
  malformed "a wrong schema" (replace "typed-authority/request/v1" "typed-authority/request/v2" wire_request) "$.schema";
  malformed "an anchor with two roles" (replace {|{ "realm_role": "report-author" }|} {|{ "realm_role": "report-author", "client_role": { "client": "c", "role": "r" } }|} wire_request)
    "exactly one of";
  malformed "trailing characters" (wire_request ^ " {}") "trailing characters";
  malformed "a number where a string is expected" (replace {|"resource": "q3-report",|} {|"resource": 3,|} wire_request) "$.query.resource: expected string";
  case "codec: a request over 1 MiB is request_too_large" (fun () ->
      let d = Evaluate.run (String.make (Evaluate.max_request_bytes + 1) ' ') in
      expect_eq strings "codes" [ "request_too_large" ] (codes d));
  case "codec: exactly 1 MiB is not too large" (fun () ->
      let padded = wire_request ^ String.make (Evaluate.max_request_bytes - String.length wire_request) ' ' in
      expect_eq Fun.id "verdict" "allow" (verdict (Evaluate.run padded)));
  case "codec: missing mandate decodes and is INDETERMINATE missing_mandate, not malformed" (fun () ->
      let d = Evaluate.run (replace {|"mandate": "generate-report",|} "" wire_request) in
      expect_eq strings "codes" [ "missing_mandate" ] (codes d))

let () =
  Printf.printf "%d tests, %d failed\n" !count !failures;
  if !failures > 0 then exit 1
