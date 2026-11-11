(* 1-Wire contract on hand-made step traces (before the firmware exists): validate, compile, fit,
   and the reference interpreter's firings on legal and illegal waveforms. *)
open! Core
module L = Pemu_monitor_v1.Lang
module I = Pemu_monitor_v1.Interp
module C = Pemu_monitor_v1.Compile
module Mm = Pemu_monitor_v1.Mmodel

let c = Pemu_flex_v2.Flex_lib.onewire_ctl ()

let%expect_test "validate, compile, monitor-ISA fit" =
  (match L.validate c with
   | Ok _ -> print_endline "validate ok"
   | Error es -> List.iter es ~f:print_endline);
  (match C.compile c with
   | Ok m ->
     printf "units %d, instructions %d, windows [%s], codes %d\n" (Array.length m.units)
       (Array.sum (module Int) m.units ~f:(fun u -> Array.length u.code))
       (String.concat ~sep:" " (List.map (Array.to_list m.windows) ~f:Int.to_string))
       (Array.count m.codes ~f:Option.is_some)
   | Error e -> printf "compile: %s\n" e);
  [%expect {|
    validate ok
    units 2, instructions 20, windows [0 13 47 58 2 361 480 61], codes 9
    |}]
;;

(* a step trace: list of (steps, drv, line); every step is a tick of a running lane *)
let run segs =
  let t0 = I.create c in
  (* every input goes to the interpreter and to the compiled program on the monitor model *)
  let mm = Mm.create (Result.ok_or_failwith (C.compile c)) and mism = ref 0 in
  let module I = struct
    include I

    let step (_ : I.t) i =
      let fa = I.step t0 i and fb = Mm.step mm i in
      if not ([%equal: (L.role * int) list] fa fb) then incr mism;
      fa
    ;;
  end
  in
  let t = t0 in
  let k = ref 0 and out = ref [] in
  let step drv line =
    let mi : I.inputs =
      { rst_sync_n = true; running = true; tick = true; ui_in = 0; uio_in = (if line then 0x04 else 0); uo_out = 0
      ; uio_out = 0; uio_oe = (if drv then 0x04 else 0); pop_ev = false; pop_data = 0; push_ev = false; push_data = 0 }
    in
    List.iter (I.step t mi) ~f:(fun (r, code) ->
      out := sprintf "%s%02X@%d" (match r with L.Fail -> "F" | Blame -> "B") code !k :: !out);
    incr k
  in
  (* the first input is a reset step so the interpreter starts cleanly *)
  ignore
    (I.step t
       { rst_sync_n = false; running = false; tick = false; ui_in = 0; uio_in = 0x04; uo_out = 0; uio_out = 0
       ; uio_oe = 0; pop_ev = false; pop_data = 0; push_ev = false; push_data = 0 }
     : (L.role * int) list);
  (* the monitor's input synchroniser settles before the lane's first step (on chip it tracks the
     pulled-up pad from reset on, long before RUN) *)
  for _ = 1 to 3 do
    ignore
      (I.step t
         { rst_sync_n = true; running = true; tick = false; ui_in = 0; uio_in = 0x04; uo_out = 0; uio_out = 0
         ; uio_oe = 0; pop_ev = false; pop_data = 0; push_ev = false; push_data = 0 }
       : (L.role * int) list)
  done;
  List.iter segs ~f:(fun (n, drv, line) -> for _ = 1 to n do step drv line done);
  let v = match List.rev !out with [] -> "clean" | l -> String.concat ~sep:"," l in
  if !mism = 0 then v else sprintf "%s  [Mmodel differs in %d steps]" v !mism
;;

(* waveform pieces (bus level = not drv and not device pull) *)
let idle n = [ n, false, true ]
let reset ?(rx_wait = 30) ?(presence = 120) ?(low = 500) () =
  [ low, true, false; rx_wait, false, true; presence, false, false; 485 - rx_wait - presence + 2, false, true ]
let w1 = [ 6, true, false; 65, false, true ]
let w0 = [ 66, true, false; 64, false, true ]
let r0 ?(hold = 30) () = [ 3, true, false; hold - 3, false, false; 71 - hold, false, true ]

let%expect_test "legal and illegal waveforms" =
  let t name segs = printf "%-28s %s\n" name (run segs) in
  t "reset, presence, w0 w1 r0" (idle 10 @ reset () @ w0 @ w1 @ r0 () @ w1 @ idle 100);
  t "write-0 too short (40)" (idle 10 @ reset () @ [ 40, true, false; 30, false, true ] @ idle 50);
  t "pull 200 (neither)" (idle 10 @ reset () @ [ 200, true, false ] @ idle 100);
  t "reset 400" (idle 10 @ [ 400, true, false ] @ idle 600);
  t "slots too close (50)" (idle 10 @ reset () @ [ 6, true, false; 44, false, true ] @ w1 @ idle 50);
  t "write-0 recovery 2" (idle 10 @ reset () @ [ 66, true, false; 2, false, true ] @ w1 @ idle 50);
  t "write-0, next pull s0+100" (idle 10 @ reset () @ [ 66, true, false; 34, false, true ] @ w1 @ idle 50);
  t "write-0 recovery 63" (idle 10 @ reset () @ [ 66, true, false; 63, false, true ] @ w1 @ idle 50);
  t "write-0 118" (idle 10 @ reset () @ [ 118, true, false; 64, false, true ] @ w1 @ idle 50);
  t "write-0 119" (idle 10 @ reset () @ [ 119, true, false; 5, false, true ] @ idle 50);
  t "pull during reset rx" (idle 10 @ [ 500, true, false; 100, false, true; 6, true, false ] @ idle 500);
  t "device spontaneous low" (idle 10 @ reset () @ idle 20 @ [ 5, false, false ] @ idle 50);
  t "presence too early (5)" (idle 10 @ reset ~rx_wait:5 () @ idle 50);
  t "no presence" (idle 10 @ [ 500, true, false ] @ idle 600);
  t "presence too short (30)" (idle 10 @ reset ~presence:30 () @ idle 50);
  t "read-0 held too long (80)" (idle 10 @ reset () @ [ 3, true, false; 80, false, false ] @ idle 100);
  [%expect {|
    reset, presence, w0 w1 r0    clean
    write-0 too short (40)       F11@1037
    pull 200 (neither)           F12@1197,B23@1260
    reset 400                    F12@410,B23@473
    slots too close (50)         F14@1047
    write-0 recovery 2           F14@1065
    write-0, next pull s0+100    F14@1097
    write-0 recovery 63          F14@1126
    write-0 118                  clean
    write-0 119                  F12@1116
    pull during reset rx         B23@573,F13@610
    device spontaneous low       B21@1019
    presence too early (5)       B22@517
    no presence                  B23@573
    presence too short (30)      B24@572
    read-0 held too long (80)    B25@1071
    |}]
;;
