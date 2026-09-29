type t =
  | Null
  | Bool of bool
  | Number of string
  | String of string
  | Array of t list
  | Object of (string * t) list

type parse_error = { offset : int; message : string }

exception Parse_failure of int * string

(* ---------- parsing ---------- *)

let parse ?(max_depth = 64) (src : string) : (t, parse_error) result =
  let len = String.length src in
  let pos = ref 0 in
  let fail msg = raise (Parse_failure (!pos, msg)) in
  let peek () = if !pos < len then Some src.[!pos] else None in
  let advance () = incr pos in
  let rec skip_ws () =
    match peek () with
    | Some (' ' | '\t' | '\n' | '\r') ->
        advance ();
        skip_ws ()
    | _ -> ()
  in
  let expect c =
    match peek () with
    | Some c' when c' = c -> advance ()
    | Some c' -> fail (Printf.sprintf "expected '%c' but found '%c'" c c')
    | None -> fail (Printf.sprintf "expected '%c' but reached end of input" c)
  in
  let literal word v =
    let n = String.length word in
    if !pos + n <= len && String.sub src !pos n = word then (
      pos := !pos + n;
      v)
    else fail "invalid literal"
  in
  let buf = Buffer.create 64 in
  let add_utf8 cp =
    if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
    else if cp < 0x800 then (
      Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))
    else if cp < 0x10000 then (
      Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))
    else (
      Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))
  in
  let hex4 () =
    if !pos + 4 > len then fail "truncated \\u escape";
    let v = ref 0 in
    for i = 0 to 3 do
      let d =
        match src.[!pos + i] with
        | '0' .. '9' as c -> Char.code c - 48
        | 'a' .. 'f' as c -> Char.code c - 87
        | 'A' .. 'F' as c -> Char.code c - 55
        | _ -> fail "invalid hex digit in \\u escape"
      in
      v := (!v lsl 4) lor d
    done;
    pos := !pos + 4;
    !v
  in
  (* Copies one raw (unescaped) UTF-8 sequence, validating it. *)
  let copy_utf8 () =
    let b0 = Char.code src.[!pos] in
    let need, min_cp =
      if b0 < 0x80 then (0, 0)
      else if b0 land 0xE0 = 0xC0 then (1, 0x80)
      else if b0 land 0xF0 = 0xE0 then (2, 0x800)
      else if b0 land 0xF8 = 0xF0 then (3, 0x10000)
      else fail "invalid UTF-8 lead byte"
    in
    if !pos + need >= len && need > 0 then fail "truncated UTF-8 sequence";
    let cp = ref (if need = 0 then b0 else b0 land (0x3F lsr need)) in
    for i = 1 to need do
      let b = Char.code src.[!pos + i] in
      if b land 0xC0 <> 0x80 then fail "invalid UTF-8 continuation byte";
      cp := (!cp lsl 6) lor (b land 0x3F)
    done;
    if !cp < min_cp then fail "overlong UTF-8 encoding";
    if !cp >= 0xD800 && !cp <= 0xDFFF then fail "UTF-8 encoded surrogate";
    if !cp > 0x10FFFF then fail "code point out of range";
    Buffer.add_string buf (String.sub src !pos (need + 1));
    pos := !pos + need + 1
  in
  let parse_string () =
    expect '"';
    Buffer.clear buf;
    let rec loop () =
      match peek () with
      | None -> fail "unterminated string"
      | Some '"' -> advance ()
      | Some '\\' ->
          advance ();
          (match peek () with
          | Some '"' -> Buffer.add_char buf '"'; advance ()
          | Some '\\' -> Buffer.add_char buf '\\'; advance ()
          | Some '/' -> Buffer.add_char buf '/'; advance ()
          | Some 'b' -> Buffer.add_char buf '\b'; advance ()
          | Some 'f' -> Buffer.add_char buf '\012'; advance ()
          | Some 'n' -> Buffer.add_char buf '\n'; advance ()
          | Some 'r' -> Buffer.add_char buf '\r'; advance ()
          | Some 't' -> Buffer.add_char buf '\t'; advance ()
          | Some 'u' ->
              advance ();
              let hi = hex4 () in
              if hi >= 0xD800 && hi <= 0xDBFF then (
                if !pos + 1 < len && src.[!pos] = '\\' && src.[!pos + 1] = 'u'
                then (
                  pos := !pos + 2;
                  let lo = hex4 () in
                  if lo < 0xDC00 || lo > 0xDFFF then fail "invalid low surrogate";
                  add_utf8 (0x10000 + ((hi - 0xD800) lsl 10) + (lo - 0xDC00)))
                else fail "lone high surrogate")
              else if hi >= 0xDC00 && hi <= 0xDFFF then fail "lone low surrogate"
              else add_utf8 hi
          | _ -> fail "invalid escape");
          loop ()
      | Some c when Char.code c < 0x20 -> fail "unescaped control character in string"
      | Some _ ->
          copy_utf8 ();
          loop ()
    in
    loop ();
    Buffer.contents buf
  in
  let parse_number () =
    let start = !pos in
    let digits () =
      let s = !pos in
      while match peek () with Some '0' .. '9' -> true | _ -> false do advance () done;
      if !pos = s then fail "expected digit"
    in
    if peek () = Some '-' then advance ();
    (match peek () with
    | Some '0' -> advance ()
    | Some '1' .. '9' -> digits ()
    | _ -> fail "invalid number");
    if peek () = Some '.' then (advance (); digits ());
    (match peek () with
    | Some ('e' | 'E') ->
        advance ();
        (match peek () with Some ('+' | '-') -> advance () | _ -> ());
        digits ()
    | _ -> ());
    Number (String.sub src start (!pos - start))
  in
  let rec parse_value depth =
    if depth > max_depth then fail "maximum nesting depth exceeded";
    skip_ws ();
    match peek () with
    | None -> fail "unexpected end of input"
    | Some '{' ->
        advance ();
        skip_ws ();
        if peek () = Some '}' then (advance (); Object [])
        else
          let rec members acc seen =
            skip_ws ();
            let key_offset = !pos in
            let key = parse_string () in
            if List.mem key seen then
              raise (Parse_failure (key_offset, Printf.sprintf "duplicate key %S" key));
            skip_ws ();
            expect ':';
            let v = parse_value (depth + 1) in
            skip_ws ();
            match peek () with
            | Some ',' -> advance (); members ((key, v) :: acc) (key :: seen)
            | Some '}' -> advance (); Object (List.rev ((key, v) :: acc))
            | _ -> fail "expected ',' or '}' in object"
          in
          members [] []
    | Some '[' ->
        advance ();
        skip_ws ();
        if peek () = Some ']' then (advance (); Array [])
        else
          let rec items acc =
            let v = parse_value (depth + 1) in
            skip_ws ();
            match peek () with
            | Some ',' -> advance (); items (v :: acc)
            | Some ']' -> advance (); Array (List.rev (v :: acc))
            | _ -> fail "expected ',' or ']' in array"
          in
          items []
    | Some '"' -> String (parse_string ())
    | Some 't' -> literal "true" (Bool true)
    | Some 'f' -> literal "false" (Bool false)
    | Some 'n' -> literal "null" Null
    | Some ('-' | '0' .. '9') -> parse_number ()
    | Some c -> fail (Printf.sprintf "unexpected character '%c'" c)
  in
  match
    let v = parse_value 0 in
    skip_ws ();
    if !pos <> len then fail "trailing characters after JSON value";
    v
  with
  | v -> Ok v
  | exception Parse_failure (offset, message) -> Error { offset; message }

