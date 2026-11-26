# Create the Vivado project from the repository sources.
#   vivado -mode batch -source scripts/vivado/create_project.tcl
# Part: set OFDM_PART in the environment to override (default: Zynq-7020).
set root [file normalize [file join [file dirname [info script]] .. ..]]
set part xc7z020clg400-1
if {[info exists ::env(OFDM_PART)]} { set part $::env(OFDM_PART) }

create_project ofdm_fpga [file join $root build vivado] -part $part -force
add_files -norecurse -fileset sources_1 [lsort [glob [file join $root rtl *.v]]]
add_files -norecurse -fileset sim_1     [lsort [glob [file join $root tb *.v]]]
add_files -norecurse -fileset constrs_1 [file join $root constraints ofdm_top_ooc.xdc]
set_property top ofdm_top    [get_filesets sources_1]
set_property top tb_ofdm_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Project created in [file join $root build vivado]"
