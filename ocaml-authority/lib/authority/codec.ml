open Tjson.Decode
module J = Tjson

let request_schema = "typed-authority/request/v1"
let ledger_schema = "typed-authority/ledger/v1"
let decision_schema = "typed-authority/decision/v1"
let sp = Printf.sprintf

(* ---------- decoding ---------- *)

let rec all f = function
  | [] -> Ok []
  | x :: xs ->
      let* y = f x in
      let+ ys = all f xs in
      y :: ys

let req name f c = Result.bind (field name c) f

let opt name f c =
  let* v = field_opt name c in
  match v with None -> Ok None | Some v -> Result.map Option.some (f v)

let validated of_string c =
  let* s = string c in
  match of_string s with Ok v -> Ok v | Error m -> fail c m

let nonempty f c =
  let* xs = map_list f c in
  match Nonempty.of_list xs with Some l -> Ok l | None -> fail c "must be non-empty"

let one_of options c =
  let* s = string c in
  match List.assoc_opt s options with
  | Some v -> Ok v
  | None -> fail c (sp "expected one of %s" (String.concat ", " (List.map (fun (k, _) -> sp "%S" k) options)))

let timestamp = validated Timestamp.of_string

let schema expected c =
  let* f = field "schema" c in
  let* s = string f in
  if s = expected then Ok () else fail f (sp "expected %S" expected)

let principal_fields c =
  let* kind = req "type" (one_of [ ("user", Principal.User); ("service", Principal.Service) ]) c in
  let+ id = req "id" (validated Id.Principal.of_string) c in
  { Principal.kind; id }

let principal c =
  let* _ = obj ~allowed:[ "type"; "id" ] c in
  principal_fields c

let capability c =
  let* _ = obj ~allowed:[ "resource_type"; "action" ] c in
  let* resource_type = req "resource_type" (validated Id.Resource_type.of_string) c in
  let+ action = req "action" (validated Id.Action.of_string) c in
  { Capability.resource_type; action }

let audience = one_of [ ("self", Effect.Self); ("organization", Effect.Organization); ("public", Effect.Public) ]

(* observe and administer must not carry an audience, even a null one;
   produce and disclose must carry one. *)
let effect c =
  let* fields = obj ~allowed:[ "kind"; "audience" ] c in
  let* kind = field "kind" c in
  let* k = string kind in
  match k with
  | ("observe" | "administer") when List.mem_assoc "audience" fields -> fail c (k ^ " must not carry an audience")
  | "observe" -> Ok Effect.Observe
  | "administer" -> Ok Effect.Administer
  | "produce" -> Result.map (fun a -> Effect.Produce a) (req "audience" audience c)
  | "disclose" -> Result.map (fun a -> Effect.Disclose a) (req "audience" audience c)
  | _ -> fail kind "expected one of \"observe\", \"produce\", \"disclose\", \"administer\""

let target c =
  match value c with
  | J.String "any" -> Ok Capability.Any_resource
  | J.Object _ ->
      let* _ = obj ~allowed:[ "resource" ] c in
      Result.map (fun r -> Capability.Resource r) (req "resource" (validated Id.Resource.of_string) c)
  | _ -> fail c "expected \"any\" or {\"resource\": <id>}"

let anchor c =
  let* fields = obj ~allowed:[ "realm_role"; "client_role" ] c in
  match fields with
  | [ ("realm_role", r) ] -> Result.map (fun role -> Grant.Realm_role role) (validated Id.Role.of_string r)
  | [ ("client_role", cr) ] ->
      let* _ = obj ~allowed:[ "client"; "role" ] cr in
      let* client = req "client" (validated Id.Client.of_string) cr in
      let+ role = req "role" (validated Id.Role.of_string) cr in
      Grant.Client_role { client; role }
  | _ -> fail c "expected exactly one of \"realm_role\", \"client_role\""

let provenance c =
  let* kind = req "kind" string c in
  match kind with
  | "root" ->
      let* _ = obj ~allowed:[ "kind"; "anchor" ] c in
      Result.map (fun a -> Grant.Root a) (req "anchor" anchor c)
  | "delegated" ->
      let* _ = obj ~allowed:[ "kind"; "parent"; "delegator" ] c in
      let* parent = req "parent" (validated Id.Grant.of_string) c in
      let+ delegator = req "delegator" principal c in
      Grant.Delegated { parent; delegator }
  | _ -> fail c "provenance kind must be \"root\" or \"delegated\""

