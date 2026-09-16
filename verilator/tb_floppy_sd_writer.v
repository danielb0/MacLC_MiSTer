/* tb_floppy_sd_writer.v — Phase 4 gate: a committed sector reaches the card.
 *
 * WHAT THIS COVERS THAT tb_floppy_commit.v CANNOT. That bench proves the
 * sector reaches SDRAM byte-exactly. This one starts where it stops: the
 * persistence tap, the depth-2 queue, the hps_io sd_wr/sd_ack handshake, and
 * every path that must REFUSE to write. The refusals matter more than the
 * happy path — this is the first module in the whole floppy write chain that
 * can damage the user's file, and every defect class below writes a full,
 * well-formed sector at a plausible offset, which is exactly the kind a
 * "does it still boot" check never catches.
 *
 * ★ THE BYTE ORDER IS THE HEADLINE CHECK (section 1). The committer packs the
 * EVEN source byte into the word's HIGH half; hps_io's wire format is the
 * opposite half-order, and floppy_loader.v:123 swaps on the way in. If this
 * module's swap does not mirror that one, every byte pair in the .dsk comes
 * out transposed — an image that still mounts, still passes its checksums per
 * sector, and is quietly wrong. So the bench drives a sector whose bytes are
 * all distinct and asserts the exact wire word for each of the 256.
 *
 * ★ THE ACK TIMEOUT MUST RE-PRESENT, NOT RETIRE (section 5). hps_io captures
 * sd_lba in one poll command and raises sd_ack in a LATER one, so the gap is
 * unbounded. If a timeout retired the entry and flipped `head`, a late ack
 * would stream the OTHER buffer to the LBA the HPS already captured: a whole
 * sector of unrelated data at a valid offset. The bench therefore checks that
 * after a timeout the SAME lba and the SAME payload are presented again.
 *
 * ★ A REMOUNT MUST ABORT THE FSM, NOT JUST THE QUEUE (sections 10-11). The
 * MacPlus interlock only clears `valid` and lets the FSM run on, which is safe
 * when a sector is one request. A DC42 sector is four and the eject flush is
 * ~1600, and sd_ack is shared per slot: the LOADER's acks for the new image
 * walk the old FSM forward until it raises sd_wr against the loader's LBA. The
 * first version of this module did exactly that (found in review 2026-09-16,
 * reproduced in Icarus); these two sections are the pin.
 *
 * Sections 12-14 pin the flush trigger: the eject must rewrite the checksum
 * even if Floppy Write was switched off after the writes, and even if the
 * session's only sector was still queued when the eject arrived; and it must
 * NOT rewrite when nothing of ours ever reached the file.
 *
 * ACK_TIMEOUT_BITS is overridden to 6 so the timeout is reachable in
 * simulation; the shipping default (24) is ~0.5s at clk_sys.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_floppy_sd_writer \
 *     -o scratch/phase4/tb_sdw.vvp verilator/tb_floppy_sd_writer.v \
 *     rtl/floppy_sd_writer.v
 *   /c/iverilog/bin/vvp scratch/phase4/tb_sdw.vvp
 */
