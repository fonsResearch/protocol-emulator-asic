(* Cycle-level peer models for Psim. *)
open! Core

(* asynchronous 8N1 sender on pin [pin]: bit period [bp] cycles (float), frames start at
   given cycles; optional defects *)
type defect =
  | No_defect
  | Glitch of int * int * int (* frame index, cycle offset into the frame, length: inversion *)
  | Short_stop of int (* frame index: stop bit lasts 0.4 bit *)

let sender ~pin ~bp ~frames ~defect =
  (* frames: (start_cycle, byte). When frames overlap, the most recently started frame
     drives the line (a new start bit truncates the previous stop bit). *)
  let indexed = List.rev (List.mapi frames ~f:(fun i fr -> i, fr)) in
  fun (v : Psim.chip_view) ->
    let level =
      List.fold indexed ~init:None ~f:(fun acc (fi, (st, b)) ->
        match acc with
        | Some _ -> acc
        | None ->
          let t = Float.of_int (v.cycle - st) in
          if Float.(t < 0. || t >= 10. *. bp)
          then None
          else (
            let k = Float.to_int (t /. bp) in
            let bitv = if k = 0 then 0 else if k = 9 then 1 else (b lsr (k - 1)) land 1 in
            let bitv =
              match defect with
              | Glitch (f, off, len) when f = fi && v.cycle - st >= off && v.cycle - st < off + len ->
                1 - bitv
              | Short_stop f when f = fi && k = 9 && Float.(t >= 9.4 *. bp) -> 0
              | _ -> bitv
            in
            Some bitv))
    in
    let lv = Option.value level ~default:1 in
    { Psim.drive_oe = 1 lsl pin; drive_val = lv lsl pin }
;;

let frames_of ~bp ~st0 bytes ~gap =
  List.folding_map bytes ~init:st0 ~f:(fun st b ->
    let next = st + Float.to_int (Float.round_up (10. *. bp)) + gap b in
    next, (st, b))
;;


(* ---- SPI (doc/protocols/spi_v1.md): CS uio4, SCLK uio5, MOSI uio6, MISO uio7 ---- *)
let spi_cs = 4
let spi_sclk = 5
let spi_mosi = 6
let spi_miso = 7

(* SPI target peer for testing a controller lane. It reads the pads (chip-driven CS, SCLK,
   MOSI). While CS is low it drives MISO: the first bit at CS fall (after [tco] cycles), the
   next bit [tco] cycles after each shifting edge (trailing for CPHA 0, leading for CPHA 1).
   It samples MOSI on sampling edges and records one byte per CS assertion.
   [miso_glitch]: (frame, bit) whose MISO bit is inverted for [glitch_len] cycles starting at
   the sampling edge (a target that violates hold time). *)
type spi_target_peer =
  { drive : Psim.chip_view -> Psim.peer_drive
  ; received : unit -> int list (* MOSI bytes, one per completed frame *)
  }

let spi_target ~cpol ~cpha ~tco ~(send : int list) ?miso_glitch ?(glitch_len = 0) () =
  let send = Queue.of_list send in
  let received = ref [] in
  let prev_cs = ref 1 and prev_sclk = ref (if cpol then 1 else 0) in
  let in_frame = ref false and frame = ref (-1) in
  let tx = ref 0 and edges = ref 0 and rx = ref 0 and nrx = ref 0 in
  let miso = ref 1 and pending = ref [] (* (due cycle, value) *) in
  let glitch_until = ref (-1) in
  let bit_of k = (!tx lsr (7 - k)) land 1 in
  let drive (v : Psim.chip_view) =
    let cs = (v.pad lsr spi_cs) land 1 and sclk = (v.pad lsr spi_sclk) land 1 in
    let mosi = (v.pad lsr spi_mosi) land 1 in
    if !prev_cs = 1 && cs = 0
    then (
      in_frame := true;
      incr frame;
      tx := Option.value (Queue.dequeue send) ~default:0xFF;
      edges := 0;
      rx := 0;
      nrx := 0;
      if not cpha then pending := [ v.cycle + tco, bit_of 0 ]);
    if !in_frame && sclk <> !prev_sclk && cs = 0
    then (
      incr edges;
      let leading = !edges % 2 = 1 in
      let sampling = Bool.equal leading (not cpha) in
      if sampling
      then (
        rx := (!rx lsl 1) lor mosi;
        incr nrx;
        (match miso_glitch with
         | Some (f, b) when f = !frame && b = !nrx - 1 -> glitch_until := v.cycle + glitch_len
         | _ -> ()));
      (* shifting edge: next bit after tco *)
      if not sampling
      then (
        let k = if cpha then (!edges - 1) / 2 else !edges / 2 in
        if k <= 7 then pending := !pending @ [ v.cycle + tco, bit_of k ]));
    if !prev_cs = 0 && cs = 1 && !in_frame
    then (
      in_frame := false;
      if !nrx = 8 then received := !rx :: !received);
    List.iter !pending ~f:(fun (due, b) -> if due <= v.cycle then miso := b);
    pending := List.filter !pending ~f:(fun (due, _) -> due > v.cycle);
    prev_cs := cs;
    prev_sclk := sclk;
    let m = if v.cycle < !glitch_until then 1 - !miso else !miso in
    if cs = 0
    then { Psim.drive_oe = 1 lsl spi_miso; drive_val = m lsl spi_miso }
    else { Psim.drive_oe = 0; drive_val = 0 }
  in
  { drive; received = (fun () -> List.rev !received) }
