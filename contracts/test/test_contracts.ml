open! Core
open Hardcaml
open Pemu_contracts
module MC = Mon_circuit
module MSim = Cyclesim.With_interface (MC.I) (MC.O)
module SSim = Cyclesim.With_interface (Pemu_spec.Spec_circuit.I) (Pemu_spec.Spec_circuit.O)

let%expect_test "text view and compiled sizes of the spike contract (d = 4)" =
  let c = Library.uart_tx_v01 ~d:4 () in
  print_string (Contract.to_text c);
  let p = Program.compile c in
  Array.iter p.watchers ~f:(fun w ->
    printf "%s: %d instructions\n" w.wname (Array.length w.instrs));
  printf "counter width %d, max window %d\n" (MC.count_width p) (Program.max_window p);
  [%expect {|
    contract uart_tx_v01_d4 clock 50000000
      out tx = uo[0]
      in run = ui[7]
      in d0 = uio[0]
      watcher host_run base 0x80 {
        await run idle
        await !run idle
        raise blame 1
      }
      watcher frame base 0x10 {
        await run idle
        hold tx for 1 else fail 1
        loop {
          await !tx idle
          hold !tx for 3 else fail 2
          repeat 8 {
            skip 1
            hold stable tx for 3 else fail 3
          }
          hold tx for 4 else fail 4
        }
      }
      watcher progress base 0x20 {
        await run idle
        await fall tx within [1, 5] else fail 1
        loop {
          skip 39
          await fall tx within [1, 5] else fail 2
        }
      }
    end
    host_run: 2 instructions
    frame: 21 instructions
    progress: 4 instructions
    counter width 6, max window 39
    |}]
;;

let%expect_test "role rules WF1/WF2 are enforced" =
  let open Contract in
  let bad =
    { name = "bad"
    ; clock_hz = 1
    ; observables = [ "tx", Uo 0; "rx", Ui 0 ]
    ; watchers =
        [ watcher "w" ~base:0 [ hold (v "rx") ~for_:1 ~else_:(fail 1) ]
        ; watcher "u" ~base:8 [ hold (v "tx") ~for_:1 ~else_:(blame 1) ]
        ]
    }
  in
  (match validate bad with
   | Ok () -> print_endline "accepted"
   | Error es -> List.iter es ~f:print_endline);
  [%expect {|
    w: fail check requires environment observable rx (WF1)
    u: blame check requires chip observable tx (WF2)
    |}]
;;

(* ---- lockstep harness: spec core (optional) + interpreter + hardwired + engine ---- *)
type stim =
  { rst : bool
  ; ui : int
  ; uio : int
  ; uo_override : int option (* None: take uo_out from the spec core *)
  }

let run ?(d = 4) ~contract stims =
  let p = Program.compile contract in
  let interp = Interp.create contract in
  let hw = MSim.create (MC.Hardwired.create p) in
  let en = MSim.create (Engine.create_rom p) in
  let spec =
    SSim.create
      (Pemu_spec.Spec_circuit.create
         ~rom:(Pemu_spec.Isa.assemble (Pemu_spec.Programs.uart_tx ~d)))
  in
  let si = Cyclesim.inputs spec
  and so = Cyclesim.outputs ~clock_edge:Before spec in
  let sims = [ hw; en ] in
  let mismatches = ref 0
  and first_mismatch = ref None
  and events = ref [] in
  List.iteri stims ~f:(fun cyc s ->
    si.rst_sync_n := Bits.of_bool (not s.rst);
    si.ui_in := Bits.of_int ~width:8 s.ui;
    si.uio_in := Bits.of_int ~width:8 s.uio;
    Cyclesim.cycle spec;
    (* uo_out is registered: its pre-edge value is the value driven during this cycle *)
    let uo = Option.value s.uo_override ~default:(Bits.to_int !(so.uo_out)) in
    let pins =
      { Interp.rst_sync_n = not s.rst
      ; ui_in = s.ui
      ; uio_in = s.uio
      ; uo_out = uo
      ; uio_out = 0
      ; uio_oe = 0
      }
    in
    let vi = Interp.step interp pins in
    let outs =
      List.map sims ~f:(fun sim ->
        let i = Cyclesim.inputs sim
        and o = Cyclesim.outputs ~clock_edge:Before sim in
        i.rst_sync_n := Bits.of_bool (not s.rst);
        i.ui_in := Bits.of_int ~width:8 s.ui;
        i.uio_in := Bits.of_int ~width:8 s.uio;
        i.uo_out := Bits.of_int ~width:8 uo;
        i.uio_out := Bits.zero 8;
        i.uio_oe := Bits.zero 8;
        Cyclesim.cycle sim;
        let b x = Bits.to_bool !x in
        { Interp.fail_now = b o.fail_now
        ; blame_now = b o.blame_now
        ; fail_flag = b o.fail_flag
        ; blame_flag = b o.blame_flag
        ; first_fail =
            (if b o.first_fail_valid then Some (Bits.to_int !(o.first_fail)) else None)
        ; first_blame =
            (if b o.first_blame_valid then Some (Bits.to_int !(o.first_blame)) else None)
        })
    in
    List.iter outs ~f:(fun vo ->
      if not (Interp.equal_verdict vi vo)
      then (
        incr mismatches;
        if Option.is_none !first_mismatch then first_mismatch := Some cyc));
    if vi.fail_now then events := (cyc, "fail", vi.first_fail) :: !events;
    if vi.blame_now then events := (cyc, "blame", vi.first_blame) :: !events);
  !mismatches, !first_mismatch, List.rev !events
