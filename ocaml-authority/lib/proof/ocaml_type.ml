(* OCaml names and type expressions for a chosen assignment. *)

open Jgraph

let keywords =
  [ "and"; "as"; "asr"; "assert"; "begin"; "class"; "constraint"; "do"; "done"; "downto"; "else"; "end";
    "exception"; "external"; "false"; "for"; "fun"; "function"; "functor"; "if"; "in"; "include"; "inherit";
    "initializer"; "land"; "lazy"; "let"; "lor"; "lsl"; "lsr"; "lxor"; "match"; "method"; "mod"; "module";
    "mutable"; "new"; "nonrec"; "object"; "of"; "open"; "or"; "private"; "rec"; "sig"; "struct"; "then"; "to";
    "true"; "try"; "type"; "val"; "virtual"; "when"; "while"; "with" ]

(* Type names the emitted file uses itself. *)
let reserved_types =
  [ "array"; "bool"; "bytes"; "char"; "exn"; "float"; "format"; "int"; "int32"; "int64"; "java_class";
    "java_object"; "lazy_t"; "list"; "nativeint"; "option"; "ref"; "result"; "string"; "t"; "unit" ]

let is_upper c = Char.uppercase_ascii c = c && Char.lowercase_ascii c <> c
let is_lower c = Char.lowercase_ascii c = c && Char.uppercase_ascii c <> c
let is_digit c = c >= '0' && c <= '9'

(* camelCase, PascalCase and ACRONYMS to snake_case; '.' becomes '_'. *)
let snake s =
  let n = String.length s in
  let b = Buffer.create (n + 8) in
  String.iteri
    (fun i c ->
      if c = '.' || c = '$' then Buffer.add_char b '_'
      else if is_upper c then begin
        let prev = if i > 0 then s.[i - 1] else '_' in
        let next = if i + 1 < n then s.[i + 1] else '_' in
        if i > 0 && prev <> '.' && prev <> '_' && (is_lower prev || is_digit prev || (is_upper prev && is_lower next))
        then Buffer.add_char b '_';
        Buffer.add_char b (Char.lowercase_ascii c)
      end
      else Buffer.add_char b c)
    s;
  Buffer.contents b

let ident s =
  let s = snake s in
  if List.mem s keywords then s ^ "_" else s

let tvar v = "'" ^ ident v

type names = { slice : (string, string) Hashtbl.t; external_ : (string, string) Hashtbl.t }

let names (m : Model.t) : names =
  let taken = Hashtbl.create 64 in
  List.iter (fun r -> Hashtbl.replace taken r ()) (reserved_types @ keywords);
  let claim base =
    let rec go i =
      let cand = if i = 0 then base else Printf.sprintf "%s_%d" base i in
      if Hashtbl.mem taken cand then go (i + 1)
      else begin
        Hashtbl.replace taken cand ();
        cand
      end
    in
    go 0
  in
  let slice = Hashtbl.create 64 and external_ = Hashtbl.create 16 in
  Array.iter (fun (jt : jtype) -> Hashtbl.replace slice jt.id (claim (snake jt.id))) m.nodes;
  List.iter
    (fun (q, _) ->
      let short = snake (simple_name q) in
      let base = if Hashtbl.mem taken short then snake q else short in
      Hashtbl.replace external_ q (claim base))
    m.externals;
  { slice; external_ }

let type_name names id = Hashtbl.find names.slice id
let external_name names q = Hashtbl.find names.external_ q
let module_type_name names id = String.uppercase_ascii (type_name names id)

type collection_kind = Set_of | Map_of
type element = Scalar_module of string | Slice_element of string

