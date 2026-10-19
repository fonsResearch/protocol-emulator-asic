(* Proof-side contents checker for USB-LS TX (doc/protocols/usb_ls_v1.md G7, G9 values; [P]: part
   of the A2 harness, not of the chip). Written from the protocol document and USB 2.0,
   independently of the lane's serializer (spec_v1 Lane_circuit): it is a low-speed receiver
   that, at every lane step, NRZI-decodes the chip's own D+/D- outputs, removes stuffed bits and
   compares the packet with the bytes the lane popped.
   - The PID and N are the last two bytes popped before the packet's first K (host framing).
   - SYNC: the first 8 decoded bits must be 0000000 then 1.
   - Byte d of the packet: d = 0 is the PID; 1 <= d <= N are payload bytes, compared in order
     with the bytes popped during the packet (a 2-entry queue; overflow or an empty queue is a
     mismatch); the last two bytes are the CRC field.
   - Stuffing: after six decoded 1 bits the next step must be a transition (a stuffed 0).
   - At the first SE0 of a packet that was not aborted: byte aligned, exactly N + 3 bytes after
     SYNC, and the CRC field equals the ones complement of CRC-16 (x^16 + x^15 + x^2 + 1, initial
     all ones, LSB-first data) over the payload bits, sent in the same bit order.
   - A push inside a packet marks an abort and must carry 2; after it the decoder stops until
     the end of the packet. The first push after a complete packet must carry 0; a push outside
     a packet otherwise must carry 1 with the last popped byte (N) > 8.
   All state is cleared while the lane is not running. *)
open! Core
open Hardcaml
open Signal

