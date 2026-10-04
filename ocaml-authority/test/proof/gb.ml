(* Builders for small Java graphs, written the way the extractor would emit them. *)

open Proof.Jgraph

let cls ?(resolution = Jdk) name args = Class { written = simple_name name; resolution; name; basis = "test"; args }
let string_ = cls "java.lang.String" []
let object_ = cls "java.lang.Object" []
let boxed_long = cls "java.lang.Long" []
let class_of t = cls "java.lang.Class" [ t ]
let list_ e = cls "java.util.List" [ e ]
let raw_list = cls "java.util.List" []
let set_ e = cls "java.util.Set" [ e ]
let map_ k v = cls "java.util.Map" [ k; v ]
let slice ?(args = []) id = cls ~resolution:Slice id args
let ext ?(args = []) q = cls ~resolution:External q args
let prim p = Primitive p
let var v = Type_var v

let ann name = { ann_name = name; ann_qualified = None; ann_arguments = []; ann_line = 1 }

let param ?(annotations = []) name ty = { p_name = name; p_type = ty; p_varargs = false; p_annotations = annotations }

let meth ?(mods = [ "public"; "abstract" ]) ?(params = []) ?(returns_null = false) ?(annotations = []) ?(throws = [])
    ?(type_params = []) name ret =
  {
    m_kind = Method;
    m_name = name;
    m_line = 1;
    m_modifiers = mods;
    m_annotations = annotations;
    m_type_params = type_params;
    m_type = Some ret;
    m_params = params;
    m_throws = throws;
    m_has_body = returns_null || List.mem "default" mods || List.mem "static" mods;
    m_returns_null = returns_null;
  }

let field ?(mods = [ "protected" ]) name ty =
  { (meth ~mods name ty) with m_kind = Field; m_has_body = false }

let component name ty = { (field ~mods:[ "final" ] name ty) with m_kind = Component }
let getter name ty = meth name ty
let setter name ty = meth name Void ~params:[ param "v" ty ]
let command ?(params = []) name = meth name Void ~params
let query ?(params = []) name ret = meth name ret ~params
let static m = { m with m_modifiers = [ "public"; "static" ]; m_has_body = true }

let jtype ?(kind = Interface) ?(type_params = []) ?(extends = []) ?(implements = []) ?(constants = []) id members =
  {
    id;
    qualified_name = "test." ^ id;
    kind;
    file = "test/" ^ id ^ ".java";
    line = 1;
    enclosing = None;
    modifiers = [ "public" ];
    annotations = [];
    type_params = List.map (fun (n, bounds) -> { tp_name = n; tp_bounds = bounds }) type_params;
    extends;
    implements;
    constants = List.map (fun c -> { c_name = c; c_line = 1; c_annotations = [] }) constants;
    members;
  }

let enum_ id constants members = jtype ~kind:Enum ~constants id members
let record_ id components = jtype ~kind:Record_decl id components
let class_ id members = jtype ~kind:Class_decl id members

let graph types =
  let g =
    { commit = "test"; extractor = "test"; resolution_mode = "test"; files = [];
      types = List.sort (fun a b -> compare a.id b.id) types }
  in
  match validate g with Ok () -> g | Error e -> failwith ("Gb.graph: " ^ e)

(* Run the search and index the result by obligation id. *)
type run = {
  model : Proof.Model.t;
  outcome : Proof.Search.outcome;
  cert : Proof.Certificate.t;
  verdict : string -> Proof.Encoding.verdict;
  entry : string -> Proof.Certificate.entry;
  encoding : string -> Proof.Encoding.t;
}

let run g =
  let model = Proof.Model.build g in
  let outcome = Proof.Search.run model in
  let stats : Proof.Certificate.search_stats =
    { components = Array.length model.components; cyclic_components = Proof.Model.cyclic_count model;
      largest_component = Proof.Model.largest_component model; states_explored = outcome.stats.states_explored;
      memo_hits = outcome.stats.memo_hits; branches_pruned = outcome.stats.branches_pruned;
      infeasible_rejected = outcome.stats.infeasible }
  in
  let cert = Proof.Certificate.make model ~digest:"test" outcome.assignment outcome.verdicts outcome.cost stats in
  let entry id =
    match List.find_opt (fun (e : Proof.Certificate.entry) -> e.obligation = id) cert.entries with
    | Some e -> e
    | None ->
        failwith
          ("no obligation " ^ id ^ "; have: "
          ^ String.concat ", " (List.map (fun (e : Proof.Certificate.entry) -> e.obligation) cert.entries))
  in
  { model; outcome; cert; verdict = (fun id -> (entry id).verdict); entry;
    encoding = (fun id -> outcome.assignment.(Proof.Model.node model id)) }

let show_verdict = Proof.Encoding.verdict_to_string
let show_encoding = Proof.Encoding.label
let show_opt = function None -> "none" | Some s -> s
