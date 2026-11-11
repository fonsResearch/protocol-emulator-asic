(* Contract compiler front end for the tape-out library (doc/toolchain.md section 3).
   Packages are named by ROM index, by name, or as a variant of a Library_v1 family
   ("family:k=v,..."). [retune] decides whether a variant can run on a ROM package through the
   option-D window override (interface v2.1, monitor_isa_v1.md section 8): only if the variant
   compiles to the ROM package's tables in every field except the window values. *)
open! Core
module L = Pemu_monitor_v1.Lang
module Lib = Pemu_monitor_v1.Library_v1
module C = Pemu_monitor_v1.Compile
module M = Pemu_monitor_v1.Mprog
module R = Pemu_rtl_v1.Rom_lib

(* tape-out configuration (v2-inc5-usb): 5 slots, lane_pipe, param_windows, 30 MHz *)
let slots = 5
let clock_hz = R.v2_clock_hz

(* ROM-mode admission on the tape-out build (Mon_engine, lane_pipe): RUN only if P >= slots.
   Rom_lib.admissibility_violations checks the unpipelined rule P >= slots - 1. *)
let min_p = slots
let rom () = List.mapi (R.v2_inc5_with_p ()) ~f:(fun i (c, p) -> i, c, p)

let families =
  [ "uart_tx", [ "d"; "pin" ]; "uart_rx", [ "d"; "m"; "pin" ]; "spi_ctl", [ "cpol"; "cpha"; "h" ]
  ; "spi_tgt", [ "cpol"; "cpha"; "h_min"; "g" ]; "i2c_ctl", [ "l"; "h"; "tsu"; "thold" ]
  ; "i2c_tgt", [ "h_min"; "l_min"; "hd" ]; "usb_ls_tx", [] ]
;;

let parse_variant s : (L.t, string) Result.t =
  let fam, args = match String.lsplit2 s ~on:':' with Some (f, a) -> f, a | None -> s, "" in
  match List.Assoc.find families ~equal:String.equal fam with
  | None -> Error (sprintf "unknown family %S (known: %s)" fam (String.concat ~sep:" " (List.map families ~f:fst)))
  | Some keys ->
    let kv =
      if String.is_empty (String.strip args)
      then []
      else
        List.map (String.split args ~on:',') ~f:(fun x ->
          match String.lsplit2 x ~on:'=' with
          | Some (k, v) -> String.strip k, String.strip v
          | None -> String.strip x, "")
    in
    (match List.find kv ~f:(fun (k, _) -> not (List.mem keys k ~equal:String.equal)) with
     | Some (k, _) -> Error (sprintf "%s: unknown parameter %S (parameters: %s)" fam k (String.concat ~sep:" " keys))
     | None ->
       (match List.find keys ~f:(fun k -> not (List.Assoc.mem kv ~equal:String.equal k)) with
        | Some k -> Error (sprintf "%s: missing parameter %s=" fam k)
        | None ->
          let int k =
            let v = List.Assoc.find_exn kv ~equal:String.equal k in
            match Int.of_string_opt v with
            | Some i -> i
            | None -> failwithf "%s: %s=%s is not an integer" fam k v ()
          in
          let bool k = int k <> 0 in
          (try
             Ok
               (match fam with
                | "uart_tx" -> Lib.uart_tx ~d:(int "d") ~pin:(int "pin")
                | "uart_rx" -> Lib.uart_rx ~d:(int "d") ~m:(int "m") ~pin:(int "pin")
                | "spi_ctl" -> Lib.spi_ctl ~cpol:(bool "cpol") ~cpha:(bool "cpha") ~h:(int "h")
                | "spi_tgt" -> Lib.spi_tgt ~cpol:(bool "cpol") ~cpha:(bool "cpha") ~h_min:(int "h_min") ~g:(int "g")
                | "i2c_ctl" -> Lib.i2c_ctl ~l:(int "l") ~h:(int "h") ~tsu:(int "tsu") ~thold:(int "thold")
                | "i2c_tgt" -> Lib.i2c_tgt ~h_min:(int "h_min") ~l_min:(int "l_min") ~hd:(int "hd")
                | _ -> Lib.usb_ls_tx ())
           with
           | e -> Error (Exn.to_string e))))
;;

(* a package argument: ROM index, ROM package name, or variant *)
let resolve s : (L.t * int option, string) Result.t =
  let r = rom () in
  match Int.of_string_opt s with
  | Some i ->
    (match List.find r ~f:(fun (k, _, _) -> k = i) with
     | Some (_, c, p) -> Ok (c, Some p)
     | None -> Error (sprintf "no ROM package %d (0..%d)" i (List.length r - 1)))
  | None ->
    (match List.find r ~f:(fun (_, c, _) -> String.equal c.L.name s) with
     | Some (_, c, p) -> Ok (c, Some p)
     | None -> Result.map (parse_variant s) ~f:(fun c -> c, None))
;;

let compile c : (M.t, string) Result.t =
  match L.validate c with
  | Error es -> Error ("validate: " ^ String.concat ~sep:"; " es)
  | Ok c -> (match C.compile c with Ok m -> Ok m | Error e -> Error ("compile: " ^ e))
;;

let role_s : L.role -> string = function Fail -> "F" | Blame -> "B"

let summary ?p (m : M.t) =
  let units = Array.length m.units in
  let codes = Array.to_list m.codes |> List.filter_opt |> List.map ~f:(fun (r, k) -> sprintf "%s%02X" (role_s r) k) in
  let instrs = Array.sum (module Int) m.units ~f:(fun u -> Array.length u.code) in
  let adm =
    match p with
    | None -> "P not given"
    | Some p ->
      if units > slots
      then sprintf "NOT ADMISSIBLE: %d units > %d slots" units slots
      else if p < min_p
      then sprintf "NOT ADMISSIBLE: P %d < %d (lane_pipe rule P >= slots)" p min_p
      else sprintf "admissible at P %d (rule P >= %d, units %d <= %d slots)" p min_p units slots
  in
  [ sprintf "package   %s" m.name
  ; sprintf "units     %d (%d instructions)" units instrs
  ; sprintf "preds     %d of 14" (Array.count m.preds ~f:(fun x -> not (M.equal_pred x M.pred_true || M.equal_pred x M.pred_false)))
  ; sprintf "windows   %s" (String.concat ~sep:" " (List.map (List.tl_exn (Array.to_list m.windows)) ~f:Int.to_string))
  ; sprintf "codes     %s" (String.concat ~sep:" " codes)
  ; sprintf "remap     %s" (String.concat ~sep:" " (Array.to_list (Array.map m.remap ~f:Int.to_string)))
  ; sprintf "admission %s" adm ]
;;

(* window equivalence: equal tables after replacing the window values *)
let retune ~rom_index variant : (int array, string) Result.t =
  let open Result.Let_syntax in
  let%bind rc, _ = resolve (Int.to_string rom_index) in
  let%bind rm = compile rc in
  let%bind vm = compile variant in
  let same_but_windows = M.equal { vm with windows = rm.windows; name = rm.name } rm in
  let w12 = Array.for_all vm.windows ~f:(fun w -> w >= 0 && w < 4096) in
  if not same_but_windows
  then (
    let diff =
      List.filter_map
        [ "remap", [%equal: int array] vm.remap rm.remap; "preds", [%equal: M.pred array] vm.preds rm.preds
        ; "codes", [%equal: (L.role * int) option array] vm.codes rm.codes
        ; "units", [%equal: M.unit_prog array] vm.units rm.units ]
        ~f:(fun (n, eq) -> if eq then None else Some n)
    in
    Error
      (sprintf "%s is not window-equivalent to ROM %d (%s): differs in %s" variant.L.name rom_index rm.name
         (String.concat ~sep:", " diff)))
  else if not w12
  then Error "a window value does not fit the 12-bit window registers"
  else Ok vm.windows
;;