;;

(* SPI controller peer for testing a target lane. Frames are scheduled in cycles: CS falls at
   t0, edge j (0..15) at t0 + setup + j hp, CS rises [hold] cycles after the last edge, the next
   frame starts [gap] cycles later. MOSI changes [mdly] cycles after each shifting edge (first
   bit at CS fall for CPHA 0). MISO is sampled from the pads at each sampling edge.
   Defects (each applies to one frame): *)
type spi_ctl_defect =
  | Ctl_ok
  | Early_rise of int * int (* frame, CS rises after this many edges *)
  | Mosi_at_sample of int * int (* frame, bit: MOSI changes at the sampling edge itself *)
  | Bad_idle of int (* frame: SCLK at the active level from 2 hp before CS falls until hp/2 after *)
  | Fast_pair of int * int (* frame, edge j: edge j+1 comes only [hp/3] after edge j *)

type spi_controller_peer =
  { cdrive : Psim.chip_view -> Psim.peer_drive
  ; sampled : unit -> int list (* MISO bytes, one per frame *)
  ; frames_end : int (* cycle after the last frame *)
  }

let spi_controller ~cpol ~cpha ~hp ~setup ~hold ~gap ~mdly ~t0 ~(bytes : int list) ?(defect = Ctl_ok) () =
  let idle = if cpol then 1 else 0 in
  (* per frame: cs fall, edge cycles, cs rise *)
  let frames =
    List.folding_mapi bytes ~init:t0 ~f:(fun fi st b ->
      let edges =
        Array.init 16 ~f:(fun j ->
          let base = st + setup + (j * hp) in
          match defect with
          | Fast_pair (f, j0) when f = fi && j > j0 -> base - hp + (hp / 3)
          | _ -> base)
      in
      let n_edges = match defect with Early_rise (f, n) when f = fi -> n | _ -> 16 in
      let rise = if n_edges = 16 then edges.(15) + hold else edges.(Int.max 0 (n_edges - 1)) + (hp / 2) in
      let next = rise + gap in
      next, (st, edges, n_edges, rise, b, fi))
  in
  let frames_end = match List.last frames with Some (_, _, _, r, _, _) -> r + gap | None -> t0 in
  let sampled = ref [] and cur = ref 0 and ncur = ref 0 in
  let cdrive (v : Psim.chip_view) =
    let c = v.cycle in
    let cs, sclk, mosi =
      match List.find frames ~f:(fun (st, _, _, rise, _, _) -> c >= st - (2 * hp) && c < rise + gap) with
      | None -> 1, idle, 1
      | Some (st, edges, n_edges, rise, b, fi) ->
        if c < st || c >= rise
        then (
          let bad = match defect with Bad_idle f when f = fi && c < st -> true | _ -> false in
          1, (if bad then 1 - idle else idle), 1)
        else (
          let n = Array.count (Array.sub edges ~pos:0 ~len:n_edges) ~f:(fun e -> e <= c) in
          let bad = match defect with Bad_idle f when f = fi && c < st + (hp / 2) -> true | _ -> false in
          let sclk = if bad then 1 - idle else if n % 2 = 1 then 1 - idle else idle in
          (* MOSI bit index in force at cycle c *)
          let change k =
            (* cycle at which bit k appears *)
            let e = if cpha then edges.(2 * k) else if k = 0 then st else edges.((2 * k) - 1) in
            let e = e + (if k = 0 && not cpha then 0 else mdly) in
            match defect with
            | Mosi_at_sample (f, bk) when f = fi && bk = k -> (if cpha then edges.((2 * k) + 1) else edges.(2 * k))
            | _ -> e
          in
          let k = List.fold (List.range 0 8) ~init:(-1) ~f:(fun acc k -> if change k <= c then k else acc) in
          let m = if k < 0 then 1 else (b lsr (7 - k)) land 1 in
          (* MISO sampling at sampling edges *)
          Array.iteri edges ~f:(fun j e ->
            if j < n_edges && e = c && Bool.equal (j % 2 = 0) (not cpha)
            then (
              cur := (!cur lsl 1) lor ((v.pad lsr spi_miso) land 1);
              incr ncur;
              if !ncur = 8 then (sampled := (!cur land 0xFF) :: !sampled; cur := 0; ncur := 0)));
          0, sclk, m)
    in
    { Psim.drive_oe = (1 lsl spi_cs) lor (1 lsl spi_sclk) lor (1 lsl spi_mosi)
    ; drive_val = (cs lsl spi_cs) lor (sclk lsl spi_sclk) lor (mosi lsl spi_mosi)
    }
  in
  { cdrive; sampled = (fun () -> List.rev !sampled); frames_end }