let depth c =
  let* n = int c in
  if n >= 0 then Ok n else fail c "must be >= 0"

(* The one tolerated omission: without provenance the entry decodes to the
   separate type [Grant.unanchored]. *)
let entry c =
  let* _ =
    obj c
      ~allowed:
        [ "id"; "holder"; "capability"; "target"; "mandates"; "effects"; "valid_from"; "valid_until";
          "delegable_depth"; "provenance" ]
  in
  let* id = req "id" (validated Id.Grant.of_string) c in
  let* holder = req "holder" principal c in
  let* capability = req "capability" capability c in
  let* target = req "target" target c in
  let* mandates = req "mandates" (nonempty (validated Id.Mandate.of_string)) c in
  let* effects = req "effects" (nonempty effect) c in
  let* valid_from = opt "valid_from" timestamp c in
  let* valid_until = opt "valid_until" timestamp c in
  let* delegable_depth = opt "delegable_depth" depth c in
  let+ provenance = opt "provenance" provenance c in
  let delegable_depth = Option.value ~default:0 delegable_depth in
  let terms = { Grant.id; holder; capability; target; mandates; effects; valid_from; valid_until; delegable_depth } in
  match provenance with
  | Some provenance -> Grant.Anchored { terms; provenance }
  | None -> Grant.Unanchored { claimed = terms }

let mandate c =
  let* _ = obj ~allowed:[ "id"; "purpose"; "capabilities"; "effects" ] c in
  let* id = req "id" (validated Id.Mandate.of_string) c in
  let* purpose = req "purpose" string c in
  let* capabilities = req "capabilities" (nonempty capability) c in
  let+ effects = req "effects" (nonempty effect) c in
  { Mandate.id; purpose; capabilities; effects }

let revocation c =
  let* _ = obj ~allowed:[ "grant"; "reason"; "at" ] c in
  let* grant = req "grant" (validated Id.Grant.of_string) c in
  let* reason = req "reason" string c in
  let+ at = req "at" timestamp c in
  { Ledger.grant; reason; at }

let prohibition c =
  let* _ = obj ~allowed:[ "id"; "holder"; "effects"; "reason" ] c in
  let* id = req "id" (validated Id.Prohibition.of_string) c in
  let* holder = req "holder" principal c in
  let* effects = req "effects" (nonempty effect) c in
  let+ reason = req "reason" string c in
  { Ledger.id; holder; effects; reason }

let ledger_of_json c =
  let* _ = obj ~allowed:[ "schema"; "principals"; "mandates"; "grants"; "revocations"; "prohibitions" ] c in
  let* () = schema ledger_schema c in
  let* principals = req "principals" (map_list principal) c in
  let* mandates = req "mandates" (map_list mandate) c in
  let* entries = req "grants" (map_list entry) c in
  let* revocations = opt "revocations" (map_list revocation) c in
  let+ prohibitions = opt "prohibitions" (map_list prohibition) c in
  let revocations = Option.value ~default:[] revocations and prohibitions = Option.value ~default:[] prohibitions in
  { Ledger.principals; mandates; entries; revocations; prohibitions }

let client_roles c =
  let* fields = obj c in
  all
    (fun (client, roles) ->
      let* client = match Id.Client.of_string client with Ok id -> Ok id | Error m -> fail roles m in
      let+ roles = map_list (validated Id.Role.of_string) roles in
      (client, roles))
    fields

let roles c =
  let* _ = obj ~allowed:[ "type"; "id"; "realm_roles"; "client_roles" ] c in
  let* principal = principal_fields c in
  let* realm_roles = req "realm_roles" (map_list (validated Id.Role.of_string)) c in
  let+ client_roles = req "client_roles" client_roles c in
  { Facts.principal; realm_roles; client_roles }

let facts_of_json c =
  let* _ = obj ~allowed:[ "source"; "realm"; "evaluated_at"; "subject"; "actor_chain"; "principals" ] c in
  let* source = req "source" (one_of [ ("keycloak", Facts.Keycloak); ("fixture", Facts.Fixture) ]) c in
  let* realm = opt "realm" string c in
  let* evaluated_at = req "evaluated_at" timestamp c in
  let* subject = req "subject" principal c in
  let* actor_chain = req "actor_chain" (map_list principal) c in
  let+ principals = req "principals" (map_list roles) c in
  { Facts.source; realm; evaluated_at; subject; actor_chain; principals }

