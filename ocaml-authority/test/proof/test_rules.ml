(* Each verdict rule of docs/proof-search.md on a tiny hand-built graph. Every
   run is also handed to the independent checker, which must accept it. *)

open Harness
open Gb
open Proof.Encoding

let run_checked name g =
  let r = run g in
  (match Proof.Certificate.check g ~digest:"test" r.cert with
  | Ok _ -> check (name ^ ": checker accepts") true
  | Error errs -> check (name ^ ": checker accepts (" ^ String.concat "; " errs ^ ")") false);
  r

let verdict name r id expected = check_eq (name ^ ": " ^ id) show_verdict expected (r.verdict id)
let ocaml name r id expected = check_eq (name ^ ": OCaml type of " ^ id) show_opt (Some expected) (r.entry id).ocaml
let encoding name r id expected = check_eq (name ^ ": encoding of " ^ id) show_encoding expected (r.encoding id)
let has_obligation r id = List.exists (fun (e : Proof.Certificate.entry) -> e.obligation = id) r.cert.entries

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  go 0

let nullability () =
  let name = "Grant getGrant() { return null; }" in
  let g =
    graph
      [
        jtype "Holder"
          [
            meth ~mods:[ "public"; "default" ] ~returns_null:true "getGrant" (slice "Grant");
            getter "getName" string_;
            meth ~annotations:[ ann "Nonnull" ] "getId" string_;
            meth ~annotations:[ ann "Nullable" ] "getNote" string_;
            getter "getCount" (prim "int");
          ];
        jtype "Grant" [ getter "getId" string_ ];
      ]
  in
  let r = run_checked name g in
  verdict name r "Nullability:Holder.getGrant()@return" Strengthened;
  ocaml name r "Nullability:Holder.getGrant()@return" "grant option";
  verdict name r "Represent:Holder.getGrant()@return" Proven;
  verdict "no evidence" r "Nullability:Holder.getName()@return" Proven;
  ocaml "no evidence" r "Nullability:Holder.getName()@return" "string option";
  verdict "@Nonnull" r "Nullability:Holder.getId()@return" Strengthened;
  ocaml "@Nonnull" r "Nullability:Holder.getId()@return" "string";
  verdict "@Nullable" r "Nullability:Holder.getNote()@return" Strengthened;
  ocaml "@Nullable" r "Nullability:Holder.getNote()@return" "string option";
  check "a primitive has no Nullability obligation" (not (has_obligation r "Nullability:Holder.getCount()@return"))

let represent () =
  let name = "Represent" in
  let g =
    graph
      [
        jtype "Values"
          [
            getter "getTs" (prim "long");
            getter "getBoxed" boxed_long;
            getter "getCount" (prim "int");
            getter "isOn" (prim "boolean");
            getter "getRatio" (prim "double");
            getter "getName" string_;
            getter "getTags" (list_ string_);
            getter "getColor" (slice "Color");
            getter "getClock" (ext "java.time.Clock");
          ];
        enum_ "Color" [ "RED"; "GREEN" ] [];
      ]
  in
  let r = run_checked name g in
  verdict "long -> Int64" r "Represent:Values.getTs()@return" Proven;
  ocaml "long -> Int64" r "Represent:Values.getTs()@return" "Int64.t";
  ocaml "Long -> Int64 option" r "Nullability:Values.getBoxed()@return" "Int64.t option";
  ocaml "int" r "Represent:Values.getCount()@return" "int";
  ocaml "boolean" r "Represent:Values.isOn()@return" "bool";
  ocaml "double" r "Represent:Values.getRatio()@return" "float";
  ocaml "String" r "Represent:Values.getName()@return" "string";
  verdict "List<String>" r "Represent:Values.getTags()@return" Proven;
  ocaml "List<String>" r "Represent:Values.getTags()@return" "string list";
  verdict "slice type" r "Represent:Values.getColor()@return" Proven;
  ocaml "slice type" r "Represent:Values.getColor()@return" "color";
  verdict "external type" r "Represent:Values.getClock()@return" Unknown;
  ocaml "external type" r "Represent:Values.getClock()@return" "clock";
  (* enum -> variant *)
  encoding "enum" r "Color" Variant;
  verdict "enum" r "Closed:Color" Proven

