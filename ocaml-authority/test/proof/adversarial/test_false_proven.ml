(* Attack 1: false PROVEN. Each fixture under fixtures/lies declares a Java type
   that its runtime values do not respect. LiesDemo proves each lie at run time;
   the real extractor and attempt_proof then give their verdicts.

   A declared type that lies inside a method body, or inside a string, is out of
   reach by construction: the extractor is parse-only and records two body facts
   (docs/proof-search.md, "Obligations"). Those cases are pinned as
   known_weakness_* and stay open. *)

open Adv
open Proof.Encoding

let slice_files = List.filter (fun f -> not (contains f "MiniJson" || contains f "LiesDemo")) (java_files "fixtures/lies")

let () =
  (* The lies are real: compile the fixtures and run the demo. *)
  let demo = run_java ~name:"lies" ~files:(java_files "fixtures/lies") ~main:"adv.lies.LiesDemo" in
  let lie marker = check ("runtime: " ^ marker) (contains demo marker) in
  List.iter lie
    [
      "LIE 1a getClaims() List<String> element is java.lang.Integer";
      "LIE 1a getClaims() List<String> value is java.lang.String";
      "LIE 1a typed read: java.lang.ClassCastException";
      "LIE 1b getNames() List<String> element is java.lang.Integer";
      "LIE 1c getAct() String holds a JSON object: true";
      "LIE 1d toArray() E[] with E=String: java.lang.ClassCastException";
      "LIE 1d buckets() List<String>[] typed read: java.lang.ClassCastException";
      "LIE 1e literalNull() Optional is null: true";
      "LIE 1e indirectNull() Optional is null: true";
      "LIE 1f setName(String): java.lang.UnsupportedOperationException";
      "LIE 1f getConfig().put: java.lang.UnsupportedOperationException";
      "LIE 1g getNames() Set<String> of {Read, read} has size 1";
    ];
  let r = prove (extract ~name:"lies" slice_files) in
  report "attack 1: %d obligations, result %s, cost %s" (List.length r.cert.entries)
    (Proof.Certificate.result_to_string r.cert.result) (cost_to_string r.cert.cost);

  (* 1a: unchecked cast (Map<String, List<String>>) readValue(..., Map.class) in a constructor. *)
  report "1a unchecked cast of readValue(..., Map.class)";
  dump r ~member:"getClaims()" "PushedClaims";
  known_weakness "known_weakness_unchecked_cast_claims_map"
    ~detail:"Represent, Nullability and Keyed of PushedClaims.getClaims() are PROVEN; at run time the List<String> holds an Integer and one value is a String"
    (r.verdict "Represent:PushedClaims.getClaims()@return" = Some Proven
    && r.verdict "Keyed:PushedClaims.getClaims()@return" = Some Proven
    && ocaml_of r "Represent:PushedClaims.getClaims()@return" = Some "string list String_map.t");

  (* 1b: heap pollution through a raw type. The raw parameter is seen; the polluted getter is not. *)
  report "1b heap pollution through a raw type";
  dump r "Roles";
  expect r "1b raw parameter is Dynamic" "Dynamic:Roles.setLegacy(List)@param:legacy" Unknown;
  known_weakness "known_weakness_raw_type_heap_pollution"
    ~detail:"Represent:Roles.getNames()@return is PROVEN (string list) while merge() adds an Integer through a raw alias in its body"
    (r.verdict "Represent:Roles.getNames()@return" = Some Proven && r.verdict "Command:Roles.merge(List)" = Some Proven);

  (* 1c: a String field that holds JSON. *)
  report "1c String that holds JSON";
  dump r "DelegatedIdentity";
  known_weakness "known_weakness_string_holds_json"
    ~detail:"Represent:DelegatedIdentity.actClaim@type and getAct() are PROVEN as string; the act chain's structure lives in the string"
    (r.verdict "Represent:DelegatedIdentity.actClaim@type" = Some Proven
    && r.verdict "Represent:DelegatedIdentity.getAct()@return" = Some Proven);

  (* 1d: @SuppressWarnings("unchecked") generic arrays. *)
  report "1d @SuppressWarnings(\"unchecked\") generic arrays";
  dump r "Buckets";
  known_weakness "known_weakness_unchecked_generic_array"
    ~detail:"Represent of Buckets.toArray() ('e array) and Buckets.buckets(int) (string list array) are PROVEN; both throw ClassCastException on a typed read"
    (r.verdict "Represent:Buckets.toArray()@return" = Some Proven
    && r.verdict "Represent:Buckets.buckets(int)@return" = Some Proven);

  (* 1e: Optional returned as null. Held: Optional is outside the known JDK types, and the value is an option. *)
  report "1e Optional returned as null";
  dump r "Lookup";
  expect r "1e Optional is external" "Represent:Lookup.literalNull()@return" Unknown;
  expect r "1e null literal is evidence" "Nullability:Lookup.literalNull()@return" Strengthened;
  check_eq "1e literalNull carries None" show_opt (Some "string optional option")
    (ocaml_of r "Nullability:Lookup.literalNull()@return");
  expect r "1e indirect null: no evidence, still option" "Nullability:Lookup.indirectNull()@return" Proven;
  check_eq "1e indirectNull carries None" show_opt (Some "string optional option")
    (ocaml_of r "Nullability:Lookup.indirectNull()@return");

  (* 1f: a setter that throws UnsupportedOperationException, and an unmodifiable map. *)
  report "1f setter that throws UnsupportedOperationException";
  dump r "FrozenPolicy";
  known_weakness "known_weakness_throwing_setter_is_mutable"
    ~detail:"Mutable:FrozenPolicy.setName(String) is PROVEN (mutable record field); the setter always throws"
    (r.verdict "Mutable:FrozenPolicy.setName(String)" = Some Proven && r.encoding "FrozenPolicy" = Record);

  (* 1g (extra): a Set<String> ordered by a comparator that is not String.equals. *)
  report "1g Set<String> with a case-insensitive comparator";
  dump r "ScopeNames";
  known_weakness "known_weakness_comparator_set_uniqueness"
    ~detail:"Unique:ScopeNames.getNames()@return is PROVEN (String_set.t); the TreeSet collapses \"Read\" and \"read\""
    (r.verdict "Unique:ScopeNames.getNames()@return" = Some Proven);

  (* The checker accepts every one of these certificates: nothing it re-derives can see the lies. *)
  (match Proof.Certificate.check r.graph ~digest:r.digest r.cert with
  | Ok _ -> check "checker accepts the attack-1 certificate" true
  | Error errs -> check ("checker accepts the attack-1 certificate: " ^ String.concat "; " errs) false);
  finish "test_false_proven"
