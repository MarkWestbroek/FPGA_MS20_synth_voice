# Diagnose: lijst de slechtste setup-paden van de laatste impl-run.
#   vivado -mode batch -source report_paths.tcl
set dir [file dirname [info script]]
open_checkpoint $dir/build/ms20_arty.runs/impl_1/synth_top_arty_routed.dcp
report_timing -max_paths 40 -nworst 1 -slack_lesser_than 0 \
    -file $dir/build/failing_paths.rpt
puts "KLAAR: $dir/build/failing_paths.rpt"
