// Copyright (C) 2023 Ewen Crawford
`timescale 1ns / 1ps

`ifndef MAX
`define MAX(a, b) ((a) > (b) ? (a) : (b))
`endif

// TODO: Split classes/modules into separate files
module tb_afifo #(
    parameter WIDTH      = 4,
    parameter DEPTH      = 4,
    parameter WCLK_PRD   = 10,
    parameter RCLK_PRD   = WCLK_PRD,
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

  // ------------------------
  // Group Design I/Os
  // ------------------------

  typedef struct {
    rand logic             wrst;
    rand logic             we;
    rand logic [WIDTH-1:0] wdata;
  } WriteInSigs;

  typedef struct {
    rand logic rrst;
    rand logic re;
  } ReadInSigs;

  typedef struct {
    logic             wfull;
    logic [WIDTH-1:0] rdata;
    logic             rempty;
  } OutSigs;

  // ------------------------
  // Specify Coverage
  // ------------------------

  covergroup WriteCG (
      ref WriteInSigs in, 
      ref logic       re, 
      ref OutSigs     out
  ) @ (posedge wclk);
    rw_coll   : coverpoint (re & in.we); // Cover r/w collisions (general case)
    // Cover r/w collisions under full condition
    wfull     : coverpoint out.wfull;
    coll_cond : cross rw_coll, wfull;
    wrst_coll : coverpoint (in.wrst & in.we); // Cover write and reset collision
    oflw      : coverpoint (in.we & out.wfull); // Cover overflow
  endgroup

  covergroup ReadCG (
      ref ReadInSigs in,
      ref logic      we,
      ref OutSigs    out
  ) @ (posedge rclk);
    rw_coll   : coverpoint (in.re & we); // Cover r/w collisions (general case)
    // Cover r/w collisions under empty condition
    rempty    : coverpoint out.rempty;
    coll_cond : cross rw_coll, rempty;
    rrst_coll : coverpoint (in.rrst & in.re); // Cover read and reset collision
    // Cover underflow
    re        : coverpoint in.re;
    empty     : coverpoint out.rempty {
      // We want to observe the case where rempty is asserted after all
      // elements are read out of the FIFO. Because rempty is initially
      // 1 following reset, we explicitly specify the sequence below to avoid 
      // having the uflw coverpoint hit the first time rempty goes low after a 
      // reset
      bins from_full = (0 => 1);
    }
    uflw      : cross re, empty;
  endgroup

  // ------------------------
  // Direct test sequence
  // ------------------------

  class Sequencer;
    typedef enum {OFLW, UFLW, RAND, DONE} TestSeq;
    TestSeq testSeq;

    WriteCG wcg;
    ReadCG rcg;

    function TestSeq getSequence();
      // Direct stimulus based on coverage samples. Effectively defines a 
      // sequence of tests, where each test biases the stimulus to increase the 
      // likelihood of hitting specific coverpoints
      logic oflw_hit = wcg.oflw.get_inst_coverage() == 100;
      logic uflw_hit = rcg.uflw.get_inst_coverage() == 100;
      logic all_hit = (wcg.get_inst_coverage() == 100) &&
		      (rcg.get_inst_coverage() == 100);

      case (testSeq)
	OFLW   : testSeq = oflw_hit ? UFLW : OFLW;
	UFLW   : testSeq = uflw_hit ? RAND : UFLW;
	RAND   : testSeq = all_hit ? DONE : RAND;
	default: testSeq = DONE;
      endcase

      return testSeq;
    endfunction

    function new(ref WriteCG wcg, ref ReadCG rcg);
      testSeq = OFLW;
      this.wcg = wcg;
      this.rcg = rcg;
    endfunction
  endclass

  // ------------------------
  // Generate Stimulus
  // ------------------------

  class WriteStim;
    rand WriteInSigs in;
    Sequencer seq;

    int weight_rst;
    int weight_we_hi;
    int weight_we_lo;

    function void pre_randomize();
      Sequencer::TestSeq currentSeq = seq.getSequence();

      // Set random variable weights for current test sequence
      if (currentSeq == Sequencer::OFLW) begin
	weight_rst = 0;
	weight_we_hi = DEPTH;
	weight_we_lo = 1;
      end else if (currentSeq == Sequencer::UFLW) begin
	// Sample underflow test PMF when DEPTH=4
	//    we 
	// r    |  0  |  1 
	// e  --------------
	//    0 |0.25 | 0.1 
	//   ---------------
	//    1 | 0.4 | 0.25 

	weight_rst = 0;
	weight_we_hi = 1;
	weight_we_lo = DEPTH;
      end else begin
	weight_rst = 1;
	weight_we_hi = 1;
	weight_we_lo = 1;
      end
    endfunction

    // Constrain random variables with weightings
    constraint rst_en {
      in.wrst dist {1 := weight_rst, 0};
    }

    constraint we_bias {
      in.we dist {1 := weight_we_hi, 0 := weight_we_lo};
    }

    function new(ref Sequencer seq);
      this.seq = seq;
    endfunction
  endclass

  class ReadStim;
    rand ReadInSigs in;
    Sequencer seq;

    int weight_rst;
    int weight_re_hi;
    int weight_re_lo;

    function void pre_randomize();
      Sequencer::TestSeq currentSeq = seq.getSequence();

      // Set random variable weights for current test sequence
      if (currentSeq == Sequencer::OFLW) begin
	weight_rst = 0;
	weight_re_hi = 1;
	weight_re_lo = DEPTH;
      end else if (currentSeq == Sequencer::UFLW) begin
	weight_rst = 0;
	weight_re_hi = DEPTH;
	weight_re_lo = 1;
      end else begin
	weight_rst = 1;
	weight_re_hi = 1;
	weight_re_lo = 1;
      end
    endfunction

    // Constrain random variables with weightings
    constraint rst_en {
      in.rrst dist {1 := weight_rst, 0};
    }

    constraint re_bias {
      in.re dist {1 := weight_re_hi, 0 := weight_re_lo};
    }

    function new(ref Sequencer seq);
      this.seq = seq;
    endfunction
  endclass;

  WriteInSigs wIn;
  ReadInSigs rIn;
  OutSigs dut_out, ref_out;

  // ------------------------
  // Instantiate DUT
  // ------------------------
  
  afifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut(
    .wclk(wclk),
    .wrst(wIn.wrst),
    .we(wIn.we),
    .wdata(wIn.wdata),
    .wfull(dut_out.wfull),
    .rclk(rclk),
    .rrst(rIn.rrst),
    .re(rIn.re),
    .rempty(dut_out.rempty),
    .rdata(dut_out.rdata)
  );

  // ------------------------
  // Instantiate Ref Model
  // ------------------------
  
  ref_afifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) ref_model(
    .wclk(wclk),
    .wrst(wIn.wrst),
    .we(wIn.we),
    .wdata(wIn.wdata),
    .wfull(ref_out.wfull),
    .rclk(rclk),
    .rrst(rIn.rrst),
    .re(rIn.re),
    .rempty(ref_out.rempty),
    .rdata(ref_out.rdata)
  );

  // ------------------------
  // Drive Stimulus
  // ------------------------

  WriteCG wcg = new(wIn, rIn.re, ref_out);
  ReadCG rcg = new(rIn, wIn.we, ref_out);
  Sequencer seq = new(wcg, rcg);
  WriteStim wStim = new(seq);
  ReadStim rStim = new(seq);

  initial begin
    // Reset sequence
    wIn.wrst <= 0;
    rIn.rrst <= 0;
    wIn.we <= 0;
    wIn.wdata <= 0;
    rIn.rrst <= 0;
    rIn.re <= 0;
    #`MAX(WCLK_PRD, RCLK_PRD);
    wIn.wrst <= 1;
    rIn.rrst <= 1;
    #`MAX(WCLK_PRD, RCLK_PRD);
    wIn.wrst <= 0;
    rIn.rrst <= 0;

    fork
      while (seq.getSequence() != Sequencer::DONE) begin
	#WCLK_PRD;
	wStim.randomize();
	wIn <= wStim.in;
      end

      while (seq.getSequence() != Sequencer::DONE) begin
	#RCLK_PRD;
	rStim.randomize();
	rIn <= rStim.in;
      end
    join

    $display("Asynchronous FIFO test complete, coverage %0d%%", 
	     $get_coverage());
    $finish;
  end

  // ------------------------
  // Assert Design Properties
  // ------------------------
  
  // Assertion severity must be fatal for Vivado to stop simulation
  prop_wrst : assert property(
    @ (posedge wclk)
    wIn.wrst |-> ##1 ref_out.wfull == dut_out.wfull
  ) else $fatal(1, "Incorrect full signal following write reset");

  prop_rrst : assert property(
    @ (posedge rclk)
    rIn.rrst |-> ##1 ref_out.rempty == dut_out.rempty
  ) else $fatal(1, "Incorrect empty signal following read reset");

  prop_wfull : assert property(
    @ (posedge wclk) disable iff (wIn.wrst)
    wIn.we |-> ##1 ref_out.wfull == dut_out.wfull
  ) else $fatal(1, "DUT full flag does not match reference model");

  prop_rempty : assert property(
    @ (posedge rclk) disable iff (rIn.rrst)
    rIn.re |-> ##1 ref_out.rempty == dut_out.rempty
  ) else $fatal(1, "DUT empty flag does not match reference model");

  prop_re: assert property(
    @ (posedge rclk) disable iff (rIn.rrst)
    rIn.re & ~ref_out.rempty |-> ##1 ref_out.rdata == dut_out.rdata
  ) else $fatal(1, "DUT read data does not match reference model");

