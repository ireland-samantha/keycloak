type kind = User | Service

(* A user is identified by username, a service by its client_id. *)
type t = { kind : kind; id : Id.Principal.t }

let equal a b = a.kind = b.kind && Id.Principal.equal a.id b.id
let same_id a b = Id.Principal.equal a.id b.id
let kind_to_string = function User -> "user" | Service -> "service"
let to_string p = Printf.sprintf "%s (%s)" (Id.Principal.to_string p.id) (kind_to_string p.kind)

(* A delegation path, root first: [samantha > research-agent]. *)
let path_to_string path = "[" ^ String.concat " > " (List.map (fun p -> Id.Principal.to_string p.id) path) ^ "]"
