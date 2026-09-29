(* java-source-graph/v1: the Java side of the proof search, as extracted by
   tools/java-graph/JavaGraph.java. Decoding is strict: unknown keys, unknown
   enumeration values and dangling slice references are errors. *)

let schema = "java-source-graph/v1"

type resolution = Slice | Jdk | External
type relation = Extends | Super

type type_ref =
  | Void
  | Primitive of string
  | Array of type_ref
  | Type_var of string
  | Wildcard of (relation * type_ref) option
  | Class of class_ref

and class_ref = {
  written : string;
  resolution : resolution;
  name : string;  (** slice type id, or qualified name for [Jdk] and [External] *)
  basis : string;  (** how the extractor resolved the name *)
  args : type_ref list;
}

type annotation = {
  ann_name : string;
  ann_qualified : string option;
  ann_arguments : string list;
  ann_line : int;
}

type type_param = { tp_name : string; tp_bounds : type_ref list }

type param = {
  p_name : string;
  p_type : type_ref;
  p_varargs : bool;
  p_annotations : annotation list;
}

type member_kind = Field | Component | Method | Constructor

type member = {
  m_kind : member_kind;
  m_name : string;
  m_line : int;
  m_modifiers : string list;
  m_annotations : annotation list;
  m_type_params : type_param list;
  m_type : type_ref option;  (** [None] only for constructors *)
  m_params : param list;
  m_throws : type_ref list;
  m_has_body : bool;
  m_returns_null : bool;
}

type type_kind = Interface | Class_decl | Enum | Record_decl | Annotation_decl
type constant = { c_name : string; c_line : int; c_annotations : annotation list }

type jtype = {
  id : string;  (** Outer.Inner, unique within the slice *)
  qualified_name : string;
  kind : type_kind;
  file : string;
  line : int;
  enclosing : string option;
  modifiers : string list;
  annotations : annotation list;
  type_params : type_param list;
  extends : type_ref list;
  implements : type_ref list;
  constants : constant list;
  members : member list;
}

type source_file = { path : string; git_blob : string }

type t = {
  commit : string;
  extractor : string;
  resolution_mode : string;
  files : source_file list;
  types : jtype list;  (** sorted by id *)
}

(* ---------- small queries ---------- *)

let has_modifier m name = List.mem name m.m_modifiers
let is_static m = has_modifier m "static"
let is_private m = has_modifier m "private"
let is_final m = has_modifier m "final"
let is_default m = has_modifier m "default"

let simple_name id =
  match String.rindex_opt id '.' with None -> id | Some i -> String.sub id (i + 1) (String.length id - i - 1)

let find_type g id = List.find_opt (fun t -> t.id = id) g.types

let kind_to_string = function
  | Interface -> "interface"
  | Class_decl -> "class"
  | Enum -> "enum"
  | Record_decl -> "record"
  | Annotation_decl -> "annotation"

let is_reference = function Void | Primitive _ -> false | _ -> true

(* Java-like rendering, used in reasons and reports. *)
let rec render = function
  | Void -> "void"
  | Primitive p -> p
  | Array e -> render e ^ "[]"
  | Type_var v -> v
  | Wildcard None -> "?"
  | Wildcard (Some (Extends, t)) -> "? extends " ^ render t
  | Wildcard (Some (Super, t)) -> "? super " ^ render t
  | Class c ->
      let head = match c.resolution with Slice -> c.name | Jdk | External -> simple_name c.name in
      if c.args = [] then head else head ^ "<" ^ String.concat ", " (List.map render c.args) ^ ">"

(* Erased simple name of a parameter type, used to key overloaded methods. *)
let rec erased = function
  | Void -> "void"
  | Primitive p -> p
  | Array e -> erased e ^ "[]"
  | Type_var v -> v
  | Wildcard _ -> "?"
  | Class c -> ( match c.resolution with Slice -> c.name | Jdk | External -> simple_name c.name)

(* ---------- decoding ---------- *)

open Tjson.Decode

let enum_of c table =
  let* s = string c in
  match List.assoc_opt s table with
  | Some v -> Ok v
  | None -> fail c (Printf.sprintf "unexpected value %S" s)

let string_list c = map_list string c

let string_opt name c =
  let* v = field_opt name c in
  match v with None -> Ok None | Some v -> Result.map Option.some (string v)

