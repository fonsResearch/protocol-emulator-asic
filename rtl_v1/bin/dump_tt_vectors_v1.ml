(* Wrapper-level replay vectors for core v1 (pemu_core_v1m with the all-15 ROM library, the
   tape-out build of plan step 8). The Hardcaml core runs in cyclesim with behavioural SRAMs,
   driven through its pins by a bit-banged SPI host (mode 0, SCK half period 6 cycles), behind
   a model of the wrapper's 2-flop reset synchroniser. test/test.py replays the rows on the
   Verilog wrapper with the IHP SRAM models (RTL and gate level), so the replay checks
   Verilog emission, the SRAM model agreement and the netlist, not the design itself.

   usage: dump_tt_vectors_v1.exe <out dir>
   Row format (hex, one per cycle): rst_n ui_in uio_in exp_uio_oe exp_uio_out exp_uo_out,
   with the convention of test/vectors/README.md (outputs of row c are the values after
   edge e_c; the inputs of row c are applied for edge e_{c+1}). *)
open! Core
open Hardcaml
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module Sim = Cyclesim.With_interface (Top_v1.I) (Top_v1.O)
module Psim = Pemu_protocols_v1.Psim
module Peers = Pemu_protocols_v1.Peers

type h =
  { sim : (Bits.t ref Top_v1.I.t, Bits.t ref Top_v1.O.t) Cyclesim.t
  ; mutable rst_n : bool
  ; mutable s0 : bool (* wrapper reset synchroniser rst_sync[0], rst_sync[1] *)
  ; mutable s1 : bool
  ; mutable cs_n : bool
  ; mutable sck : bool
  ; mutable mosi : bool
  ; mutable ui_hi : int
  ; mutable uio_in : int
  ; mutable miso : int
  ; rows : Buffer.t
  ; mutable n : int
  ; mutable peer : (Psim.chip_view -> Psim.peer_drive) option
      (* v2 scenarios: a protocol peer in the loop; the pad of each cycle resolves the chip's
         current drive (values after the previous edge) and the peer's drive, pull-up idle *)
  ; mutable t0 : int (* peer time origin *)
  ; mutable prev_pad : int
  }

let ui h =
  Bool.to_int h.cs_n lor (Bool.to_int h.sck lsl 1) lor (Bool.to_int h.mosi lsl 2) lor (h.ui_hi lsl 3)
;;

let cycle h =
  let i = Cyclesim.inputs h.sim
  and o = Cyclesim.outputs h.sim in
  (* expected outputs of this row = values after the previous edge *)
  let uo = Bits.to_int !(o.uo_out)
  and uout = Bits.to_int !(o.uio_out)
  and uoe = Bits.to_int !(o.uio_oe) in
  h.miso <- uo land 1;
  (match h.peer with
   | None -> ()
   | Some p ->
     let (pd : Psim.peer_drive) = p { Psim.cycle = h.n - h.t0; out = uout; oe = uoe; pad = h.prev_pad } in
     let pad = (uoe land uout) lor (lnot uoe land pd.drive_oe land pd.drive_val) lor (lnot uoe land lnot pd.drive_oe land 0xFF) in
     h.uio_in <- pad land 0xFF;
     h.prev_pad <- h.uio_in);
  bprintf h.rows "%x %02x %02x %02x %02x %02x\n" (Bool.to_int h.rst_n) (ui h) h.uio_in uoe uout uo;
  (* rst_n low clears the synchroniser asynchronously (within this cycle) *)
  if not h.rst_n then (h.s0 <- false; h.s1 <- false);
  i.rst_sync_n := Bits.of_bool h.s1;
  i.ui_in := Bits.of_int ~width:8 (ui h);
  i.uio_in := Bits.of_int ~width:8 h.uio_in;
  Cyclesim.cycle h.sim;
  if h.rst_n then (h.s1 <- h.s0; h.s0 <- true);
  h.n <- h.n + 1
;;

let wait h k = for _ = 1 to k do cycle h done

let xfer_byte h b =
  let r = ref 0 in
  for k = 7 downto 0 do
    h.mosi <- (b lsr k) land 1 = 1;
    wait h 6;
    r := (!r lsl 1) lor h.miso;
    h.sck <- true;
    wait h 6;
    h.sck <- false
  done;
  !r
;;

let transaction h bytes =
  h.cs_n <- false;
  wait h 6;
  let out = List.map bytes ~f:(xfer_byte h) in
  wait h 6;
  h.cs_n <- true;
  wait h 8;
  out
;;

let write h a d = ignore (transaction h ((a land 0x7F) :: d) : int list)
let read h a k = List.tl_exn (transaction h ((0x80 lor a) :: List.init k ~f:(fun _ -> 0)))
let read1 h a = List.hd_exn (read h a 1)

let load h ~lane prog =
  let b = 0x10 + (16 * lane) in
  let words = Isa1.assemble prog in
  write h (b + 4) [ List.length prog ];
  write h (b + 7) [ 0 ];
  write h (b + 8) (List.concat_map (List.init (List.length prog) ~f:Fn.id) ~f:(fun a ->
    [ words.(a) land 0xFF; words.(a) lsr 8 ]))
;;

let set_pkg h ~lane ~idx (p : Mprog.t) =
  write h (0x50 + (8 * lane)) [ 0x80 lor idx ];
  write h (0x60 + (16 * lane)) (Array.to_list p.remap)
;;

let write_store h ~lane img =
  let b = 0x50 + (8 * lane) in
  let img = List.sort img ~compare:(fun (a, _) (b, _) -> Int.compare a b) in
  let a0 = fst (List.hd_exn img) in
  List.iteri img ~f:(fun k (a, _) -> assert (a = a0 + k));
  write h (b + 4) [ a0 ];
  write h (b + 5) (List.concat_map img ~f:(fun (_, w) -> [ w land 0xFF; w lsr 8 ]))
;;

(* PEMU_LIB = uart2 | lib10 | all (default) and PEMU_LOADABLE = rom | l1 (default) | both select
   the configuration, as in emit_lane_rtl.exe top_macro_mon_sweep (v2 step-2 probes). *)
let env_or v d = Option.value (Sys.getenv v) ~default:d

let lib =
  List.map ~f:Compile.compile_exn
    (match env_or "PEMU_LIB" "all" with
     | "uart2" -> [ Library_v1.uart_tx ~d:3 ~pin:0; Library_v1.uart_tx ~d:4 ~pin:1 ]
     | "lib10" -> Rom_lib.protocol10 ()
     | "v2min" -> Rom_lib.minimum_v2 ()
     | "v2inc1" -> Rom_lib.v2_inc1 ()
     | "v2inc3" -> Rom_lib.v2_inc3 ()
     | _ -> Rom_lib.all15 ())
;;

let loadable =
  match env_or "PEMU_LOADABLE" "l1" with
  | "rom" -> [| false; false |]
  | "both" -> [| true; true |]
  | _ -> [| false; true |]
;;

(* ROM package 0 is UART TX on uio[0]; its bit period d is 3 (uart2) or 4 (lib10, all) *)
let uart_d = if String.is_substring (List.hd_exn lib).Mprog.name ~substring:"_d3_" then 3 else 4

let create () =
  let sim =
    Sim.create
      (Top_v1.create ~loadable ?mon_slots:(Option.map (Sys.getenv "PEMU_SLOTS") ~f:Int.of_string)
         ?lane_pipe:(Option.some_if (String.equal (Option.value (Sys.getenv "PEMU_LPIPE") ~default:"0") "1") true)
         ?param_windows:(Option.some_if (String.equal (Option.value (Sys.getenv "PEMU_PWIN") ~default:"0") "1") true) ?verdict_pipe:(Option.some_if (String.equal (Option.value (Sys.getenv "PEMU_VPIPE") ~default:"0") "1") true) ~lib
         ~sram:(fun _ i -> fst (Sram256.behavioural i)))
  in
  let h =
    { sim; rst_n = false; s0 = false; s1 = false; cs_n = true; sck = false; mosi = false; ui_hi = 0
    ; uio_in = 0xFF; miso = 0; rows = Buffer.create 65536; n = 0; peer = None; t0 = 0
    ; prev_pad = 0xFF }
  in
  wait h 3;
  h.rst_n <- true;
  wait h 6;
  h
;;

let verdict h = read h 0x40 4

(* lane 0: UART TX d = 4 on uio[0] with ROM package 0 (uart_tx_v1_d4_p0); correct program,
   then the start-bit-long mutant (fail pin uo[1]), then CLR_VERDICT *)
let rom_uart h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  note "ID 0x%02X" (read1 h 0x00);
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 7; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:uart_d);
  set_pkg h ~lane:0 ~idx:0 (List.nth_exn lib 0);
  write h 0x19 [ 0xA5 ];
  write h 0x01 [ 0x01 ];
  wait h 800;
  note "correct: STATUS 0x%02X VERDICT %s" (read1 h 0x02)
    (String.concat ~sep:" " (List.map (verdict h) ~f:(sprintf "%02X")));
  write h 0x01 [ 0x00 ];
  load h ~lane:0 (Programs_v1.uart_tx_bad_start ~d:uart_d);
  write h 0x01 [ 0x10 ];
  write h 0x19 [ 0x3C ];
  write h 0x01 [ 0x01 ];
  wait h 600;
  note "bad start: STATUS 0x%02X VERDICT %s" (read1 h 0x02)
    (String.concat ~sep:" " (List.map (verdict h) ~f:(sprintf "%02X")));
  write h 0x01 [ 0x10 ];
  note "after clear: VERDICT 0x%02X" (read1 h 0x40);
  List.rev !log
