(* Random Java graphs for the P2 and emitter tests. *)

open Gb
open Proof

(* A random graph of [n] types drawn from every construct the rules look at. *)
let random_graph ?(max_members = 4) rng n =
  let int k = Random.State.int rng k in
  let kinds =
    Array.init n (fun _ ->
        match int 20 with
        | x when x < 10 -> Jgraph.Interface
        | x when x < 14 -> Jgraph.Class_decl
        | x when x < 17 -> Jgraph.Enum
        | _ -> Jgraph.Record_decl)
  in
  (* Some interfaces are named like SPI providers, which makes them Open. *)
  let ids = Array.mapi (fun i k -> if k = Jgraph.Interface && int 5 = 0 then Printf.sprintf "T%dProvider" i else Printf.sprintf "T%d" i) kinds in
  let pick () = ids.(int n) in
  let value_type () =
    match int 12 with
    | 0 -> string_
    | 1 -> prim "long"
    | 2 | 3 -> slice (pick ())
    | 4 | 5 -> set_ (slice (pick ()))
    | 6 -> set_ string_
    | 7 -> map_ (slice (pick ())) string_
    | 8 -> list_ (slice (pick ()))
    | 9 -> object_
    | 10 -> ext "org.example.Ext"
    | _ -> map_ string_ (set_ (slice (pick ())))
  in
  let member i j =
    if kinds.(i) = Jgraph.Record_decl then component (Printf.sprintf "c%d" j) (value_type ())
    else
      match int 7 with
      | 0 | 1 -> getter (Printf.sprintf "getP%d" j) (value_type ())
      | 2 -> setter (Printf.sprintf "setP%d" j) (value_type ())
      | 3 -> command ~params:[ param "x" (value_type ()) ] (Printf.sprintf "doIt%d" j)
      | 4 -> query ~params:[ param "x" string_ ] (Printf.sprintf "ask%d" j) (value_type ())
      | 5 -> field (Printf.sprintf "f%d" j) (value_type ())
      | _ -> static (query (Printf.sprintf "make%d" j) (slice ids.(i)))
  in
  let interfaces = List.filter (fun i -> kinds.(i) = Jgraph.Interface) (List.init n Fun.id) in
  let types =
    List.init n (fun i ->
        let members = List.init (int max_members) (member i) in
        let kind = kinds.(i) in
        let type_params =
          if (kind = Jgraph.Interface || kind = Jgraph.Class_decl) && int 5 = 0 then
            [ ("P", [ (if int 3 = 0 then ext "org.example.Base" else slice (pick ())) ]) ]
          else []
        in
        let supers =
          if kind <> Jgraph.Enum && kind <> Jgraph.Record_decl && interfaces <> [] && int 4 = 0 then
            let j = List.nth interfaces (int (List.length interfaces)) in
            if j = i then [] else [ slice ids.(j) ]
          else []
        in
        match kind with
        | Jgraph.Enum -> enum_ ids.(i) (List.init (1 + int 3) (Printf.sprintf "K%d")) members
        | Jgraph.Record_decl -> record_ ids.(i) members
        | Jgraph.Class_decl -> jtype ~kind ~type_params ~implements:supers ids.(i) members
        | _ -> jtype ~kind ~type_params ~extends:supers ids.(i) members)
  in
  graph types
