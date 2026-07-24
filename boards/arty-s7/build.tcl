# ============================================================================
# build.tcl — Vivado batch-build voor de Arty S7-50 poort
#
# Gebruik (na installatie van Vivado ML Standard, gratis editie):
#   cd boards/arty-s7
#   vivado -mode batch -source build.tcl
#
# Resultaat: build/ms20_arty.runs/impl_1/synth_top_arty.bit
# Flashen: Vivado Hardware Manager (GUI) of program.tcl hiernaast.
# ============================================================================

set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set build_dir [file join [file dirname [info script]] build]

create_project ms20_arty $build_dir -part xc7s50csga324-1 -force

# Vendor-neutrale RTL (testbenches niet meesynthetiseren)
add_files [list \
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
]

# LUT-inhoud ($readmemh): toevoegen zodat Vivado ze bij synthese vindt
add_files [list \
    $repo_root/wavetable.hex \
    $repo_root/tanh_table.hex \
    $repo_root/note_period.hex \
    $repo_root/note_phinc.hex \
]

# Bord-specifieke wrapper + constraints
add_files [file join [file dirname [info script]] synth_top_arty.v]
add_files -fileset constrs_1 [file join [file dirname [info script]] arty_s7.xdc]

set_property top synth_top_arty [current_fileset]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthese mislukt — zie $build_dir/ms20_arty.runs/synth_1/runme.log"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementatie mislukt — zie $build_dir/ms20_arty.runs/impl_1/runme.log"
}

open_run impl_1
report_utilization -file $build_dir/utilization.rpt
report_timing_summary -file $build_dir/timing.rpt
puts "KLAAR: $build_dir/ms20_arty.runs/impl_1/synth_top_arty.bit"