let collections () =
  let name = "Set<Iface> with Iface as Record" in
  let g =
    graph
      [
        jtype "Box"
          [
            getter "getItems" (set_ (slice "Item"));
            getter "getNames" (set_ string_);
            getter "getByColor" (map_ (slice "Color") string_);
            getter "getAttrs" (map_ string_ (list_ string_));
          ];
        jtype "Item" [ getter "getName" string_ ];
        enum_ "Color" [ "RED" ] [];
      ]
  in
  let r = run_checked name g in
  encoding name r "Item" Record;
  verdict name r "Unique:Box.getItems()@return" Unknown;
  ocaml name r "Represent:Box.getItems()@return" "Item_set.t";
  check (name ^ ": reason names Java equals") (contains (r.entry "Unique:Box.getItems()@return").reason "equals of Item");
  verdict "Set<String>" r "Unique:Box.getNames()@return" Proven;
  ocaml "Set<String>" r "Represent:Box.getNames()@return" "String_set.t";
  verdict "Map<enum, String>" r "Keyed:Box.getByColor()@return" Proven;
  ocaml "Map<enum, String>" r "Represent:Box.getByColor()@return" "string Color_map.t";
  verdict "Map<String, List<String>>" r "Keyed:Box.getAttrs()@return" Proven;
  (* Element with behaviour: the trade-off is refuted, and the counterexample names the conflict. *)
  let name = "Set<Iface> with behaviour on Iface" in
  let g =
    graph
      [ jtype "Box" [ getter "getItems" (set_ (slice "Item")) ]; jtype "Item" [ getter "getName" string_; command "rename" ] ]
  in
  let r = run_checked name g in
  encoding name r "Item" Closures;
  verdict name r "Unique:Box.getItems()@return" Refuted;
  ocaml name r "Represent:Box.getItems()@return" "item list";
  let e = r.entry "Unique:Box.getItems()@return" in
  check (name ^ ": counterexample says why") (contains e.reason "Item must be comparable because Box.getItems() : Set<Item>");
  check (name ^ ": counterexample names the command") (contains e.reason "Item.rename() needs a closure");
  check_eq (name ^ ": conflicts") (String.concat ",") [ "Command:Item.rename()" ] e.conflicts;
  (* Comparability goes through record fields. *)
  let name = "comparable record with a behavioural field" in
  let g =
    graph
      [
        jtype "Holder" [ getter "getLeaves" (set_ (slice "Leaf")) ];
        jtype "Leaf" [ getter "getInner" (slice "Inner") ];
        jtype "Inner" [ command "poke" ];
      ]
  in
  let r = run_checked name g in
  encoding name r "Leaf" Record;
  encoding name r "Inner" Closures;
  verdict name r "Unique:Holder.getLeaves()@return" Refuted;
  let e = r.entry "Unique:Holder.getLeaves()@return" in
  check (name ^ ": culprit is the field's type") (contains e.reason "Inner must be comparable");
  check (name ^ ": path through the record") (contains e.reason "reached through the fields of Leaf")

let behaviour () =
  let name = "commands and queries" in
  let g =
    graph
      [
        record_ "Point" [ component "x" (prim "int"); query "norm" (prim "double") ];
        record_ "Origin"
          [ component "x" (prim "int"); static (query ~params:[ param "x" (prim "int") ] "of" (slice "Origin")) ];
        jtype "Store" [ command ~params:[ param "k" string_; param "v" string_ ] "setEntry"; query "toMap" (map_ string_ string_); getter "isOpen" (prim "boolean") ];
      ]
  in
  let r = run_checked name g in
  verdict "query on a Java record" r "Query:Point.norm()" Refuted;
  check "reason: records only take Record" (contains (r.entry "Query:Point.norm()").reason "Record is the only encoding allowed");
  verdict "static query" r "Query:Origin.of(int)" Proven;
  verdict "two-argument set* is a command" r "Command:Store.setEntry(String,String)" Proven;
  verdict "nullary non-getter is a query" r "Query:Store.toMap()" Proven;
  check "isX() is data, no Query" (not (has_obligation r "Query:Store.isOpen()"));
  encoding name r "Store" Closures