(* ---------- printing ---------- *)

let escape_to buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

let to_string v =
  let buf = Buffer.create 256 in
  let rec go = function
    | Null -> Buffer.add_string buf "null"
    | Bool b -> Buffer.add_string buf (if b then "true" else "false")
    | Number n -> Buffer.add_string buf n
    | String s -> escape_to buf s
    | Array xs ->
        Buffer.add_char buf '[';
        List.iteri (fun i x -> if i > 0 then Buffer.add_char buf ','; go x) xs;
        Buffer.add_char buf ']'
    | Object kvs ->
        Buffer.add_char buf '{';
        List.iteri
          (fun i (k, x) ->
            if i > 0 then Buffer.add_char buf ',';
            escape_to buf k;
            Buffer.add_char buf ':';
            go x)
          kvs;
        Buffer.add_char buf '}'
  in
  go v;
  Buffer.contents buf

let to_string_pretty v =
  let buf = Buffer.create 256 in
  let indent n = Buffer.add_string buf (String.make (2 * n) ' ') in
  let rec go d = function
    | (Null | Bool _ | Number _ | String _) as scalar -> Buffer.add_string buf (to_string scalar)
    | Array [] -> Buffer.add_string buf "[]"
    | Object [] -> Buffer.add_string buf "{}"
    | Array xs ->
        Buffer.add_string buf "[\n";
        List.iteri
          (fun i x ->
            if i > 0 then Buffer.add_string buf ",\n";
            indent (d + 1);
            go (d + 1) x)
          xs;
        Buffer.add_char buf '\n';
        indent d;
        Buffer.add_char buf ']'
    | Object kvs ->
        Buffer.add_string buf "{\n";
        List.iteri
          (fun i (k, x) ->
            if i > 0 then Buffer.add_string buf ",\n";
            indent (d + 1);
            escape_to buf k;
            Buffer.add_string buf ": ";
            go (d + 1) x)
          kvs;
        Buffer.add_char buf '\n';
        indent d;
        Buffer.add_char buf '}'
  in
  go 0 v;
  Buffer.contents buf

