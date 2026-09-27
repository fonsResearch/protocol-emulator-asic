(* Instruction-memory SRAM behind the exact RM_IHPSG13_1P_64x16_c2 port list
   (doc/sram_interface.md). Two implementations with identical ports:
   - [behavioural]: Hardcaml registers implementing the three rules of the functional model
   - [blackbox]: instantiation of the IHP macro for synthesis *)
open! Core
open Hardcaml
open Signal

let macro_name = "RM_IHPSG13_1P_64x16_c2"
let depth = 64
let addr_width = 6
let data_width = 16

module I = struct
  type 'a t =
    { a_clk : 'a [@rtlname "A_CLK"]
    ; a_men : 'a [@rtlname "A_MEN"]
    ; a_wen : 'a [@rtlname "A_WEN"]
    ; a_ren : 'a [@rtlname "A_REN"]
    ; a_addr : 'a [@bits 6] [@rtlname "A_ADDR"]
    ; a_din : 'a [@bits 16] [@rtlname "A_DIN"]
    ; a_dly : 'a [@rtlname "A_DLY"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { a_dout : 'a [@bits 16] [@rtlname "A_DOUT"] } [@@deriving hardcaml]
end

(* Functional model rules (sram_interface.md):
   1. MEN & WEN: mem[ADDR] <- DIN; if REN also, DOUT <- DIN (write-through), else DOUT holds.
   2. else MEN & REN: DOUT <- mem[ADDR].
   3. else DOUT holds.
   Memory words have no reset (contents undefined after power-up). The DOUT register has no
   reset either; it is X until the first read in silicon (0 in cyclesim). *)
let behavioural ?(name_prefix = "rtl_imem") (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.a_clk () in
  let write = i.a_men &: i.a_wen in
  let read = i.a_men &: i.a_ren in
  let mem =
    List.init depth ~f:(fun a ->
      reg spec ~enable:(write &: (i.a_addr ==:. a)) i.a_din -- sprintf "%s_%d" name_prefix a)
  in
  let rd = mux i.a_addr mem in
  let dout_en = (write &: i.a_ren) |: (~:write &: read) in
  let dout_d = mux2 write i.a_din rd in
  let dout = reg spec ~enable:dout_en dout_d -- (name_prefix ^ "_dout") in
  { O.a_dout = dout }
;;

(* Formal/test-only ROM: the words are the constants [contents] and writes are ignored
   entirely (no memory update and no write-through), i.e. A_DOUT <- rom[ADDR] when MEN & REN,
   else DOUT holds. This matches [Spec_circuit.create ~rom], which ignores load writes; with
   write-through kept, a load write to address 0 would make the ROM RTL diverge from the ROM
   spec (found by PDR on a1_rom, frame 6). Used to fix a program in the RTL for
   program-level proofs (timed QED). Not for synthesis. *)
let behavioural_rom ?(name = "rtl_imem_dout") ~(contents : int array) (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.a_clk () in
  let read = i.a_men &: i.a_ren in
  let mem = List.init depth ~f:(fun a -> of_int ~width:data_width contents.(a)) in
  let rd = mux i.a_addr mem in
  let dout = reg spec ~enable:read rd -- name in
  ignore (i.a_wen, i.a_din);
  { O.a_dout = dout }
;;

let blackbox (i : _ I.t) =
  let module Inst = Instantiation.With_interface (I) (O) in
  Inst.create ~instance:"u_imem" ~name:macro_name i
;;
