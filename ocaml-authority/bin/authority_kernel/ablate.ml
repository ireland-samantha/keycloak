(* Ablation (hypothesis W4, and which of the five questions decided each
   scenario). The kernel never short-circuits a check, so each candidate's
   evidence is complete. A counterfactual ("would this have been allowed had
   the checks of dimension D been ignored?") is therefore recomputed from the
   evidence alone: the kernel is neither re-run nor weakened. Counterfactuals
   are booleans for analysis; they are not decisions and mint nothing.

   The empty ablation must reproduce the real verdict. If it does not, the
   evidence was incomplete, and the run fails (this is a test of S2). *)

open Authority

type dimension = Who | Mandate | Effect | Target | Provenance

let dimensions = [ Who; Mandate; Effect; Target; Provenance ]

let name = function
  | Who -> "who" | Mandate -> "mandate" | Effect -> "effect" | Target -> "target" | Provenance -> "provenance"

let dimension_of : Check.name -> dimension = function
  | Holder_is_actor | Delegation_path_matches -> Who
  | Mandate_permitted | Mandate_covers_capability -> Mandate
  | Effect_within_grant | Effect_within_mandate -> Effect
  | Target_covers_resource -> Target
  | Provenance -> Provenance

(* Well-formedness failures decide before any check runs; they are not
   ablated (there is no evidence to recompute from). *)
let decided_before_checks (d : Decision.t) =
  match d.verdict with
  | Indeterminate rs -> Nonempty.exists (fun (r : Decision.reason) -> r.code <> Decision.Insufficient_evidence) rs
  | Allow _ | Deny _ -> false

(* Allowed iff no applicable prohibition remains and some candidate passes
   every check that is not ignored. Prohibitions restrict effects, so ignoring
   Effect ignores them too. *)
let would_allow ignored (d : Decision.t) =
  let ignored_check (c : Check.t) = List.mem (dimension_of c.name) ignored in
  let prohibited =
    (not (List.mem Effect ignored))
    && List.exists (fun (p : Decision.prohibition_check) -> p.outcome = Check.Fail) d.evidence.prohibitions
  in
  (not prohibited)
  && List.exists
       (fun (c : Decision.candidate) -> List.for_all (fun (k : Check.t) -> k.outcome = Check.Pass || ignored_check k) c.checks)
       d.evidence.candidates

let rec subsets = function [] -> [ [] ] | x :: xs -> let s = subsets xs in s @ List.map (fun t -> x :: t) s

(* Smallest sets of dimensions whose removal turns a non-allow into an allow. *)
let minimal_flips d =
  let flips = List.filter (fun s -> s <> [] && would_allow s d) (subsets dimensions) in
  let subset a b = List.for_all (fun x -> List.mem x b) a in
  List.filter (fun s -> not (List.exists (fun t -> t != s && subset t s && List.length t < List.length s) flips)) flips
  |> List.sort (fun a b -> compare (List.length a) (List.length b))

let run path (file : Scenario.file) =
  let sp = Printf.sprintf in
  Printf.printf "# Ablation: %s\n\n" (Filename.basename path);
  print_string
    "Each column recomputes the outcome from the decision's own evidence with one dimension's checks ignored\n\
     (who: holder_is_actor, delegation_path_matches; mandate: mandate_permitted, mandate_covers_capability;\n\
     effect: effect_within_grant, effect_within_mandate, prohibitions; target: target_covers_resource;\n\
     provenance: chain verification). `allow` in a column means that dimension alone decided against the request.\n\
     Well-formedness INDETERMINATE decisions are decided before any check and are not ablated.\n\n";
  Printf.printf "| scenario | decision | %s | minimal sets that flip it |\n|---|---|%s---|\n"
    (String.concat " | " (List.map (fun d -> "w/o " ^ name d) dimensions))
    (String.concat "" (List.map (fun _ -> "---|") dimensions));
  let decisive = Hashtbl.create 8 and ablatable = ref 0 and not_allowed = ref 0 in
  List.iter
    (fun (s : Scenario.t) ->
      let d = Scenario.evaluate s in
      let verdict = Decision.verdict_to_string d.verdict in
      if decided_before_checks d then
        Printf.printf "| %s | %s | %s | (well-formedness) |\n" s.name verdict
          (String.concat " | " (List.map (fun _ -> "-") dimensions))
      else begin
        let actual = match d.verdict with Decision.Allow _ -> true | _ -> false in
        if would_allow [] d <> actual then
          failwith (sp "%s: evidence does not reproduce the verdict %s; evidence is incomplete" s.name verdict);
        incr ablatable;
        if not actual then incr not_allowed;
        let cell dim =
          let a = would_allow [ dim ] d in
          if a && not actual then Hashtbl.replace decisive dim (s.name :: (try Hashtbl.find decisive dim with Not_found -> []));
          if a then "allow" else "-"
        in
        let cells = List.map cell dimensions in
        let flips =
          if actual then "(allowed)"
          else match minimal_flips d with
            | [] -> "none: no candidate for the capability"
            | l -> String.concat "; " (List.map (fun set -> "{" ^ String.concat ", " (List.map name set) ^ "}") l)
        in
        Printf.printf "| %s | %s | %s | %s |\n" s.name verdict (String.concat " | " cells) flips
      end)
    file.scenarios;
  Printf.printf "\n- scenarios: %d; ablated: %d (the rest are well-formedness INDETERMINATE); not allowed among them: %d\n"
    (List.length file.scenarios) !ablatable !not_allowed;
  Printf.printf "- the empty ablation reproduced every ablated verdict from evidence alone\n";
  List.iter
    (fun dim ->
      let names = List.rev (try Hashtbl.find decisive dim with Not_found -> []) in
      Printf.printf "- %s alone decisive in %d: %s\n" (name dim) (List.length names)
        (if names = [] then "-" else String.concat ", " names))
    dimensions
