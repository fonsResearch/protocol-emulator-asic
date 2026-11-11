(* The firmware that goes with the tape-out ROM library (the same set and lane configuration as
   rtl_v1/bin/export_demo_assets.ml), with the ROM package each program is checked by. *)
open! Core
module P1 = Pemu_spec_v1.Programs_v1

type program =
  { name : string
  ; prog : Pemu_spec_v1.Isa1.t list
  ; own : int
  ; od : int
  ; cfg : int
  ; cfg2 : int
  ; rom : int option (* ROM package index (Rom_lib.v2_inc5) *)
  }

let programs () =
  let p ?rom name prog ~own ~od ~cfg ~cfg2 = { name; prog; own; od; cfg; cfg2; rom } in
  [ p "uart_tx_d4" (P1.uart_tx ~d:4) ~own:0x01 ~od:0 ~cfg:0 ~cfg2:0 ~rom:0
  ; p "uart_rx_d8_pin1" (P1.uart_rx ~d:8 ~pin:1) ~own:0 ~od:0 ~cfg:0 ~cfg2:0 ~rom:1
  ; p "spi_ctl_m0" (P1.spi_ctl ~cpol:false ~cpha:false) ~own:P1.spi_own_ctl ~od:0 ~cfg:P1.spi_cfg_ctl ~cfg2:P1.spi_cfg2_ctl ~rom:2
  ; p "spi_tgt_m0" (P1.spi_tgt ~cpol:false ~cpha:false) ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0 ~rom:3
  ; p "i2c_ctl_fm" (P1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ~rom:4
  ; p "i2c_ctl_sm" (P1.i2c_ctl ~l:5 ~h:5 ~tsu:5 ~thold:5) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ~rom:5
  ; p "i2c_tgt_0x50" (P1.i2c_tgt ~addr:0x50) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0 ~rom:6
  ; p "usb_ls_tx" P1.usb_ls_tx ~own:P1.usb_own ~od:0 ~cfg:P1.usb_cfg ~cfg2:0 ~rom:7
    (* negative example: the start bit is wrong, ROM package 0 fails it *)
  ; p "uart_tx_bad_start_d4" (P1.uart_tx_bad_start ~d:4) ~own:0x01 ~od:0 ~cfg:0 ~cfg2:0 ~rom:0 ]
;;