`timescale 1ns/1ps

module tb_floppy_sd_writer;

   reg clk = 0;
   always #5 clk = ~clk;

   reg         reset       = 1'b1;
   reg         img_mounted = 1'b0;
   reg         commit_done = 1'b0;
   reg  [21:0] commit_addr = 22'd0;
   reg         commit_buf_wr   = 1'b0;
   reg   [7:0] commit_buf_addr = 8'd0;
   reg  [15:0] commit_buf_data = 16'd0;
   reg         write_ok    = 1'b1;
   reg         loader_busy = 1'b0;
   reg         dc42        = 1'b0;
   reg         flush_req   = 1'b0;
   reg  [12:0] file_blocks = 13'd1600;   // an 800K raw image

   wire [31:0] sd_lba;
   wire        sd_rd, sd_wr;
   reg         sd_ack = 1'b0;
   reg   [7:0] sd_buff_addr = 8'd0;
   reg  [15:0] sd_buff_dout = 16'd0;
   reg         sd_buff_wr   = 1'b0;
   wire [15:0] sd_buff_din;
   wire        busy;
   wire [31:0] dbg;

   floppy_sd_writer #(.ACK_TIMEOUT_BITS(6)) dut
   (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted),
      .commit_done(commit_done), .commit_addr(commit_addr),
      .commit_buf_wr(commit_buf_wr), .commit_buf_addr(commit_buf_addr),
      .commit_buf_data(commit_buf_data),
      .write_ok(write_ok), .loader_busy(loader_busy),
      .dc42(dc42), .flush_req(flush_req), .file_blocks(file_blocks),
      .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr_i({5'd0, sd_buff_addr}),
      .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
      .sd_buff_din(sd_buff_din),
      .busy(busy),
      .dbg(dbg)
   );

   integer checks = 0;
   integer fails  = 0;

   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin
            fails = fails + 1;
            $display("  FAIL: %0s", what);
         end
      end
   endtask

   // Fill the shadow with a sector whose every byte is distinct, the way the
   // committer would: sd_buf_addr/data/wr mirror the SDRAM word stream.
   task load_sector(input [15:0] seed);
      integer i;
      begin
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            commit_buf_addr <= i[7:0];
            commit_buf_data <= seed + i[15:0];
            commit_buf_wr   <= 1'b1;
         end
         @(posedge clk);
         commit_buf_wr <= 1'b0;
      end
   endtask

   task pulse_commit(input [21:0] addr);
      begin
         @(posedge clk);
         commit_addr <= addr;
         commit_done <= 1'b1;
         @(posedge clk);
         commit_done <= 1'b0;
      end
   endtask

   // Answer a request the way hps_io does: raise sd_ack, walk sd_buff_addr
   // over the block while it is high, then drop it.
   task serve_block(input [15:0] expect_seed, input check_data);
      integer i;
      reg [15:0] want;
      begin
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            @(posedge clk);          // the module's read is registered
            @(posedge clk);
            if (check_data) begin
               want = expect_seed + i[15:0];
               check(sd_buff_din === {want[7:0], want[15:8]},
                     "sd_buff_din must be the committer word with its halves swapped");
            end
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         // P_WAIT_DONE needs to SEE the ack fall before it retires the entry,
         // so give the FSM a few cycles rather than sampling busy in the same
         // breath as the deassertion.
         repeat (4) @(posedge clk);
      end
   endtask

   // Serve a READ the way hps_io does: raise sd_ack, then stream the block in
   // on sd_buff_wr. The payload is card_seed + index, so the bench can tell
   // card words from shadow words in whatever comes back out.
   task serve_read(input [15:0] card_seed);
      integer i;
      begin
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            sd_buff_dout <= card_seed + i[15:0];
            sd_buff_wr   <= 1'b1;
            @(posedge clk);
            sd_buff_wr   <= 1'b0;
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         repeat (4) @(posedge clk);
      end
   endtask

   // Check a DC42 block on its way back out. lo_from_card says which source
   // owns words 0..41:
   //   phase 0 block N   : [card 0..41][shadow 0..213]
   //   phase 1 block N+1 : [shadow 214..255][card 42..255]
   task serve_block_dc42(input [15:0] card_seed, input [15:0] shadow_seed,
                         input lo_from_card);
      integer i;
      reg [15:0] want, exp;
      reg        card;
      begin
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            @(posedge clk);
            @(posedge clk);
            // A word this sector owns comes from the shadow, in the
            // internal convention, so it picks up the output swap. A word
            // belonging to the NEIGHBOURING sector was read off the card in
            // wire order and must go back byte-for-byte as it came - the
            // capture swap and the output swap cancel, which is the point.
            card = (i < 42) ? lo_from_card : !lo_from_card;
            if (card)
               want = card_seed + i[15:0];
            else if (i < 42)
               want = shadow_seed + 16'd214 + i[15:0];
            else
               want = shadow_seed + (i[15:0] - 16'd42);
            exp = card ? want : {want[7:0], want[15:8]};
            check(sd_buff_din === exp,
                  "DC42 block word must come from the right source, byte order intact");
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         repeat (4) @(posedge clk);
      end
   endtask

   // Stream one block of a modelled DC42 file for the checksum scan, and
   // accumulate what the DUT ought to be computing. Block 0 carries dataSize
   // in header words 32/33; every other word is seed + index.
   integer    exp_blk;
   reg [31:0] exp_cksum;
   reg [21:0] exp_dsize;
   reg [31:0] cksum_hold;

   task scan_block(input [12:0] blk, input [15:0] seed);
      integer i;
      reg [15:0] w;
      reg [12:0] lb;
      reg  [7:0] lw;
      reg [31:0] acc;
      begin
         lb = (22'd83 + exp_dsize) >> 9;
         lw = ((22'd83 + exp_dsize) >> 1) & 8'hFF;
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            if (blk == 0 && i == 32)      w = {10'd0, exp_dsize[21:16]};
            else if (blk == 0 && i == 33) w = exp_dsize[15:0];
            else                          w = seed + i[15:0];
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            sd_buff_dout <= {w[7:0], w[15:8]};   // wire order
            sd_buff_wr   <= 1'b1;
            @(posedge clk);
            sd_buff_wr   <= 1'b0;
            // sum = ror32(sum + word), the same definition as the DUT and
            // scripts/mk_dc42.py.
            if ((blk != 0 || i >= 42) && (blk < lb || i <= lw)) begin
               acc       = exp_cksum + {16'd0, w};
               exp_cksum = {acc[0], acc[31:1]};
            end
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         repeat (4) @(posedge clk);
      end
   endtask

   // The rewritten block 0: every word exactly as it was read back, except
   // words 36/37 which must now carry the recomputed data checksum, and word
   // 38/39 (the TAG checksum) which must be untouched.
   task check_header(input [15:0] seed);
      integer i;
      reg [15:0] w, exp;
      begin
         @(posedge clk);
         sd_ack <= 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            sd_buff_addr <= i[7:0];
            @(posedge clk);
            @(posedge clk);
            if (i == 36)      w = exp_cksum[31:16];
            else if (i == 37) w = exp_cksum[15:0];
            else if (i == 32) w = {10'd0, exp_dsize[21:16]};
            else if (i == 33) w = exp_dsize[15:0];
            else              w = seed + i[15:0];
            exp = {w[7:0], w[15:8]};
            check(sd_buff_din === exp,
                  "header word: checksum substituted, everything else intact");
         end
         @(posedge clk);
         sd_ack <= 1'b0;
         repeat (4) @(posedge clk);
      end
   endtask

   task wait_rd(input integer limit, output ok);
      integer n;
      begin
         n = 0; ok = 0;
         while (n < limit && !ok) begin
            @(posedge clk);
            if (sd_rd) ok = 1;
            n = n + 1;
         end
      end
   endtask

   task wait_wr(input integer limit, output ok);
      integer n;
      begin
         n = 0; ok = 0;
         while (n < limit && !ok) begin
            @(posedge clk);
            if (sd_wr) ok = 1;
            n = n + 1;
         end
      end
   endtask

   integer i;
   reg     got;
   reg [31:0] lba_first;

   initial begin
      repeat (4) @(posedge clk);
      reset <= 1'b0;
      repeat (4) @(posedge clk);

      // ─── 1. the happy path, and the byte order ──────────────────────────
      $display("1. commit -> sd_wr at the right LBA, bytes in hps_io order");
      load_sector(16'h1000);
      pulse_commit(22'd512 * 22'd7);       // sector 7 -> LBA 7
      wait_wr(64, got);
      check(got, "sd_wr must be asserted after a commit");
      check(sd_lba === 32'd7, "sd_lba must be commit_addr >> 9");
      serve_block(16'h1000, 1'b1);
      check(!busy, "busy must fall once the block has drained");

      // ─── 2. write_ok low: nothing may reach the card ────────────────────
      $display("2. write_ok low refuses the sector outright");
      write_ok <= 1'b0;
      load_sector(16'h2000);
      pulse_commit(22'd512 * 22'd9);
      wait_wr(64, got);
      check(!got, "a commit with write_ok low must never raise sd_wr");
      check(!busy, "and must not leave the queue busy");
      write_ok <= 1'b1;

      // --- 3. past the end of the image: refuse, do not wrap ──────────────
      $display("3. an LBA at or past size_blocks is retired unwritten");
      load_sector(16'h3000);
      pulse_commit(22'd512 * 22'd1600);    // LBA 1600 == size_blocks
      wait_wr(64, got);
      check(!got, "an out-of-range LBA must not be written");
      repeat (8) @(posedge clk);
      check(!busy, "and must be retired rather than left queued");

      // ─── 4. a remount drops what was captured against the old image ─────
      $display("4. img_mounted drops the queued sector");
      loader_busy <= 1'b1;                 // hold it in the queue
      load_sector(16'h4000);
      pulse_commit(22'd512 * 22'd11);
      repeat (4) @(posedge clk);
      check(busy, "the sector should be queued while the loader owns the slot");
      @(posedge clk); img_mounted <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      loader_busy <= 1'b0;
      wait_wr(64, got);
      check(!got, "a sector captured before a remount must never be written");
      check(!busy, "and the queue must be empty again");

      // ─── 5. ack timeout re-presents the SAME request ────────────────────
      $display("5. an ack timeout re-presents, never retires");
      load_sector(16'h5000);
      pulse_commit(22'd512 * 22'd13);
      wait_wr(64, got);
      check(got, "first presentation");
      lba_first = sd_lba;
      // never ack: let the timeout fire, then wait for the next presentation
      wait_wr(400, got);
      check(got, "the request must be presented again after the timeout");
      check(sd_lba === lba_first, "the re-presented LBA must be unchanged");
      check(busy, "busy must stay high while a write is still owed");
      serve_block(16'h5000, 1'b1);         // same payload, not the other buffer
      check(!busy, "and clears once the late ack is finally served");

      // ─── 6. two queued sectors drain in order ───────────────────────────
      $display("6. the depth-2 queue drains in capture order");
      loader_busy <= 1'b1;
      load_sector(16'h6000);
      pulse_commit(22'd512 * 22'd21);
      load_sector(16'h7000);
      pulse_commit(22'd512 * 22'd22);
      loader_busy <= 1'b0;
      wait_wr(64, got);
      check(got && sd_lba === 32'd21, "the first captured sector goes first");
      serve_block(16'h6000, 1'b1);
      wait_wr(64, got);
      check(got && sd_lba === 32'd22, "then the second");
      serve_block(16'h7000, 1'b1);
      check(!busy, "both drained");

      // --- 7. DC42: one sector becomes a read-modify-write of TWO blocks ---
      $display("7. DC42 sector -> RMW of blocks N and N+1, sources interleaved");
      dc42        <= 1'b1;
      file_blocks <= 13'd1637;             // tagged 800K DC42: 838484 B = 1637 whole
      load_sector(16'h0800);
      pulse_commit(22'd512 * 22'd31);      // sector 31
      wait_rd(64, got);
      check(got, "DC42 must READ the first block before writing it");
      check(sd_lba === 32'd31, "and the first block is N, not N+1");
      serve_read(16'h2A00);
      wait_wr(64, got);
      check(got && sd_lba === 32'd31, "then write that same block back");
      serve_block_dc42(16'h2A00, 16'h0800, 1'b1);
      wait_rd(64, got);
      check(got && sd_lba === 32'd32, "then read the SECOND block, N+1");
      serve_read(16'h3B00);
      wait_wr(64, got);
      check(got && sd_lba === 32'd32, "and write it back");
      serve_block_dc42(16'h3B00, 16'h0800, 1'b0);
      check(!busy, "the sector is done only once BOTH blocks have landed");

      // --- 8. the file's final partial block is refused ------------------
      $display("8. a sector straddling the partial tail block is refused");
      load_sector(16'h0900);
      pulse_commit(22'd512 * 22'd1636);    // needs blocks 1636 AND 1637
      wait_rd(64, got);
      check(!got, "must not even read: the pair straddles the partial tail");
      wait_wr(32, got);
      check(!got, "and must never write half a sector");
      repeat (8) @(posedge clk);
      check(!busy, "retired instead");
      dc42 <= 1'b0;

      // --- 9. eject -> the DC42 data checksum is recomputed and written ---
      $display("9. guest eject rewrites the DC42 data checksum in block 0");
      dc42        <= 1'b1;
      file_blocks <= 13'd64;
      exp_dsize    = 22'd1024;          // a tiny modelled file: data ends in block 2
      exp_cksum    = 32'd0;
      // make the session dirty: one ordinary DC42 sector write
      load_sector(16'h0A00);
      pulse_commit(22'd512 * 22'd4);
      wait_rd(64, got);   check(got, "sector write reads its first block");
      serve_read(16'h1100);
      wait_wr(64, got);   check(got, "and writes it");
      serve_block_dc42(16'h1100, 16'h0A00, 1'b1);
      wait_rd(64, got);   check(got, "second block read");
      serve_read(16'h1200);
      wait_wr(64, got);   check(got, "second block written");
      serve_block_dc42(16'h1200, 16'h0A00, 1'b0);
      check(!busy, "sector done");

      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      @(posedge clk);
      check(busy, "the flush makes it busy");

      // pass 1: blocks 0,1,2 are scanned
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "scan starts at block 0");
      scan_block(13'd0, 16'h5000);
      wait_rd(64, got);   check(got && sd_lba === 32'd1, "then block 1");
      scan_block(13'd1, 16'h6000);
      wait_rd(64, got);   check(got && sd_lba === 32'd2, "then block 2, the last with data");
      scan_block(13'd2, 16'h7000);

      // pass 2: block 0 is re-read, then written back with the two words swapped
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "then block 0 is re-read");
      // The DUT has already stopped accumulating (scan_active is down), so
      // the model must not count this block either - hold the expected sum
      // across the re-read. Getting this wrong here is what a double-count
      // in the DUT would look like, so the guard is worth the two lines.
      cksum_hold = exp_cksum;
      scan_block(13'd0, 16'h5000);
      exp_cksum  = cksum_hold;
      wait_wr(200, got);  check(got && sd_lba === 32'd0, "and block 0 written back");
      check_header(16'h5000);
      check(!busy, "flush complete");

      // --- 10. a remount in the middle of a DC42 RMW aborts it -------------
      $display("10. img_mounted mid-RMW: the loader's ack must not become our sd_wr");
      load_sector(16'h0B00);
      pulse_commit(22'd512 * 22'd6);
      wait_rd(64, got);   check(got && sd_lba === 32'd6, "the RMW read is presented");
      @(posedge clk); img_mounted <= 1'b1; loader_busy <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      @(posedge clk);
      check(!sd_rd && !sd_wr, "both request lines drop at the mount pulse");
      check(!busy, "and the writer is idle, queue and phase dropped");
      // the loader now streams the new image; its first block is acked on
      // the shared slot. The old FSM turned this into P_RD_DONE -> sd_wr.
      serve_read(16'h2C00);
      wait_wr(32, got);   check(!got, "no sd_wr may follow the loader's ack");
      check(!busy, "still idle");
      loader_busy <= 1'b0;

      // --- 11. a remount during the eject flush abandons the scan -----------
      $display("11. img_mounted mid-flush: the scan is abandoned, no header write");
      load_sector(16'h0C00);
      pulse_commit(22'd512 * 22'd8);
      wait_rd(64, got);   serve_read(16'h1300);
      wait_wr(64, got);   serve_block_dc42(16'h1300, 16'h0C00, 1'b1);
      wait_rd(64, got);   serve_read(16'h1400);
      wait_wr(64, got);   serve_block_dc42(16'h1400, 16'h0C00, 1'b0);
      check(!busy, "sector landed, mount is dirty");
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "scan starts");
      exp_cksum = 32'd0;
      scan_block(13'd0, 16'h5000);
      wait_rd(64, got);   check(got && sd_lba === 32'd1, "second scan block requested");
      @(posedge clk); img_mounted <= 1'b1; loader_busy <= 1'b1;
      @(posedge clk); img_mounted <= 1'b0;
      @(posedge clk);
      check(!busy && !sd_rd && !sd_wr, "the flush is abandoned at the mount pulse");
      // enough loader acks to have walked the old FSM through the rest of
      // the scan, the header re-read and into F_HDR_WR
      for (i = 0; i < 6; i = i + 1) serve_read(16'h2D00 + i[15:0]);
      wait_wr(32, got);   check(!got, "no header write may reach the new image");
      check(!busy, "idle throughout");
      loader_busy <= 1'b0;

      // --- 12. Floppy Write switched off AFTER writing: eject still flushes -
      $display("12. write_ok low at eject: the checksum is still rewritten");
      load_sector(16'h0D00);
      pulse_commit(22'd512 * 22'd10);
      wait_rd(64, got);   serve_read(16'h1500);
      wait_wr(64, got);   serve_block_dc42(16'h1500, 16'h0D00, 1'b1);
      wait_rd(64, got);   serve_read(16'h1600);
      wait_wr(64, got);   serve_block_dc42(16'h1600, 16'h0D00, 1'b0);
      check(!busy, "sector landed");
      write_ok <= 1'b0;
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      @(posedge clk);
      check(busy, "the flush latches although write_ok is now low");
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "scan starts");
      exp_cksum = 32'd0;
      scan_block(13'd0, 16'h5100);
      wait_rd(64, got);   scan_block(13'd1, 16'h6100);
      wait_rd(64, got);   scan_block(13'd2, 16'h7100);
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "block 0 re-read");
      cksum_hold = exp_cksum;
      scan_block(13'd0, 16'h5100);
      exp_cksum  = cksum_hold;
      wait_wr(200, got);  check(got && sd_lba === 32'd0, "header written");
      check_header(16'h5100);
      check(!busy, "flush complete");
      write_ok <= 1'b1;

      // --- 13. eject while the session's only sector is still QUEUED --------
      $display("13. eject with the only sector still queued: sector first, then the flush");
      loader_busy <= 1'b1;                 // hold it in the queue
      load_sector(16'h0E00);
      pulse_commit(22'd512 * 22'd12);
      // The point of this section is an eject that finds `dirty` LOW with a
      // sector queued. Pin the precondition: on the pre-fix RTL, section 12's
      // skipped flush left dirty set and this section passed for the wrong
      // reason (negative control, 2026-09-16).
      check(dut.dirty === 1'b0, "precondition: nothing has landed yet this mount");
      @(posedge clk); flush_req <= 1'b1;   // dirty is still 0 here
      @(posedge clk); flush_req <= 1'b0;
      loader_busy <= 1'b0;
      wait_rd(64, got);   check(got && sd_lba === 32'd12, "the queued sector drains first");
      serve_read(16'h1700);
      wait_wr(64, got);   serve_block_dc42(16'h1700, 16'h0E00, 1'b1);
      wait_rd(64, got);   serve_read(16'h1800);
      wait_wr(64, got);   serve_block_dc42(16'h1800, 16'h0E00, 1'b0);
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "then the scan starts: the flush latched on the queued sector");
      exp_cksum = 32'd0;
      scan_block(13'd0, 16'h5200);
      wait_rd(64, got);   scan_block(13'd1, 16'h6200);
      wait_rd(64, got);   scan_block(13'd2, 16'h7200);
      wait_rd(64, got);   check(got && sd_lba === 32'd0, "block 0 re-read");
      cksum_hold = exp_cksum;
      scan_block(13'd0, 16'h5200);
      exp_cksum  = cksum_hold;
      wait_wr(200, got);  check(got && sd_lba === 32'd0, "header written");
      check_header(16'h5200);
      check(!busy, "flush complete");

      // --- 14. eject after a sector that was REFUSED: nothing to rewrite ----
      $display("14. eject when nothing of ours reached the file: header left alone");
      loader_busy <= 1'b1;
      load_sector(16'h0F00);
      pulse_commit(22'd512 * 22'd63);      // needs blocks 63 AND 64; file_blocks is 64
      @(posedge clk); flush_req <= 1'b1;
      @(posedge clk); flush_req <= 1'b0;
      loader_busy <= 1'b0;
      wait_rd(32, got);   check(!got, "nothing is read");
      wait_wr(32, got);   check(!got, "nothing is written");
      check(!busy, "the latched flush is dropped once the queue proves clean");
      // the witness word: refusals in sections 3, 8 and 14; never an overflow
      check(dbg[23:16] === 8'd3, "dbg refused count = 3");
      check(dbg[31:24] === 8'd0, "dbg overflow count = 0");
      check(dbg[3:0] === 4'd0,   "dbg pstate = idle");

      $display("");
      $display("tb_floppy_sd_writer: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS");
      else            $display("FAIL");
      $finish;
   end

   initial begin
      #20_000_000;
      $display("tb_floppy_sd_writer: TIMEOUT");
      $finish;
   end

endmodule
