module type S = sig
  type t = private string

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

let allowed = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | ':' | '@' | '-' -> true
  | _ -> false

module Make (K : sig
  val kind : string
end) : S = struct
  type t = string

  let of_string s =
    let n = String.length s in
    if n >= 1 && n <= 128 && String.for_all allowed s then Ok s
    else if n > 128 then Error (Printf.sprintf "%s id has %d characters; at most 128 are allowed" K.kind n)
    else Error (Printf.sprintf "invalid %s id %S: expected 1-128 characters from [A-Za-z0-9._:@-]" K.kind s)

  let to_string s = s
  let equal = String.equal
  let compare = String.compare
end

module Principal = Make (struct let kind = "principal" end)
module Mandate = Make (struct let kind = "mandate" end)
module Grant = Make (struct let kind = "grant" end)
module Prohibition = Make (struct let kind = "prohibition" end)
module Resource = Make (struct let kind = "resource" end)
module Resource_type = Make (struct let kind = "resource type" end)
module Action = Make (struct let kind = "action" end)
module Role = Make (struct let kind = "role" end)
module Client = Make (struct let kind = "client" end)
module Request = Make (struct let kind = "request" end)