let query c =
  let* _ = obj ~allowed:[ "mandate"; "capability"; "resource"; "effect" ] c in
  let* mandate = opt "mandate" (validated Id.Mandate.of_string) c in
  let* capability = req "capability" capability c in
  let* resource = req "resource" (validated Id.Resource.of_string) c in
  let+ effect = opt "effect" effect c in
  { Request.mandate; capability; resource; effect }

let request_of_json j =
  let c = root j in
  let* _ = obj ~allowed:[ "schema"; "request_id"; "query"; "facts"; "ledger" ] c in
  let* () = schema request_schema c in
  let* request_id = opt "request_id" (validated Id.Request.of_string) c in
  let* query = req "query" query c in
  let* facts = req "facts" facts_of_json c in
  let+ ledger = req "ledger" ledger_of_json c in
  { Request.request_id; query; facts; ledger }

let parse_request s =
  match Tjson.parse s with
  | Error (e : Tjson.parse_error) -> Error (sp "byte %d: %s" e.offset e.message)
  | Ok j -> (
      match request_of_json j with Ok r -> Ok r | Error (e : error) -> Error (sp "%s: %s" e.path e.message))

(* ---------- encoding ---------- *)

let id to_string x = J.str (to_string x)
let nonempty_json f l = J.list f (Nonempty.to_list l)
let timestamp_json t = J.str (Timestamp.to_string t)
let optional name f = function None -> [] | Some v -> [ (name, f v) ]
let principal_json (p : Principal.t) = J.obj [ ("type", J.str (Principal.kind_to_string p.kind)); ("id", id Id.Principal.to_string p.id) ]

let capability_json (c : Capability.t) =
  J.obj [ ("resource_type", id Id.Resource_type.to_string c.resource_type); ("action", id Id.Action.to_string c.action) ]

let effect_json e =
  let kind k = ("kind", J.str k) and audience a = ("audience", J.str (Effect.audience_to_string a)) in
  J.obj
    (match e with
    | Effect.Observe -> [ kind "observe" ]
    | Administer -> [ kind "administer" ]
    | Produce a -> [ kind "produce"; audience a ]
    | Disclose a -> [ kind "disclose"; audience a ])

let target_json = function
  | Capability.Any_resource -> J.str "any"
  | Resource r -> J.obj [ ("resource", id Id.Resource.to_string r) ]

let anchor_json = function
  | Grant.Realm_role r -> J.obj [ ("realm_role", id Id.Role.to_string r) ]
  | Client_role { client; role } ->
      J.obj [ ("client_role", J.obj [ ("client", id Id.Client.to_string client); ("role", id Id.Role.to_string role) ]) ]

let provenance_json = function
  | Grant.Root a -> J.obj [ ("kind", J.str "root"); ("anchor", anchor_json a) ]
  | Delegated { parent; delegator } ->
      J.obj [ ("kind", J.str "delegated"); ("parent", id Id.Grant.to_string parent); ("delegator", principal_json delegator) ]

let entry_json e =
  let t = Grant.terms e in
  J.obj
    ([ ("id", id Id.Grant.to_string t.id);
       ("holder", principal_json t.holder);
       ("capability", capability_json t.capability);
       ("target", target_json t.target);
       ("mandates", nonempty_json (id Id.Mandate.to_string) t.mandates);
       ("effects", nonempty_json effect_json t.effects) ]
    @ optional "valid_from" timestamp_json t.valid_from
    @ optional "valid_until" timestamp_json t.valid_until
    @ (if t.delegable_depth = 0 then [] else [ ("delegable_depth", J.int t.delegable_depth) ])
    @ match e with Grant.Anchored g -> [ ("provenance", provenance_json g.provenance) ] | Unanchored _ -> [])

let ledger_json (l : Ledger.t) =
  let mandate (m : Mandate.t) =
    J.obj
      [ ("id", id Id.Mandate.to_string m.id); ("purpose", J.str m.purpose);
        ("capabilities", nonempty_json capability_json m.capabilities); ("effects", nonempty_json effect_json m.effects) ]
  in
  let revocation (r : Ledger.revocation) =
    J.obj [ ("grant", id Id.Grant.to_string r.grant); ("reason", J.str r.reason); ("at", timestamp_json r.at) ]
  in
  let prohibition (p : Ledger.prohibition) =
    J.obj
      [ ("id", id Id.Prohibition.to_string p.id); ("holder", principal_json p.holder);
        ("effects", nonempty_json effect_json p.effects); ("reason", J.str p.reason) ]
  in
  J.obj
    [ ("schema", J.str ledger_schema); ("principals", J.list principal_json l.principals);
      ("mandates", J.list mandate l.mandates); ("grants", J.list entry_json l.entries);
      ("revocations", J.list revocation l.revocations); ("prohibitions", J.list prohibition l.prohibitions) ]

