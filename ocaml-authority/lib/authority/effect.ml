(* Effects and their partial order (authority-model.md, "Effect"). The order
   is generic: deciding a scenario never needs an effect rule of its own. *)

type audience = Self | Organization | Public

type t =
  | Observe
  | Produce of audience  (** create a new artifact visible to the audience *)
  | Disclose of audience  (** make an existing resource visible to the audience *)
  | Administer  (** change configuration or authority of the system *)

(* A non-empty list of maxima. *)
type bound = t Nonempty.t

let reach = function Self -> 0 | Organization -> 1 | Public -> 2

(* Same kind and no wider audience. Different kinds are incomparable. *)
let leq a b =
  match (a, b) with
  | Observe, Observe | Administer, Administer -> true
  | Produce x, Produce y | Disclose x, Disclose y -> reach x <= reach y
  | _ -> false

let within e (bound : bound) = Nonempty.exists (leq e) bound

let all =
  [ Observe; Produce Self; Produce Organization; Produce Public;
    Disclose Self; Disclose Organization; Disclose Public; Administer ]

let audience_to_string = function Self -> "self" | Organization -> "organization" | Public -> "public"

let to_string = function
  | Observe -> "observe"
  | Administer -> "administer"
  | Produce a -> "produce:" ^ audience_to_string a
  | Disclose a -> "disclose:" ^ audience_to_string a

let list_to_string l = String.concat ", " (List.map to_string (Nonempty.to_list l))
