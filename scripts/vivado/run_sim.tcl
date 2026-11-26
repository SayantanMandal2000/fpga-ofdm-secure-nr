# Run the system regression in Vivado xsim (batch) and keep the log and constellation dump.
#   vivado -mode batch -source scripts/vivado/run_sim.tcl
set root [file normalize [file join [file dirname [info script]] .. ..]]
open_project [file join $root build vivado ofdm_fpga.xpr]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
set simdir [file join $root build vivado ofdm_fpga.sim sim_1 behav xsim]
if {[file exists [file join $simdir constellation.csv]]} {
    file copy -force [file join $simdir constellation.csv] [file join $root build constellation.csv]
}
close_sim