let openness () =
  let name = "Open" in
  let g =
    graph
      [
        jtype "FooProvider" [ command "run" ];
        jtype "BarProvider" [ getter "getName" string_ ];
        jtype "Registry" [ getter "getAll" (set_ (slice "BarProvider")) ];
        jtype ~extends:[ ext "org.keycloak.provider.Provider" ] "Plugin" [ command "close" ];
      ]
  in
  let r = run_checked name g in
  verdict "name ends in Provider" r "Open:FooProvider" Proven;
  encoding name r "FooProvider" Closures;
  verdict "extends Provider" r "Open:Plugin" Proven;
  encoding "open but demanded comparable" r "BarProvider" Record;
  verdict "open but demanded comparable" r "Open:BarProvider" Unknown;
  verdict "open but demanded comparable" r "Unique:Registry.getAll()@return" Unknown

let mutation_and_checked () =
  let name = "Mutable and Checked" in
  let g =
    graph
      [
        jtype "Named" [ getter "getName" string_; setter "setName" string_ ];
        class_ "Token"
          [ field "subject" string_; field ~mods:[ "protected"; "final" ] "issuer" string_;
            meth ~throws:[ ext "java.io.IOException" ] "load" Void ];
        enum_ "Mode" [ "A" ] [ setter "setLabel" string_ ];
      ]
  in
  let r = run_checked name g in
  encoding name r "Named" Record;
  verdict "setter on a Record" r "Mutable:Named.setName(String)" Proven;
  verdict "non-final field" r "Mutable:Token.subject" Proven;
  check "final field is not Mutable" (not (has_obligation r "Mutable:Token.issuer"));
  verdict "throws" r "Checked:Token.load()@throws IOException" Proven;
  verdict "setter on an enum" r "Mutable:Mode.setLabel(String)" Refuted;
  check "enum setter reason" (contains (r.entry "Mutable:Mode.setLabel(String)").reason "enum constant cannot change")

let dynamic () =
  let name = "Dynamic" in
  let g =
    graph
      [ jtype "Bag" [ getter "getAny" object_; getter "getType" (class_of (Wildcard None)); getter "getRaw" raw_list ] ]
  in
  let r = run_checked name g in
  verdict "Object" r "Dynamic:Bag.getAny()@return" Unknown;
  verdict "Object is carried" r "Represent:Bag.getAny()@return" Proven;
  ocaml "Object" r "Represent:Bag.getAny()@return" "java_object";
  verdict "Class<?>" r "Dynamic:Bag.getType()@return" Unknown;
  verdict "raw List" r "Dynamic:Bag.getRaw()@return" Unknown

let cycles () =
  let name = "Module_type in a cycle" in
  let g = graph [ jtype "Node" [ getter "getNext" (slice "Node"); command "visit" ]; jtype "Leaf" [ command "visit" ] ] in
  let m = Proof.Model.build g in
  check "Node is cyclic" m.cyclic.(m.component_of.(Proof.Model.node m "Node"));
  check "Module_type is not feasible in a cycle" (not (List.mem Module_type (Proof.Model.feasible m (Proof.Model.node m "Node"))));
  check "Module_type is feasible outside a cycle" (List.mem Module_type (Proof.Model.feasible m (Proof.Model.node m "Leaf")));
  let r = run_checked name g in
  let forced =
    { r.cert with encodings = List.map (fun (n, e) -> if n = "Node" then (n, Module_type) else (n, e)) r.cert.encodings }
  in
  (match Proof.Certificate.check g ~digest:"test" forced with
  | Ok _ -> check "checker rejects Module_type in a cycle" false
  | Error errs -> check "checker rejects Module_type in a cycle" (List.exists (fun e -> contains e "cyclic component") errs));
  let forced_leaf =
    { r.cert with encodings = List.map (fun (n, e) -> if n = "Leaf" then (n, Module_type) else (n, e)) r.cert.encodings }
  in
  (* Module_type is allowed for Leaf; the certificate is rejected only because its cost changes. *)
  match Proof.Certificate.check g ~digest:"test" forced_leaf with
  | Ok _ -> check "Module_type outside a cycle changes the cost" false
  | Error errs ->
      check "Module_type outside a cycle is structurally fine" (not (List.exists (fun e -> contains e "cyclic") errs));
      check "Module_type outside a cycle changes the cost" (List.exists (fun e -> contains e "claimed cost") errs)

