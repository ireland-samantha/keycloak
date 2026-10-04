type t = int (* seconds since 1970-01-01T00:00:00Z, proleptic Gregorian *)

let is_leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

let days_in_month y = function
  | 2 -> if is_leap y then 29 else 28
  | 4 | 6 | 9 | 11 -> 30
  | _ -> 31

(* Day number relative to 1970-01-01 and its inverse, after H. Hinnant's
   days_from_civil / civil_from_days. Eras are 400-year cycles of 146097 days;
   months are counted from March so the leap day falls at the end. *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * ((m + 9) mod 12)) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((yoe + (era * 400)) + (if m <= 2 then 1 else 0), m, d)

let of_string s =
  let shape = "expected YYYY-MM-DDThh:mm:ssZ (RFC 3339, UTC, second precision)" in
  let number pos len =
    let digits = String.sub s pos len in
    if String.for_all (fun c -> c >= '0' && c <= '9') digits then Some (int_of_string digits) else None
  in
  let separators = [ (4, '-'); (7, '-'); (10, 'T'); (13, ':'); (16, ':'); (19, 'Z') ] in
  if String.length s <> 20 || not (List.for_all (fun (i, c) -> s.[i] = c) separators) then
    Error (Printf.sprintf "invalid timestamp %S: %s" s shape)
  else
    match (number 0 4, number 5 2, number 8 2, number 11 2, number 14 2, number 17 2) with
    | Some y, Some mo, Some d, Some h, Some mi, Some se ->
        if mo < 1 || mo > 12 then Error (Printf.sprintf "invalid timestamp %S: month %d" s mo)
        else if d < 1 || d > days_in_month y mo then
          Error (Printf.sprintf "invalid timestamp %S: %04d-%02d has no day %d" s y mo d)
        else if h > 23 || mi > 59 || se > 59 then Error (Printf.sprintf "invalid timestamp %S: time of day out of range" s)
        else Ok ((days_from_civil y mo d * 86400) + (h * 3600) + (mi * 60) + se)
    | _ -> Error (Printf.sprintf "invalid timestamp %S: %s" s shape)

let to_string t =
  let days = if t >= 0 then t / 86400 else (t - 86399) / 86400 in
  let secs = t - (days * 86400) in
  let y, m, d = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d (secs / 3600) (secs mod 3600 / 60) (secs mod 60)

let to_unix t = t
let compare = Int.compare