;;

(* ---- I2C (doc/protocols/i2c_v1.md): SCL uio2, SDA uio3, open-drain wired-AND ---- *)
let i2c_scl = 2
let i2c_sda = 3

(* I2C target peer for testing a controller lane. It watches the resolved pads of the previous
   cycle and detects START/Sr/STOP and SCL edges. It answers address [addr] (7 bit): ACK in the
   ACK cell, then receives (write) or sends [read_data] in order (read). SDA changes [dd]
   cycles after an SCL fall (its data hold time). Options:
   - [nack_write]: index (0-based, over all written bytes) of a data byte it NACKs;
   - [stretch]: after the SCL fall that ends each ACK cell it holds SCL low that many cycles;
   - [ack_on_rise] (misbehaviour, A1): it pulls SDA for the address ACK [dd] cycles after the
     SCL rise of the 8th address cell instead of after its fall;
   - [change_in_high] d (misbehaviour, A2): from the third read data cell of each byte on, the
     cell's bit is put on SDA d cycles after the SCL rise instead of [dd] after the fall.
   [log ()] is the transcript: S, Sr, P, A<addr><R|W><+|->, W<byte><+|->, R<byte><+|-> (the
   controller's ACK/NACK after a read byte). *)
type i2c_target_peer =
  { drive : Psim.chip_view -> Psim.peer_drive
  ; log : unit -> string
  }

type i2c_tmode =
  | T_idle
  | T_addr
  | T_ack_addr of bool (* read *)
  | T_write
  | T_ack_w of bool (* acked *)
  | T_read of int * int (* byte, bits driven *)
  | T_ack_r
  | T_ignore

let i2c_target ~addr ~read_data ?(dd = 8) ?(nack_write = -1) ?(stretch = 0) ?(ack_on_rise = false)
    ?change_in_high () =
  let last = ref 0xFF in
  let mode = ref T_idle and bits = ref 0 and shift = ref 0 in
  let sda_rel = ref true and pend = ref None in
  let scl_hold_until = ref (-1) in
  let rd = Queue.of_list read_data and nw = ref 0 and ctl_ack = ref false and rcell = ref 0 in
  let log = Queue.create () in
  let in_tx = ref false and own_change = ref (-100) in
  let set_sda cy lv = pend := Some (cy + dd, lv) in
  let drive (v : Psim.chip_view) =
    let b x i = (x lsr i) land 1 = 1 in
    let scl0 = b !last i2c_scl and sda0 = b !last i2c_sda in
    let scl = b v.pad i2c_scl and sda = b v.pad i2c_sda in
    let cy = v.cycle in
    (* an SDA edge within 4 cycles of the peer's own SDA change is its own, not a condition *)
    let own = cy - !own_change <= 4 in
    if scl0 && scl && sda0 && (not sda) && not own
    then (
      Queue.enqueue log (if !in_tx then "Sr" else "S");
      in_tx := true;
      mode := T_addr;
      bits := 0;
      shift := 0;
      pend := None;
      sda_rel := true)
    else if scl0 && scl && (not sda0) && sda && not own
    then (
      Queue.enqueue log "P";
      in_tx := false;
      mode := T_idle;
      pend := None;
      sda_rel := true)
    else if (not scl0) && scl
    then (
      match !mode with
      | T_addr | T_write ->
        shift := ((!shift lsl 1) lor if sda then 1 else 0) land 0xFF;
        incr bits;
        if ack_on_rise && Poly.(!mode = T_addr) && !bits = 8 && !shift lsr 1 = addr then set_sda cy false
      | T_read (d, k) when Option.is_some change_in_high && !rcell >= 2 && k < 8 ->
        pend := Some (cy + Option.value_exn change_in_high, b d (7 - k));
        mode := T_read (d, k + 1)
      | T_ack_r -> ctl_ack := not sda
      | _ -> ())
    else if scl0 && not scl
    then (
      let boundary () = if stretch > 0 then scl_hold_until := cy + stretch in
      match !mode with
      | T_addr when !bits = 8 ->
        let rw = !shift land 1 = 1 in
        let hit = !shift lsr 1 = addr in
        Queue.enqueue log (sprintf "A%02X%c%c" (!shift lsr 1) (if rw then 'R' else 'W') (if hit then '+' else '-'));
        if hit
        then (
          set_sda cy false;
          mode := T_ack_addr rw)
        else mode := T_ignore
      | T_ack_addr rw ->
        boundary ();
        if rw
        then (
          let d = Option.value (Queue.dequeue rd) ~default:0xFF in
          set_sda cy (b d 7);
          rcell := 0;
          mode := T_read (d, 1))
        else (
          set_sda cy true;
          mode := T_write;
          bits := 0;
          shift := 0)
      | T_write when !bits = 8 ->
        let ack = !nw <> nack_write in
        incr nw;
        Queue.enqueue log (sprintf "W%02X%c" !shift (if ack then '+' else '-'));
        if ack then set_sda cy false;
        mode := T_ack_w ack
      | T_ack_w ack ->
        boundary ();
        set_sda cy true;
        if ack
        then (
          mode := T_write;
          bits := 0;
          shift := 0)
        else mode := T_ignore
      | T_read (d, k) ->
        (* a fall ends one read cell; [rcell] counts them *)
        incr rcell;
        if !rcell = 8
        then (
          set_sda cy true;
          Queue.enqueue log (sprintf "R%02X" d);
          mode := T_ack_r)
        else if not (Option.is_some change_in_high && !rcell >= 2)
        then (
          set_sda cy (b d (7 - k));
          mode := T_read (d, k + 1))
      | T_ack_r ->
        boundary ();
        Queue.enqueue log (if !ctl_ack then "+" else "-");
        if !ctl_ack
        then (
          let d = Option.value (Queue.dequeue rd) ~default:0xFF in
          set_sda cy (b d 7);
          rcell := 0;
          mode := T_read (d, 1))
        else mode := T_ignore
      | _ -> ());
    (match !pend with
     | Some (t, lv) when cy >= t ->
       if Bool.(lv <> !sda_rel) then own_change := cy;
       sda_rel := lv;
       pend := None
     | _ -> ());
    last := v.pad;
    let scl_low = cy <= !scl_hold_until in
    let oe = (if !sda_rel then 0 else 1 lsl i2c_sda) lor if scl_low then 1 lsl i2c_scl else 0 in
    { Psim.drive_oe = oe; drive_val = 0 }
  in
  { drive
  ; log =
      (fun () ->
        Queue.to_list log
        |> List.fold ~init:[] ~f:(fun acc s ->
          match s, acc with
          | ("+" | "-"), x :: rest -> (x ^ s) :: rest
          | _ -> s :: acc)
        |> List.rev
        |> String.concat ~sep:" ")
  }
;;