;;

(* lane 1 (loadable): UART TX d = 4 on uio[1] with the same package loaded into its store
   (units 6, 7), exercising the lane-1 imem and the store macro *)
let loadable_l1 h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  let ld1 = Compile.compile_exn (Library_v1.uart_tx ~d:4 ~pin:1) in
  let on_pin1 = List.map ~f:(function Isa1.Out 1 -> Isa1.Out 2 | Oen 1 -> Oen 2 | Pin (0, a) -> Pin (1, a) | x -> x) in
  write h 0x20 [ 0x02 ];
  write h 0x22 [ 13; 0 ];
  load h ~lane:1 (on_pin1 (Programs_v1.uart_tx ~d:4));
  let n6 = Array.length ld1.units.(0).code in
  (* v2 serial loadable lane (PEMU_SLOTS < 8): 50 + 3 slots header words, units 0..n-1 *)
  let slots = Option.value_map (Sys.getenv "PEMU_SLOTS") ~default:8 ~f:Int.of_string in
  let image =
    if slots < 8
    then Mprog.store_image ~slots ld1 ~ctx_base:0 ~bases:(snd (Mprog.serial_layout ld1))
    else Mprog.store_image ld1 ~ctx_base:0 ~bases:[ 56; 56 + (6 * n6) ]
  in
  write_store h ~lane:1 image;
  write h 0x5A [ 0 ];
  write h 0x58 [ 0x80 ];
  write h 0x70 (Array.to_list ld1.remap);
  write h 0x59 [ 0x83 ];
  note "LOAD_UNITS 0x%02X" (read1 h 0x59);
  write h 0x29 [ 0x5A ];
  write h 0x01 [ 0x02 ];
  wait h 1500;
  note "loaded: STATUS 0x%02X VERDICT %s" (read1 h 0x02)
    (String.concat ~sep:" " (List.map (verdict h) ~f:(sprintf "%02X")));
  List.rev !log
