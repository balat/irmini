type algorithm = Sha1 | Sha256

type _ t =
  | Sha1_hash : string -> [ `Sha1 ] t
  | Sha256_hash : string -> [ `Sha256 ] t

type sha1 = [ `Sha1 ] t
type sha256 = [ `Sha256 ] t

let sha1 data = Sha1_hash Digestif.SHA1.(to_raw_string (digest_string data))

let sha256 data =
  Sha256_hash Digestif.SHA256.(to_raw_string (digest_string data))

let sha1_of_bytes raw =
  if String.length raw <> 20 then
    invalid_arg "Hash.sha1_of_bytes: expected 20 bytes";
  Sha1_hash raw

let sha256_of_bytes raw =
  if String.length raw <> 32 then
    invalid_arg "Hash.sha256_of_bytes: expected 32 bytes";
  Sha256_hash raw

let to_bytes : type a. a t -> string = function
  | Sha1_hash s -> s
  | Sha256_hash s -> s

let to_hex h =
  let bytes = to_bytes h in
  let buf = Buffer.create (String.length bytes * 2) in
  String.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    bytes;
  Buffer.contents buf

let hex_to_bytes hex =
  let len = String.length hex in
  if len mod 2 <> 0 then Error (`Msg "hex string has odd length")
  else
    let bytes = Bytes.create (len / 2) in
    let rec loop i =
      if i >= len then Ok (Bytes.to_string bytes)
      else
        let hi = hex.[i] and lo = hex.[i + 1] in
        let decode c =
          match c with
          | '0' .. '9' -> Some (Char.code c - Char.code '0')
          | 'a' .. 'f' -> Some (Char.code c - Char.code 'a' + 10)
          | 'A' .. 'F' -> Some (Char.code c - Char.code 'A' + 10)
          | _ -> None
        in
        match (decode hi, decode lo) with
        | Some h, Some l ->
            Bytes.set bytes (i / 2) (Char.chr ((h lsl 4) lor l));
            loop (i + 2)
        | _ ->
            Error
              (`Msg (Printf.sprintf "invalid hex character at position %d" i))
    in
    loop 0

let sha1_of_hex hex =
  match hex_to_bytes hex with
  | Error _ as e -> e
  | Ok bytes ->
      if String.length bytes <> 20 then
        Error (`Msg "SHA-1 hex must be 40 characters")
      else Ok (Sha1_hash bytes)

let sha256_of_hex hex =
  match hex_to_bytes hex with
  | Error _ as e -> e
  | Ok bytes ->
      if String.length bytes <> 32 then
        Error (`Msg "SHA-256 hex must be 64 characters")
      else Ok (Sha256_hash bytes)

type existential = Ex : _ t -> existential

let of_hex algo hex : (existential, _) result =
  match algo with
  | Sha1 -> Result.map (fun h -> Ex h) (sha1_of_hex hex)
  | Sha256 -> Result.map (fun h -> Ex h) (sha256_of_hex hex)

let equal : type a. a t -> a t -> bool =
 fun h1 h2 -> String.equal (to_bytes h1) (to_bytes h2)

let compare : type a. a t -> a t -> int =
 fun h1 h2 -> String.compare (to_bytes h1) (to_bytes h2)

let length : type a. a t -> int = function
  | Sha1_hash _ -> 20
  | Sha256_hash _ -> 32

let algorithm_of : type a. a t -> algorithm = function
  | Sha1_hash _ -> Sha1
  | Sha256_hash _ -> Sha256

let algorithm_length = function Sha1 -> 20 | Sha256 -> 32

let mst_depth (Sha256_hash bytes) =
  let rec count_zeros i acc =
    if i >= 32 then acc
    else
      let byte = Char.code bytes.[i] in
      let hi = (byte lsr 6) land 0x3 in
      let mid_hi = (byte lsr 4) land 0x3 in
      let mid_lo = (byte lsr 2) land 0x3 in
      let lo = byte land 0x3 in
      if hi <> 0 then acc
      else if mid_hi <> 0 then acc + 1
      else if mid_lo <> 0 then acc + 2
      else if lo <> 0 then acc + 3
      else count_zeros (i + 1) (acc + 4)
  in
  count_zeros 0 0

type any = Any : _ t -> any

let any_algorithm (Any h) = algorithm_of h
let any_to_bytes (Any h) = to_bytes h
let any_to_hex (Any h) = to_hex h
let pp fmt h = Format.fprintf fmt "%s" (to_hex h)

let pp_short fmt h =
  let hex = to_hex h in
  Format.fprintf fmt "%s" (String.sub hex 0 (min 7 (String.length hex)))
