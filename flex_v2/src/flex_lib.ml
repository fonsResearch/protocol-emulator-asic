(* Held-out protocol contracts (plan step 11, log/flexibility_v2.md). Contract language v1 as
   frozen; each contract is committed before its firmware (procedural isolation). *)
open! Core
open Pemu_monitor_v1.Lang

(* ---- 1-Wire controller, standard speed (doc/protocols/onewire_v1.md) ----
   DQ = uio2, open drain; one step = 1 us at P = 29. drv = the chip pulls DQ; line = bus level.
   s0 = the first step of a pull, L = its length in steps. Language v1 constraints that shape
   this text (log/flexibility_v2.md section 2): one elapsed/register modifier per instruction, no
   negated elapsed tests, if branches and guard handlers start with a consuming statement, at most
   7 distinct window values (here 2, 13, 47, 58, 61, 361, 480). *)
let onewire_ctl () =
  let drv = v "drv" and line = v "line" in
  (* The monitor ISA cannot branch on elapsed time (a branch condition is a bank predicate, the
     unit-local modifiers attach only to requirements and expects).  Pull classes are therefore
     separated by fixed time points: a pull released by s0 + 13 is short (write-1, read), one
     released in s0 + 61 .. s0 + 118 is a write-0, one still held at s0 + 118 is a reset.  After a
     write-0 the chip keeps the bus released until s0 + 124 at least, so the device watcher may
     ignore the line between s0 + 13 and s0 + 118. *)
  let master =
    watcher "master" ~base:0x10
      [ loop
          [ await_idle drv (* s0 *)
          ; skip 13 (* anchor s0 + 13 *)
          ; if_ drv
              [ hold drv ~for_:47 ~else_:(fail 1) (* F11: no release in s0 + 14 .. s0 + 60 *)
              ; guard !!drv
                  [ skip 58 (* s0 + 61 .. s0 + 118 *) ]
                  ~on:[ (* write-0 released at r *) hold !!drv ~for_:2 ~else_:(fail 4) ]
              ; if_ drv
                  [ (* reset: F12 L >= 480, F13 released r .. r + 480 *)
                    hold drv ~for_:361 ~else_:(fail 2)
                  ; await_idle !!drv
                  ; hold !!drv ~for_:480 ~else_:(fail 3)
                  ]
                  [ (* write-0: F14 released for 61 more steps (r + 63 >= s0 + 124) *)
                    hold !!drv ~for_:61 ~else_:(fail 4)
                  ]
              ]
              [ (* short pull: F14 no new pull until s0 + 61 *)
                hold !!drv ~for_:47 ~else_:(fail 4)
              ]
          ]
      ]
  in
  let device =
    watcher "device" ~base:0x20
      [ loop
          [ guard drv
              [ (* B21: while the chip is released the line stays high *)
                loop [ hold line ~for_:480 ~else_:(blame 1) ]
              ]
              ~on:
                [ skip 13 (* s0 + 13 *)
                ; if_ drv
                    [ skip 47
                    ; skip 58 (* s0 + 118 *)
                    ; if_ drv
                        [ (* reset: presence *)
                          await_idle !!drv (* release r *)
                        ; skip 2 (* synchroniser lag: the line is read from r + 2 on *)
                        ; await !!line (win 13 61 ~early:(blame 2) ~else_:(blame 3))
                        ; hold_until !!line line (win 47 480 ~else_:(blame 4))
                        ]
                        [ (* write-0: the line is high again *)
                          await line (win 2 61 ~else_:(blame 5))
                        ]
                    ]
                    [ (* short pull (write-1 or read): a read-0 ends within 61 steps *)
                      await line (win 2 61 ~else_:(blame 5))
                    ]
                ]
          ]
      ]
  in
  { name = "onewire_ctl_v1"
  ; observables = [ "drv", Drive 2; "line", Uio_in 2 ]
  ; watchers = [ master; device ]
  }
;;