;;

(* option D (PEMU_PWIN=1): lane 0 UART TX d = 6 firmware on ROM package 0 (d = 4). Without the
   window override the d4 contract fails it; with the windows of uart_tx d6 loaded (WIN_CTL/LO/HI)
   it is accepted; the d6 bad-start mutant is then failed *)
let pwin_uart h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  let vs () = String.concat ~sep:" " (List.map (verdict h) ~f:(sprintf "%02X")) in
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 7; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:6);
  set_pkg h ~lane:0 ~idx:0 (List.nth_exn lib 0);
  write h 0x19 [ 0xA5 ];
  write h 0x01 [ 0x01 ];
  wait h 800;
  note "d6 on ROM d4, no override: VERDICT %s" (vs ());
  write h 0x01 [ 0x10 ];
  let w = (Compile.compile_exn (Library_v1.uart_tx ~d:6 ~pin:0)).windows in
  for k = 1 to 7 do
    write h 0x53 [ k ];
    write h 0x56 [ w.(k) land 0xFF ];
    write h 0x57 [ w.(k) lsr 8 ]
  done;
  write h 0x53 [ 0x80 ];
  note "WIN_CTL 0x%02X" (read1 h 0x53);
  write h 0x19 [ 0x3C ];
  write h 0x01 [ 0x01 ];
  wait h 800;
  note "d6 on ROM d4 + windows(d6): VERDICT %s" (vs ());
  write h 0x01 [ 0x00 ];
  load h ~lane:0 (Programs_v1.uart_tx_bad_start ~d:6);
  write h 0x01 [ 0x10 ];
  write h 0x19 [ 0x5A ];
  write h 0x01 [ 0x01 ];
  wait h 600;
  note "d6 bad start + windows(d6): VERDICT %s" (vs ());
  List.rev !log
