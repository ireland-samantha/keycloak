type fault_code =
  | Missing_parent
  | Forged_delegation
  | Delegation_depth_exceeded
  | Capability_amplified
  | Target_amplified
  | Mandate_amplified
  | Effect_amplified
  | Validity_extended
  | Cycle
  | Chain_too_long
  | Revoked
  | Not_yet_valid
  | Expired
  | Anchor_missing

type gap_code = Unanchored_ancestor | No_role_facts
type 'code finding = { code : 'code; grant : Id.Grant.t; detail : string }
type verified = { links : Grant.t Nonempty.t; anchor : Grant.anchor }

type result =
  | Verified of verified
  | Invalid of fault_code finding Nonempty.t
  | Unverifiable of gap_code finding Nonempty.t

let max_links = 16
let sp = Printf.sprintf
let gid (t : Grant.terms) = Id.Grant.to_string t.id
let links v = v.links
let leaf v = Nonempty.last v.links
let root_holder v = v.links.head.terms.holder
let anchor v = v.anchor

let describe v =
  sp "%s; root anchored in %s held by %s"
    (String.concat " > " (List.map (fun (g : Grant.t) -> gid g.terms) (Nonempty.to_list v.links)))
    (Grant.anchor_to_string v.anchor) (Principal.to_string (root_holder v))

let window (t : Grant.terms) =
  let bound default = Option.fold ~none:default ~some:Timestamp.to_string in
  sp "[%s, %s)" (bound "-inf" t.valid_from) (bound "+inf" t.valid_until)

(* [c]'s validity window lies inside [p]'s; an absent bound is unbounded. *)
let window_within (c : Grant.terms) (p : Grant.terms) =
  let inside ~inner ~outer ok =
    match (outer, inner) with None, _ -> true | Some _, None -> false | Some o, Some i -> ok (Timestamp.compare i o)
  in
  inside ~inner:c.valid_from ~outer:p.valid_from (fun n -> n >= 0)
  && inside ~inner:c.valid_until ~outer:p.valid_until (fun n -> n <= 0)

(* The per-link checks of the table, for child [c] delegated by [delegator]
   from parent [p]. *)
let link_faults (p : Grant.terms) (c : Grant.terms) delegator =
  List.filter_map
    (fun (ok, code, detail) -> if ok then None else Some { code; grant = c.id; detail })
    [ ( Principal.equal delegator p.holder,
        Forged_delegation,
        sp "%s names delegator %s but parent %s is held by %s" (gid c) (Principal.to_string delegator) (gid p)
          (Principal.to_string p.holder) );
      ( p.delegable_depth >= 1 && c.delegable_depth <= p.delegable_depth - 1,
        Delegation_depth_exceeded,
        sp "parent %s has delegable_depth %d; %s has %d" (gid p) p.delegable_depth (gid c) c.delegable_depth );
      ( Capability.equal c.capability p.capability,
        Capability_amplified,
        sp "%s grants %s; parent %s grants %s" (gid c) (Capability.to_string c.capability) (gid p)
          (Capability.to_string p.capability) );
      ( Capability.target_subset c.target p.target,
        Target_amplified,
        sp "%s targets %s; parent %s targets %s" (gid c) (Capability.target_to_string c.target) (gid p)
          (Capability.target_to_string p.target) );
      ( Nonempty.for_all (fun m -> Nonempty.exists (Id.Mandate.equal m) p.mandates) c.mandates,
        Mandate_amplified,
        let names l = String.concat ", " (List.map Id.Mandate.to_string (Nonempty.to_list l)) in
        sp "%s is usable under %s; parent %s only under %s" (gid c) (names c.mandates) (gid p) (names p.mandates) );
      ( Nonempty.for_all (fun e -> Effect.within e p.effects) c.effects,
        Effect_amplified,
        sp "%s allows effects %s; parent %s allows %s" (gid c) (Effect.list_to_string c.effects) (gid p)
          (Effect.list_to_string p.effects) );
      ( window_within c p,
        Validity_extended,
        sp "%s is valid %s; parent %s only %s" (gid c) (window c) (gid p) (window p) ) ]

let grant_faults ledger now (t : Grant.terms) =
  let fault code detail = { code; grant = t.id; detail } in
  let revoked =
    match Ledger.revocation ledger t.id with
    | Some r -> [ fault Revoked (sp "%s was revoked at %s: %s" (gid t) (Timestamp.to_string r.at) r.reason) ]
    | None -> []
  in
  let early =
    match t.valid_from with
    | Some f when Timestamp.compare now f < 0 -> [ fault Not_yet_valid (sp "%s is not valid before %s" (gid t) (Timestamp.to_string f)) ]
    | _ -> []
  in
  let late =
    match t.valid_until with
    | Some u when Timestamp.compare now u >= 0 -> [ fault Expired (sp "%s expired at %s" (gid t) (Timestamp.to_string u)) ]
    | _ -> []
  in
  revoked @ early @ late

