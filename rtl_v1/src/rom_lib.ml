(* Monitor ROM libraries (plan step 7). [protocol10]: UART TX/RX and SPI controller/target
   modes 0-3. [all15]: plus I2C controller Fm/Sm, I2C target Fm/Sm and USB-LS TX, with the
   parameters of their A2 proofs (formal/src/ag_pkg.ml). [all15] is the tape-out library of
   the first v1 TT run (user decision 2026-10-19); package index = list position. *)
open! Core
open Pemu_monitor_v1

let protocol10 () =
  let m = [ false, false; false, true; true, false; true, true ] in
  [ Library_v1.uart_tx ~d:4 ~pin:0; Library_v1.uart_rx ~d:8 ~m:2 ~pin:1 ]
  @ List.map m ~f:(fun (cpol, cpha) -> Library_v1.spi_ctl ~cpol ~cpha ~h:2)
  @ List.map m ~f:(fun (cpol, cpha) -> Library_v1.spi_tgt ~cpol ~cpha ~h_min:3 ~g:6)
;;

let all15 () =
  protocol10 ()
  @ [ Library_v1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6
    ; Library_v1.i2c_ctl ~l:5 ~h:5 ~tsu:5 ~thold:5
    ; Library_v1.i2c_tgt ~h_min:8 ~l_min:18 ~hd:8
    ; Library_v1.i2c_tgt ~h_min:59 ~l_min:69 ~hd:59
    ; Library_v1.usb_ls_tx ()
    ]
;;
