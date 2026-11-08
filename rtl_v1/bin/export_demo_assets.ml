(* Toolchain output for the virtual demo board (plan step 8, test/demo/): assembled firmware
   images and the ROM package table of the tape-out library (Rom_lib.v2_inc5), as JSON. The demo
   host (test/demo/pemu_host.py) loads these the way the RP2350 MicroPython host would; it holds
   no assembler or contract compiler of its own.
   usage: export_demo_assets.exe <out.json> *)
open! Core
open Pemu_spec_v1
open Pemu_monitor_v1
open Pemu_rtl_v1
module P1 = Programs_v1

let ints l = "[" ^ String.concat ~sep:", " (List.map l ~f:Int.to_string) ^ "]"

let program name prog ~own ~od ~cfg ~cfg2 =
  let w = Isa1.assemble prog in
  sprintf "    %S: {\"words\": %s, \"own\": %d, \"od\": %d, \"cfg\": %d, \"cfg2\": %d}" name
    (ints (Array.to_list (Array.sub w ~pos:0 ~len:(List.length prog)))) own od cfg cfg2
;;

let () =
  let out = (Sys.get_argv ()).(1) in
  let lib = Rom_lib.v2_inc5_with_p () in
  let pkgs =
    List.mapi lib ~f:(fun i (c, p) ->
      let m = Compile.compile_exn c in
      sprintf "    {\"index\": %d, \"name\": %S, \"p\": %d, \"remap\": %s, \"windows\": %s}" i m.name p
        (ints (Array.to_list m.remap)) (ints (Array.to_list m.windows)))
  in
  let win name c =
    let m = Compile.compile_exn c in
    sprintf "    %S: %s" name (ints (Array.to_list m.windows))
  in
  let progs =
    [ program "uart_tx_d4" (P1.uart_tx ~d:4) ~own:0x01 ~od:0 ~cfg:0 ~cfg2:0
    ; program "uart_tx_d6" (P1.uart_tx ~d:6) ~own:0x01 ~od:0 ~cfg:0 ~cfg2:0
    ; program "uart_tx_bad_start_d4" (P1.uart_tx_bad_start ~d:4) ~own:0x01 ~od:0 ~cfg:0 ~cfg2:0
    ; program "uart_rx_d8_pin1" (P1.uart_rx ~d:8 ~pin:1) ~own:0 ~od:0 ~cfg:0 ~cfg2:0
    ; program "spi_ctl_m0" (P1.spi_ctl ~cpol:false ~cpha:false) ~own:P1.spi_own_ctl ~od:0 ~cfg:P1.spi_cfg_ctl
        ~cfg2:P1.spi_cfg2_ctl
    ; program "spi_tgt_m0" (P1.spi_tgt ~cpol:false ~cpha:false) ~own:P1.spi_own_tgt ~od:0 ~cfg:0 ~cfg2:0
    ; program "i2c_ctl_fm" (P1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0
    ; program "i2c_ctl_sm" (P1.i2c_ctl ~l:5 ~h:5 ~tsu:5 ~thold:5) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0
    ; program "i2c_tgt_0x50" (P1.i2c_tgt ~addr:0x50) ~own:P1.i2c_own ~od:P1.i2c_od ~cfg:0 ~cfg2:0
    ; program "usb_ls_tx" P1.usb_ls_tx ~own:P1.usb_own ~od:0 ~cfg:P1.usb_cfg ~cfg2:0
    ]
  in
  let wins = [ win "uart_tx_d6" (Library_v1.uart_tx ~d:6 ~pin:0) ] in
  let json =
    sprintf "{\n  \"clock_hz\": %d,\n  \"library\": \"v2inc5\",\n  \"packages\": [\n%s\n  ],\n  \"programs\": {\n%s\n  },\n  \"windows\": {\n%s\n  }\n}\n"
      Rom_lib.v2_clock_hz (String.concat ~sep:",\n" pkgs) (String.concat ~sep:",\n" progs)
      (String.concat ~sep:",\n" wins)
  in
  Out_channel.write_all out ~data:json;
  printf "wrote %s: %d packages, %d programs\n" out (List.length pkgs) (List.length progs)
;;
