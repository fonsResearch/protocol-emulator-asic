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

