(* Scenario files (typed-authority/scenarios/v1): one ledger, default facts,
   and scenarios that each give a query, optional facts overrides and an
   expectation. Each scenario becomes the full request document the adapter
   would send; the kernel evaluates that document, not a shortcut. *)

open Tjson.Decode

let schema = "typed-authority/scenarios/v1"

type t = {
  name : string;
  description : string;
  request : Tjson.t;
  expect : string;  (** allow | deny | indeterminate *)
  expect_reasons : string list;  (** codes that must appear among the reasons *)
}

type file = { ledger : Tjson.t; default_facts : Tjson.t; scenarios : t list }

(* Top-level keys of [override] replace those of [defaults]. *)
let merge defaults override =
  match (defaults, override) with
  | Tjson.Object d, Tjson.Object o ->
      Tjson.Object
        (List.map (fun (k, v) -> (k, Option.value ~default:v (List.assoc_opt k o))) d
        @ List.filter (fun (k, _) -> not (List.mem_assoc k d)) o)
  | _, o -> o

let scenario ~prefix ~ledger ~default_facts c =
  let* _ = obj ~allowed:[ "name"; "description"; "query"; "facts"; "expect"; "expect_reasons" ] c in
  let* name_c = field "name" c in
  let* name = string name_c in
  let* () = match Authority.Id.Request.of_string name with Ok _ -> Ok () | Error m -> fail name_c m in
  let* description = Result.bind (field "description" c) string in
  let* query = field "query" c in
  let* facts = field_opt "facts" c in
  let* expect_c = field "expect" c in
  let* expect = string expect_c in
  let* () = if List.mem expect [ "allow"; "deny"; "indeterminate" ] then Ok () else fail expect_c "expected allow, deny or indeterminate" in
  let+ expect_reasons =
    Result.bind (field_opt "expect_reasons" c) (function None -> Ok [] | Some r -> map_list string r)
  in
  let facts = match facts with None -> default_facts | Some o -> merge default_facts (value o) in
  let request =
    Tjson.obj
      [ ("schema", Tjson.str Authority.Codec.request_schema); ("request_id", Tjson.str (prefix ^ "-" ^ name));
        ("query", value query); ("facts", facts); ("ledger", ledger) ]
  in
  { name; description; request; expect; expect_reasons }

let decode ~prefix json =
  let c = root json in
  let* _ = obj ~allowed:[ "schema"; "ledger"; "defaults"; "scenarios" ] c in
  let* schema_c = field "schema" c in
  let* s = string schema_c in
  let* () = if s = schema then Ok () else fail schema_c (Printf.sprintf "expected %S" schema) in
  let* ledger = Result.map value (field "ledger" c) in
  let* defaults = field "defaults" c in
  let* _ = obj ~allowed:[ "facts" ] defaults in
  let* default_facts = Result.map value (field "facts" defaults) in
  let* scenarios = Result.bind (field "scenarios" c) (map_list (scenario ~prefix ~ledger ~default_facts)) in
  let names = List.map (fun s -> s.name) scenarios in
  match List.find_opt (fun n -> List.length (List.filter (String.equal n) names) > 1) names with
  | Some n -> fail c (Printf.sprintf "scenario name %S is used twice" n)
  | None -> Ok { ledger; default_facts; scenarios }

(* Request ids are "<file stem>-<scenario name>", e.g. demo-02-delegated-generate. *)
let load path =
  let prefix = Filename.remove_extension (Filename.basename path) in
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error m -> Error m
  | text -> (
      match Tjson.parse text with
      | Error e -> Error (Printf.sprintf "%s: byte %d: %s" path e.offset e.message)
      | Ok json -> (
          match decode ~prefix json with Ok f -> Ok f | Error e -> Error (Printf.sprintf "%s: %s: %s" path e.path e.message)))

let evaluate s = Authority.Evaluate.run (Tjson.to_string s.request)
let codes d = List.map (fun (r : Authority.Decision.reason) -> Authority.Decision.reason_code_to_string r.code) (Authority.Decision.reasons d)

let meets s d =
  String.equal (Authority.Decision.verdict_to_string d.Authority.Decision.verdict) s.expect
  && List.for_all (fun c -> List.mem c (codes d)) s.expect_reasons

(* The decoded request, when it decodes. *)
let request s = Result.to_option (Authority.Codec.request_of_json s.request)
