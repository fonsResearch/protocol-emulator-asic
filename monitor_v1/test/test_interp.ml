(* Language v1 reference interpreter against the lane reference model running the UART TX
   reference program: no fail on the correct program over random bytes, divisors and RUN
   drops; each defective program variant fails with the expected code. *)
open! Core
open Pemu_monitor_v1
open Pemu_spec_v1

let run_lane ~prog ~d ~seed ~cycles =
  let st = Random.State.make [| seed |] in
  let p = Random.State.int st 4 in
  let words = Isa1.assemble prog in
  let lane = Lane_model.create words in
  let mon = Interp.create (Library_v1.uart_tx ~d ~pin:0) in
  let cnt = ref 0 and prev_running = ref false in
  let fired = ref [] and pops = ref 0 in
  for c = 0 to cycles - 1 do
    let r n = Random.State.int st n in
    let rst = c > 0 in
    let run = r 5000 <> 0 in
    (* the lane runs if RUN and loaded and not faulted; the model resets on halt *)
    let running = rst && run in
    if not (running && !prev_running) then cnt := 0;
    let tick = running && !cnt = p in
    let inp : Lane_model.inputs =
      { rst_sync_n = rst; tick; run; loaded = true; len = List.length prog; own = 1; od = 0
      ; cfg = 0; cfg2 = 0; pins = 0; tx_push = r 30 = 0; tx_wdata = r 256; rx_pop = false
      ; blame_in = false; clear_fault = false }
    in
    let o = Lane_model.step lane inp in
    if o.pop_ev then incr pops;
    let f =
      Interp.step
        mon
        { rst_sync_n = rst; running; tick; ui_in = 0; uio_in = 0; uo_out = 0
        ; uio_out = o.uio_out; uio_oe = o.uio_oe; pop_ev = o.pop_ev; pop_data = o.pop_data
        ; push_ev = o.push_ev; push_data = o.push_data }
    in
    fired := List.rev_append f !fired;
    (* prescaler: counter held at 0 while not running *)
    cnt := if running then if tick then 0 else !cnt + 1 else 0;
    prev_running := running
  done;
  List.rev !fired, !pops
;;

let summary ~prog ~d =
  let firings = ref [] and pops = ref 0 in
  for seed = 1 to 40 do
    let f, p = run_lane ~prog ~d ~seed ~cycles:6000 in
    pops := !pops + p;
    firings := f @ !firings
  done;
  let codes =
    List.map !firings ~f:(fun (r, c) -> sprintf "%s 0x%02X" (match r with Lang.Fail -> "fail" | Blame -> "blame") c)
    |> List.dedup_and_sort ~compare:String.compare
  in
  sprintf "frames %s, firings %d %s" (if !pops > 500 then ">500" else Int.to_string !pops)
    (List.length !firings) (String.concat ~sep:", " codes)
;;

let%expect_test "UART TX v1 contract vs lane model" =
  let d = 4 in
  let good = Programs_v1.uart_tx ~d in
  let replace k ins = List.mapi good ~f:(fun i x -> if i = k then ins else x) in
  List.iter
    [ "correct", good
    ; "start bit d+1", Programs_v1.uart_tx_bad_start ~d
    ; "MSB first", replace 6 (Isa1.Pin (0, Out_msb))
    ; "stop bit d-1", replace 10 (Isa1.Wait (d - 3)) ]
    ~f:(fun (name, prog) -> printf "%-14s %s\n" name (summary ~prog ~d));
  [%expect {|
    correct        frames >500, firings 0
    start bit d+1  frames >500, firings 76 fail 0x13, fail 0x14, fail 0x15, fail 0x16, fail 0x17, fail 0x1A
    MSB first      frames >500, firings 76 fail 0x13, fail 0x14, fail 0x15, fail 0x16
    stop bit d-1   frames >500, firings 74 fail 0x21
    |}]
;;