let facts_json (f : Facts.t) =
  let roles (r : Facts.roles) =
    let client (c, roles) = (Id.Client.to_string c, J.list (id Id.Role.to_string) roles) in
    J.obj
      [ ("type", J.str (Principal.kind_to_string r.principal.kind)); ("id", id Id.Principal.to_string r.principal.id);
        ("realm_roles", J.list (id Id.Role.to_string) r.realm_roles); ("client_roles", J.obj (List.map client r.client_roles)) ]
  in
  J.obj
    ([ ("source", J.str (Facts.source_to_string f.source)) ]
    @ optional "realm" J.str f.realm
    @ [ ("evaluated_at", timestamp_json f.evaluated_at); ("subject", principal_json f.subject);
        ("actor_chain", J.list principal_json f.actor_chain); ("principals", J.list roles f.principals) ])

let request_to_json (r : Request.t) =
  let q = r.query in
  let query =
    J.obj
      (optional "mandate" (id Id.Mandate.to_string) q.mandate
      @ [ ("capability", capability_json q.capability); ("resource", id Id.Resource.to_string q.resource) ]
      @ optional "effect" effect_json q.effect)
  in
  J.obj
    ([ ("schema", J.str request_schema) ]
    @ optional "request_id" (id Id.Request.to_string) r.request_id
    @ [ ("query", query); ("facts", facts_json r.facts); ("ledger", ledger_json r.ledger) ])

let check_json (c : Check.t) =
  J.obj [ ("check", J.str (Check.name_to_string c.name)); ("outcome", J.str (Check.outcome_to_string c.outcome)); ("detail", J.str c.detail) ]

let authority_json a =
  let v = Mint.chain a in
  let link (g : Grant.t) =
    J.obj [ ("grant", id Id.Grant.to_string g.terms.id); ("holder", principal_json g.terms.holder); ("provenance", provenance_json g.provenance) ]
  in
  J.obj
    [ ("grant", id Id.Grant.to_string (Chain.leaf v).terms.id); ("chain", nonempty_json link (Chain.links v));
      ("anchor", J.str (Mint.anchor_statement a)) ]

let evidence_json (d : Decision.t) =
  let e = d.evidence in
  let prohibition (p : Decision.prohibition_check) =
    J.obj
      [ ("prohibition", id Id.Prohibition.to_string p.prohibition); ("outcome", J.str (Check.outcome_to_string p.outcome));
        ("detail", J.str p.detail) ]
  in
  let candidate (c : Decision.candidate) =
    J.obj [ ("grant", id Id.Grant.to_string c.grant); ("status", J.str (Decision.status_to_string c.status)); ("checks", J.list check_json c.checks) ]
  in
  let held = match (e.candidates, d.about) with [], Some _ -> [ ("held_capabilities", J.list capability_json e.held) ] | _ -> [] in
  J.obj
    ([ ("request_checks", J.list check_json e.request_checks); ("prohibitions", J.list prohibition e.prohibitions);
       ("candidates", J.list candidate e.candidates) ]
    @ held)

let decision_to_json (d : Decision.t) =
  let about f = match d.about with None -> J.Null | Some a -> f a in
  let reason (r : Decision.reason) = J.obj [ ("code", J.str (Decision.reason_code_to_string r.code)); ("message", J.str r.message) ] in
  J.obj
    ([ ("schema", J.str decision_schema);
       ("request_id", J.opt (id Id.Request.to_string) d.request_id);
       ("decision", J.str (Decision.verdict_to_string d.verdict));
       ("acting", about (fun a -> principal_json (Decision.acting a)));
       ("subject", about (fun a -> principal_json a.subject));
       ("actor_chain", about (fun a -> J.list principal_json a.actor_chain));
       ("mandate", about (fun a -> J.opt (id Id.Mandate.to_string) a.query.mandate));
       ("capability", about (fun a -> capability_json a.query.capability));
       ("resource", about (fun a -> id Id.Resource.to_string a.query.resource));
       ("effect", about (fun a -> J.opt effect_json a.query.effect)) ]
    @ (match d.verdict with Allow a -> [ ("authority", authority_json a) ] | Deny _ | Indeterminate _ -> [])
    @ [ ("reasons", J.list reason (Decision.reasons d)); ("evidence", evidence_json d) ])
