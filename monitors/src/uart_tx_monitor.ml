(* UART 8N1 TX monitor (doc/protocols/uart.md), bit period [b] cycles, tolerance 0.

   Frame timing: cycle 0 of a frame is the first cycle the line is observed low after idle.
   Within a frame (offsets 0 .. 10b-1): the line may change only at offsets that are
   multiples of b; it must be low for offsets 0..b-1 and high for offsets 9b..10b-1.

   Outputs describe the CURRENT cycle's observation (combinational in [line]):
     bad        - a violation in this cycle, or any earlier one (sticky)
     frame_done - this cycle is offset 10b-1 of a frame with no violation
     frame_data - data bits of the current/last frame (valid when frame_done)
     timeout    - the line has been low for more than 10b consecutive cycles (sticky)

   Two implementations with the same interface behaviour:
   - [Model]: pure OCaml using an absolute frame offset k (reference)
   - [circuit]: Hardcaml using (bit index, phase) counters *)
open! Core
open Hardcaml

type obs =
  { bad : bool
  ; frame_done : bool
  ; frame_data : int
  ; timeout : bool
  }
[@@deriving sexp_of, equal]

module Model = struct
  type state =
    | Wait_idle
    | Idle
    | Frame
  [@@deriving sexp_of, equal]

  type t =
    { b : int
    ; mutable state : state
    ; mutable k : int
    ; mutable prev : bool
    ; mutable data : int
    ; mutable bad : bool
    ; mutable frame_viol : bool
    ; mutable low_run : int
    ; mutable timeout : bool
    }

  let create ~b =
    if b < 1 then raise_s [%message "bit period must be >= 1" (b : int)];
    { b
    ; state = Wait_idle
    ; k = 0
    ; prev = true
    ; data = 0
    ; bad = false
    ; frame_viol = false
    ; low_run = 0
    ; timeout = false
    }
  ;;

  (* Observe one cycle; returns the outputs for this cycle, then advances. *)
  let step m line =
    let b = m.b in
    let violation =
      match m.state with
      | Frame ->
        (m.k >= 1 && Bool.( <> ) line m.prev && m.k % b <> 0)
        || (m.k < b && line)
        || (m.k >= 9 * b && not line)
      | Wait_idle | Idle -> false
    in
    let low_run' = if line then 0 else Int.min (m.low_run + 1) ((10 * b) + 1) in
    let timeout_now = m.timeout || low_run' > 10 * b in
    let frame_done =
      (match m.state with
       | Frame -> m.k = (10 * b) - 1
       | _ -> false)
      && (not violation)
      && not m.frame_viol
    in
    let out =
      { bad = m.bad || violation; frame_done; frame_data = m.data; timeout = timeout_now }
    in
    (* advance *)
    m.bad <- m.bad || violation;
    m.timeout <- timeout_now;
    m.low_run <- low_run';
    (match m.state with
     | Wait_idle -> if line then m.state <- Idle
     | Idle ->
       if not line
       then (
         m.state <- Frame;
         m.k <- 1;
         m.data <- 0;
         m.frame_viol <- false)
     | Frame ->
       m.frame_viol <- m.frame_viol || violation;
       if m.k % b = 0 && m.k >= b && m.k <= 8 * b
       then (
         let j = (m.k / b) - 1 in
         if line then m.data <- m.data lor (1 lsl j));
       if m.k = (10 * b) - 1 then m.state <- Idle else m.k <- m.k + 1);
    m.prev <- line;
    out
  ;;
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; line : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { bad : 'a
    ; frame_done : 'a
    ; frame_data : 'a [@bits 8]
    ; timeout : 'a
    }
  [@@deriving hardcaml]
end

let create ~b (i : _ I.t) =
  let open Signal in
  if b < 1 then raise_s [%message "bit period must be >= 1" (b : int)];
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let phase_w = Int.max 1 (Int.ceil_log2 (b + 1)) in
  let run_w = Int.ceil_log2 ((10 * b) + 2) in
  let d w = wire w in
  (* state encoding: 0 = wait_idle, 1 = idle, 2 = frame *)
  let state_d = d 2
  and phase_d = d phase_w
  and bitidx_d = d 4
  and prev_d = d 1
  and data_d = d 8
  and bad_d = d 1
  and fviol_d = d 1
  and run_d = d run_w
  and tmo_d = d 1 in
  let state = reg spec state_d
  and phase = reg spec phase_d
  and bitidx = reg spec bitidx_d
  and prev = reg spec ~enable:vdd prev_d
  and data = reg spec data_d
  and bad_r = reg spec bad_d
  and fviol = reg spec fviol_d
  and run = reg spec run_d
  and tmo = reg spec tmo_d in
  let line = i.line in
  let in_wait = state ==:. 0
  and in_idle = state ==:. 1
  and in_frame = state ==:. 2 in
  let first_cycle_of_frame = bitidx ==:. 0 &: (phase ==:. 0) in
  let changed = line ^: prev in
  let violation =
    in_frame
    &: ((changed &: (phase <>:. 0) &: ~:first_cycle_of_frame)
        |: (bitidx ==:. 0 &: line)
        |: (bitidx ==:. 9 &: ~:line))
  in
  let last = in_frame &: (bitidx ==:. 9) &: (phase ==:. b - 1) in
  let run_next = mux2 line (zero run_w) (mux2 (run ==:. (10 * b) + 1) run (run +:. 1)) in
  let timeout_now = tmo |: (run_next >:. 10 * b) in
  let frame_done = last &: ~:violation &: ~:fviol in
  (* data bit j sampled at phase 0 of bit index j+1 (j = 0..7) *)
  let sample = in_frame &: (phase ==:. 0) &: (bitidx >=:. 1) &: (bitidx <=:. 8) in
  let data_sampled =
    List.init 8 ~f:(fun j ->
      mux2 (sample &: (bitidx ==:. j + 1)) line (bit data j))
    |> concat_lsb
  in
  let start = in_idle &: ~:line in
  let phase_inc = mux2 (phase ==:. b - 1) (zero phase_w) (phase +:. 1) in
  let bitidx_inc = mux2 (phase ==:. b - 1) (bitidx +:. 1) bitidx in
  state_d
  <== mux2 in_wait (mux2 line (of_int ~width:2 1) state)
      @@ mux2 start (of_int ~width:2 2)
      @@ mux2 last (of_int ~width:2 1) state;
  (* A frame starts at offset 0 in the cycle that sees the falling edge; the next cycle is
     offset 1: phase 1 (or bit index 1 when b = 1). *)
  let start_phase = if b = 1 then zero phase_w else of_int ~width:phase_w 1 in
  let start_bitidx = if b = 1 then of_int ~width:4 1 else zero 4 in
  phase_d <== mux2 start start_phase (mux2 in_frame phase_inc phase);
  bitidx_d <== mux2 start start_bitidx (mux2 in_frame bitidx_inc bitidx);
  prev_d <== line;
  data_d <== mux2 start (zero 8) (mux2 in_frame data_sampled data);
  bad_d <== (bad_r |: violation);
  fviol_d <== mux2 start gnd (mux2 in_frame (fviol |: violation) fviol);
  run_d <== run_next;
  tmo_d <== timeout_now;
  { O.bad = bad_r |: violation; frame_done; frame_data = data; timeout = timeout_now }
;;

let circuit ~b =
  let module C = Circuit.With_interface (I) (O) in
  C.create_exn ~name:(sprintf "pemu_uart_tx_monitor_b%d" b) (create ~b)
;;
