(* All harnesses (slice + assume-guarantee), for the emitter and the counterexample
   replayer. Mutant names ("m_...") are resolved by [Harness.find]. *)
open! Core
open Hardcaml

let all ?debug () = Harness.all ?debug () @ Ag_harness.all ?debug () @ Ag_v1.all ?debug () @ A1_lane.all ?debug () @ Presc16.all ?debug () @ Top_props.all ?debug () @ Mon_ref.all ?debug () @ Mon_fetch.all ?debug () @ Ag_pkg.all ?debug ()

let find ?debug name =
  if String.is_prefix name ~prefix:"w2_"
  then Witness_v2.find ?debug name
  else if String.is_prefix name ~prefix:"m2c_"
  then Cmut.find name
  else if String.is_prefix name ~prefix:"m2_"
  then Mut_v2_harness.find ?debug name
  else if String.is_prefix name ~prefix:"m_"
  then Harness.find ?debug name
  else List.find_exn (all ?debug ()) ~f:(fun c -> String.equal (Circuit.name c) name)
;;