let rec type_ref c : type_ref r =
  let* fields = obj c in
  let* kind = field "kind" c in
  let* kind = string kind in
  let keys = List.map fst fields in
  let only allowed = match List.find_opt (fun k -> not (List.mem k allowed)) keys with
    | Some k -> fail c (Printf.sprintf "unknown field %S for a %s type reference" k kind)
    | None -> Ok ()
  in
  match kind with
  | "void" ->
      let* () = only [ "kind" ] in
      Ok Void
  | "primitive" ->
      let* () = only [ "kind"; "name" ] in
      let* n = field "name" c in
      let* n = string n in
      if List.mem n [ "boolean"; "byte"; "short"; "char"; "int"; "long"; "float"; "double" ] then Ok (Primitive n)
      else fail c ("unknown primitive " ^ n)
  | "array" ->
      let* () = only [ "kind"; "element" ] in
      let* e = field "element" c in
      let+ e = type_ref e in
      Array e
  | "type_var" ->
      let* () = only [ "kind"; "name" ] in
      let* n = field "name" c in
      let+ n = string n in
      Type_var n
  | "wildcard" -> (
      let* () = only [ "kind"; "bound" ] in
      let* b = field_opt "bound" c in
      match b with
      | None -> Ok (Wildcard None)
      | Some b ->
          let* _ = obj ~allowed:[ "relation"; "type" ] b in
          let* rel = field "relation" b in
          let* rel = enum_of rel [ ("extends", Extends); ("super", Super) ] in
          let* t = field "type" b in
          let+ t = type_ref t in
          Wildcard (Some (rel, t)))
  | "class" ->
      let* () = only [ "kind"; "written"; "resolution"; "name"; "basis"; "args" ] in
      let* written = field "written" c in
      let* written = string written in
      let* res = field "resolution" c in
      let* resolution = enum_of res [ ("slice", Slice); ("jdk", Jdk); ("external", External) ] in
      let* name = field "name" c in
      let* name = string name in
      let* basis = field "basis" c in
      let* basis = string basis in
      let* args = field "args" c in
      let+ args = map_list type_ref args in
      Class { written; resolution; name; basis; args }
  | k -> fail c ("unknown type reference kind " ^ k)

let annotation c =
  let* _ = obj ~allowed:[ "name"; "qualified"; "arguments"; "line" ] c in
  let* n = field "name" c in
  let* ann_name = string n in
  let* ann_qualified = string_opt "qualified" c in
  let* a = field "arguments" c in
  let* ann_arguments = string_list a in
  let* l = field "line" c in
  let+ ann_line = int l in
  { ann_name; ann_qualified; ann_arguments; ann_line }

let type_param c =
  let* _ = obj ~allowed:[ "name"; "bounds" ] c in
  let* n = field "name" c in
  let* tp_name = string n in
  let* b = field "bounds" c in
  let+ tp_bounds = map_list type_ref b in
  { tp_name; tp_bounds }

let param c =
  let* _ = obj ~allowed:[ "name"; "type"; "varargs"; "annotations" ] c in
  let* n = field "name" c in
  let* p_name = string n in
  let* t = field "type" c in
  let* p_type = type_ref t in
  let* v = field "varargs" c in
  let* p_varargs = bool v in
  let* a = field "annotations" c in
  let+ p_annotations = map_list annotation a in
  { p_name; p_type; p_varargs; p_annotations }

let member c =
  let* _ =
    obj
      ~allowed:
        [ "kind"; "name"; "line"; "modifiers"; "annotations"; "type_params"; "type"; "params"; "throws";
          "has_body"; "returns_null_literal" ]
      c
  in
  let* k = field "kind" c in
  let* m_kind =
    enum_of k [ ("field", Field); ("component", Component); ("method", Method); ("constructor", Constructor) ]
  in
  let* n = field "name" c in
  let* m_name = string n in
  let* l = field "line" c in
  let* m_line = int l in
  let* m = field "modifiers" c in
  let* m_modifiers = string_list m in
  let* a = field "annotations" c in
  let* m_annotations = map_list annotation a in
  let* tp = field "type_params" c in
  let* m_type_params = map_list type_param tp in
  let* t = field_opt "type" c in
  let* m_type = match t with None -> Ok None | Some t -> Result.map Option.some (type_ref t) in
  let* p = field "params" c in
  let* m_params = map_list param p in
  let* th = field "throws" c in
  let* m_throws = map_list type_ref th in
  let* hb = field "has_body" c in
  let* m_has_body = bool hb in
  let* rn = field "returns_null_literal" c in
  let* m_returns_null = bool rn in
  let* () =
    match (m_kind, m_type) with
    | Constructor, Some _ -> fail c "a constructor has no type"
    | (Field | Component | Method), None -> fail c "a field, component or method needs a type"
    | _ -> Ok ()
  in
  Ok
    { m_kind; m_name; m_line; m_modifiers; m_annotations; m_type_params; m_type; m_params; m_throws; m_has_body;
      m_returns_null }

let constant c =
  let* _ = obj ~allowed:[ "name"; "line"; "annotations" ] c in
  let* n = field "name" c in
  let* c_name = string n in
  let* l = field "line" c in
  let* c_line = int l in
  let* a = field "annotations" c in
  let+ c_annotations = map_list annotation a in
  { c_name; c_line; c_annotations }