;;

(* rst_n pulse while lane 0 runs, then the ID read and a restart *)
let reset_mid h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 7; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:4);
  write h 0x19 [ 0x81 ];
  write h 0x01 [ 0x01 ];
  wait h 300;
  h.rst_n <- false;
  wait h 2;
  h.rst_n <- true;
  wait h 6;
  note "after reset: ID 0x%02X STATUS 0x%02X" (read1 h 0x00) (read1 h 0x02);
  (* registers (LEN, loaded) are cleared by reset: reload before the restart *)
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 7; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:4);
  write h 0x19 [ 0x42 ];
  write h 0x01 [ 0x01 ];
  wait h 600;
  note "restart: STATUS 0x%02X" (read1 h 0x02);
  List.rev !log
;;

let compose peers (v : Psim.chip_view) =
  List.fold peers ~init:{ Psim.drive_oe = 0; drive_val = 0 } ~f:(fun (acc : Psim.peer_drive) p ->
    let (d : Psim.peer_drive) = p v in
    { Psim.drive_oe = acc.drive_oe lor d.drive_oe; drive_val = acc.drive_val lor (d.drive_val land d.drive_oe) })
;;

let hex l = String.concat ~sep:" " (List.map l ~f:(sprintf "%02X"))

let rx_fifo h ~lane =
  let b = 0x10 + (16 * lane) in
  let lvl = (read1 h (b + 11) lsr 4) land 0xF in
  if lvl = 0 then [] else read h (b + 10) lvl
;;

(* v2 minimum (PEMU_LIB=v2min), divisors of Rom_lib.minimum_v2_with_p at 33 MHz. Lane 1: SPI
   controller m0 (ROM package 2, P = 7) against an SPI target peer whose MISO bit 4 of frame 3
   violates hold (blame 0x91). Lane 0: UART RX (package 1, P = 35) against a 115200-baud sender
   at 33 MHz (286.46 cycles per bit). *)
