import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project camera_to_dsi_display.al
elaborate -top design_top_wrapper

read_adc ../user_source/constraints_source/pin.adc
read_ip_adc -ip ddr2 -file ../user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc
read_sdc camera_to_dsi_display.sdc
read_sdc -ip ddr2 ../user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc
read_sdc -ip w128_d512_fifo ../user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl

optimize_rtl
report_area -file lat_rtl.area

optimize_gate -packarea lat_gate.area
legalize_phy_inst
update_timing
report_timing_summary -file lat_gate.timing
flow_status -file lat_flow.status

place
update_timing -mode manhattan
report_timing_summary -file lat_place.timing
report_area -io_info -file lat_place.area

route
update_timing -mode final
report_timing_summary -file lat_route.timing
report_area -io_info -file lat_route.area
report_clock_utilization -file lat_clock_util.txt
check_timing -verbose -file lat_chk.timing

bitgen -bit camera_to_dsi_display_lat.bit

puts "=== BUILD OK ==="
exit 0
