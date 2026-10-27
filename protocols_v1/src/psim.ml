(* Cycle-level co-simulation of one lane (ISA v1 model) running a program, its monitor
   package (reference interpreter and compiled ISA model, cross-checked every cycle) and a
   peer model, composed as in the chip (rtl_v1/Top_v1 with the engine):
   - ticks from the lane prescaler (divisor P; counter held at 0 while the lane is halted);
   - the lane reads the pads through a 2-flop synchroniser; the monitor gets the raw pads
     and synchronises them itself;
   - the monitor observes the lane's outputs masked by OWN, and the lane's xo bits only;
   - a blame reaches the lane one cycle later (registered).
   The peer sees, each cycle, the chip's pin drive of the previous edge (out/oe per pin) and
   returns its own drive; the pad value is resolved per pin: chip oe = 1 drives the pad,
   otherwise the peer's drive, otherwise the pull-up (1). Open-drain lines are wired-AND:
   the pad is 0 if either side pulls low. *)
open! Core
module L = Pemu_spec_v1.Lane_model
module Isa1 = Pemu_spec_v1.Isa1
module Lang = Pemu_monitor_v1.Lang
module Interp = Pemu_monitor_v1.Interp
module Mmodel = Pemu_monitor_v1.Mmodel
module Compile = Pemu_monitor_v1.Compile

type peer_drive =
  { drive_oe : int (* pins the peer drives *)
  ; drive_val : int
  }

type chip_view =
  { cycle : int
  ; out : int (* uio_out of the lane *)
  ; oe : int
  ; pad : int (* pads resolved in the previous cycle *)
  }

type setup =
  { prog : Isa1.t list
  ; own : int
  ; od : int
  ; cfg : int
  ; cfg2 : int
  ; p : int (* prescaler divisor *)
  ; contract : Lang.t
  ; open_drain_wired_and : int (* pins resolved as wired-AND (I2C) *)
  }

type event =
  | Fire of Lang.role * int
  | Push of int
  | Pop of int

type result =
  { events : (int * event) list (* cycle, event; in order *)
  ; pads : int array (* resolved pad value per cycle *)
  ; outs : (int * int) array (* uio_out, uio_oe per cycle *)
  ; steps : int (* ticks while running *)
  ; model_mismatch : int (* Interp vs Mmodel firing disagreements *)
  }

(* [tx_times]: earliest cycle at which the host may write each TX byte (default 0; shorter
   lists leave the rest at 0) *)