let create ~clock ~running ~step ~dp ~dm ~pop_ev ~pop_data ~push_ev ~push_data =
  let rs = Reg_spec.create ~clock () in
  let fb n w f =
    let d = wire w in
    let q = reg rs d -- n in
    d <== mux2 ~:running (zero w) (f q);
    q
  in
  let j = ~:dp &: dm and k = dp &: ~:dm and se0 = ~:dp &: ~:dm in
  let jk = j |: k in
  let in_pkt_w = wire 1 and aborted_w = wire 1 in
  let in_pkt = in_pkt_w and aborted = aborted_w in
  (* the last two pops (outside or inside a packet) *)
  let pop1 = fb "u_pop1" 8 (fun q -> mux2 pop_ev pop_data q) in
  let pop2 = fb "u_pop2" 8 (fun q -> mux2 pop_ev pop1 q) in
  let start = step &: ~:in_pkt &: k in
  let pid_r = fb "u_pid" 8 (fun q -> mux2 start pop2 q) in
  let n_r = fb "u_n" 8 (fun q -> mux2 start pop1 q) in
  let live = step &: in_pkt &: ~:aborted &: jk in
  let lvl = fb "u_lvl" 1 (fun q -> mux2 start vdd (mux2 live k q)) in
  let b = ~:(k ^: lvl) (* level unchanged = 1 *) in
  let onesc_w = wire 3 in
  let stuff_slot = onesc_w ==:. 6 in
  let data = live &: ~:stuff_slot in
  let stuff_err = live &: stuff_slot &: b in
  let onesc =
    fb "u_ones" 3 (fun q -> mux2 start (zero 3) (mux2 live (mux2 stuff_slot (zero 3) (mux2 b (q +:. 1) (zero 3))) q))
  in
  onesc_w <== onesc;
  (* SYNC: bit 0 is the start step; bits 1..7 follow *)
  let sync_cnt = wire 4 in
  let in_sync = sync_cnt <:. 8 in
  let sync_q = fb "u_sync" 4 (fun q -> mux2 start (of_int ~width:4 1) (mux2 (data &: (q <:. 8)) (q +:. 1) q)) in
  sync_cnt <== sync_q;
  let sync_err = data &: in_sync &: mux2 (sync_cnt ==:. 7) ~:b b in
  let dbit = data &: ~:in_sync in
  let bc = fb "u_bc" 3 (fun q -> mux2 start (zero 3) (mux2 dbit (q +:. 1) q)) in
  let sh = fb "u_sh" 8 (fun q -> mux2 dbit (b @: select q 7 1) q) in
  let byte_v = b @: select sh 7 1 in
  let byte_done = dbit &: (bc ==:. 7) in
  let d = fb "u_d" 5 (fun q -> mux2 start (zero 5) (mux2 byte_done (q +:. 1) q)) in
  let d8 = uresize d 8 in
  let is_pid = d ==:. 0 in
  let is_payload = ~:is_pid &: (d8 <=: n_r) in
  (* payload queue: pops inside the packet, in order *)
  let enq = in_pkt &: pop_ev in
  let deq = byte_done &: is_payload in
  let qcnt_w = wire 2 and qa_w = wire 8 in
  let head = mux2 (qcnt_w ==:. 0) pop_data qa_w in
  let q_err = (deq &: (qcnt_w ==:. 0) &: ~:enq) |: (enq &: ~:deq &: (qcnt_w ==:. 2)) in
  let qb = fb "u_qb" 8 (fun q -> mux2 enq pop_data q) in
  let qa =
    fb "u_qa" 8 (fun q ->
      mux2 (enq &: deq)
        (mux2 (qcnt_w ==:. 2) qb pop_data)
        (mux2 enq (mux2 (qcnt_w ==:. 0) pop_data q) (mux2 deq qb q)))
  in
  qa_w <== qa;
  let qcnt =
    fb "u_qcnt" 2 (fun q ->
      mux2 start (zero 2)
        (mux2 (enq &: ~:deq &: (q <:. 2)) (q +:. 1) (mux2 (deq &: ~:enq &: (q >:. 0)) (q -:. 1) q)))
  in
  qcnt_w <== qcnt;
  let byte_mm = byte_done &: ((is_pid &: (byte_v <>: pid_r)) |: (is_payload &: (byte_v <>: head))) in
  (* CRC over payload bits: data bits after the PID go through a 16-bit delay line; the bit
     leaving it updates the CRC, so at the end the line holds the CRC field *)
  let crc_in = dbit &: ~:is_pid in
  let nin = fb "u_nin" 5 (fun q -> mux2 start (zero 5) (mux2 (crc_in &: (q <:. 16)) (q +:. 1) q)) in
  let dl = fb "u_dl" 16 (fun q -> mux2 crc_in (b @: select q 15 1) q) in
  let outb = bit dl 0 in
  let crc =
    fb "u_crc" 16 (fun q ->
      let fbk = bit q 0 ^: outb in
      let shifted = srl q 1 in
      mux2 start (ones 16) (mux2 (crc_in &: (nin ==:. 16)) (shifted ^: mux2 fbk (of_int ~width:16 0xA001) (zero 16)) q))
  in
  let end_ = step &: in_pkt &: se0 in
  let end_ok =
    (bc ==:. 0) &: (d8 ==: n_r +:. 3) &: (nin ==:. 16) &: (dl ==: (crc ^: ones 16))
  in
  let end_mm = end_ &: ~:aborted &: ~:end_ok in
  (* packet state *)
  let in_pkt_q = fb "u_in" 1 (fun q -> mux2 start vdd (mux2 end_ gnd q)) in
  in_pkt_w <== in_pkt_q;
  let abort_now = in_pkt &: push_ev in
  let aborted_q = fb "u_ab" 1 (fun q -> mux2 start gnd (mux2 abort_now vdd q)) in
  aborted_w <== aborted_q;
  let expect0 = fb "u_e0" 1 (fun q -> mux2 (end_ &: ~:aborted) vdd (mux2 push_ev gnd q)) in
  let status_mm =
    (abort_now &: (push_data <>:. 2))
    |: (push_ev &: ~:in_pkt &: expect0 &: (push_data <>:. 0))
    |: (push_ev &: ~:in_pkt &: ~:expect0 &: ((push_data <>:. 1) |: (pop1 <=:. 8)))
  in
  let mismatch = stuff_err |: sync_err |: byte_mm |: q_err |: end_mm |: status_mm in
  ( mismatch
  , [ "u_stuff", stuff_err; "u_sync_err", sync_err; "u_byte_mm", byte_mm; "u_q_err", q_err
    ; "u_end_mm", end_mm; "u_status_mm", status_mm; "u_in", in_pkt; "u_d", d ] )
;;