let bounds () =
  let name = "bounded type parameter" in
  let g =
    graph
      [
        jtype ~type_params:[ ("D", [ slice "Ctx" ]) ] "Decider" [ command ~params:[ param "d" (var "D") ] "decide" ];
        jtype "Ctx" [ getter "getName" string_ ];
        jtype ~type_params:[ ("R", [ ext "org.example.Base" ]) ] "Factory" [ getter "getRep" (var "R") ];
      ]
  in
  let r = run_checked name g in
  encoding "bound forces Object" r "Ctx" Object;
  verdict "bound forces Object" r "Bounded:Decider@<D extends Ctx>" Proven;
  let greedy = Proof.Baselines.greedy r.model in
  check_eq "greedy keeps Ctx a Record" show_encoding Record greedy.(Proof.Model.node r.model "Ctx");
  let gv = Proof.Evaluate.verdicts r.model greedy in
  let idx = ref (-1) in
  Array.iteri (fun i (o : Proof.Obligation.t) -> if o.id = "Bounded:Decider@<D extends Ctx>" then idx := i) r.model.obligations;
  check_eq "greedy refutes the bound" show_verdict Refuted gv.(!idx);
  verdict "external bound" r "Bounded:Factory@<R extends Base>" Refuted;
  check "external bound reason" (contains (r.entry "Bounded:Factory@<R extends Base>").reason "carry no bounds")

let subtypes () =
  let name = "Subtype" in
  let behavioural =
    graph
      [
        jtype ~extends:[ slice "B" ] "A" [ command "a" ];
        jtype ~extends:[ slice "C" ] "B" [ command "b" ];
        jtype "C" [ command "c" ];
      ]
  in
  let r = run_checked name behavioural in
  List.iter (fun id -> encoding "behavioural hierarchy is structural" r id Object) [ "A"; "B"; "C" ];
  verdict name r "Subtype:A@<: B" Proven;
  check_eq "behavioural hierarchy complexity: 3 x Object + 2 x 0" string_of_int 12 r.cert.cost.complexity;
  let data = graph [ jtype ~extends:[ slice "B" ] "A" [ getter "getA" string_ ]; jtype "B" [ getter "getB" string_ ] ] in
  let r = run_checked name data in
  List.iter (fun id -> encoding "data hierarchy" r id Record) [ "A"; "B" ];
  check_eq "data hierarchy complexity: 2 x Record + coercion 2" string_of_int 6 r.cert.cost.complexity;
  check_eq "subtype complexity Object/Object" string_of_int 0 (subtype_complexity Object Object);
  check_eq "subtype complexity Module_type/Module_type" string_of_int 1 (subtype_complexity Module_type Module_type);
  check_eq "subtype complexity same" string_of_int 2 (subtype_complexity Closures Closures);
  check_eq "subtype complexity different" string_of_int 3 (subtype_complexity Record Object)

let projection () =
  let g =
    graph
      [
        class_ "Thing"
          [
            field ~mods:[ "private" ] "secret" string_;
            { (meth ~mods:[ "public" ] "Thing" Void) with m_kind = Constructor; m_type = None };
            getter "getName" string_;
          ];
      ]
  in
  let r = run_checked "projection" g in
  check "private members produce no obligations" (not (List.exists (fun (e : Proof.Certificate.entry) -> e.member = Some "secret") r.cert.entries));
  check "constructors produce no obligations" (not (List.exists (fun (e : Proof.Certificate.entry) -> e.member = Some "Thing()") r.cert.entries))

let () =
  nullability ();
  represent ();
  collections ();
  behaviour ();
  openness ();
  mutation_and_checked ();
  dynamic ();
  cycles ();
  bounds ();
  subtypes ();
  projection ();
  finish "test_rules"
