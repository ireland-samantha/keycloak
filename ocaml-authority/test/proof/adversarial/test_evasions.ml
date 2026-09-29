(* Attack 2: extractor evasions. Every fixture under fixtures/evasions is legal
   Java (javac accepts it together with fixtures/support). The real extractor
   must not resolve a reference to the wrong slice type, drop a member, or crash.

   Resolution is parse-only by design (tools/java-graph/JavaGraph.java, header):
   static imports and inherited member types are documented as unseen. Where
   that makes a reference resolve to the wrong slice type, the case is pinned
   as known_weakness_* and stays open. *)

open Adv
open Proof
open Proof.Encoding

let support = java_files "fixtures/support"
let slice_files = java_files "fixtures/evasions"

(* The type reference of a member's return (or field) type, or of one parameter. *)
let member (g : Jgraph.t) owner name =
  match Jgraph.find_type g owner with
  | None -> None
  | Some t -> List.find_opt (fun (m : Jgraph.member) -> m.m_name = name) t.members

let return_type g owner name = Option.bind (member g owner name) (fun m -> m.m_type)
let set_element = function Some (Jgraph.Class { args = [ e ]; _ }) -> Some e | _ -> None

let show_ref = function
  | None -> "none"
  | Some (Jgraph.Class c) ->
      Printf.sprintf "%s %s (%s)" (match c.resolution with Slice -> "slice" | Jdk -> "jdk" | External -> "external") c.name c.basis
  | Some t -> Jgraph.render t

let is_slice name = function Some (Jgraph.Class { resolution = Slice; name = n; _ }) -> n = name | _ -> false
let is_external name = function Some (Jgraph.Class { resolution = External; name = n; _ }) -> n = name | _ -> false
let is_var name = function Some (Jgraph.Type_var v) -> v = name | _ -> false

(* Member names per class, as javap reads them from the compiled class files: non-private fields and
   methods, without constructors, synthetic names, and the enum methods javac generates. *)
let javap_members ~classes (names : string list) =
  let log = "evasions.javap" in
  ignore (run_quiet (Printf.sprintf "javap -cp %s %s" classes (String.concat " " (List.map Filename.quote names))) log);
  let tbl = Hashtbl.create 32 in
  let current = ref None in
  List.iter
    (fun line ->
      let t = String.trim line in
      if line <> "" && line.[0] <> ' ' && String.length t > 0 && t.[String.length t - 1] = '{' then begin
        (* "public class adv.evasions.Registry<Mode> {" *)
        let words = String.split_on_char ' ' t in
        let rec after = function
          | ("class" | "interface" | "enum" | "record") :: n :: _ -> Some n
          | _ :: rest -> after rest
          | [] -> None
        in
        current :=
          Option.map (fun n -> match String.index_opt n '<' with Some i -> String.sub n 0 i | None -> n) (after words);
        Option.iter (fun c -> if not (Hashtbl.mem tbl c) then Hashtbl.replace tbl c []) !current
      end
      else
        match !current with
        | Some c when String.length t > 1 && t.[String.length t - 1] = ';' ->
            let head = match String.index_opt t '(' with Some i -> String.sub t 0 i | None -> String.sub t 0 (String.length t - 1) in
            let name = List.nth (String.split_on_char ' ' head) (List.length (String.split_on_char ' ' head) - 1) in
            if not (String.contains name '.' || String.contains name '$' || String.contains name '{') then
              Hashtbl.replace tbl c (name :: Hashtbl.find tbl c)
        | _ -> ())
    (String.split_on_char '\n' (read_file log));
  tbl

let () =
  check "fixtures are legal Java (javac)" (javac_accepts ~name:"evasions" (support @ slice_files));
  let g, digest = extract ~name:"evasions" slice_files in
  (* No member dropped: the extractor's non-private members (and enum constants) of every fixture type are
     the members javap reads from the class files javac produced. *)
  let binary (t : Jgraph.jtype) =
    let pkg = String.sub t.qualified_name 0 (String.length t.qualified_name - String.length t.id - 1) in
    pkg ^ "." ^ String.map (fun c -> if c = '.' then '$' else c) t.id
  in
  let from_javap = javap_members ~classes:"evasions-javac" (List.map binary g.types) in
  List.iter
    (fun (t : Jgraph.jtype) ->
      let generated = match t.kind with Jgraph.Enum -> [ "values"; "valueOf" ] | _ -> [] in
      let javap =
        Option.value (Hashtbl.find_opt from_javap (binary t)) ~default:[]
        |> List.filter (fun n -> not (List.mem n generated))
        |> List.sort compare
      in
      let extracted =
        List.filter_map (fun (m : Jgraph.member) -> if Obligation.projected m then Some m.m_name else None) t.members
        @ List.map (fun (c : Jgraph.constant) -> c.c_name) t.constants
        |> List.sort compare
      in
      if javap <> extracted then
        report "  %s: javap [%s], extractor [%s]" t.id (String.concat ", " javap) (String.concat ", " extracted);
      check ("2 no member dropped (javap): " ^ t.id) (javap = extracted))
    g.types;
  let r =
    try Some (prove (g, digest))
    with Invalid_argument e ->
      check ("attempt_proof runs on legal overloads (Overloads.java): " ^ e) false;
      None
  in
  let with_run f = match r with Some r -> f r | None -> check "attempt_proof ran" false in

  (* 2a: a type parameter shadowing a slice type name. *)
  report "2a type parameters named Mode and Scope";
  let own = set_element (return_type g "Registry" "own") in
  let view = set_element (return_type g "Registry.View" "modes") in
  report "  Registry.own() element: %s" (show_ref own);
  report "  Registry.View.modes() element: %s" (show_ref view);
  report "  Registry.pick(...) return: %s" (show_ref (return_type g "Registry" "pick"));
  check "2a class type parameter" (is_var "Mode" own);
  check "2a method type parameter" (is_var "Scope" (return_type g "Registry" "pick"));
  check "2a inner class sees the enclosing class's type parameter (not the slice enum Mode)" (is_var "Mode" view);
  with_run (fun r ->
      expect r "2a" "Unique:Registry.own()@return" Unknown;
      expect r "2a" "Unique:Registry.View.modes()@return" Unknown;
      expect r "2a" "Unique:Registry.pick(Set)@param:from" Unknown);

  (* 2b: two nested types with the same simple name in different outers. *)
  report "2b Left.Entry and Right.Entry";
  report "  Left.first(): %s" (show_ref (return_type g "Left" "first"));
  report "  Right.mine() element: %s" (show_ref (set_element (return_type g "Right" "mine")));
  report "  Right.theirs() element: %s" (show_ref (set_element (return_type g "Right" "theirs")));
  check "2b Left.first -> Left.Entry" (is_slice "Left.Entry" (return_type g "Left" "first"));
  check "2b Right.mine -> Right.Entry" (is_slice "Right.Entry" (set_element (return_type g "Right" "mine")));
  check "2b Right.theirs -> Left.Entry" (is_slice "Left.Entry" (set_element (return_type g "Right" "theirs")));
  with_run (fun r ->
      report "  encodings: Left.Entry %s, Right.Entry %s" (label (r.encoding "Left.Entry")) (label (r.encoding "Right.Entry"));
      expect r "2b data-only Entry" "Unique:Right.theirs()@return" Unknown;
      dump r "Right.Entry";
      dump r ~member:"mine()" "Right");

  (* 2c: a fully-qualified external type with the simple name of a slice type. *)
  report "2c org.example.ext.Policy next to the slice's Policy";
  List.iter
    (fun (o, n) -> report "  %s.%s(): %s" o n (show_ref (return_type g o n)))
    [ ("Holder", "external"); ("Holder", "internal"); ("Holder", "qualified"); ("ImportsExternal", "imported") ];
  check "2c FQN external" (is_external "org.example.ext.Policy" (return_type g "Holder" "external"));
  check "2c simple name -> slice" (is_slice "Policy" (return_type g "Holder" "internal"));
  check "2c FQN slice -> slice" (is_slice "Policy" (return_type g "Holder" "qualified"));
  check "2c FQN external in Set" (is_external "org.example.ext.Policy" (set_element (return_type g "Holder" "externals")));
  check "2c single-type import shadows the same-package slice type"
    (is_external "org.example.ext.Policy" (return_type g "ImportsExternal" "imported"));
  with_run (fun r ->
      expect r "2c" "Represent:Holder.external()@return" Unknown;
      expect r "2c" "Represent:Holder.internal()@return" Proven);

  (* 2d: a static import of a nested type named like a top-level slice type. *)
  report "2d import static adv.evasions.Outer.Mode";
  let static_elem = set_element (return_type g "UsesStaticImport" "getModes") in
  report "  UsesStaticImport.getModes() element: %s (javac: Outer.Mode, an interface with a command)" (show_ref static_elem);
  with_run (fun r ->
      report "  encodings: Mode %s, Outer.Mode %s" (label (r.encoding "Mode")) (label (r.encoding "Outer.Mode"));
      expect r "2d" "Unique:UsesStaticImport.getModes()@return" Proven;
      known_weakness "known_weakness_static_import_resolves_wrong_slice_type"
        ~detail:
          "Set<Mode> under 'import static Outer.Mode' resolves to the top-level enum Mode, so Unique is PROVEN; javac resolves Outer.Mode, whose encoding is not comparable"
        (is_slice "Mode" static_elem
        && r.verdict "Unique:UsesStaticImport.getModes()@return" = Some Proven
        && comparability (r.encoding "Outer.Mode") = Not_comparable));

  (* 2e: a wildcard import of the slice package from another package. *)
  report "2e import adv.evasions.* from adv.consumer";
  let wild = set_element (return_type g "UsesWildcard" "getModes") in
  report "  UsesWildcard.getModes() element: %s (javac: adv.evasions.Mode)" (show_ref wild);
  with_run (fun r ->
      expect r "2e" "Unique:UsesWildcard.getModes()@return" Unknown;
      known_weakness "known_weakness_wildcard_import_hides_slice_type"
        ~detail:
          "a slice type reached through 'import adv.evasions.*' becomes external '*.Mode' (basis unknown): UNKNOWN instead of PROVEN; conservative, never a wrong slice type"
        (is_external "*.Mode" wild && r.verdict "Represent:UsesWildcard.getScope()@return" = Some Unknown));
  (* 2e': that external used to be named plain "Mode", the slice id of the enum. A certificate lists slice ids
     and external names in one list, so the checker rejected attempt_proof's own certificate. *)
  let text = read_file "evasions.graph.json" in
  let plain_mode =
    let needle = "\"name\": \"*.Mode\"" and by = "\"name\": \"Mode\"" in
    let b = Buffer.create (String.length text) in
    let n = String.length needle in
    let rec go i =
      if i >= String.length text then ()
      else if i + n <= String.length text && String.sub text i n = needle then (Buffer.add_string b by; go (i + n))
      else (Buffer.add_char b text.[i]; go (i + 1))
    in
    go 0;
    Buffer.contents b
  in
  check "2e' the extractor names it *.Mode" (contains text "\"name\": \"*.Mode\"");
  (match Jgraph.of_string plain_mode with
  | Ok _ -> check "2e' a graph whose external name equals a slice id is rejected" false
  | Error e -> check ("2e' a graph whose external name equals a slice id is rejected: " ^ e) (contains e "has the name of a slice type"));

  (* 2f: annotations named Nullable / Nonnull / NotNull from different packages. *)
  report "2f nullness annotations by simple name";
  with_run (fun r ->
      dump r "Annotated";
      check_eq "2f custom @Nonnull -> bare type" show_opt (Some "string") (ocaml_of r "Nullability:Annotated.customNonnull()@return");
      check_eq "2f validation @NotNull -> bare type" show_opt (Some "string")
        (ocaml_of r "Nullability:Annotated.validationNotNull()@return");
      check_eq "2f @Nullable wins over @Nonnull" show_opt (Some "string option") (ocaml_of r "Nullability:Annotated.both()@return");
      check_eq "2f a type-use annotation on a qualified type is dropped (safe: option)" show_opt (Some "string option")
        (ocaml_of r "Nullability:Annotated.typeUseNonnull()@return");
      known_weakness "known_weakness_nonnull_by_simple_name"
        ~detail:
          "any annotation whose simple name is Nonnull or NotNull makes the value a bare type (STRENGTHENED), including org.example.ext.Nonnull on nullAtRuntime(), which returns null"
        (r.verdict "Nullability:Annotated.nullAtRuntime()@return" = Some Strengthened
        && ocaml_of r "Nullability:Annotated.nullAtRuntime()@return" = Some "string"));

  (* 2g: default methods, null literals, lambdas, var. *)
  report "2g default methods returning null";
  List.iter
    (fun n ->
      let m = member g "Defaults" n in
      report "  Defaults.%s(): returns_null_literal=%b" n (match m with Some m -> m.m_returns_null | None -> false))
    [ "lazy"; "direct"; "castNull"; "switchNull"; "yieldNull"; "viaLambda"; "localVar" ];
  let returns_null n = match member g "Defaults" n with Some m -> m.m_returns_null | None -> false in
  check "2g a null inside a lambda is not the method's" (not (returns_null "lazy"));
  check "2g return null" (returns_null "direct");
  check "2g return (String) null is the null literal" (returns_null "castNull");
  check "2g a switch-expression arm '-> null' is the null literal" (returns_null "switchNull");
  check "2g 'yield null' is the null literal" (returns_null "yieldNull");
  check "2g var is inert" (not (returns_null "localVar"));
  with_run (fun r ->
      dump r ~member:"castNull()" "Defaults";
      check_eq "2g @Nonnull castNull() returns null: option" show_opt (Some "string option")
        (ocaml_of r "Nullability:Defaults.castNull()@return");
      check_eq "2g @Nonnull switchNull(int) returns null: option" show_opt (Some "string option")
        (ocaml_of r "Nullability:Defaults.switchNull(int)@return");
      check_eq "2g @Nonnull yieldNull(int) returns null: option" show_opt (Some "string option")
        (ocaml_of r "Nullability:Defaults.yieldNull(int)@return");
      expect r "2g Supplier is external" "Represent:Defaults.lazy()@return" Unknown;
      known_weakness "known_weakness_nonnull_default_returns_null_via_lambda"
        ~detail:"@Nonnull viaLambda() returns a lambda's null through Supplier.get(); the value is a bare string (STRENGTHENED)"
        (ocaml_of r "Nullability:Defaults.viaLambda()@return" = Some "string"));

  (* 2h: varargs. *)
  report "2h varargs";
  let varargs n p =
    match member g "Varargs" n with
    | Some m -> (
        match List.find_opt (fun (x : Jgraph.param) -> x.p_name = p) m.m_params with
        | Some x -> Some (x.p_varargs, Jgraph.render x.p_type)
        | None -> None)
    | None -> None
  in
  List.iter
    (fun (n, p) ->
      match varargs n p with
      | Some (va, t) -> report "  Varargs.%s %s: %s varargs=%b" n p t va
      | None -> report "  Varargs.%s %s: missing" n p)
    [ ("grant", "scopes"); ("mixed", "scopes"); ("listOf", "items"); ("commented", "plain") ];
  check "2h String... is an array, varargs" (varargs "grant" "scopes" = Some (true, "String[]"));
  check "2h Scope... is an array of the slice type" (varargs "mixed" "scopes" = Some (true, "Scope[]"));
  check "2h T... is an array of the type variable" (varargs "listOf" "items" = Some (true, "T[]"));
  check "2h '...' inside a comment is not varargs" (varargs "commented" "plain" = Some (false, "String"));
  with_run (fun r ->
      expect r "2h" "Represent:Varargs.grant(String[])@param:scopes" Proven;
      check_eq "2h String... carried as an array" show_opt (Some "string array")
        (ocaml_of r "Represent:Varargs.grant(String[])@param:scopes"));

  (* 2i: arrays of generics and C-style declarators. *)
  report "2i arrays of generics";
  with_run (fun r ->
      dump r "GenericArrays";
      check_eq "2i String names[]" show_opt (Some "string array") (ocaml_of r "Represent:GenericArrays.names@type");
      check_eq "2i String legacy()[]" show_opt (Some "string array") (ocaml_of r "Represent:GenericArrays.legacy()@return");
      check_eq "2i List<String>[]" show_opt (Some "string list array") (ocaml_of r "Represent:GenericArrays.buckets()@return");
      expect r "2i Map inside an array" "Keyed:GenericArrays.indexes()@return/[]" Proven;
      (* Scope's encoding is a trade-off with Overloads' <T extends Scope> bound, so only "not PROVEN" is fixed. *)
      report "  Scope: %s" (label (r.encoding "Scope"));
      check "2i Set<Scope> inside a Map inside an array: derived, not PROVEN"
        (match r.verdict "Unique:GenericArrays.indexes()@return/[]/1" with Some (Unknown | Refuted) -> true | _ -> false);
      expect r "2i Set<Mode>[][]" "Unique:GenericArrays.grid()@return/[]/[]" Proven);

  (* 2j: an interface extending two slice interfaces. *)
  report "2j interface Both extends Policy, Scope";
  with_run (fun r ->
      dump r "Both";
      expect r "2j" "Subtype:Both@<: Policy" Proven;
      expect r "2j" "Subtype:Both@<: Scope" Proven;
      report "  encodings: Both %s, Policy %s, Scope %s" (label (r.encoding "Both")) (label (r.encoding "Policy"))
        (label (r.encoding "Scope"));
      expect r "2j" "Unique:UsesBoth.all()@return" Unknown;
      let emitted = emit_source r in
      known_weakness "known_weakness_subtype_drops_inherited_members"
        ~detail:
          "Both is encoded Record with no fields ('type both = unit'), yet Subtype:Both@<: Policy is PROVEN and Set<Both> is only UNKNOWN; a Both is a Policy, whose addScope needs a closure"
        (r.encoding "Both" = Record
        && r.verdict "Subtype:Both@<: Policy" = Some Proven
        && contains emitted "type both = unit"
        && comparability (r.encoding "Policy") = Not_comparable));

  (* 2k (extra): legal overloads whose parameter types share a simple name. *)
  report "2k overloads register(<T extends Policy>) / register(<T extends Scope>), at(java.util.Date) / at(java.sql.Date)";
  with_run (fun r ->
      dump r "Overloads";
      List.iter
        (fun id -> check ("2k distinct obligation " ^ id) (r.entry id <> None))
        [ "Command:Overloads.register(Policy)"; "Command:Overloads.register(Scope)"; "Command:Overloads.at(java.util.Date)";
          "Command:Overloads.at(java.sql.Date)" ];
      match Certificate.check r.graph ~digest:r.digest r.cert with
      | Ok _ -> check "2k checker accepts" true
      | Error errs -> check ("2k checker accepts: " ^ String.concat "; " errs) false);

  (* 2l (extra): two top-level slice types with one simple name. *)
  report "2l org.example.ext.Policy and adv.evasions.Policy in one slice";
  (match extract_result ~name:"evasions-dup" [ "fixtures/evasions/Policy.java"; "fixtures/support/Policy.java" ] with
  | Ok _ -> known_weakness "known_weakness_same_simple_name_aborts_extractor" ~detail:"extraction succeeded" false
  | Error e ->
      known_weakness "known_weakness_same_simple_name_aborts_extractor"
        ~detail:"slice ids are simple names: the extractor stops with 'duplicate type id in slice: Policy' (fails loudly, no graph)"
        (contains e "duplicate type id in slice: Policy"));
  (match r with
  | Some r -> (
      match Certificate.check r.graph ~digest:r.digest r.cert with
      | Ok _ -> check "checker accepts the attack-2 certificate" true
      | Error errs -> check ("checker accepts the attack-2 certificate: " ^ String.concat "; " errs) false)
  | None -> ());
  finish "test_evasions"
