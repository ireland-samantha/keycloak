type source = Keycloak | Fixture

(* Live role mappings of one principal, as the adapter resolved them. *)
type roles = {
  principal : Principal.t;
  realm_roles : Id.Role.t list;
  client_roles : (Id.Client.t * Id.Role.t list) list;
}

type t = {
  source : source;
  realm : string option;
  evaluated_at : Timestamp.t;
  subject : Principal.t;  (** whose authority is exercised (token sub) *)
  actor_chain : Principal.t list;  (** RFC 8693 act chain, current actor first *)
  principals : roles list;
}

let acting f = match f.actor_chain with a :: _ -> a | [] -> f.subject

(* Token sub = s, act = a1{act = a2{... ak}} gives the path [s; ak; ...; a1]. *)
let token_path f = f.subject :: List.rev f.actor_chain
let roles_of f p = List.find_opt (fun r -> Principal.equal r.principal p) f.principals

let holds r = function
  | Grant.Realm_role role -> List.exists (Id.Role.equal role) r.realm_roles
  | Grant.Client_role { client; role } ->
      List.exists (fun (c, roles) -> Id.Client.equal c client && List.exists (Id.Role.equal role) roles) r.client_roles

let source_to_string = function Keycloak -> "keycloak" | Fixture -> "fixture"
