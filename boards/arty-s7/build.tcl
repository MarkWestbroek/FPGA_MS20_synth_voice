# ============================================================================
# build.tcl — Vivado batch-build voor de Arty S7-50 poort (non-project flow)
#
# Gebruik (werkt vanuit elke map):
#   vivado -mode batch -source boards/arty-s7/build.tcl
#
# Non-project flow met cwd = repo-root, zodat de $readmemh-bestanden
# (wavetable.hex, tanh_table.hex, note_*.hex) gewoon gevonden worden.
# De eerdere project-flow (launch_runs) draaide synthese in een run-map en
# liet de ROM's stilletjes leeg — Vivado geeft daar alleen een CRITICAL
# WARNING voor. Dit script maakt er een harde fout van.
#
# Resultaat: boards/arty-s7/build/synth_top_arty.bit + rapporten.
# ============================================================================

set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set board_dir [file join $repo_root boards arty-s7]
set build_dir [file join $board_dir build]
file mkdir $build_dir
cd $repo_root

read_verilog [list \
    $repo_root/src/synth_top.v \
    $repo_root/src/voice_engine.v \
    $repo_root/src/ks_string.v \
    $repo_root/src/mass_spring_resonator.v \
    $repo_root/src/ms20_filter.v \
    $repo_root/src/tanh_lut.v \
    $repo_root/src/note_to_period.v \
    $repo_root/src/note_phinc.v \
    $repo_root/src/spi_slave.v \
    $repo_root/src/spi_frame.v \
    $repo_root/src/pt8211_tx.v \
    $repo_root/src/i2s_tx.v \
    $repo_root/src/tape_echo.v \
    $repo_root/src/fdn_reverb.v \
    $board_dir/synth_top_arty.v \
]
read_xdc $board_dir/arty_s7.xdc

synth_design -top synth_top_arty -part xc7s50csga324-1

# Lege ROM's zijn hier een harde fout, geen waarschuwing.
if {[get_msg_config -count -severity {CRITICAL WARNING}] > 0} {
    error "STOP: CRITICAL WARNING(s) bij synthese (waarschijnlijk \$readmemh niet gevonden) - ROM's zouden leeg zijn."
}

opt_design
place_design
phys_opt_design
route_design

report_utilization  -file $build_dir/utilization.rpt
report_utilization  -hierarchical -hierarchical_depth 3 -file $build_dir/hier_util.rpt
report_timing_summary -file $build_dir/timing.rpt
write_checkpoint -force $build_dir/synth_top_arty_routed.dcp

set wns [get_property SLACK [get_timing_paths -max_paths 1]]
if {$wns < 0} { error "STOP: timing niet gehaald (WNS = $wns ns) — geen bitstream." }

write_bitstream -force $build_dir/synth_top_arty.bit
puts "KLAAR: $build_dir/synth_top_arty.bit (WNS = $wns ns)"
