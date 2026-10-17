(* Instruction SRAM RM_IHPSG13_1P_256x16_c2_bm_bist (IHP-Open-PDK 2bbec755; vendored model in
   rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/), with the exact port list. Implementations:
   - [behavioural]: Hardcaml registers implementing SRAM_1P_behavioral_bm_bist with
     A_BIST_EN = 0 (the BIST multiplexer then selects the functional port, including the clock).
     The memory words are returned too, so a proof harness can let a specification read the
     same array (lane A1, rtl_v1/README section on A1).
   - [blackbox]: instantiation of the macro for synthesis.
   Tie-offs used by the lane: A_DLY = 1 (datasheet), A_MEN = 1, A_BM = all ones, A_BIST_* = 0. *)
open! Core
open Hardcaml
open Signal

let macro_name = "RM_IHPSG13_1P_256x16_c2_bm_bist"
let depth = 256
let addr_width = 8
let data_width = 16

module I = struct
  type 'a t =
    { a_clk : 'a [@rtlname "A_CLK"]
    ; a_men : 'a [@rtlname "A_MEN"]
    ; a_wen : 'a [@rtlname "A_WEN"]
    ; a_ren : 'a [@rtlname "A_REN"]
    ; a_addr : 'a [@bits 8] [@rtlname "A_ADDR"]
    ; a_din : 'a [@bits 16] [@rtlname "A_DIN"]
    ; a_dly : 'a [@rtlname "A_DLY"]
    ; a_bm : 'a [@bits 16] [@rtlname "A_BM"]
    ; a_bist_clk : 'a [@rtlname "A_BIST_CLK"]
    ; a_bist_en : 'a [@rtlname "A_BIST_EN"]
    ; a_bist_men : 'a [@rtlname "A_BIST_MEN"]
    ; a_bist_wen : 'a [@rtlname "A_BIST_WEN"]
    ; a_bist_ren : 'a [@rtlname "A_BIST_REN"]
    ; a_bist_addr : 'a [@bits 8] [@rtlname "A_BIST_ADDR"]
    ; a_bist_din : 'a [@bits 16] [@rtlname "A_BIST_DIN"]
    ; a_bist_bm : 'a [@bits 16] [@rtlname "A_BIST_BM"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { a_dout : 'a [@bits 16] [@rtlname "A_DOUT"] } [@@deriving hardcaml]
end

(* Functional rules (A_BIST_EN = 0), per rising edge of A_CLK:
   1. MEN & WEN: mem[ADDR] <- (mem[ADDR] & ~BM) | (DIN & BM); if REN also, DOUT <- that value.
   2. else MEN & REN: DOUT <- mem[ADDR].
   3. else DOUT holds.
   No reset on the words or on DOUT. [mem_name] prefixes the word registers (formal: name them
   free_* to leave their initial contents free); DOUT is named [dout_name]. *)
let behavioural ?(mem_name = "imem_word") ?(dout_name = "rtl_imem_dout") (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.a_clk () in
  let write = i.a_men &: i.a_wen in
  let read = i.a_men &: i.a_ren in
  (* Explicit hold multiplexers instead of ~enable: cyclesim's Reg.of_int does not persist on
     a held enable register (it reverts at the next edge), which broke counterexample replay
     of free initial contents. Behaviour is identical. *)
  let hold_reg ~en d name =
    let q = wire (width d) in
    let r = reg spec (mux2 en d q) -- name in
    q <== r;
    r
  in
  let mem_q = List.init depth ~f:(fun _ -> wire data_width) in
  let cur = mux i.a_addr mem_q in
  let merged = (cur &: ~:(i.a_bm)) |: (i.a_din &: i.a_bm) in
  List.iteri mem_q ~f:(fun a q ->
    q <== hold_reg ~en:(write &: (i.a_addr ==:. a)) merged (sprintf "%s_%d" mem_name a));
  let dout_en = (write &: i.a_ren) |: (~:write &: read) in
  let dout = hold_reg ~en:dout_en (mux2 write merged cur) dout_name in
  { O.a_dout = dout }, mem_q
;;

let blackbox ?(instance = "u_imem") (i : _ I.t) =
  let module Inst = Instantiation.With_interface (I) (O) in
  Inst.create ~instance ~name:macro_name i
;;

(* Tie-offs for the functional port only (lane use). *)
let tie ~clock ~wen ~ren ~addr ~din =
  { I.a_clk = clock
  ; a_men = vdd
  ; a_wen = wen
  ; a_ren = ren
  ; a_addr = addr
  ; a_din = din
  ; a_dly = vdd
  ; a_bm = ones 16
  ; a_bist_clk = gnd
  ; a_bist_en = gnd
  ; a_bist_men = gnd
  ; a_bist_wen = gnd
  ; a_bist_ren = gnd
  ; a_bist_addr = zero 8
  ; a_bist_din = zero 16
  ; a_bist_bm = zero 16
  }
;;
