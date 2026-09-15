# Name the combinational loop(s) Quartus is estimating through.
#
# WHY: MacLC.sdc's kernel-cap note attributes the loop to setexecOPC feeding the
# setstate mux trees in TG68KdotC_Kernel.vhd. Reading the RTL does not support
# that: across all 15 `IF setexecOPC` guards in the big decode process the ONLY
# signals assigned are datatype / dest_2ndHbits / dest_areg / dest_hbits /
# source_2ndHbits / source_areg / source_lowbits, and none of them feed
# setexecOPC's own inputs (setstate, next_micro_state, set_direct_data,
# exec_write_back, state, addrvalue). The node counts disagree too — the note
# says 150, the 2026-09-15 build says 132.
#
# So before cutting anything in a working CPU core, get the loop from the tool
# that is complaining about it rather than from a description of it.
#
# Usage (project must NOT be mid-compile — quartus_sta takes the project DB):
#   "$QUARTUS_BIN/quartus_sta" -t scripts/report_loops.tcl
project_open MacLC
create_timing_netlist -model slow
read_sdc
update_timing_netlist
puts "===== COMBINATIONAL LOOPS ====="
if {[catch {report_loops -detail full_path -stdout} err]} {
	puts "report_loops failed: $err"
	puts "falling back to summary detail"
	catch {report_loops -stdout} err2
	puts $err2
}
project_close
