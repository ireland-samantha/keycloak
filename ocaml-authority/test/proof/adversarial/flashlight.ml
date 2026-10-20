(* The P3 / Q2 measurement of docs/flashlight.md, computed from
   glue-sites.tsv (the README's 44 glue sites with their consumed members) and
   the committed certificate. The procedure is fixed in docs/flashlight.md,
   section 1.

   The rendered result is written to flashlight.out.md, and must appear
   verbatim between the flashlight:begin / flashlight:end markers of
   docs/flashlight.md, so the document cannot drift from the computation. *)

open Adv
open Proof

let cert_path = "../../../examples/proof/certificate.json"
let graph_path = "../../../examples/proof/keycloak-authz.graph.json"

type consumed = Slice_member of { owner : string; key : string; position : string } | Outside of string

type site = {
  n : int;
  location : string;
  kind : string;
  enters : string;
  rule : string;
  consumed : consumed list;
}

let split c s = List.map String.trim (String.split_on_char c s)

(* Index of the first occurrence of [needle] in [hay] at or after [from]. *)
let find ?(from = 0) hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = if i + n > h then None else if String.sub hay i n = needle then Some i else go (i + 1) in
  go from

let parse_consumed s =
  (* Text after " -- " documents an R2 trace. *)
  let s = match find s " -- " with Some i -> String.sub s 0 i | None -> s in
  List.filter_map
    (fun item ->
      if item = "" then None
      else if String.length item > 6 && String.sub item 0 6 = "slice:" then
        match split '|' (String.sub item 6 (String.length item - 6)) with
        | [ owner; key; position ] -> Some (Slice_member { owner; key; position })
        | _ -> failwith ("bad slice member " ^ item)
      else if String.length item > 8 && String.sub item 0 8 = "outside:" then Some (Outside (String.sub item 8 (String.length item - 8)))
      else failwith ("bad consumed member " ^ item))
    (split ';' (String.trim s))

let sites () =
  read_file "glue-sites.tsv" |> String.split_on_char '\n'
  |> List.filter (fun l -> String.trim l <> "" && l.[0] <> '#')
  |> List.map (fun l ->
         match String.split_on_char '\t' l with
         | [ n; location; kind; enters; rule; consumed ] ->
             { n = int_of_string n; location; kind; enters; rule; consumed = parse_consumed consumed }
         | _ -> failwith ("bad TSV line: " ^ l))

type cls = A | B | C

let cls_label = function A -> "(a) NON-PROVEN" | B -> "(b) PROVEN" | C -> "(c) NO OBLIGATION"

let member_label = function
  | Slice_member { owner; key; _ } -> "`" ^ owner ^ "." ^ key ^ "`"
  | Outside m -> "`" ^ m ^ "` (outside)"

let () =
  let cert = match Certificate.of_string (read_file cert_path) with Ok c -> c | Error e -> failwith e in
  let g, digest = match Jgraph.of_string (read_file graph_path) with Ok x -> x | Error e -> failwith e in
  check "the certificate is the one pinned in docs/flashlight.md" (cert.graph_digest = "md5:d208acaa0dae3ac1ef242a2d5191d28b" && digest = cert.graph_digest);
  let slice_ids = List.map (fun (t : Jgraph.jtype) -> t.id) g.types in
  let sites = sites () in
  check_eq "44 glue sites, numbered 1..44" (fun l -> String.concat "," (List.map string_of_int l)) (List.init 44 (fun i -> i + 1))
    (List.map (fun s -> s.n) sites);
  (* Relevant obligations of an in-slice member: its value position and positions nested under it. *)
  let relevant owner key position =
    List.filter
      (fun (e : Certificate.entry) ->
        e.owner = owner && e.member = Some key
        && match e.position with
           | Some p -> p = position || (String.length p > String.length position && String.sub p 0 (String.length position + 1) = position ^ "/")
           | None -> false)
      cert.entries
  in
  let classify s =
    let in_slice = List.filter (function Slice_member _ -> true | Outside _ -> false) s.consumed in
    List.iter
      (function
        | Slice_member { owner; key; position } ->
            check (Printf.sprintf "site %d: %s is a slice type" s.n owner) (List.mem owner slice_ids);
            check (Printf.sprintf "site %d: %s.%s@%s has obligations" s.n owner key position) (relevant owner key position <> [])
        | Outside m ->
            let ty = match String.index_opt m '(' with Some i -> String.sub m 0 i | None -> m in
            let ty = match String.rindex_opt ty '.' with Some i -> String.sub ty 0 i | None -> ty in
            check (Printf.sprintf "site %d: %s is outside the slice" s.n ty)
              (not (List.exists (fun id -> id = ty || ((not (String.contains ty '.')) && Jgraph.simple_name id = ty)) slice_ids)))
      s.consumed;
    let obligations = List.concat_map (fun (m : _) -> match m with Slice_member { owner; key; position } -> relevant owner key position | Outside _ -> []) s.consumed in
    let cls =
      if in_slice = [] then C
      else if List.exists (fun (e : Certificate.entry) -> e.verdict = Encoding.Unknown || e.verdict = Encoding.Refuted) obligations then A
      else B
    in
    (cls, obligations)
  in
  let rows = List.map (fun s -> (s, classify s)) sites in
  let count c = List.length (List.filter (fun (_, (c', _)) -> c' = c) rows) in
  let a = count A and b = count B and c = count C in
  let total = List.length rows in
  let pct x n = if n = 0 then "n/a" else Printf.sprintf "%.1f%%" (100. *. float_of_int x /. float_of_int n) in
  let buf = Buffer.create 16384 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in
  line "### Per-site table";
  line "";
  line "| # | file:line | kind | rule | consumed member(s) | relevant obligations: verdict | class |";
  line "|---|---|---|---|---|---|---|";
  List.iter
    (fun (s, (cls, obls)) ->
      let members = String.concat "; " (List.sort_uniq compare (List.map member_label s.consumed)) in
      let obls =
        if obls = [] then "none"
        else
          String.concat "; "
            (List.sort_uniq compare
               (List.map (fun (e : Certificate.entry) -> "`" ^ e.obligation ^ "`: " ^ Encoding.verdict_to_string e.verdict) obls))
      in
      line "| %d | %s | %s | %s | %s | %s | %s |" s.n s.location s.kind s.rule members obls (cls_label cls))
    rows;
  line "";
  line "### Counts";
  line "";
  line "| class | sites | share of all %d sites | share of the %d in-slice sites (secondary) |" total (a + b);
  line "|---|---:|---:|---:|";
  line "| (a) NON-PROVEN | %d | %s | %s |" a (pct a total) (pct a (a + b));
  line "| (b) PROVEN | %d | %s | %s |" b (pct b total) (pct b (a + b));
  line "| (c) NO OBLIGATION | %d | %s | not applicable |" c (pct c total);
  line "| total | %d | 100.0%% | |" total;
  line "";
  line "- **P3** = |a| / %d = %d / %d = **%s**. The threshold is at least 75%%. %s." total a total (pct a total)
    (if 100 * a >= 75 * total then "Supported" else "Not supported");
  line "- **Q2** = |b| / %d = %d / %d = **%s**. The threshold is at least 50%%. %s." total b total (pct b total)
    (if 100 * b >= 50 * total then "Triggered" else "Not triggered");
  line "- Secondary view, over the %d in-slice sites only: (a) %d / %d = %s, and (b) %d / %d = %s. Under this view, P3 is %s and Q2 is %s."
    (a + b) a (a + b) (pct a (a + b)) b (a + b) (pct b (a + b))
    (if 100 * a >= 75 * (a + b) then "supported" else "not supported")
    (if 100 * b >= 50 * (a + b) then "triggered" else "not triggered");
  let block = Buffer.contents buf in
  write_file "flashlight.out.md" block;
  print_string block;
  (* Sensitivity, not the pre-registered reading: the same classes with (i) the README's K-only rows left
     out, and (ii) sites classified in the slice only through an R2 trace counted as (c) instead. *)
  let sens = Buffer.create 1024 in
  let sline fmt = Printf.ksprintf (fun s -> Buffer.add_string sens s; Buffer.add_char sens '\n') fmt in
  let summary label rows =
    let n = List.length rows in
    let k c = List.length (List.filter (fun (_, c') -> c' = c) rows) in
    sline "| %s | %d | %d | %d | %d | %s | %s |" label n (k A) (k B) (k C) (pct (k A) n) (pct (k B) n)
  in
  sline "| reading | sites | (a) | (b) | (c) | P3 = a / sites | Q2 = b / sites |";
  sline "|---|---:|---:|---:|---:|---:|---:|";
  summary "pre-registered (all 44 README rows)" (List.map (fun (s, (cls, _)) -> (s, cls)) rows);
  summary "without the K-only rows" (List.filter_map (fun (s, (cls, _)) -> if s.kind = "K" then None else Some (s, cls)) rows);
  summary "R2 in-slice sites counted as (c)"
    (List.map (fun (s, (cls, _)) -> (s, if s.rule = "R2" && cls <> C then C else cls)) rows);
  let sensitivity = Buffer.contents sens in
  write_file "flashlight.sensitivity.md" sensitivity;
  print_string sensitivity;
  (* The README rows in the TSV should be verbatim. Parallel edits to the adapter are expected, so a
     difference is reported, not failed: the procedure pins a62035c9. *)
  let root = Lazy.force source_root in
  (match In_channel.with_open_bin (Filename.concat root "keycloak-adapter/README.md") In_channel.input_all with
  | readme ->
      let rows =
        String.split_on_char '\n' readme
        |> List.filter_map (fun l ->
               match split '|' l with
               | "" :: n :: location :: kind :: enters :: _ :: _ when int_of_string_opt n <> None -> Some (int_of_string n, location, kind, enters)
               | _ -> None)
      in
      let same = List.map (fun s -> (s.n, s.location, s.kind, s.enters)) sites = rows in
      if same then report "README glue table: identical to glue-sites.tsv (%d rows)" (List.length rows)
      else report "WARNING: keycloak-adapter/README.md glue table differs from glue-sites.tsv (pinned at a62035c9); the measurement uses the pinned rows"
  | exception Sys_error e -> report "WARNING: cannot read the adapter README: %s" e);
  (* The document must carry exactly this block. *)
  let doc = read_file (Filename.concat root "docs/flashlight.md") in
  let between tag =
    let marker_begin = "<!-- " ^ tag ^ ":begin -->\n" and marker_end = "<!-- " ^ tag ^ ":end -->" in
    match find doc marker_begin with
    | None -> None
    | Some i ->
        let i = i + String.length marker_begin in
        Option.map (fun j -> String.sub doc i (j - i)) (find ~from:i doc marker_end)
  in
  check "docs/flashlight.md carries the computed block verbatim between its markers" (between "flashlight" = Some block);
  check "docs/flashlight.md carries the sensitivity table verbatim between its markers"
    (between "flashlight-sensitivity" = Some sensitivity);
  finish "flashlight"
