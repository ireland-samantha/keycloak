(* An action on a resource type, e.g. document:publish. *)
type t = { resource_type : Id.Resource_type.t; action : Id.Action.t }

type target = Any_resource | Resource of Id.Resource.t

let equal a b = Id.Resource_type.equal a.resource_type b.resource_type && Id.Action.equal a.action b.action
let to_string c = Id.Resource_type.to_string c.resource_type ^ ":" ^ Id.Action.to_string c.action
let list_to_string l = String.concat ", " (List.map to_string l)
let covers target r = match target with Any_resource -> true | Resource r' -> Id.Resource.equal r r'

(* t1 is a subset of t2. *)
let target_subset t1 t2 =
  match (t1, t2) with
  | _, Any_resource -> true
  | Resource a, Resource b -> Id.Resource.equal a b
  | Any_resource, Resource _ -> false

let target_to_string = function Any_resource -> "any" | Resource r -> Id.Resource.to_string r