type ctx = {
  m : Model.t;
  enc : Model.assignment;
  names : names;
  used : (string, collection_kind * element) Hashtbl.t;  (** Set/Map modules the rendered types need *)
  subst : (string * string) list;  (** type variables to replace, e.g. a bound's parameters *)
}

let context m enc = { m; enc; names = names m; used = Hashtbl.create 16; subst = [] }

let scalar_module = function
  | "String" -> Some "String"
  | "boolean" | "Boolean" -> Some "Bool"
  | "int" | "short" | "byte" | "char" | "Integer" | "Short" | "Byte" | "Character" -> Some "Int"
  | "long" | "Long" -> Some "Int64"
  | "float" | "double" | "Float" | "Double" -> Some "Float"
  | _ -> None

let scalar_type = function
  | "String" -> "string"
  | "boolean" | "Boolean" -> "bool"
  | "long" | "Long" -> "Int64.t"
  | "float" | "double" | "Float" | "Double" -> "float"
  | _ -> "int"

let apply args name =
  match args with [] -> name | [ a ] -> a ^ " " ^ name | l -> "(" ^ String.concat ", " l ^ ") " ^ name

let collection_suffix = function Set_of -> "_set" | Map_of -> "_map"

(* The Set.Make / Map.Make module for an element or key type, if the encoding
   admits one: a scalar, or a single slice type whose comparison is not REFUTED.
   Everything else is carried as a list. *)
let collection_module ctx kind (elem : type_ref) =
  let register name el =
    Hashtbl.replace ctx.used name (kind, el);
    Some name
  in
  let scalar s =
    Option.bind (scalar_module s) (fun md -> register (md ^ collection_suffix kind) (Scalar_module md))
  in
  match elem with
  | Primitive p -> scalar p
  | Class { resolution = Jdk; name; _ } -> scalar (simple_name name)
  | Class { resolution = Slice; name; args = []; _ } when ctx.m.arity name = 0 ->
      if Evaluate.comparable_verdict ctx.m ctx.enc (Model.leaves ctx.m elem) = Encoding.Refuted then None
      else register (String.capitalize_ascii (type_name ctx.names name) ^ collection_suffix kind) (Slice_element name)
  | _ -> None

let rec render ctx (t : type_ref) : string =
  match t with
  | Void -> "unit"
  | Primitive p -> scalar_type p
  | Array e -> render ctx e ^ " array"
  | Type_var v -> ( match List.assoc_opt v ctx.subst with Some s -> s | None -> tvar v)
  | Wildcard None -> "java_object"
  | Wildcard (Some (_, b)) -> render ctx b
  | Class c -> (
      match c.resolution with
      | Jdk -> (
          match (simple_name c.name, c.args) with
          | s, _ when scalar_module s <> None -> scalar_type s
          | "Class", _ -> "java_class"
          | ("List" | "Collection"), [ e ] -> render ctx e ^ " list"
          | "Set", [ e ] -> (
              match collection_module ctx Set_of e with Some md -> md ^ ".t" | None -> render ctx e ^ " list")
          | "Map", [ k; v ] -> (
              match collection_module ctx Map_of k with
              | Some md -> render ctx v ^ " " ^ md ^ ".t"
              | None -> "(" ^ render ctx k ^ " * " ^ render ctx v ^ ") list")
          | _ -> "java_object")
      | Slice ->
          let v = Model.node ctx.m c.name in
          let arity = ctx.m.arity c.name in
          if arity > 0 && c.args = [] then "java_object"
          else if ctx.enc.(v) = Encoding.Module_type then "(module " ^ module_type_name ctx.names c.name ^ ")"
          else apply (List.map (render ctx) c.args) (type_name ctx.names c.name)
      | External ->
          let arity = Option.value (List.assoc_opt c.name ctx.m.externals) ~default:0 in
          let args = List.map (render ctx) c.args in
          let args = args @ List.init (max 0 (arity - List.length args)) (fun _ -> "java_object") in
          apply args (external_name ctx.names c.name))

(* Type of a value position after the Nullability verdict: [option] unless the
   source says @Nonnull. *)
let with_nullability (t : type_ref) (ev : Obligation.evidence) base =
  if is_reference t then match ev with Obligation.Nonnull_annotation _ -> base | _ -> base ^ " option" else base

(* The OCaml type recorded in the certificate for Represent and Nullability. *)
let of_obligation ctx (o : Obligation.t) =
  match o.subject with
  | Value t -> Some (render ctx t)
  | Null_evidence (t, ev) -> Some (with_nullability t ev (render ctx t))
  | _ -> None
