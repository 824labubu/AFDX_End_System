// synopsys translate_off
`timescale 1 ps / 1 ps
// synopsys translate_on
module FIFO_QUE (
	clock,
	data,
	rdreq,
	wrreq,
	almost_empty,
	almost_full,
	empty,
	full,
	q
	);

	input    clock;
	input    [7:0]    data;
	input    rdreq;
	input    wrreq;
	output    almost_empty;
	output    almost_full;
	output    empty;
	output    full;
	output    [7:0]    q;

	scfifo    scfifo (
		.clock (clock),
		.sclr (),
		.wrreq (wrreq),
		.aclr (),
		.data (data),
		.rdreq (rdreq),
		.usedw (),
		.empty (empty),
		.full (full),
		.q (q),
		.almost_empty (almost_empty),
		.almost_full (almost_full)
	);

	defparam
		scfifo.add_ram_output_register = "ON",
		scfifo.almost_full_value = 8191,
		scfifo.almost_empty_value = 1,
		scfifo.intended_device_family = "Stratix",
		scfifo.lpm_hint = "RAM_BLOCK_TYPE=M4K",
		scfifo.lpm_numwords = 8192,
		scfifo.lpm_showahead = "OFF",
		scfifo.lpm_type = "scfifo",
		scfifo.lpm_width = 8,
		scfifo.lpm_widthu = 13,
		scfifo.overflow_checking = "ON",
		scfifo.underflow_checking = "ON",
		scfifo.use_eab = "ON";
endmodule