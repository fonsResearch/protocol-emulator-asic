(* Which constructs the frozen contract language v1 and its compiler accept (step 11 probe). *)
open! Core
open Pemu_monitor_v1.Lang
module C = Pemu_monitor_v1.Compile

let probe name body =
  let c =
    { name; observables = [ "drv", Drive 2; "line", Uio_in 2 ]; watchers = [ watcher "w" ~base:0x10 [ loop body ] ] }
  in
  let r =
    match validate c with
    | Error es -> "validate: " ^ String.concat ~sep:"; " es
    | Ok _ -> (match C.compile c with Ok m -> sprintf "ok (%d instr)" (Array.length m.units.(0).code) | Error e -> "compile: " ^ e)
  in
  printf "%-34s %s\n" name r
;;

let drv = v "drv"
let el t = Elapsed_ge { mark = 0; t }

let%expect_test "probe" =
  let pre = [ await_idle drv; mark 0; await_idle !!drv ] in
  probe "expect when el -> el" (pre @ [ expect ~when_:(el 14) (el 61) ~else_:(fail 1) ]);
  probe "expect el, then if el" (pre @ [ expect (el 61) ~else_:(fail 1); if_ (el 121) [ skip 1 ] [ skip 2 ] ]);
  probe "if el, empty else" (pre @ [ if_ (el 121) [ skip 1 ] [] ]);
  probe "if drv after skip" [ await_idle drv; skip 13; if_ drv [ hold drv ~for_:47 ~else_:(fail 1) ] [ skip 1 ] ];
  probe "hold_until ~when_" (pre @ [ hold_until ~when_:(el 14) !!drv (el 61) (win 1 480 ~else_:(fail 2)) ]);
  probe "expect (drv ||| el)" (pre @ [ expect (!!drv ||| el 61) ~else_:(fail 1) ]);
  probe "expect (!el)" (pre @ [ expect !!(el 14) ~else_:(fail 1) ]);
  probe "hold 1; expect el" (pre @ [ hold !!drv ~for_:1 ~else_:(fail 3); expect (el 481) ~else_:(fail 2); skip 1 ]);
  probe "await_idle; if el" (pre @ [ if_ (el 121) [ skip 1 ] [ skip 2 ] ]);
  probe "skip; mark; if drv" [ await_idle drv; skip 13; mark 0; if_ drv [ skip 1 ] [ skip 2 ] ];
  probe "hold 2; if el" (pre @ [ hold !!drv ~for_:2 ~else_:(fail 4); if_ (el 121) [ skip 1 ] [ skip 2 ] ]);
  probe "await_idle; skip 2; if el" (pre @ [ skip 2; if_ (el 121) [ skip 1 ] [ skip 2 ] ]);
  probe "hold 2; expect el; hold" (pre @ [ hold !!drv ~for_:2 ~else_:(fail 3); expect (el 484) ~else_:(fail 2); hold !!drv ~for_:480 ~else_:(fail 3) ]);
  probe "if branch ends, loop await_idle" [ loop [ await_idle drv; mark 0; skip 13; if_ drv [ hold drv ~for_:47 ~else_:(fail 1) ] [ hold !!drv ~for_:47 ~else_:(fail 4) ] ] ];
  probe "await win early" (pre @ [ await !!(v "line") (win 13 61 ~early:(blame 2) ~else_:(blame 3)) ]);
  probe "await line win 2" (pre @ [ await (v "line") (win 2 61 ~else_:(blame 5)) ]);
  probe "await; hold_until line" (pre @ [ await !!(v "line") (win 13 61 ~early:(blame 2) ~else_:(blame 3)); hold_until !!(v "line") (v "line") (win 47 480 ~else_:(blame 4)) ]);
  [%expect {|
    expect when el -> el               compile: register or elapsed term inside a predicate (only one top-level modifier)
    expect el, then if el              compile: register or elapsed term inside a predicate (only one top-level modifier)
    if el, empty else                  validate: w: if branches must start with a consuming statement
    if drv after skip                  ok (4 instr)
    hold_until ~when_                  compile: register or elapsed term inside a predicate (only one top-level modifier)
    expect (drv ||| el)                compile: register or elapsed term inside a predicate (only one top-level modifier)
    expect (!el)                       compile: register or elapsed term inside a predicate (only one top-level modifier)
    hold 1; expect el                  ok (4 instr)
    await_idle; if el                  compile: register or elapsed term inside a predicate (only one top-level modifier)
    skip; mark; if drv                 ok (4 instr)
    hold 2; if el                      compile: register or elapsed term inside a predicate (only one top-level modifier)
    await_idle; skip 2; if el          compile: register or elapsed term inside a predicate (only one top-level modifier)
    hold 2; expect el; hold            ok (4 instr)
    if branch ends, loop await_idle    ok (4 instr)
    await win early                    ok (3 instr)
    await line win 2                   ok (3 instr)
    await; hold_until line             ok (4 instr)
    |}]
;;
