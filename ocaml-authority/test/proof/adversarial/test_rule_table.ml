(* Attack 4: the rule table of docs/proof-search.md ("Verdict rules", lines
   119-131, and "Obligations", lines 86-100) against the implementation.

   - rule_*: the implementation contradicted the table and was fixed; the test
     asserts the table.
   - doc_deviation_*: the implementation departs from the table as written, in
     a way the doc's own "Implementation notes" (lines 365-390) describe or that
     the table does not cover. Pinned, not changed. *)

open Adv
open Proof
open Proof.Encoding

let real_graph = "../../../examples/proof/keycloak-authz.graph.json"
let real_cert = "../../../examples/proof/certificate.json"

let entry (c : Certificate.t) id = List.find_opt (fun (e : Certificate.entry) -> e.obligation = id) c.entries
let verdict c id = Option.map (fun (e : Certificate.entry) -> e.verdict) (entry c id)
let ocaml c id = Option.bind (entry c id) (fun (e : Certificate.entry) -> e.ocaml)

(* Doc line 125: Unique / Keyed are PROVEN only for an element or key that is String, a primitive or an
   enum (Set.Make / Map.Make). Record elements are UNKNOWN, non-comparable ones REFUTED. *)
let table_admits_proven (m : Model.t) (enc : string -> Encoding.t) (o : Obligation.t) =
  let t = match o.subject with Obligation.Element e -> Some e | Obligation.Key_value (k, _) -> Some k | _ -> None in
  match t with
  | Some (Jgraph.Primitive _) -> true
  | Some (Jgraph.Class { resolution = Jdk; name; args = []; _ }) -> List.mem (Jgraph.simple_name name) Obligation.scalar_jdk
  | Some (Jgraph.Class { resolution = Slice; name; args = []; _ }) -> m.arity name = 0 && enc name = Variant
  | _ -> false

let unique_keyed_invariant name (m : Model.t) (c : Certificate.t) =
  let enc id = List.assoc id c.encodings in
  let bad =
    Array.to_list m.obligations
    |> List.filter (fun (o : Obligation.t) ->
           (o.kind = Obligation.Unique || o.kind = Obligation.Keyed)
           && (match verdict c o.id with Some (Proven | Strengthened) -> true | _ -> false)
           && not (table_admits_proven m enc o))
  in
  List.iter (fun (o : Obligation.t) -> report "  PROVEN outside doc line 125: %s (%s)" o.id (Obligation.describe o)) bad;
  check (name ^ ": every PROVEN Unique/Keyed has a String, primitive or enum element (doc line 125)") (bad = [])