(* ---------- decoding ---------- *)

module Decode = struct
  type error = { path : string; message : string }
  type 'a r = ('a, error) result
  type cursor = { path : string; value : t }

  let root value = { path = "$"; value }
  let path c = c.path
  let value c = c.value
  let fail c message = Error { path = c.path; message }
  let ( let* ) = Result.bind
  let ( let+ ) r f = Result.map f r

  let kind = function
    | Null -> "null"
    | Bool _ -> "boolean"
    | Number _ -> "number"
    | String _ -> "string"
    | Array _ -> "array"
    | Object _ -> "object"

  let expected c what = fail c (Printf.sprintf "expected %s, found %s" what (kind c.value))

  let obj ?allowed c =
    match c.value with
    | Object kvs ->
        let unknown =
          match allowed with
          | None -> None
          | Some keys -> List.find_opt (fun (k, _) -> not (List.mem k keys)) kvs
        in
        (match unknown with
        | Some (k, _) -> fail c (Printf.sprintf "unknown field %S" k)
        | None -> Ok (List.map (fun (k, v) -> (k, { path = c.path ^ "." ^ k; value = v })) kvs))
    | _ -> expected c "object"

  let field name c =
    match c.value with
    | Object kvs -> (
        match List.assoc_opt name kvs with
        | Some v -> Ok { path = c.path ^ "." ^ name; value = v }
        | None -> fail c (Printf.sprintf "missing required field %S" name))
    | _ -> expected c "object"

  let field_opt name c =
    match c.value with
    | Object kvs -> (
        match List.assoc_opt name kvs with
        | None | Some Null -> Ok None
        | Some v -> Ok (Some { path = c.path ^ "." ^ name; value = v }))
    | _ -> expected c "object"

  let string c = match c.value with String s -> Ok s | _ -> expected c "string"
  let bool c = match c.value with Bool b -> Ok b | _ -> expected c "boolean"

  let int c =
    match c.value with
    | Number n
      when String.for_all (fun ch -> (ch >= '0' && ch <= '9') || ch = '-') n -> (
        match int_of_string_opt n with
        | Some i -> Ok i
        | None -> fail c "integer out of range")
    | Number _ -> fail c "expected an integer"
    | _ -> expected c "number"

  let list c =
    match c.value with
    | Array xs -> Ok (List.mapi (fun i v -> { path = Printf.sprintf "%s[%d]" c.path i; value = v }) xs)
    | _ -> expected c "array"

  let map_list f c =
    let* items = list c in
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | x :: rest ->
          let* y = f x in
          go (y :: acc) rest
    in
    go [] items
end

let obj kvs = Object kvs
let str s = String s
let int i = Number (string_of_int i)
let list f xs = Array (List.map f xs)
let opt f = function None -> Null | Some x -> f x
