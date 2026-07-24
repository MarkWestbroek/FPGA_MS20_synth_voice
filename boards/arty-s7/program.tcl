# Flash de bitstream naar de Arty S7-50 via de onboard USB-JTAG (micro-USB).
#   vivado -mode batch -source program.tcl
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7s50*] 0]
current_hw_device $dev
set bit [file join [file dirname [info script]] build ms20_arty.runs impl_1 synth_top_arty.bit]
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Geflasht: $bit"