(* [clear_at]: cycles in which the host's clear_fault input is high.
   [on_cycle cy mi fired]: observation hook, called once per cycle with the monitor inputs and
   the interpreter's firings of that cycle (used by the C3 replay test). *)
let run
  ?(on_cycle = fun (_ : int) (_ : Interp.inputs) (_ : (Lang.role * int) list) -> ())
  ?(clear_at = [])
  ?(tx_bytes = [])
  ?(tx_times = [])
  ?(rx_pop_every = 1)
  ~setup ~cycles ~(peer : chip_view -> peer_drive) () =
  let words = Isa1.assemble setup.prog in
  let lane = L.create words in
  let pkg = Compile.compile_exn setup.contract in
  let mon = Interp.create setup.contract
  and mm = Mmodel.create pkg in
  let tx = Queue.of_list (List.mapi tx_bytes ~f:(fun i b -> b, Option.value (List.nth tx_times i) ~default:0)) in
  let events = Queue.create () in
  let pads = Array.create ~len:cycles 0xFF
  and outs = Array.create ~len:cycles (0, 0) in
  let sync1 = ref 0xFF
  and sync2 = ref 0xFF in
  let cnt = ref 0
  and blame_q = ref false
  and steps = ref 0
  and mism = ref 0 in
  let tx_level = ref 0 in
  let prev_out = ref 0
  and prev_oe = ref 0
  and prev_pad = ref 0xFF in
  for cy = 0 to cycles - 1 do
    let rst = cy > 1 in
    (* pads from last edge's chip drive and the peer *)
    let pd = peer { cycle = cy; out = !prev_out; oe = !prev_oe; pad = !prev_pad } in
    let pad =
      List.init 8 ~f:(fun i ->
        let b x = (x lsr i) land 1 = 1 in
        let chip_low = b !prev_oe && not (b !prev_out)
        and chip_high = b !prev_oe && b !prev_out
        and peer_low = b pd.drive_oe && not (b pd.drive_val)
        and peer_high = b pd.drive_oe && b pd.drive_val in
        let v =
          if b setup.open_drain_wired_and
          then not (chip_low || peer_low)
          else if chip_low || chip_high
          then chip_high
          else if peer_low || peer_high
          then peer_high
          else true
        in
        if v then 1 lsl i else 0)
      |> List.fold ~init:0 ~f:( lor )
    in
    pads.(cy) <- pad;
    (* the lane: running as in ISA v1 (faulted from the model's previous outputs) *)
    let run_in = rst in
    (* running at the start of this cycle (ISA v1: run && loaded && not faulted) *)
    let running = rst && not lane.L.faulted in
    let tick = running && !cnt = setup.p in
    (* the host writes TXF only while FIFO_ST shows room (as a driver polling FIFO_ST) *)
    let tx_push =
      (match Queue.peek tx with Some (_, t) -> cy >= t | None -> false) && cy % 7 = 3 && !tx_level < 8
    in
    let tx_wdata = if tx_push then fst (Queue.dequeue_exn tx) else 0 in
    let o =
      L.step lane
        { rst_sync_n = rst; tick; run = run_in; loaded = true; len = List.length setup.prog
        ; own = setup.own; od = setup.od; cfg = setup.cfg; cfg2 = setup.cfg2; pins = !sync2
        ; tx_push; tx_wdata; rx_pop = cy % rx_pop_every = 0; blame_in = !blame_q
        ; clear_fault = List.mem clear_at cy ~equal:Int.equal }
    in
    if tick then incr steps;
    let mi : Interp.inputs =
      { rst_sync_n = rst; running; tick; ui_in = 0; uio_in = pad
      ; uo_out = 0; uio_out = o.uio_out land setup.own; uio_oe = o.uio_oe land setup.own
      ; pop_ev = o.pop_ev; pop_data = o.pop_data; push_ev = o.push_ev; push_data = o.push_data }
    in
    let fa = Interp.step mon mi
    and fb = Mmodel.step mm mi in
    if not ([%equal: (Lang.role * int) list] fa fb) then incr mism;
    on_cycle cy mi fa;
    List.iter fa ~f:(fun (r, c) -> Queue.enqueue events (cy, Fire (r, c)));
    if o.push_ev then Queue.enqueue events (cy, Push o.push_data);
    if o.pop_ev then Queue.enqueue events (cy, Pop o.pop_data);
    blame_q := List.exists fa ~f:(fun (r, _) -> Lang.equal_role r Blame);
    (* prescaler: counts while running, ticks at P *)
    cnt := if running then if tick then 0 else !cnt + 1 else 0;
    sync2 := !sync1;
    sync1 := pad;
    tx_level := o.tx_level + (if tx_push then 1 else 0);
    prev_out := o.uio_out;
    prev_oe := o.uio_oe;
    prev_pad := pad;
    outs.(cy) <- (o.uio_out, o.uio_oe)
  done;
  { events = Queue.to_list events; pads; outs; steps = !steps; model_mismatch = !mism }
;;

let firings r = List.filter_map r.events ~f:(function c, Fire (ro, k) -> Some (c, ro, k) | _ -> None)
let pushes r = List.filter_map r.events ~f:(function _, Push b -> Some b | _ -> None)
let pops r = List.filter_map r.events ~f:(function _, Pop b -> Some b | _ -> None)

let show_firings r =
  firings r
  |> List.map ~f:(fun (c, ro, k) ->
    sprintf "%s%02X@%d" (match ro with Lang.Fail -> "F" | Blame -> "B") k c)
  |> String.concat ~sep:","
;;

(* run-length export of one or more pad bits for the sigrok front end (bit j of the sample
   = pad pin pins.(j)) *)
let write_rle ~file ~pins (a : int array) =
  let sample x = List.foldi pins ~init:0 ~f:(fun j acc p -> acc lor (((x lsr p) land 1) lsl j)) in
  let oc = Out_channel.create file in
  let last = ref (-1)
  and n = ref 0 in
  Array.iter a ~f:(fun x ->
    let s = sample x in
    if s = !last
    then incr n
    else (
      if !n > 0 then Out_channel.output_string oc (sprintf "%d %d\n" !n !last);
      last := s;
      n := 1));
  if !n > 0 then Out_channel.output_string oc (sprintf "%d %d\n" !n !last);
  Out_channel.close oc
;;