let () =
  let g, digest = match Jgraph.of_string (read_file real_graph) with Ok x -> x | Error e -> failwith e in
  let real = match Certificate.of_string (read_file real_cert) with Ok c -> c | Error e -> failwith e in
  let real_model = Model.build g in
  ignore digest;
  let r = prove (extract ~name:"rules" (java_files "fixtures/emit")) in
  let emitted = emit_source r in

  (* rule_unique_compound_element: doc line 125 vs evaluate.ml comparable_verdict, which gave PROVEN to any
     element whose leaves are all scalar, while ocaml_type.ml carried such a Set as a plain list. *)
  report "rule_unique_compound_element (doc line 125)";
  dump r "Compound";
  unique_keyed_invariant "committed certificate" real_model real;
  unique_keyed_invariant "fixtures/emit" r.model r.cert;
  expect r "Set<List<String>>" "Unique:Compound.getLists()@return" Unknown;
  expect r "Set<String[]> (Java: identity equals)" "Unique:Compound.getArrays()@return" Unknown;
  expect r "Map<Set<String>, String>" "Keyed:Compound.getBySet()@return" Unknown;
  expect r "Set<? extends Level>, carried as a list" "Unique:Compound.getLevels()@return" Unknown;
  expect r "Set<Level>" "Unique:Compound.getPlainLevels()@return" Proven;
  check_eq "Set<Level> is a Set.Make" show_opt (Some "Level_set.t") (ocaml_of r "Represent:Compound.getPlainLevels()@return");

  (* rule_represent_super_wildcard: doc line 121 (Represent) and line 131 (Dynamic). A List<? super Integer>
     may hold any supertype of Integer; it was carried as 'int list', PROVEN. *)
  report "rule_represent_super_wildcard (doc lines 121, 131)";
  dump r ~member:"getSink()" "Compound";
  check "List<? super Integer> is not an int list" (ocaml_of r "Represent:Compound.getSink()@return" <> Some "int list");
  expect r "? super is dynamic" "Dynamic:Compound.getSink()@return" Unknown;

  (* rule_checked_record_getter: doc line 128, Checked is PROVEN by an (_, exn) result return type. A getter
     that throws, in a Record, was emitted as a plain field. *)
  report "rule_checked_record_getter (doc line 128)";
  dump r "Loader";
  report "  Loader: %s" (label (r.encoding "Loader"));
  expect r "Checked" "Checked:Loader.getBody()@throws IOException" Proven;
  check "the Record field of a throwing getter is an (_, exn) result" (contains emitted "body : (string option, exn) result");

  (* rule_setter_type_mismatch: doc line 111 (Record carries data members; setters as mutable fields) and
     line 127 (Mutable). setName(Integer) next to String getName() made the String field mutable, and the
     Integer the setter takes was carried nowhere, while Represent@param:name was PROVEN as int. *)
  report "rule_setter_type_mismatch (doc lines 111, 121, 127)";
  dump r "Named";
  report "  Named: %s" (label (r.encoding "Named"));
  expect r "setter value" "Represent:Named.setName(Integer)@param:name" Proven;
  check "a Record carries the setter's Integer" (r.encoding "Named" <> Record || contains emitted ": int option;");

  (* doc_deviation_query_nullary: doc line 95, Query arises from a "non-void method with parameters";
     obligation.ml gives a Query to every non-void non-getter (implementation note, doc lines 371-373). *)
  report "doc_deviation_query_nullary (doc line 95; implementation note lines 371-373)";
  let nullary =
    List.filter
      (fun (e : Certificate.entry) ->
        e.kind = "Query" && match e.member with Some k -> String.length k > 2 && String.sub k (String.length k - 2) 2 = "()" | None -> false)
      real.entries
  in
  List.iter (fun (e : Certificate.entry) -> report "  %s %s" (verdict_to_string e.verdict) e.obligation) nullary;
  check_eq "doc_deviation_query_nullary: nullary Query obligations on the real slice" string_of_int 5 (List.length nullary);

  (* doc_deviation_represent_dynamic_proven: doc line 121 has no Represent row for Object, raw types,
     Class<...> or '?'; line 131 says Dynamic is UNKNOWN. Represent is PROVEN (java_object / java_class),
     and Dynamic carries the UNKNOWN once (implementation note, lines 383-385). *)
  report "doc_deviation_represent_dynamic_proven (doc lines 121, 131; note lines 383-385)";
  let dyn =
    List.filter
      (fun (e : Certificate.entry) ->
        e.kind = "Represent" && e.verdict = Proven
        && match e.ocaml with Some t -> contains t "java_object" || contains t "java_class" | None -> false)
      real.entries
  in
  List.iter (fun (e : Certificate.entry) -> report "  PROVEN %s : %s" e.obligation (show_opt e.ocaml)) dyn;
  check_eq "doc_deviation_represent_dynamic_proven: count on the real slice" string_of_int 11 (List.length dyn);

  (* doc_deviation_bounded_object_bound: doc line 129, "Bound B encoded Object -> PROVEN. Otherwise REFUTED".
     rules.ml bound_target makes a java.lang.Object bound PROVEN (vacuous). *)
  report "doc_deviation_bounded_object_bound (doc line 129)";
  dump r "Boxed";
  expect r "T extends Object" "Bounded:Boxed@<T extends Object>" Proven;
  expect r "L extends Level (an enum, Variant)" "Bounded:Boxed@<L extends Level>" Refuted;

  (* doc_deviation_unique_unknown_leaves: doc line 125 has no row for a type-variable, external or dynamic
     element; the implementation gives UNKNOWN (evaluate.ml, rules.ml leaf_verdict). *)
  report "doc_deviation_unique_unknown_leaves (doc line 125)";
  expect r "Set<T>" "Unique:Boxed.getAll()@return" Unknown;

  (* doc_deviation_represent_arrays_and_boxed: doc line 121 lists primitives, String, List/Collection, slice and
     external types. Arrays ('string array') and boxed scalars (Integer -> int) are PROVEN as well. *)
  report "doc_deviation_represent_arrays_and_boxed (doc line 121)";
  check_eq "String[] getAudience()" show_opt (Some "string array") (ocaml real "Represent:JsonWebToken.getAudience()@return");
  check "String[] getAudience() PROVEN" (verdict real "Represent:JsonWebToken.getAudience()@return" = Some Proven);
  check_eq "Integer valueOfInteger(Integer)" show_opt (Some "int")
    (ocaml real "Represent:DecisionStrategy.valueOfInteger(Integer)@param:id");

  (* doc_deviation_static_and_variant_behaviour: doc line 126 lists Closures/Object/Module_type -> PROVEN and
     Record -> REFUTED. A static method is PROVEN whatever the owner (note lines 374-375), including on a
     Variant owner, which the table does not list. *)
  report "doc_deviation_static_and_variant_behaviour (doc line 126; note lines 374-378)";
  List.iter
    (fun id -> report "  %s %s" (show_verdict (verdict real id)) id)
    [ "Query:DecisionStrategy.valueOfInteger(Integer)"; "Query:AuthZen.SubjectType.fromValue(String)"; "Query:Attributes.from(Map)" ];
  check "static Query on a Variant owner is PROVEN" (verdict real "Query:DecisionStrategy.valueOfInteger(Integer)" = Some Proven);

  (* The search's floor for compound elements (search.ml) must agree with the checker's global evaluation:
     the DP's cost equals exhaustive enumeration on these fixtures. *)
  let _, bf_cost, scored = Baselines.brute_force r.model in
  report "fixtures/emit: DP %s, brute force %s over %d assignments" (cost_to_string r.cert.cost) (cost_to_string bf_cost) scored;
  check "fixtures/emit: DP cost = brute-force optimum" (compare_cost r.cert.cost bf_cost = 0);
  (* The fixture certificate must still pass the checker. *)
  (match Certificate.check r.graph ~digest:r.digest r.cert with
  | Ok _ -> check "checker accepts the fixtures/emit certificate" true
  | Error errs -> check ("checker accepts the fixtures/emit certificate: " ^ String.concat "; " errs) false);
  finish "test_rule_table"
