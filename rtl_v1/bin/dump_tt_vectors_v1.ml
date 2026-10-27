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
      (Top_v1.create ~loadable ?mon_slots:(Option.map (Sys.getenv "PEMU_SLOTS") ~f:Int.of_string) ~lib
         ~sram:(fun _ i -> fst (Sram256.behavioural i)))
  in
  let h =
    { sim; rst_n = false; s0 = false; s1 = false; cs_n = true; sck = false; mosi = false; ui_hi = 0
    ; uio_in = 0xFF; miso = 0; rows = Buffer.create 65536; n = 0 }
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
  write_store h ~lane:1 (Mprog.store_image ld1 ~ctx_base:0 ~bases:[ 56; 56 + (6 * n6) ]);
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

let () =
  let dir = (Sys.get_argv ()).(1) in
  List.iter
    ([ "v1_rom_uart", rom_uart ]
     @ (if loadable.(1) then [ "v1_loadable_l1", loadable_l1 ] else [])
     @ [ "v1_reset_mid", reset_mid ])
    ~f:(fun (name, f) ->
      let h = create () in
      let log = f h in
      wait h 4;
      Out_channel.write_all (dir ^/ name ^ ".vec") ~data:(Buffer.contents h.rows);
      printf "%s: %d cycles\n" name h.n;
      List.iter log ~f:(printf "  %s\n"))
;;
