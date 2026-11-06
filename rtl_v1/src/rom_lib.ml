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

(* v2 minimum library (doc/decisions/arch_v2_options.md, V2-5): UART TX, UART RX, SPI controller
   mode 0, SPI target mode 0, with the divisor P each package is documented to run at on the
   33 MHz v2 clock (V2-1, revised 2026-10-27): UART 115200 baud (TX 4 steps/bit:
   33e6 / (115200 * 4) = 71.6 cycles per step, P = 71, bit = 288 cycles, +0.5 %; RX 8 steps/bit:
   35.8, P = 35, bit = 288 cycles, +0.5 %); SPI at P = 7 (controller SCLK
   33 MHz / (2 * h * (P + 1)) = 1.03 MHz with h = 2). The divisor is a host register, so other
   clocks only change these numbers. *)
let minimum_v2_with_p () =
  [ Library_v1.uart_tx ~d:4 ~pin:0, 71
  ; Library_v1.uart_rx ~d:8 ~m:2 ~pin:1, 35
  ; Library_v1.spi_ctl ~cpol:false ~cpha:false ~h:2, 7
  ; Library_v1.spi_tgt ~cpol:false ~cpha:false ~h_min:3 ~g:6, 7
  ]
;;

let minimum_v2 () = List.map (minimum_v2_with_p ()) ~f:fst

(* Increment 1 (log/increments_v2.md): v2 minimum plus the I2C controller, Fm and Sm, as ROM
   packages 4 and 5. Divisors at 33 MHz: Fm P = 8 (step 0.273 us, SCL 10 steps = 367 kHz; the v1
   step was 0.25 us at P = 14 / 60 MHz, P = 7 would give 412 kHz > 400 kHz); Sm P = 32 (step 1 us,
   as in v1). The controller contract encodes only UM10204 minimum times, so a longer step keeps it
   valid. *)
let v2_inc1_with_p () =
  minimum_v2_with_p ()
  @ [ Library_v1.i2c_ctl ~l:6 ~h:4 ~tsu:3 ~thold:6, 8; Library_v1.i2c_ctl ~l:5 ~h:5 ~tsu:5 ~thold:5, 32 ]
;;

let v2_inc1 () = List.map (v2_inc1_with_p ()) ~f:fst

(* Divisor rules behind the documented values, for any clock (integer arithmetic, so no float
   rounding can move a ceiling). A lane step is P + 1 cycles.
   - UART TX (4 steps/bit) and RX (8 steps/bit) at 115200 baud: P + 1 = round (f / (115200 * steps)).
   - SPI controller/target: P = 7 (fixed; the SCLK rate scales with the clock).
   - I2C Fm: the shortest step of at least 0.25 us (the v1 step; SCL = 10 steps <= 400 kHz).
   - I2C Sm: the shortest step of at least 1 us.
   At 33 MHz these give 71, 35, 7, 7, 8, 32, the values of [v2_inc1_with_p] (checked in
   test_rom_lib_v2.ml); at 30 MHz 64, 32, 7, 7, 7, 29. *)
let divisors_at ~clock_hz =
  let round_div a b = ((2 * a) + b) / (2 * b) in
  let ceil_div a b = (a + b - 1) / b in
  let uart steps = round_div clock_hz (115_200 * steps) - 1 in
  let min_step ~ns = ceil_div (clock_hz * ns) 1_000_000_000 - 1 in
  [ uart 4; uart 8; 7; 7; min_step ~ns:250; min_step ~ns:1000 ]
;;

let v2_inc1_with_p_at ~clock_hz =
  List.map2_exn (v2_inc1 ()) (divisors_at ~clock_hz) ~f:(fun c p -> c, p)
;;

let minimum_v2_with_p_at ~clock_hz = List.take (v2_inc1_with_p_at ~clock_hz) 4

(* Static admissibility (D13 recurrence check, log/harness_audit_v2.md C4): a serial monitor with
   [slots] slots admits RUN only for P >= slots - 1, and a package must fit in the slots.
   Returns the violations; [] means every shipped package runs monitored at its documented P. *)
let admissibility_violations ~slots (lib : (Lang.t * int) list) =
  List.filter_map lib ~f:(fun (c, p) ->
    let m = Compile.compile_exn c in
    let units = Array.length m.units in
    if units > slots || p < slots - 1
    then Some (sprintf "%s: units %d (slots %d), P %d (min %d)" m.name units slots p (slots - 1))
    else None)
;;