;;

let show (mm, first, events) =
  printf
    "mismatches=%d first=%s events=[%s]\n"
    mm
    (Option.value_map first ~default:"-" ~f:Int.to_string)
    (String.concat
       ~sep:"; "
       (List.map events ~f:(fun (c, r, code) ->
          sprintf "%d:%s:%s" c r (Option.value_map code ~default:"?" ~f:(sprintf "0x%02x")))))
;;

let steady n ~ui = List.init n ~f:(fun _ -> { rst = false; ui; uio = 0x5a; uo_override = None })

let%expect_test "spec core under the contract: RUN high is clean; RUN drop blames first" =
  let c = Library.uart_tx_v01 ~d:4 () in
  let reset = List.init 3 ~f:(fun _ -> { rst = true; ui = 0; uio = 0; uo_override = None }) in
  show (run ~contract:c (reset @ steady 1500 ~ui:0x80));
  show (run ~contract:c (reset @ steady 100 ~ui:0x80 @ steady 60 ~ui:0x00));
  let no_assume = Library.uart_tx_v01 ~with_assumption:false ~d:4 () in
  show (run ~contract:no_assume (reset @ steady 100 ~ui:0x80 @ steady 60 ~ui:0x00));
  let bad_prog_contract = Library.uart_tx_v01 ~d:3 () in
  show (run ~d:4 ~contract:bad_prog_contract (reset @ steady 200 ~ui:0x80));
  [%expect {|
    mismatches=0 first=- events=[]
    mismatches=0 first=- events=[105:blame:0x81; 106:fail:0x13; 139:fail:0x13]
    mismatches=0 first=- events=[106:fail:0x13; 139:fail:0x13]
    mismatches=0 first=- events=[17:fail:0x13; 75:fail:0x13]
    |}]
;;

let%expect_test "differential: interpreter == hardwired == engine on random traces" =
  let rng = Random.State.make [| 2026; 10; 17 |] in
  let gen ~random_tx n =
    List.init n ~f:(fun _ ->
      let r = Random.State.int rng 1000 in
      { rst = r < 4
      ; ui = (if Random.State.int rng 100 < 97 then 0x80 else 0x00) lor Random.State.int rng 0x80
      ; uio = Random.State.int rng 256
      ; uo_override =
          (if random_tx then Some (if Random.State.int rng 10 < 7 then 1 else 0) else None)
      })
  in
  List.iter
    [ Library.uart_tx_v01 ~d:4 ()
    ; Library.uart_tx_v01 ~d:3 ()
    ; Library.uart_tx_v01 ~blame_delay:2 ~overstrong:true ~d:4 ()
    ]
    ~f:(fun c ->
      List.iter [ false; true ] ~f:(fun random_tx ->
        let mm, first, ev = run ~contract:c (gen ~random_tx 20_000) in
        let count r = List.count ev ~f:(fun (_, r', _) -> String.equal r r') in
        printf
          "%s random_tx=%b mismatches=%d first=%s fails=%d blames=%d\n"
          c.name
          random_tx
          mm
          (Option.value_map first ~default:"-" ~f:Int.to_string)
          (count "fail")
          (count "blame")));
  [%expect {|
    uart_tx_v01_d4 random_tx=false mismatches=0 first=- fails=138 blames=77
    uart_tx_v01_d4 random_tx=true mismatches=0 first=- fails=147 blames=78
    uart_tx_v01_d3 random_tx=false mismatches=0 first=- fails=134 blames=71
    uart_tx_v01_d3 random_tx=true mismatches=0 first=- fails=98 blames=54
    uart_tx_v01_d4 random_tx=false mismatches=0 first=- fails=128 blames=146
    uart_tx_v01_d4 random_tx=true mismatches=0 first=- fails=148 blames=175
    |}]
;;
