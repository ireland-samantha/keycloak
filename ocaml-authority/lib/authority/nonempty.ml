(* A list with at least one element. The record shape makes emptiness
   unrepresentable, so no constructor needs to validate. *)

type 'a t = { head : 'a; tail : 'a list }

let make head tail = { head; tail }
let singleton head = { head; tail = [] }
let to_list { head; tail } = head :: tail
let of_list = function [] -> None | head :: tail -> Some { head; tail }
let length l = 1 + List.length l.tail
let map f { head; tail } = { head = f head; tail = List.map f tail }
let exists p l = List.exists p (to_list l)
let for_all p l = List.for_all p (to_list l)
let last l = List.fold_left (fun _ x -> x) l.head l.tail

(* [prepend xs l] and [concat l ls] keep the result non-empty. *)
let prepend xs l = match xs with [] -> l | head :: rest -> { head; tail = rest @ to_list l }
let concat l ls = { l with tail = l.tail @ List.concat_map to_list ls }

(* Keeps the first occurrence of each element (structural equality). *)
let dedup l =
  let tail = List.fold_left (fun acc x -> if x = l.head || List.mem x acc then acc else x :: acc) [] l.tail in
  { l with tail = List.rev tail }
