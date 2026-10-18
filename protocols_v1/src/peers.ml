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