let v2_spi_ctl_uart_rx h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  write h 0x10 [ 0x00 ];
  write h 0x12 [ 35; 0 ];
  load h ~lane:0 (Programs_v1.uart_rx ~d:8 ~pin:1);
  set_pkg h ~lane:0 ~idx:1 (List.nth_exn lib 1);
  write h 0x20 [ Programs_v1.spi_own_ctl ];
  write h 0x22 [ 7; 0 ];
  write h 0x25 [ Programs_v1.spi_cfg_ctl ];
  write h 0x26 [ Programs_v1.spi_cfg2_ctl ];
  load h ~lane:1 (Programs_v1.spi_ctl ~cpol:false ~cpha:false);
  set_pkg h ~lane:1 ~idx:2 (List.nth_exn lib 2);
  write h 0x29 [ 0xA5; 0x3C; 0x00; 0xFF; 0x81; 0x7E; 0x55; 0x0F ];
  let tgt =
    Peers.spi_target ~cpol:false ~cpha:false ~tco:3 ~send:[ 0x96; 0x01; 0x80; 0xC3; 0x5A; 0xF0; 0x33; 0xE7 ]
      ~miso_glitch:(3, 4) ~glitch_len:10 ()
  in
  let bp = 33e6 /. 115200. in
  let snd =
    Peers.sender ~pin:1 ~bp ~frames:(Peers.frames_of ~bp ~st0:400 [ 0x55; 0xC3; 0x0F; 0xA5 ] ~gap:(fun b -> 50 + b))
      ~defect:No_defect
  in
  h.t0 <- h.n;
  h.peer <- Some (compose [ tgt.drive; snd ]);
  write h 0x01 [ 0x03 ];
  wait h 13000;
  h.peer <- None;
  h.uio_in <- 0xFF;
  note "VERDICT %s STATUS 0x%02X" (hex (read h 0x40 12)) (read1 h 0x02);
  note "lane 0 UART RX bytes [%s]" (hex (rx_fifo h ~lane:0));
  note "lane 1 SPI ctl RX bytes [%s]; peer received [%s]" (hex (rx_fifo h ~lane:1)) (hex (tgt.received ()));
  List.rev !log
;;

(* Lane 1: SPI target m0 (package 3, P = 7, release on blame) against an SPI controller peer whose
   frame 5 raises CS after 9 edges (blame 0x52, lane 1 faults); then the host clears the fault
   and the verdict. Lane 0: UART TX (package 0, P = 71, 288 cycles per bit). *)
let v2_spi_tgt_uart_tx h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  write h 0x10 [ 0x01 ];
  write h 0x12 [ 71; 0 ];
  load h ~lane:0 (Programs_v1.uart_tx ~d:4);
  set_pkg h ~lane:0 ~idx:0 (List.nth_exn lib 0);
  write h 0x19 [ 0xA5; 0x3C; 0x96 ];
  write h 0x20 [ Programs_v1.spi_own_tgt ];
  write h 0x22 [ 7; 0 ];
  write h 0x25 [ 0x01 ];
  load h ~lane:1 (Programs_v1.spi_tgt ~cpol:false ~cpha:false);
  set_pkg h ~lane:1 ~idx:3 (List.nth_exn lib 3);
  write h 0x29 [ 0xA5; 0x3C; 0x00; 0xFF; 0x81; 0x7E; 0x55; 0x0F ];
  let ctl =
    Peers.spi_controller ~cpol:false ~cpha:false ~hp:40 ~setup:40 ~hold:40 ~gap:144 ~mdly:2 ~t0:400
      ~bytes:[ 0x96; 0x01; 0x80; 0xC3; 0x5A; 0xF0; 0x33; 0xE7 ] ~defect:(Early_rise (5, 9)) ()
  in
  h.t0 <- h.n;
  h.peer <- Some ctl.cdrive;
  write h 0x01 [ 0x03 ];
  wait h (Int.max (ctl.frames_end + 300) 9500);
  h.peer <- None;
  h.uio_in <- 0xFF;
  note "VERDICT %s STATUS 0x%02X" (hex (read h 0x40 12)) (read1 h 0x02);
  note "lane 1 SPI tgt RX bytes [%s]" (hex (rx_fifo h ~lane:1));
  write h 0x01 [ 0x03 lor 0x40 lor 0x10 ];
  wait h 50;
  note "after clear fault L1 + CLR_VERDICT: VERDICT 0x%02X STATUS 0x%02X" (read1 h 0x40) (read1 h 0x02);
  List.rev !log
