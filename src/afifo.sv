// Copywrite (C) 2023 Ewen Crawford

module afifo #(
    parameter WIDTH = 4,
    parameter DEPTH = 4 // Depth must be a power-of-2
  )(
    // Write clock domain ports
    input wclk,
    input wrst,
    input we,
    input logic [WIDTH-1:0] wdata,
    output logic wfull,
    // Read clock domain ports
    input rclk,
    input rrst,
    input re,
    output logic rempty,
    output logic [WIDTH-1:0] rdata
  );

  localparam PTR_WIDTH = $clog2(DEPTH);

  // Synchronized read/write pointers (Gray coded)
  logic [1:0][PTR_WIDTH:0] r2w_sync, w2r_sync;
  wire  [PTR_WIDTH:0] wgray_sync = w2r_sync[1],
		      rgray_sync = r2w_sync[1];

  // Memory-addressing read/write pointers
  logic [PTR_WIDTH:0] wptr, rptr;

  // Gray code full/empty condition pointers (fed to CDC synchronizers)
  logic [PTR_WIDTH:0] wgray, rgray;

  // Read/write pointer increment logic
  wire [PTR_WIDTH:0] wptr_next = wptr + (we & ~wfull),
		     rptr_next = rptr + (re & ~rempty);
  
  // Binary-to-gray conversion logic
  wire [PTR_WIDTH:0] wgray_next = (wptr_next >> 1) ^ wptr_next,
		     rgray_next = (rptr_next >> 1) ^ rptr_next;

  // For full condition to be true, the two MSBs of the Gray code pointers
  // should NOT be equal, while the remaining LSBs should be equal.
  //
  // The 1st MSB distinguishes between when rptr==wptr due to the FIFO being 
  // empty, vs. due to the wptr wrapping around to the rptr. Thus, the 1st
  // MSBs should be different to indicate that the pointers have wrapped an
  // uneven amount of times and the wptr has effectively "caught up" to the 
  // rptr.
  //
  // The 2nd MSB is mirrored asymmetrically about the midpoint of the Gray
  // code sequence (i.e., when the MSB transitions from 0 to 1). However, for
  // the sake of comparison, we want this reflection to be symmetrical so that
  // the sequence given by the 2nd MSB and remaining LSBs is identical for
  // both halves of the 1st MSB. Thus, the 2nd MSBs should also be different
  // to maintain sequence consistencies.
  //
  // Count | Gray Code | 2nd MSB Corrected
  // -------------------------------------
  //   0      000	    0[00]
  //   1      001	    0[01]
  //   2      011	    0[11]
  //   3      010	    0[10]    _
  //   4      110	    1[00]     |--> Correction needs to be made once 
  //   5      111	    1[01]     |	  pointer has wrapped (MSB==1)
  //   6      101	    1[11]     |
  //   7      100	    1[10]    _|
  //
  wire wfull_next = (wgray_next == {~rgray_sync[PTR_WIDTH:PTR_WIDTH-1],
				     rgray_sync[PTR_WIDTH-2:0]});
  wire rempty_next = (rgray_next == wgray_sync);

 // Write-domain sequential logic
  always_ff @ (posedge wclk) begin
    if (wrst) begin
      wptr <= 0;
      wgray <= 0;
    end else begin
      // Flop increment input into memory/Gray write pointers
      wptr <= wptr_next[PTR_WIDTH-1:0];
      wgray <= wgray_next; // Binary-to-Gray conversion
      // Flop full condition
      wfull <= wfull_next;
      // Synchronize read pointer
      r2w_sync <= {r2w_sync[0], rgray};
    end
  end
    
  // Read-domain sequential logic
  always_ff @ (posedge rclk) begin
    if (rrst) begin
      rptr <= 0;
      rgray <= 0;
    end else begin
      // Flop increment input into memory/Gray read pointers
      rptr <= rptr_next[PTR_WIDTH-1:0];
      rgray <= rgray_next; // Binary-to-Gray conversion
      // Flop empty condition
      rempty <= rempty_next;
      // Synchronize write pointer
      w2r_sync <= {w2r_sync[0], wgray};
    end
  end

  // Memory for FIFO data storage. Should infer a simple dual-port BRAM
  logic [WIDTH-1:0] ram [DEPTH-1:0];

  // Write port
  always_ff @ (posedge wclk) begin
    if (we & ~wfull) ram[wptr] <= wdata;
  end

  // Read port
  always_ff @ (posedge rclk) begin
    if (re) rdata <= ram[rptr];
  end
endmodule
