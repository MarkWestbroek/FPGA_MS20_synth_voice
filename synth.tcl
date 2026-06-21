# ============================================================================
# synth.tcl — Gowin EDA Synthesis Script
#
# Te draaien vanuit de Gowin IDE Tcl-console:
#   cd E:/Dev/Gowin/MS20_synth_voice
#   source synth.tcl
#
# Of via command-line (indien license beschikbaar):
#   gw_sh.exe -tcl synth.tcl
# ============================================================================

# Projectconfiguratie
set project_name  "MS20_Synth_Voice"
set device        "GW2A-LV18PG256C8/I7"
set top_module    "synth_top"

# Source files (volgorde maakt niet uit voor Gowin)
set src_files {
    src/tanh_lut.v
    src/ks_string.v
    src/mass_spring_resonator.v
    src/ms20_filter.v
    src/synth_top.v
}

# Maak project aan
if {[catch {create_project -name $project_name -dir impl -force}]} {
    puts "Project bestaat al, open bestaand project..."
}

# Set device en top
set_device -name $device
set_top_module $top_module

# Voeg source files toe
foreach f $src_files {
    add_file -type verilog $f
    puts "  + $f"
}

# Optionele constraints (alleen als je een .cst bestand hebt)
# add_file -type cst src/pins.cst

# Optioneel: lees extra synthese-opties
# set_option -synthesis_tool "gowinsynthesis"

puts "\nBestanden toegevoegd. Klik 'Run Synthesis' in de IDE of gebruik:"
puts "  run_synthesis"
puts ""
puts "Na synthese: bekijk impl/gwsynthesis/$project_name\_syn.rpt.html"