;;


(* increment 3: lane 0 = I2C target Sm (ROM 6, P = 4) with an I2C controller peer at the 30 MHz
   UM10204 Sm minima (wired-AND bus on uio2/uio3; the lane drives open-drain). [thd_sta]: the
   controller's START hold in cycles (120 = minimum; 60 = violation, blamed B82). *)
let v2_i2c_tgt ~thd_sta h =
  let log = ref [] in
  let note fmt = ksprintf (fun s -> log := s :: !log) fmt in
  write h 0x10 [ Programs_v1.i2c_own ];
  write h 0x11 [ Programs_v1.i2c_od ];
  write h 0x12 [ Rom_lib.i2c_tgt_sm_p; 0 ];
  load h ~lane:0 (Programs_v1.i2c_tgt ~addr:0x50);
  set_pkg h ~lane:0 ~idx:6 (List.nth_exn lib 6);
  write h 0x19 [ 0x50; 0xA1 ];
  let t =
    { Peers.tlow = 141; thigh = 120; thd_sta; tsu_sta = 141; tsu_sto = 120; tbuf = 141; dh = 1; su = 8 }
  in
  let ctl = Peers.i2c_controller ~t [ `W (0x50, [ 0x11 ]), true; `R (0x50, 1), false ] in
  h.t0 <- h.n;
  h.peer <- Some ctl.cdrive;
  write h 0x01 [ 0x01 ];
  let start = h.n in
  while (not (ctl.cdone ())) && h.n - start < 40_000 do cycle h done;
  wait h 400;
  h.peer <- None;
  h.uio_in <- 0xFF;
  note "controller done %b, bus %s" (ctl.cdone ()) (ctl.clog ());
  note "VERDICT %s STATUS 0x%02X" (hex (read h 0x40 12)) (read1 h 0x02);
  note "lane 0 RX bytes [%s]" (hex (rx_fifo h ~lane:0));
  List.rev !log
;;

let () =
  let dir = (Sys.get_argv ()).(1) in
  List.iter
    ([ "v1_rom_uart", rom_uart ]
     @ (if loadable.(1) then [ "v1_loadable_l1", loadable_l1 ] else [])
     @ [ "v1_reset_mid", reset_mid ]
     @ (if String.equal (env_or "PEMU_PWIN" "0") "1" then [ "v2_pwin_uart", pwin_uart ] else [])
     @
     (* v2inc1 = v2min packages 0-3 unchanged + I2C controller as 4/5, so the v2 scenarios apply *)
     (if List.mem [ "v2min"; "v2inc1"; "v2inc3" ] (env_or "PEMU_LIB" "all") ~equal:String.equal
      then [ "v2_spi_ctl_uart_rx", v2_spi_ctl_uart_rx; "v2_spi_tgt_uart_tx", v2_spi_tgt_uart_tx ]
      else [])
     @
     if String.equal (env_or "PEMU_LIB" "all") "v2inc3"
     then [ "v2_i2c_tgt", v2_i2c_tgt ~thd_sta:120; "v2_i2c_tgt_blame", v2_i2c_tgt ~thd_sta:60 ]
     else [])
    ~f:(fun (name, f) ->
      let h = create () in
      let log = f h in
      wait h 4;
      Out_channel.write_all (dir ^/ name ^ ".vec") ~data:(Buffer.contents h.rows);
      printf "%s: %d cycles\n" name h.n;
      List.iter log ~f:(printf "  %s\n"))
;;