endmodule

// Asynchronous FIFO behavioural model. Supports arbitrary widths and depths
// (incl. non-powers-of-2)
module ref_afifo #(
    parameter WIDTH = 4,
    parameter DEPTH = 4
  )(
    input                    wclk,
    input                    wrst,
    input                    we,
    input  logic [WIDTH-1:0] wdata,
    output logic             wfull,
    input                    rclk,
    input                    rrst,
    input                    re,
    output logic             rempty,
    output logic [WIDTH-1:0] rdata
  );

  localparam PTR_WIDTH = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH-1:0];

  logic [PTR_WIDTH-1:0] wptr, rptr, wptr_next, rptr_next;
  assign wptr_next = (wptr + 1) % DEPTH;
  assign rptr_next = (rptr + 1) % DEPTH;

  // Toggle signals to indicate that a pointer has wrapped around the end of
  // the FIFO (used to determine full/empty conditions)
  logic wptr_wrap, rptr_wrap, wptr_wrap_next, rptr_wrap_next;

  assign wptr_wrap_next = wptr_wrap ^ (wptr_next == 0);
  assign rptr_wrap_next = rptr_wrap ^ (rptr_next == 0);

  // Model delay associated with 2FF synchronizers
  logic [1:0]                wptr_wrap_dly, rptr_wrap_dly;
  logic [1:0][PTR_WIDTH-1:0] rptr_sync_dly, wptr_sync_dly;

  always_ff @ (posedge wclk) begin
    if (wrst) begin
      wptr <= 0;
      wptr_wrap <= 0;
      rptr_wrap_dly <= 0;
      rptr_sync_dly <= 0;
      wfull <= 0;
    end else begin
      // Shift read pointer and wrap indicator bit into write domain
      rptr_wrap_dly <= {rptr_wrap_dly[0], rptr_wrap};
      rptr_sync_dly <= {rptr_sync_dly[0], rptr};

      // Logic if write is valid
      if (we & ~wfull) begin
	mem[wptr] <= wdata;
	wptr <= wptr_next;
	wptr_wrap <= wptr_wrap_next;

	// FIFO is full if r/w pointers are the same and have wrapped an uneven
	// number of times
	wfull <= (wptr_next == rptr_sync_dly[1]) & 
	         (wptr_wrap_next != rptr_wrap_dly[1]);
      end else begin
	wfull <= (wptr == rptr_sync_dly[1]) & (wptr_wrap != rptr_wrap_dly[1]);
      end
    end
  end

  always_ff @ (posedge rclk) begin
    if (rrst) begin
      rptr <= 0;
      rptr_wrap <= 0;
      wptr_wrap_dly <= 0;
      wptr_sync_dly <= 0;
      rempty <= 1;
    end else begin
      // Shift write pointer and wrap indicator bit into read domain
      wptr_wrap_dly <= {wptr_wrap_dly[0], wptr_wrap};
      wptr_sync_dly <= {wptr_sync_dly[0], wptr};

      // Logic if read is valid
      if (re) begin
	rdata <= mem[rptr];

	// If the FIFO isn't empty, the incremented read pointer is qualified
	if (~rempty) begin
	  // Advance read pointer
	  rptr <= rptr_next;
	  rptr_wrap <= rptr_wrap_next;

	  // FIFO is empty simply if r/w pointers are the same
	  rempty <= (rptr_next == wptr_sync_dly[1]) & 
	            (rptr_wrap_next == wptr_wrap_dly[1]);
	end else begin
	  rempty <= (rptr == wptr_sync_dly[1]) & 
	            (rptr_wrap_next == wptr_wrap_dly[1]);
	end
      end else begin
	rempty <= (rptr == wptr_sync_dly[1]) & (rptr_wrap == wptr_wrap_dly[1]);
      end
    end
  end
endmodule
