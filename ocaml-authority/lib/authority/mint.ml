type t = { chain : Chain.verified; checks : Check.t list; source : Facts.source }
type seal = Seal

let seal = Seal

let mint chain checks source =
  let passed (c : Check.t) = c.outcome = Check.Pass in
  if List.exists (fun (c : Check.t) -> c.name = Check.Provenance) checks && List.for_all passed checks then
    Some { chain; checks; source }
  else None

let chain a = a.chain
let checks a = a.checks
let source a = a.source

let anchor_statement a =
  Printf.sprintf "%s holds %s (facts.source = %s)"
    (Id.Principal.to_string (Chain.root_holder a.chain).id)
    (Grant.anchor_to_string (Chain.anchor a.chain))
    (Facts.source_to_string a.source)
