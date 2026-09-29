(* Obligations derived from the Java graph (docs/proof-search.md, "Obligations").

   Derivation is a pure function of the graph. The search and the certificate
   checker both call [derive]; neither trusts the other's verdicts. *)

open Jgraph

type kind =
  | Represent
  | Nullability
  | Closed
  | Open
  | Unique
  | Keyed
  | Command
  | Query
  | Mutable
  | Checked
  | Bounded
  | Subtype
  | Dynamic

let all_kinds =
  [ Represent; Nullability; Closed; Open; Unique; Keyed; Command; Query; Mutable; Checked; Bounded; Subtype; Dynamic ]

let kind_to_string = function
  | Represent -> "Represent"
  | Nullability -> "Nullability"
  | Closed -> "Closed"
  | Open -> "Open"
  | Unique -> "Unique"
  | Keyed -> "Keyed"
  | Command -> "Command"
  | Query -> "Query"
  | Mutable -> "Mutable"
  | Checked -> "Checked"
  | Bounded -> "Bounded"
  | Subtype -> "Subtype"
  | Dynamic -> "Dynamic"

type evidence = Returns_null | Nullable_annotation of string | Nonnull_annotation of string | No_evidence

type subject =
  | Value of type_ref  (** Represent *)
  | Null_evidence of type_ref * evidence  (** Nullability *)
  | Constants of string list  (** Closed *)
  | Open_because of string  (** Open *)
  | Element of type_ref  (** Unique: the element type of a Set *)
  | Key_value of type_ref * type_ref  (** Keyed: key and value types of a Map *)
  | Behaviour  (** Command, Query *)
  | Mutation of [ `Setter | `Field ]  (** Mutable *)
  | Exception of type_ref  (** Checked *)
  | Bound of string * type_ref  (** Bounded: parameter and bound *)
  | Supertype of string  (** Subtype: the slice supertype *)
  | Dynamic_parts of type_ref * string list  (** Dynamic: the type and the constructs in it that opted out *)

type member_ref = { key : string; name : string; line : int; static : bool }

type t = {
  id : string;
  kind : kind;
  owner : string;  (** slice type id *)
  member : member_ref option;
  position : string option;  (** "type", "return", "param:<name>", plus "/<arg index>" inside generics *)
  subject : subject;
}

(* ---------- member classification ---------- *)

let accessor_prefix prefix name =
  let n = String.length prefix in
  String.length name > n && String.sub name 0 n = prefix && Char.uppercase_ascii name.[n] = name.[n]
  && Char.lowercase_ascii name.[n] <> name.[n]

let is_getter m =
  m.m_kind = Method && m.m_params = [] && m.m_type <> Some Void
  && (accessor_prefix "get" m.m_name || accessor_prefix "is" m.m_name)

let is_setter m =
  m.m_kind = Method && m.m_type = Some Void && List.length m.m_params = 1 && accessor_prefix "set" m.m_name

(* How a member is carried. Data members are fields, record components and
   getters. A method that is neither getter nor setter is a command if it
   returns void and a query otherwise (including nullary non-getters such as
   toMap(), see contract notes). *)
type role = Data | Setter | Command_role | Query_role

let role m =
  match m.m_kind with
  | Field | Component -> Data
  | Constructor -> invalid_arg "Obligation.role: constructor"
  | Method ->
      if is_getter m then Data
      else if is_setter m then Setter
      else if m.m_type = Some Void then Command_role
      else Query_role

(* Constructors create values and private members are not part of the type's
   interface; neither produces obligations. *)
let projected m = m.m_kind <> Constructor && not (is_private m)

let decapitalize s = if s = "" then s else String.make 1 (Char.lowercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

(* Bean property of a data member or setter: getFoo/isFoo/setFoo -> foo; a field is its own property. *)
let property m =
  let strip p = decapitalize (String.sub m.m_name (String.length p) (String.length m.m_name - String.length p)) in
  match m.m_kind with
  | Field | Component | Constructor -> m.m_name
  | Method ->
      if accessor_prefix "get" m.m_name then strip "get"
      else if accessor_prefix "is" m.m_name then strip "is"
      else if accessor_prefix "set" m.m_name then strip "set"
      else m.m_name

let member_key m =
  match m.m_kind with
  | Field | Component -> m.m_name
  | Method | Constructor -> m.m_name ^ "(" ^ String.concat "," (List.map (fun p -> erased p.p_type) m.m_params) ^ ")"

let member_ref m = { key = member_key m; name = m.m_name; line = m.m_line; static = is_static m }

(* ---------- leaves of a type reference ---------- *)

type leaf =
  | Scalar of string  (** primitive, boxed primitive or String *)
  | Slice_type of string
  | External_type of string
  | Dynamic_value of string  (** Object, Class<...>, raw generic, unbounded wildcard *)
  | Var of string

let scalar_jdk = [ "String"; "Boolean"; "Byte"; "Short"; "Character"; "Integer"; "Long"; "Float"; "Double" ]

(* [arity id] is the number of type parameters of slice type [id]. The type
   arguments of a Class<...> are not leaves: the whole reference is dynamic. *)
let rec leaves ~arity (t : type_ref) : leaf list =
  match t with
  | Void -> []
  | Primitive p -> [ Scalar p ]
  | Array e -> leaves ~arity e
  | Type_var v -> [ Var v ]
  | Wildcard None -> [ Dynamic_value "?" ]
  | Wildcard (Some (_, b)) -> leaves ~arity b
  | Class c -> (
      let args () = List.concat_map (leaves ~arity) c.args in
      match c.resolution with
      | Slice ->
          if arity c.name > 0 && c.args = [] then [ Dynamic_value ("raw " ^ c.name) ] else Slice_type c.name :: args ()
      | External -> External_type c.name :: args ()
      | Jdk -> (
          match simple_name c.name with
          | s when List.mem s scalar_jdk -> [ Scalar s ]
          | "Object" -> [ Dynamic_value "Object" ]
          | "Class" -> [ Dynamic_value (render t) ]
          | s -> if c.args = [] then [ Dynamic_value ("raw " ^ s) ] else args ()))

(* Every slice type a reference mentions, including raw ones and those inside Class<...>. *)
let rec slice_mentions (t : type_ref) : string list =
  match t with
  | Void | Primitive _ | Type_var _ | Wildcard None -> []
  | Array e | Wildcard (Some (_, e)) -> slice_mentions e
  | Class c ->
      let rest = List.concat_map slice_mentions c.args in
      if c.resolution = Slice then c.name :: rest else rest

let rec external_mentions (t : type_ref) : (string * int) list =
  match t with
  | Void | Primitive _ | Type_var _ | Wildcard None -> []
  | Array e | Wildcard (Some (_, e)) -> external_mentions e
  | Class c ->
      let rest = List.concat_map external_mentions c.args in
      if c.resolution = External then (c.name, List.length c.args) :: rest else rest

(* ---------- per-type facts shared by search, checker and emitter ---------- *)

(* Positions of a projected member that carry a value: (position, type, annotations, returns_null). *)
let positions m =
  match (m.m_kind, m.m_type) with
  | (Field | Component), Some t -> [ ("type", t, m.m_annotations, false) ]
  | Method, Some t ->
      let ret = if t = Void then [] else [ ("return", t, m.m_annotations, m.m_returns_null) ] in
      ret @ List.map (fun p -> ("param:" ^ p.p_name, p.p_type, p.p_annotations, false)) m.m_params
  | _ -> []

(* Types a Record encoding carries as fields: instance data members, plus the
   value of every setter whose property has no data member (it needs a mutable
   field of its own). Static members do not become fields. *)
let carried_members (jt : jtype) =
  let instance = List.filter (fun m -> projected m && not (is_static m)) jt.members in
  let data = List.filter (fun m -> role m = Data) instance in
  let props = List.map property data in
  let orphan_setters = List.filter (fun m -> role m = Setter && not (List.mem (property m) props)) instance in
  (data, orphan_setters)

let carried_types jt =
  let data, orphans = carried_members jt in
  List.filter_map (fun m -> m.m_type) data @ List.map (fun m -> (List.hd m.m_params).p_type) orphans

(* Type references whose slice mentions are edges of the type-reference graph. *)
let referenced_types (jt : jtype) =
  let bounds tps = List.concat_map (fun tp -> tp.tp_bounds) tps in
  bounds jt.type_params @ jt.extends @ jt.implements
  @ List.concat_map
      (fun m ->
        if not (projected m) then []
        else
          Option.to_list m.m_type
          @ List.map (fun p -> p.p_type) m.m_params
          @ m.m_throws @ bounds m.m_type_params)
      jt.members

let open_reason (jt : jtype) =
  if jt.kind <> Interface then None
  else
    let super =
      List.find_map
        (function
          | Class c when List.mem (simple_name c.name) [ "Provider"; "ProviderFactory" ] ->
              Some ("extends " ^ simple_name c.name)
          | _ -> None)
        jt.extends
    in
    match super with
    | Some _ -> super
    | None ->
        let s = simple_name jt.id in
        let ends suffix =
          let n = String.length suffix and l = String.length s in
          l >= n && String.sub s (l - n) n = suffix
        in
        if ends "Provider" then Some "name ends in Provider"
        else if ends "Factory" then Some "name ends in Factory"
        else None

let evidence ~returns_null annotations =
  let named names = List.find_opt (fun a -> List.mem (simple_name a.ann_name) names) annotations in
  if returns_null then Returns_null
  else
    match named [ "Nullable" ] with
    | Some a -> Nullable_annotation a.ann_name
    | None -> ( match named [ "Nonnull"; "NotNull" ] with Some a -> Nonnull_annotation a.ann_name | None -> No_evidence)

(* ---------- derivation ---------- *)

let arity_of (g : Jgraph.t) =
  let tbl = Hashtbl.create 64 in
  List.iter (fun (jt : jtype) -> Hashtbl.replace tbl jt.id (List.length jt.type_params)) g.types;
  fun id -> Option.value (Hashtbl.find_opt tbl id) ~default:0

(* Set and Map occurrences inside a type, with their path of argument indices. *)
let rec collections path (t : type_ref) acc =
  match t with
  | Void | Primitive _ | Type_var _ | Wildcard None -> acc
  | Array e -> collections (path ^ "/[]") e acc
  | Wildcard (Some (_, e)) -> collections path e acc
  | Class c ->
      let here =
        match (c.resolution, simple_name c.name, c.args) with
        | Jdk, "Set", [ e ] -> [ (path, Unique, Element e) ]
        | Jdk, "Map", [ k; v ] -> [ (path, Keyed, Key_value (k, v)) ]
        | _ -> []
      in
      let acc = acc @ here in
      let _, acc =
        List.fold_left (fun (i, acc) a -> (i + 1, collections (Printf.sprintf "%s/%d" path i) a acc)) (0, acc) c.args
      in
      acc

let dynamic_parts ~arity t =
  List.filter_map (function Dynamic_value d -> Some d | _ -> None) (leaves ~arity t) |> List.sort_uniq compare

let derive (g : Jgraph.t) : t list =
  let arity = arity_of g in
  let out = ref [] in
  let emit ?member ?position kind owner subject =
    let base =
      match member with None -> owner | Some (mr : member_ref) -> owner ^ "." ^ mr.key
    in
    let id =
      kind_to_string kind ^ ":" ^ base ^ match position with None -> "" | Some p -> "@" ^ p
    in
    out := { id; kind; owner; member; position; subject } :: !out
  in
  let bounded owner ?member tps =
    List.iter
      (fun tp ->
        List.iter
          (fun b ->
            let pos = "<" ^ tp.tp_name ^ " extends " ^ render b ^ ">" in
            emit ?member ~position:pos Bounded owner (Bound (tp.tp_name, b)))
          tp.tp_bounds)
      tps
  in
  List.iter
    (fun (jt : jtype) ->
      let owner = jt.id in
      if jt.kind = Enum then emit Closed owner (Constants (List.map (fun c -> c.c_name) jt.constants));
      Option.iter (fun why -> emit Open owner (Open_because why)) (open_reason jt);
      bounded owner jt.type_params;
      List.iter
        (function
          | Class { resolution = Slice; name; _ } -> emit ~position:("<: " ^ name) Subtype owner (Supertype name)
          | _ -> ())
        (jt.extends @ jt.implements);
      List.iter
        (fun m ->
          if projected m then begin
            let member = member_ref m in
            List.iter
              (fun (pos, t, anns, returns_null) ->
                emit ~member ~position:pos Represent owner (Value t);
                if is_reference t then
                  emit ~member ~position:pos Nullability owner (Null_evidence (t, evidence ~returns_null anns));
                List.iter
                  (fun (path, kind, subject) -> emit ~member ~position:path kind owner subject)
                  (collections pos t []);
                match dynamic_parts ~arity t with
                | [] -> ()
                | parts -> emit ~member ~position:pos Dynamic owner (Dynamic_parts (t, parts)))
              (positions m);
            (match role m with
            | Data -> if m.m_kind = Field && not (is_final m) then emit ~member Mutable owner (Mutation `Field)
            | Setter -> emit ~member Mutable owner (Mutation `Setter)
            | Command_role -> emit ~member Command owner Behaviour
            | Query_role -> emit ~member Query owner Behaviour);
            List.iter (fun x -> emit ~member ~position:("throws " ^ render x) Checked owner (Exception x)) m.m_throws;
            bounded owner ~member m.m_type_params
          end)
        jt.members)
    g.types;
  List.rev !out

(* Human-readable subject of an obligation, e.g. "Policy.getScopes() : Set<Scope>". *)
let describe (o : t) =
  let where = match o.member with None -> o.owner | Some m -> o.owner ^ "." ^ m.key in
  let pos = match o.position with None | Some ("return" | "type") -> "" | Some p -> " [" ^ p ^ "]" in
  match o.subject with
  | Value t | Null_evidence (t, _) | Dynamic_parts (t, _) -> where ^ pos ^ " : " ^ render t
  | Element e -> where ^ pos ^ " : Set<" ^ render e ^ ">"
  | Key_value (k, v) -> where ^ pos ^ " : Map<" ^ render k ^ ", " ^ render v ^ ">"
  | Bound (p, b) -> where ^ " <" ^ p ^ " extends " ^ render b ^ ">"
  | Supertype s -> where ^ " <: " ^ s
  | Exception x -> where ^ " throws " ^ render x
  | Constants _ | Open_because _ | Behaviour | Mutation _ -> where ^ pos