type stop =
  | Root_reached of Grant.anchor
  | Missing of Id.Grant.t
  | Unanchored_parent of Grant.unanchored
  | Cycle_at of Id.Grant.t
  | Too_long

(* Follows parents from [g] towards the root. Returns the anchored grants
   reached (root first), why the walk stopped, and the faults of the links
   walked (upper links first). *)
let resolve ledger (g : Grant.t) =
  let rec up below faults (g : Grant.t) =
    let chain = Nonempty.make g below in
    match g.provenance with
    | Root anchor -> (chain, Root_reached anchor, faults)
    | Delegated { parent; delegator } -> (
        if Nonempty.exists (fun (x : Grant.t) -> Id.Grant.equal x.terms.id parent) chain then (chain, Cycle_at parent, faults)
        else if Nonempty.length chain >= max_links then (chain, Too_long, faults)
        else
          match Ledger.find_entry ledger parent with
          | None -> (chain, Missing parent, faults)
          | Some (Grant.Unanchored u) -> (chain, Unanchored_parent u, link_faults u.claimed g.terms delegator @ faults)
          | Some (Grant.Anchored p) -> up (Nonempty.to_list chain) (link_faults p.terms g.terms delegator @ faults) p)
  in
  up [] [] g

let verify ledger (facts : Facts.t) (g : Grant.t) =
  let chain, stop, link_fs = resolve ledger g in
  let top = chain.head.terms and now = facts.evaluated_at in
  let base = List.concat_map (fun (x : Grant.t) -> grant_faults ledger now x.terms) (Nonempty.to_list chain) @ link_fs in
  let invalid first rest = Invalid (Nonempty.make first rest) in
  let fault code detail = { code; grant = top.id; detail } in
  match stop with
  | Missing parent -> invalid (fault Missing_parent (sp "parent %s of %s is not in the ledger" (Id.Grant.to_string parent) (gid top))) base
  | Cycle_at parent -> invalid (fault Cycle (sp "%s appears twice in the chain of %s" (Id.Grant.to_string parent) (gid g.terms))) base
  | Too_long -> invalid (fault Chain_too_long (sp "the chain of %s exceeds %d grants" (gid g.terms) max_links)) base
  | Unanchored_parent u -> (
      match base @ grant_faults ledger now u.claimed with
      | f :: fs -> invalid f fs
      | [] ->
          Unverifiable
            (Nonempty.singleton
               { code = Unanchored_ancestor; grant = u.claimed.id;
                 detail = sp "ancestor %s of %s has no provenance" (gid u.claimed) (gid g.terms) }))
  | Root_reached anchor -> (
      let holder = Principal.to_string top.holder and role = Grant.anchor_to_string anchor in
      match (Facts.roles_of facts top.holder, base) with
      | None, f :: fs -> invalid f fs
      | None, [] ->
          Unverifiable
            (Nonempty.singleton
               { code = No_role_facts; grant = top.id;
                 detail = sp "root %s: %s is absent from facts.principals, so holding %s is unknown" (gid top) holder role })
      | Some roles, _ -> (
          let anchor_fs =
            if Facts.holds roles anchor then []
            else [ fault Anchor_missing (sp "root %s: %s does not hold %s" (gid top) holder role) ]
          in
          match anchor_fs @ base with f :: fs -> invalid f fs | [] -> Verified { links = chain; anchor }))

let delegation_path ledger = function
  | Grant.Unanchored u -> Some [ u.claimed.holder ]
  | Grant.Anchored g -> (
      let chain, stop, _ = resolve ledger g in
      let holders = List.map (fun (x : Grant.t) -> x.terms.holder) (Nonempty.to_list chain) in
      match stop with
      | Root_reached _ -> Some holders
      | Unanchored_parent u -> Some (u.claimed.holder :: holders)
      | Missing _ | Cycle_at _ | Too_long -> None)

let fault_code_to_string = function
  | Missing_parent -> "missing_parent"
  | Forged_delegation -> "forged_delegation"
  | Delegation_depth_exceeded -> "delegation_depth_exceeded"
  | Capability_amplified -> "capability_amplified"
  | Target_amplified -> "target_amplified"
  | Mandate_amplified -> "mandate_amplified"
  | Effect_amplified -> "effect_amplified"
  | Validity_extended -> "validity_extended"
  | Cycle -> "cycle"
  | Chain_too_long -> "chain_too_long"
  | Revoked -> "revoked"
  | Not_yet_valid -> "not_yet_valid"
  | Expired -> "expired"
  | Anchor_missing -> "anchor_missing"

let gap_code_to_string = function Unanchored_ancestor -> "unanchored_ancestor" | No_role_facts -> "no_role_facts"
