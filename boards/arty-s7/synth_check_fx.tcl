# Out-of-context synthese-check van de FX-modules op de XC7S50:
# resources + timing bij 27 MHz (en een proefrit op 98,4 MHz).
#   vivado -mode batch -source synth_check_fx.tcl
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set outd [file join [file dirname [info script]] build]

foreach mod {tape_echo fdn_reverb} {
    create_project -in_memory -part xc7s50csga324-1
    read_verilog [list $repo/src/$mod.v $repo/src/tanh_lut.v]
    add_files $repo/tanh_table.hex
    synth_design -mode out_of_context -top $mod
    create_clock -name clk -period 37.037 [get_ports clk]
    report_utilization -file $outd/fx_${mod}_util.rpt
    report_timing_summary -file $outd/fx_${mod}_timing.rpt
    puts "== $mod @27MHz: WNS = [get_property SLACK [get_timing_paths -max_paths 1]] ns"
    create_clock -name clk98 -period 10.16 [get_ports clk] -add
    close_project
}
puts "FX-CHECK KLAAR"
