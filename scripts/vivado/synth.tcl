# Out-of-context synthesis of ofdm_top at 50 MHz: utilisation and timing reports in build/reports.
#   vivado -mode batch -source scripts/vivado/synth.tcl
set root [file normalize [file join [file dirname [info script]] .. ..]]
set part xc7z020clg400-1
if {[info exists ::env(OFDM_PART)]} { set part $::env(OFDM_PART) }
set rpt [file join $root build reports]
file mkdir $rpt
read_verilog [lsort [glob [file join $root rtl *.v]]]
read_xdc -mode out_of_context [file join $root constraints ofdm_top_ooc.xdc]
synth_design -top ofdm_top -part $part -mode out_of_context
report_utilization    -file [file join $rpt utilization.rpt]
report_timing_summary -file [file join $rpt timing_summary.rpt]
report_utilization -hierarchical -file [file join $rpt utilization_hier.rpt]
puts "Reports written to $rpt"
