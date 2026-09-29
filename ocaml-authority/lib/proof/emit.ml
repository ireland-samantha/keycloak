(* OCaml source for a chosen type graph. Types are emitted component by
   component, referents first, each component as one [type ... and ...] group.
   Every member carries a comment with its verdicts, taken from the certificate.
   Static members, and the instance members of a Variant, are not part of the
   type; they are declared in a companion module type at the end. *)

open Jgraph
open Encoding

(* Comments are lexed by OCaml: keep them free of string and comment delimiters. *)
let comment_safe s =
  let b = Buffer.create (String.length s) in
  String.iteri
    (fun i c ->
      let next = if i + 1 < String.length s then s.[i + 1] else ' ' in
      match c with
      | '"' -> Buffer.add_char b '\''
      | '*' when next = ')' -> Buffer.add_string b "* "
      | '(' when next = '*' -> Buffer.add_string b "( "
      | '{' when next = '|' -> Buffer.add_string b "{ "
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

type slot = {
  name : string;
  mutable_ : bool;
  ty : string;
  notes : string list;  (** verdict comments of the members this slot carries *)
}

type layout = {
  slots : slot list;  (** fields, methods or vals of the type itself *)
  not_carried : string list;  (** members a Record cannot carry *)
  companion : slot list;  (** statics, and Variant instance members *)
}

let arrow params ret = match params with [] -> "unit -> " ^ ret | ps -> String.concat " -> " ps ^ " -> " ^ ret

(* Unique names within one type, claimed in source order. *)
let namer () =
  let taken = Hashtbl.create 16 in
  fun ?(arity = -1) base ->
    let base = if List.mem base Ocaml_type.keywords then base ^ "_" else base in
    let rec go cands =
      match cands with
      | c :: rest -> if Hashtbl.mem taken c then go rest else (Hashtbl.replace taken c (); c)
      | [] -> assert false
    in
    let stem = if base.[String.length base - 1] = '_' then base else base ^ "_" in
    let numbered = List.init 100 (fun i -> Printf.sprintf "%s%d" stem (i + 2)) in
    go ((base :: (if arity >= 0 then [ Printf.sprintf "%s%d" stem arity ] else [])) @ numbered)

type env = {
  ctx : Ocaml_type.ctx;
  m : Model.t;
  entries : (string, Certificate.entry) Hashtbl.t;
  by_member : (string * string, Obligation.t list) Hashtbl.t;
  by_type : (string, Obligation.t list) Hashtbl.t;  (** type-level obligations *)
}

let obligation_label (o : Obligation.t) =
  let pos = match o.position with None | Some ("return" | "type") -> "" | Some p -> "@" ^ p in
  Obligation.kind_to_string o.kind ^ pos

(* "PROVEN a, b; STRENGTHENED c; UNKNOWN d: why; REFUTED e: why" *)
let verdict_notes env (obls : Obligation.t list) =
  let verdict o = (Hashtbl.find env.entries o.Obligation.id : Certificate.entry) in
  let group v =
    match List.filter (fun o -> (verdict o).verdict = v) obls with
    | [] -> []
    | os -> [ verdict_to_string v ^ " " ^ String.concat ", " (List.map obligation_label os) ]
  in
  let each v =
    List.filter_map
      (fun o ->
        let e = verdict o in
        if e.verdict = v then Some (verdict_to_string v ^ " " ^ obligation_label o ^ ": " ^ e.reason) else None)
      obls
  in
  String.concat "; " (group Proven @ group Strengthened @ each Unknown @ each Refuted)

let member_note env (jt : jtype) m =
  let obls = Option.value (Hashtbl.find_opt env.by_member (jt.id, Obligation.member_key m)) ~default:[] in
  Printf.sprintf "%s %s:%d | %s" (Obligation.member_key m) (Filename.basename jt.file) m.m_line (verdict_notes env obls)

let param_types env m =
  List.map
    (fun p ->
      let ev = Obligation.evidence ~returns_null:false p.p_annotations in
      Ocaml_type.with_nullability p.p_type ev (Ocaml_type.render env.ctx p.p_type))
    m.m_params

let return_type env m =
  match m.m_type with
  | None | Some Void -> if m.m_throws = [] then "unit" else "(unit, exn) result"
  | Some t ->
      let ev = Obligation.evidence ~returns_null:m.m_returns_null m.m_annotations in
      let base = Ocaml_type.with_nullability t ev (Ocaml_type.render env.ctx t) in
      if m.m_throws = [] then base else "(" ^ base ^ ", exn) result"

(* Explicit polymorphism for method-level type parameters. *)
let poly m ty =
  match m.m_type_params with
  | [] -> ty
  | tps -> String.concat " " (List.map (fun tp -> Ocaml_type.tvar tp.tp_name) tps) ^ ". " ^ ty

let self_type env (jt : jtype) =
  Ocaml_type.apply (List.map (fun tp -> Ocaml_type.tvar tp.tp_name) jt.type_params) (Ocaml_type.type_name env.ctx.names jt.id)

let layout env (jt : jtype) (enc : Encoding.t) : layout =
  let fresh = namer () in
  (* Companion vals live in their own module type, hence their own namespace. *)
  let fresh_companion = namer () in
  let slots = ref [] and not_carried = ref [] and companion = ref [] in
  let add r s = r := s :: !r in
  let members = List.filter Obligation.projected jt.members in
  let value_type m = match m.m_type with Some t -> Ocaml_type.with_nullability t (Obligation.evidence ~returns_null:m.m_returns_null m.m_annotations) (Ocaml_type.render env.ctx t) | None -> "unit" in
  let note m = member_note env jt m in
  let snake_name m = Ocaml_type.snake m.m_name in
  let static_slot ?(fresh = fresh_companion) m =
    let name = fresh ~arity:(List.length m.m_params) (snake_name m) in
    let ty = match m.m_kind with Field | Component -> value_type m | _ -> arrow (param_types env m) (return_type env m) in
    { name; mutable_ = false; ty; notes = [ "static " ^ note m ] }
  in
  (match enc with
  | Record ->
      (* One field per property; a setter makes its property's field mutable. *)
      let data, orphans = Obligation.carried_members jt in
      let setters = List.filter (fun m -> Obligation.role m = Obligation.Setter && not (Jgraph.is_static m)) members in
      let prop_slots = Hashtbl.create 16 in
      List.iter
        (fun m ->
          let prop = Obligation.property m in
          let name = fresh (Ocaml_type.snake prop) in
          let setter_notes = List.filter (fun s -> Obligation.property s = prop) setters in
          let is_mutable = (m.m_kind = Field && not (Jgraph.is_final m)) || setter_notes <> [] in
          Hashtbl.replace prop_slots prop ();
          add slots { name; mutable_ = is_mutable; ty = value_type m; notes = note m :: List.map note setter_notes })
        data;
      List.iter
        (fun m ->
          if not (Hashtbl.mem prop_slots (Obligation.property m)) then begin
            let p = List.hd m.m_params in
            let ty = Ocaml_type.with_nullability p.p_type (Obligation.evidence ~returns_null:false p.p_annotations) (Ocaml_type.render env.ctx p.p_type) in
            Hashtbl.replace prop_slots (Obligation.property m) ();
            add slots { name = fresh (Ocaml_type.snake (Obligation.property m)); mutable_ = true; ty; notes = [ note m ] }
          end)
        orphans;
      List.iter
        (fun m ->
          if Jgraph.is_static m then add companion (static_slot m)
          else match Obligation.role m with
            | Obligation.Command_role | Obligation.Query_role -> add not_carried (note m)
            | _ -> ())
        members
  | Variant ->
      let self = self_type env jt in
      List.iter
        (fun m ->
          if Jgraph.is_static m then add companion (static_slot m)
          else
            let name = fresh_companion ~arity:(List.length m.m_params) (snake_name m) in
            let ty =
              match m.m_kind with
              | Field | Component -> self ^ " -> " ^ value_type m
              | _ -> String.concat " -> " ((self :: param_types env m) @ [ return_type env m ])
            in
            add companion { name; mutable_ = false; ty; notes = [ note m ] })
        members
  | Closures | Object | Module_type ->
      let self = match enc with Module_type -> Some (Ocaml_type.apply (List.map (fun tp -> Ocaml_type.tvar tp.tp_name) jt.type_params) "t") | _ -> None in
      let fn params ret =
        match (enc, self) with
        | Module_type, Some s -> String.concat " -> " ((s :: params) @ [ ret ])
        | Object, _ when params = [] && ret <> "unit" -> ret
        | _ -> arrow params ret
      in
      List.iter
        (fun m ->
          if Jgraph.is_static m then (if enc = Module_type then add slots (static_slot ~fresh m) else add companion (static_slot m))
          else
            let name = fresh ~arity:(List.length m.m_params) (snake_name m) in
            match (m.m_kind, Obligation.role m) with
            | (Field | Component), _ ->
                let mutable_ = m.m_kind = Field && not (Jgraph.is_final m) in
                if enc = Closures then add slots { name; mutable_; ty = value_type m; notes = [ note m ] }
                else begin
                  add slots { name; mutable_ = false; ty = fn [] (value_type m); notes = [ note m ] };
                  if mutable_ then
                    add slots { name = fresh ("set_" ^ name); mutable_ = false; ty = fn [ value_type m ] "unit"; notes = [ "setter for field " ^ m.m_name ] }
                end
            | Method, role ->
                let params = if role = Obligation.Data then [] else param_types env m in
                let ty = fn params (return_type env m) in
                (* A record field or method needs explicit polymorphism; a val does not. *)
                let ty = if enc = Module_type then ty else poly m ty in
                add slots { name; mutable_ = false; ty; notes = [ note m ] }
            | Constructor, _ -> ())
        members
  | Abstract -> ());
  { slots = List.rev !slots; not_carried = List.rev !not_carried; companion = List.rev !companion }

let slot_line ?(prefix = "") ~sep s =
  Printf.sprintf "  %s%s%s : %s%s  (* %s *)" prefix (if s.mutable_ then "mutable " else "") s.name s.ty sep
    (comment_safe (String.concat "; " s.notes))

let type_notes env (jt : jtype) enc =
  let obls = Option.value (Hashtbl.find_opt env.by_type jt.id) ~default:[] in
  let head = Printf.sprintf "%s: %s, %s:%d" jt.id (label enc) jt.file jt.line in
  comment_safe (if obls = [] then head else head ^ "\n   " ^ verdict_notes env obls)

(* [constraint 'p = < methods of B; .. >] for every Bounded parameter whose bound is
   an Object. B's own type parameters take the bound's arguments (Dynamic if raw). *)
let constraints env (jt : jtype) =
  List.concat_map
    (fun tp ->
      List.filter_map
        (fun b ->
          match (Rules.bound_target b, b) with
          | Rules.Bound_node id, Class c when env.ctx.enc.(Model.node env.m id) = Object ->
              let bt = Model.jtype env.m id in
              let args = List.map (Ocaml_type.render env.ctx) c.args in
              let subst =
                List.mapi (fun i p -> (p.tp_name, Option.value (List.nth_opt args i) ~default:"java_object")) bt.type_params
              in
              let l = layout { env with ctx = { env.ctx with subst } } bt Object in
              let methods = List.map (fun s -> s.name ^ " : " ^ s.ty ^ ";\n  ") l.slots in
              Some
                (Printf.sprintf "constraint %s = <\n  %s.. >  (* the methods of %s *)" (Ocaml_type.tvar tp.tp_name)
                   (String.concat "" methods) id)
          | _ -> None)
        tp.tp_bounds)
    jt.type_params

let definition env (jt : jtype) enc =
  let l = layout env jt enc in
  let b = Buffer.create 512 in
  let params = self_type env jt in
  (match enc with
  | Variant ->
      Printf.bprintf b "%s =" params;
      if jt.constants = [] then Buffer.add_string b " |";
      List.iter (fun c -> Printf.bprintf b "\n  | %s" (String.capitalize_ascii c.c_name)) jt.constants
  | Record | Closures ->
      if l.slots = [] && l.not_carried = [] then Printf.bprintf b "%s = unit  (* no instance data *)" params
      else if l.slots = [] then begin
        Printf.bprintf b "%s = unit" params;
        List.iter (fun n -> Printf.bprintf b "\n  (* not carried: %s *)" (comment_safe n)) l.not_carried
      end
      else begin
        Printf.bprintf b "%s = {\n" params;
        List.iter (fun s -> Buffer.add_string b (slot_line ~sep:";" s ^ "\n")) l.slots;
        List.iter (fun n -> Printf.bprintf b "  (* not carried: %s *)\n" (comment_safe n)) l.not_carried;
        Buffer.add_string b "}"
      end
  | Object ->
      Printf.bprintf b "%s = <\n" params;
      List.iter (fun s -> Buffer.add_string b (slot_line ~sep:";" s ^ "\n")) l.slots;
      Buffer.add_string b ">"
  | Module_type | Abstract -> assert false);
  List.iter (fun c -> Printf.bprintf b "\n%s" c) (constraints env jt);
  (Buffer.contents b, l)

let module_type env (jt : jtype) =
  let l = layout env jt Module_type in
  let b = Buffer.create 512 in
  let tparams = List.map (fun tp -> Ocaml_type.tvar tp.tp_name) jt.type_params in
  Printf.bprintf b "module type %s = sig\n  type %s\n" (Ocaml_type.module_type_name env.ctx.names jt.id)
    (Ocaml_type.apply tparams "t");
  List.iter (fun s -> Buffer.add_string b (slot_line ~prefix:"val " ~sep:"" s ^ "\n")) l.slots;
  Buffer.add_string b "end";
  Buffer.contents b

let collection_definition names (kind, el) name =
  let functor_ = match kind with Ocaml_type.Set_of -> "Set.Make" | Ocaml_type.Map_of -> "Map.Make" in
  match el with
  | Ocaml_type.Scalar_module md -> Printf.sprintf "module %s = %s (%s)" name functor_ md
  | Ocaml_type.Slice_element id ->
      Printf.sprintf "module %s = %s (struct type t = %s let compare = compare end)" name functor_
        (Ocaml_type.type_name names id)

let emit ~source_name (m : Model.t) (enc : Model.assignment) (cert : Certificate.t) : string =
  let ctx = Ocaml_type.context m enc in
  let entries = Hashtbl.create 1024 in
  List.iter (fun (e : Certificate.entry) -> Hashtbl.replace entries e.obligation e) cert.entries;
  let by_member = Hashtbl.create 256 and by_type = Hashtbl.create 64 in
  Array.iter
    (fun (o : Obligation.t) ->
      match o.member with
      | Some r ->
          let k = (o.owner, r.key) in
          Hashtbl.replace by_member k (Option.value (Hashtbl.find_opt by_member k) ~default:[] @ [ o ])
      | None -> Hashtbl.replace by_type o.owner (Option.value (Hashtbl.find_opt by_type o.owner) ~default:[] @ [ o ]))
    m.obligations;
  let env = { ctx; m; entries; by_member; by_type } in
  let ncomp = Array.length m.components in
  let emitted_inside = Hashtbl.create 8 in
  (* Referents first: the reverse of the search order. *)
  let order = List.init ncomp (fun i -> ncomp - 1 - i) in
  let rendered =
    List.map
      (fun k ->
        let comp = Array.to_list m.components.(k) in
        let before = Hashtbl.copy ctx.used in
        let text, companions =
          match comp with
          | [ v ] when enc.(v) = Module_type ->
              let jt = m.nodes.(v) in
              (Printf.sprintf "(* %s *)\n%s" (type_notes env jt Module_type) (module_type env jt), [])
          | _ ->
              let defs = List.map (fun v -> (m.nodes.(v), enc.(v), definition env m.nodes.(v) enc.(v))) comp in
              let text =
                String.concat "\n\n"
                  (List.mapi
                     (fun i (jt, e, (def, _)) ->
                       Printf.sprintf "(* %s *)\n%s %s" (type_notes env jt e) (if i = 0 then "type" else "and") def)
                     defs)
              in
              (text, List.filter_map (fun (jt, _, (_, l)) -> if l.companion = [] then None else Some (jt, l.companion)) defs)
        in
        (* A Set/Map over a type of this component, used inside it, is defined
           together with the group as a recursive module. *)
        let inner =
          Hashtbl.fold
            (fun name v acc ->
              match snd v with
              | Ocaml_type.Slice_element id when (not (Hashtbl.mem before name)) && List.mem (Model.node m id) comp ->
                  (name, v) :: acc
              | _ -> acc)
            ctx.used []
          |> List.sort compare
        in
        let text =
          if inner = [] then text
          else begin
            let group = String.capitalize_ascii (Ocaml_type.type_name ctx.names m.nodes.(List.hd comp).id) ^ "_types" in
            let indented = String.concat "\n" (List.map (fun l -> if l = "" then l else "  " ^ l) (String.split_on_char '\n' text)) in
            let modules =
              List.map
                (fun (name, (kind, el)) ->
                  let elt = match el with Ocaml_type.Slice_element id -> group ^ "." ^ Ocaml_type.type_name ctx.names id | Ocaml_type.Scalar_module md -> md ^ ".t" in
                  let sig_, functor_ =
                    match kind with
                    | Ocaml_type.Set_of -> ("Set.S with type elt = " ^ elt, "Set.Make")
                    | Ocaml_type.Map_of -> ("Map.S with type key = " ^ elt, "Map.Make")
                  in
                  Printf.sprintf "and %s : %s = %s (struct type t = %s let compare = compare end)" name sig_ functor_ elt)
                inner
            in
            List.iter (fun (name, _) -> Hashtbl.replace emitted_inside name ()) inner;
            Printf.sprintf
              "(* Set/Map modules over types of this group are defined with it, as recursive modules. *)\nmodule rec %s : sig\n%s\nend = %s\n%s\n\ninclude %s"
              group indented group (String.concat "\n" modules) group
          end
        in
        (k, text, companions))
      order
  in
  let b = Buffer.create 65536 in
  Printf.bprintf b
    "(* Generated by bin/prove from %s (%s, commit %s,\n   %s).\n   Do not edit: examples/proof/dune regenerates this file and fails when it is stale.\n\n   One definition per Java type, referents first, with its encoding. Each member\n   carries the verdicts of its obligations from certificate.json. Static members\n   and the instance members of enums are declared in the *_ops module types at\n   the end. *)\n\n"
    source_name Jgraph.schema m.graph.commit cert.graph_digest;
  Buffer.add_string b "[@@@warning \"-30\"]\n\n";
  Buffer.add_string b "(* Dynamic: java.lang.Object, raw types and unbounded wildcards; Class<...>. *)\n";
  Buffer.add_string b "type java_object\ntype java_class\n\n";
  if m.externals <> [] then begin
    Buffer.add_string b "(* External types, outside the slice: Abstract. *)\n";
    List.iter
      (fun (q, ar) ->
        let params = List.init ar (fun i -> Printf.sprintf "'a%d" (i + 1)) in
        Printf.bprintf b "type %s  (* %s *)\n" (Ocaml_type.apply params (Ocaml_type.external_name ctx.names q)) q)
      m.externals;
    Buffer.add_char b '\n'
  end;
  let used = Hashtbl.fold (fun name v acc -> (name, v) :: acc) ctx.used [] |> List.sort compare in
  let scalar_modules = List.filter (fun (_, (_, el)) -> match el with Ocaml_type.Scalar_module _ -> true | _ -> false) used in
  List.iter (fun (name, v) -> Printf.bprintf b "%s\n" (collection_definition ctx.names v name)) scalar_modules;
  if scalar_modules <> [] then Buffer.add_char b '\n';
  List.iter
    (fun (k, text, _) ->
      Printf.bprintf b "(* ---- component %d of %d in search order%s ---- *)\n\n%s\n\n" (k + 1) ncomp
        (if m.cyclic.(k) then ", cyclic" else "") text;
      List.iter
        (fun (name, ((_, el) as v)) ->
          match el with
          | Ocaml_type.Slice_element id when m.component_of.(Model.node m id) = k && not (Hashtbl.mem emitted_inside name) ->
              Printf.bprintf b "%s\n\n" (collection_definition ctx.names v name)
          | _ -> ())
        used)
    rendered;
  let companions = List.concat_map (fun (_, _, c) -> c) rendered |> List.sort (fun (a, _) (b, _) -> compare a.id b.id) in
  if companions <> [] then begin
    Buffer.add_string b "(* ---- static members and enum members ---- *)\n\n";
    List.iter
      (fun (jt, slots) ->
        Printf.bprintf b "module type %s_ops = sig\n" (String.capitalize_ascii (Ocaml_type.type_name ctx.names jt.id));
        List.iter (fun s -> Buffer.add_string b (slot_line ~prefix:"val " ~sep:"" s ^ "\n")) slots;
        Buffer.add_string b "end\n\n")
      companions
  end;
  let s = Buffer.contents b in
  String.sub s 0 (String.length s - 1)
