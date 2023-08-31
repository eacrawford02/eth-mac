// Copyright (C) 2023 Ewen Crawford
`timescale 1ns / 1ps

module tb_afifo #(
    parameter WIDTH = 4,
    parameter DEPTH = 4,
    parameter WCLK_PRD = 10,
    parameter RCLK_PRD = WCLK_PRD,
    parameter PHASE_DIFF = 0
  )();

  // ------------------------
  // Set up clocks
  // ------------------------

  logic wclk = 1;
  logic rclk = 1;

  always #(WCLK_PRD/2) wclk = ~wclk;

  initial begin
    #PHASE_DIFF;
    forever #(RCLK_PRD/2) rclk = ~rclk;
  end

  typedef struct {
    rand logic wrst;
    rand logic we;
    rand logic [WIDTH-1:0] wdata;
    rand logic rrst;
    rand logic re;
  } InSigs;

  typedef struct {
    logic wfull;
    logic [WIDTH-1:0] rdata;
    logic rempty;
  } OutSigs;

  // ------------------------
  // Specify Coverage
  // ------------------------

  covergroup WriteCG @ (posedge wclk);
    // TODO: cover r/w collisions when full, empty, neither
    // rw_coll : coverpoint (stim.in.re & stim.in.we);
    wrst_coll : coverpoint (stim.in.wrst & stim.in.we);
    oflw : coverpoint (stim.in.we & ref_out.wfull);
  endgroup

  covergroup ReadCG @ (posedge rclk);
    rrst_coll : coverpoint (stim.in.rrst & stim.in.re);
    // underflow : coverpoint (stim.in.re & ref_out.rempty);
  endgroup

  // ------------------------
  // Generate Stimulus
  // ------------------------

  class Stim;
    rand InSigs in;

    int weight_rst = 1;
    int weight_we_hi = 1;
    int weight_we_lo = 1;
    int weight_re_hi = 1;
    int weight_re_lo = 1;

    function void pre_randomize();
      // TODO
      // Direct stimulus based on coverage samples. Effectively defines a 
      // sequence of tests, where each test biases the stimulus to increase the 
      // likelihood of hitting specific coverpoints
      logic rst_coll_hit = wcg_inst.wrst_coll.get_inst_coverage() == 100 &&
			   rcg_inst.rrst_coll.get_inst_coverage() == 100;
      logic oflw_hit = wcg_inst.oflw.get_inst_coverage();

      if (rst_coll_hit) begin
	// Set weights for next test (overflow)
	weight_rst = 0;
	weight_we_hi = DEPTH;
	weight_re_lo = DEPTH;
      end else if (oflw_hit) begin
	// Sample underflow test PMF when DEPTH=4
	//    we 
	// r    |  0  |  1 
	// e  --------------
	//    0 |0.25 | 0.1 
	//   ---------------
	//    1 | 0.4 | 0.25 

	weight_we_hi = 1;
	weight_we_lo = DEPTH;
	weight_re_hi = DEPTH;
	weight_re_lo = 1;
      end
    endfunction

    constraint rst_en {
      in.wrst dist {1 := weight_rst, 0};
      in.rrst dist {1 := weight_rst, 0};
    }

    constraint rw_bias {
      in.we dist {1 := weight_we_hi, 0 := weight_we_lo};
      in.re dist {1 := weight_re_hi, 0 := weight_re_lo};
    }

    WriteCG wcg_inst;
    ReadCG rcg_inst;

    function int getCoverage();
      real covSum = wcg_inst.get_inst_coverage() + rcg_inst.get_inst_coverage;
      return $rtoi(covSum / 2);
    endfunction

    function new();
      wcg_inst = new;
      rcg_inst = new;
    endfunction
  endclass

  // TODO: delete class
  class OverflowStim extends Stim;
    constraint we_bias {

      // Sample PMF when DEPTH=4
      //    we 
      // r    |  0  |  1 
      // e  --------------
      //    0 |0.25 | 0.4 
      //   ---------------
      //    1 | 0.1 | 0.25 

      in.we dist {1 := DEPTH, 0 := 1};
      in.re dist {0 := DEPTH, 1 := 1};
    }
  endclass

  Stim stim = new;
  OverflowStim oflw_stim = new;

  InSigs in;
  OutSigs dut_out, ref_out;

  // ------------------------
  // Instantiate DUT
  // ------------------------
  
  afifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut(
    .wclk(wclk),
    .wrst(in.wrst),
    .we(in.we),
    .wdata(in.wdata),
    .wfull(dut_out.wfull),
    .rclk(rclk),
    .rrst(in.rrst),
    .re(in.re),
    .rempty(dut_out.rempty),
    .rdata(dut_out.rdata)
  );

  // ------------------------
  // Instantiate Ref Model
  // ------------------------
  
  ref_afifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) ref_model(
    .wclk(wclk),
    .wrst(in.wrst),
    .we(in.we),
    .wdata(in.wdata),
    .wfull(ref_out.wfull),
    .rclk(rclk),
    .rrst(in.rrst),
    .re(in.re),
    .rempty(ref_out.rempty),
    .rdata(ref_out.rdata)
  );

  WriteCG wcg_inst = new;
  ReadCG rcg_inst = new;

  // ------------------------
  // Drive Stimulus
  // ------------------------

  initial begin
    // Reset sequence
    @ (posedge wclk);
    in.wrst = 1;
    in.rrst = 1;
    //#WCLK_PRD; // Max of wclk and rclk periods
    @ (posedge wclk);
    in.wrst = 0;
    in.rrst = 0;
    //#WCLK_PRD;

    while (stim.getCoverage() < 100) begin
      stim.randomize();
      in = stim.in;
      @ (posedge wclk);
    end
    $finish;
  end

  // ------------------------
  // Assert Design Properties
  // ------------------------

  /*
  prop_wrst : assert property(
    @ (posedge wclk)
    in.wrst |-> ##1 ref_out.wfull == dut_out.wfull
  ) else $fatal(); // Severity must be fatal for Vivado to stop simulation

  prop_rrst : assert property(
    @ (posedge rclk)
    in.rrst |-> ##1 ref_out.rempty == dut_out.rempty
  ) else $fatal();

  prop_wfull : assert property(
    @ (posedge wclk) disable iff (in.wrst)
    in.we |-> ##1 ref_out.wfull == dut_out.wfull
  ) else $fatal();

  prop_rempty : assert property(
    @ (posedge rclk) disable iff (in.rrst)
    in.re |-> ##1 ref_out.rempty == dut_out.rempty
  ) else $fatal();

  prop_re: assert property(
    @ (posedge rclk) disable iff (in.rrst)
    in.re |-> ##1 ref_out.rdata == dut_out.rdata
  ) else $fatal();
  */

endmodule

// Asynchronous FIFO behavioural model. Supports arbitrary widths and depths
// (incl. non-powers-of-2)
module ref_afifo #(
    parameter WIDTH = 4,
    parameter DEPTH = 4
  )(
    input wclk,
    input wrst,
    input we,
    input logic [WIDTH-1:0] wdata,
    output logic wfull,
    input rclk,
    input rrst,
    input re,
    output logic rempty,
    output logic [WIDTH-1:0] rdata
  );

  localparam PTR_WIDTH = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH-1:0];

  logic [PTR_WIDTH-1:0] wptr, rptr, wptr_next, rptr_next;
  assign wptr_next = (wptr + 1) % DEPTH;
  assign rptr_next = (rptr + 1) % DEPTH;

  // Toggle signals to indicate that a pointer has wrapped around the end of
  // the FIFO (used to determine full/empty conditions)
  logic wptr_wrap, rptr_wrap;

  // Model delay associated with 2FF synchronizers
  logic [1:0][PTR_WIDTH-1:0] r2w_dly, w2r_dly;

  always_ff @ (posedge wclk) begin
    if (wrst) begin
      wptr <= 0;
      wptr_wrap <= 0;
      r2w_dly <= 0;
      wfull <= 0;
    end else begin
      // Shift read pointer into write domain
      r2w_dly <= {r2w_dly[0], rptr};
      // FIFO is full if r/w pointers are the same and have wrapped an uneven
	// number of times
      wfull <= (wptr_next == r2w_dly[1]) & (wptr_wrap ^ rptr_wrap);

      // Logic if write is valid
      if (we & ~wfull) begin
	mem[wptr] <= wdata;
	wptr <= wptr_next;
	if (wptr == DEPTH-1) wptr_wrap <= wptr_wrap ^ 1;
      end
    end
  end

  always_ff @ (posedge rclk) begin
    if (rrst) begin
      rptr <= 0;
      rptr_wrap <= 0;
      w2r_dly <= 0;
      rempty <= 1;
    end else begin
      // Shift write pointer into read domain
      w2r_dly <= {w2r_dly[0], wptr};

      // Logic if read is valid
      if (re) begin
	rdata <= mem[rptr];

	// If the FIFO isn't empty, the incremented read pointer is qualified
	if (~rempty) begin
	  // Advance read pointer
	  rptr <= rptr_next;
	  // FIFO is empty simply if r/w pointers are the same
	  rempty <= (rptr_next == w2r_dly[1]);
	  // Toggle if read pointer has wrapped
	  rptr_wrap <= rptr_wrap ^ (rptr_next == 0);
	end
      end
    end
  end
endmodule