let jtype c =
  let* _ =
    obj
      ~allowed:
        [ "id"; "qualified_name"; "kind"; "file"; "line"; "enclosing"; "modifiers"; "annotations"; "type_params";
          "extends"; "implements"; "constants"; "members" ]
      c
  in
  let get name dec = let* v = field name c in dec v in
  let* id = get "id" string in
  let* qualified_name = get "qualified_name" string in
  let* kind =
    get "kind" (fun v ->
        enum_of v
          [ ("interface", Interface); ("class", Class_decl); ("enum", Enum); ("record", Record_decl);
            ("annotation", Annotation_decl) ])
  in
  let* file = get "file" string in
  let* line = get "line" int in
  let* enclosing = string_opt "enclosing" c in
  let* modifiers = get "modifiers" string_list in
  let* annotations = get "annotations" (map_list annotation) in
  let* type_params = get "type_params" (map_list type_param) in
  let* extends = get "extends" (map_list type_ref) in
  let* implements = get "implements" (map_list type_ref) in
  let* constants = get "constants" (map_list constant) in
  let* members = get "members" (map_list member) in
  Ok
    { id; qualified_name; kind; file; line; enclosing; modifiers; annotations; type_params; extends; implements;
      constants; members }

let source_file c =
  let* _ = obj ~allowed:[ "path"; "git_blob" ] c in
  let* p = field "path" c in
  let* path = string p in
  let* b = field "git_blob" c in
  let+ git_blob = string b in
  { path; git_blob }

(* Every slice reference names a slice type; enclosing types exist; ids are unique. *)
let validate g =
  let ids = Hashtbl.create 64 in
  let dup = List.find_opt (fun t -> if Hashtbl.mem ids t.id then true else (Hashtbl.add ids t.id (); false)) g.types in
  match dup with
  | Some t -> Error ("duplicate type id " ^ t.id)
  | None ->
      let bad = ref None in
      let rec walk where = function
        | Void | Primitive _ | Type_var _ | Wildcard None -> ()
        | Array e | Wildcard (Some (_, e)) -> walk where e
        | Class c ->
            if c.resolution = Slice && not (Hashtbl.mem ids c.name) then
              bad := Some (Printf.sprintf "%s: slice reference to unknown type %s" where c.name);
            (* Slice ids and external names share one namespace in a certificate's encodings. *)
            if c.resolution <> Slice && Hashtbl.mem ids c.name then
              bad := Some (Printf.sprintf "%s: external type %s has the name of a slice type" where c.name);
            List.iter (walk where) c.args
      in
      List.iter
        (fun t ->
          (match t.enclosing with
          | Some e when not (Hashtbl.mem ids e) -> bad := Some (t.id ^ ": unknown enclosing type " ^ e)
          | _ -> ());
          List.iter (fun tp -> List.iter (walk t.id) tp.tp_bounds) t.type_params;
          List.iter (walk t.id) (t.extends @ t.implements);
          List.iter
            (fun m ->
              let where = t.id ^ "." ^ m.m_name in
              Option.iter (walk where) m.m_type;
              List.iter (fun p -> walk where p.p_type) m.m_params;
              List.iter (walk where) m.m_throws;
              List.iter (fun tp -> List.iter (walk where) tp.tp_bounds) m.m_type_params)
            t.members)
        g.types;
      match !bad with Some e -> Error e | None -> Ok ()

let decode (json : Tjson.t) : (t, string) result =
  let res =
    let c = root json in
    let* _ = obj ~allowed:[ "schema"; "source"; "types" ] c in
    let* s = field "schema" c in
    let* s = string s in
    let* () = if s = schema then Ok () else fail c ("expected schema " ^ schema ^ ", found " ^ s) in
    let* src = field "source" c in
    let* _ = obj ~allowed:[ "commit"; "extractor"; "resolution"; "files" ] src in
    let* commit = let* v = field "commit" src in string v in
    let* extractor = let* v = field "extractor" src in string v in
    let* resolution_mode = let* v = field "resolution" src in string v in
    let* files = let* v = field "files" src in map_list source_file v in
    let* types = let* v = field "types" c in map_list jtype v in
    Ok { commit; extractor; resolution_mode; files; types = List.sort (fun a b -> compare a.id b.id) types }
  in
  match res with
  | Error e -> Error (e.path ^ ": " ^ e.message)
  | Ok g -> Result.map (fun () -> g) (validate g)

(* The digest binds a certificate to the exact graph: MD5 of the compact
   re-serialisation, so whitespace does not matter but every value does. *)
let digest_of_json json = "md5:" ^ Digest.to_hex (Digest.string (Tjson.to_string json))

let of_string text : (t * string, string) result =
  match Tjson.parse ~max_depth:128 text with
  | Error e -> Error (Printf.sprintf "JSON error at offset %d: %s" e.offset e.message)
  | Ok json -> Result.map (fun g -> (g, digest_of_json json)) (decode json)
