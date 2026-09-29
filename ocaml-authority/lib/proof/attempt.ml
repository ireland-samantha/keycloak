(* The public entry point of docs/proof-search.md:

     attempt_proof : Java graph -> Proven | Refuted | Unknown

   Every result carries the best OCaml graph and its certificate; a refutation
   is a result, not an absence of one. *)

type ocaml_graph = { model : Model.t; assignment : Model.assignment }
type counterexample = { obligation : string; text : string; conflicts : string list }
type unresolved = { obligation : string; reason : string }

type proof_result =
  | Proven of ocaml_graph * Certificate.t  (** every obligation PROVEN or STRENGTHENED *)
  | Refuted of ocaml_graph * Certificate.t * counterexample list
  | Unknown of ocaml_graph * Certificate.t * unresolved list  (** no REFUTED, some UNKNOWN *)

let attempt_proof ?model (g : Jgraph.t) ~digest : proof_result =
  let m = match model with Some m -> m | None -> Model.build g in
  let out = Search.run m in
  let stats : Certificate.search_stats =
    {
      components = Array.length m.components;
      cyclic_components = Model.cyclic_count m;
      largest_component = Model.largest_component m;
      states_explored = out.stats.states_explored;
      memo_hits = out.stats.memo_hits;
      branches_pruned = out.stats.branches_pruned;
      infeasible_rejected = out.stats.infeasible;
    }
  in
  let cert = Certificate.make m ~digest out.assignment out.verdicts out.cost stats in
  let graph = { model = m; assignment = out.assignment } in
  let with_verdict v = List.filter (fun (e : Certificate.entry) -> e.verdict = v) cert.entries in
  match cert.result with
  | Certificate.Result_proven -> Proven (graph, cert)
  | Certificate.Result_refuted ->
      Refuted
        ( graph,
          cert,
          List.map
            (fun (e : Certificate.entry) -> { obligation = e.obligation; text = e.reason; conflicts = e.conflicts })
            (with_verdict Encoding.Refuted) )
  | Certificate.Result_unknown ->
      Unknown
        ( graph,
          cert,
          List.map (fun (e : Certificate.entry) -> { obligation = e.obligation; reason = e.reason }) (with_verdict Encoding.Unknown)
        )

let parts = function
  | Proven (g, c) | Refuted (g, c, _) | Unknown (g, c, _) -> (g, c)
