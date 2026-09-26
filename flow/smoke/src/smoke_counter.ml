(* Toolchain smoke test: a mod-(wrap+1) counter with a safety observer.
   [bad] is high when the counter exceeds 9. With [wrap = 9] the property
   holds; with [wrap = 10] it is violated after 10 cycles. The circuit's only
   output is [bad], so it can be written as an AIGER miter directly. *)
open! Core
open Hardcaml
open Signal

let counter ~clock ~wrap =
  let spec = Reg_spec.create ~clock () in
  reg_fb spec ~width:4 ~f:(fun q -> mux2 (q ==:. wrap) (zero 4) (q +:. 1))

let circuit ~wrap =
  let clock = input "clock" 1 in
  let q = counter ~clock ~wrap in
  Circuit.create_exn ~name:"ctr" [ output "bad" (q >:. 9); output "q" q ]

let observer ~wrap =
  let clock = input "clock" 1 in
  let q = counter ~clock ~wrap in
  Circuit.create_exn ~name:"ctr" [ output "bad" (q >:. 9) ]

let%expect_test "cyclesim: wrap=9 never raises bad; wrap=10 raises bad at q=10" =
  List.iter [ 9; 10 ] ~f:(fun wrap ->
    let sim = Cyclesim.create (circuit ~wrap) in
    let q = Cyclesim.out_port sim "q" and bad = Cyclesim.out_port sim "bad" in
    (* Explicit loop: List.init does not guarantee left-to-right evaluation of a
       side-effecting [f] (Core's List.init evaluates from the last index), which
       reversed the trace in the first version of this test. *)
    let trace = Queue.create () in
    for _ = 1 to 12 do
      Cyclesim.cycle sim;
      Queue.enqueue
        trace
        (sprintf "%d%s" (Bits.to_int !q) (if Bits.to_bool !bad then "!" else ""))
    done;
    printf "wrap=%d: %s\n" wrap (String.concat ~sep:" " (Queue.to_list trace)));
  [%expect {|
    wrap=9: 1 2 3 4 5 6 7 8 9 0 1 2
    wrap=10: 1 2 3 4 5 6 7 8 9 10! 0 1
    |}]

let%expect_test "waveform" =
  let sim = Cyclesim.create (circuit ~wrap:9) in
  let waves, sim = Hardcaml_waveterm.Waveform.create sim in
  for _ = 1 to 12 do Cyclesim.cycle sim done;
  Hardcaml_waveterm.Waveform.print ~display_width:70 ~display_height:9 waves;
  [%expect {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │clock          ││┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌──│
    │               ││    └───┘   └───┘   └───┘   └───┘   └───┘   └───┘  │
    │bad            ││                                                   │
    │               ││───────────────────────────────────────────────────│
    │               ││────────┬───────┬───────┬───────┬───────┬───────┬──│
    │q              ││ 0      │1      │2      │3      │4      │5      │6 │
    │               ││────────┴───────┴───────┴───────┴───────┴───────┴──│
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
