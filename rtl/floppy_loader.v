// Mount-time floppy image loader — Phase 1 of docs/floppy_write_plan.md.
//
// Floppies used to arrive as a one-way `ioctl_download` blob into SDRAM
// (plan §2.5), which is a dead end for writing: there is no file handle to
// write back through. This streams the image in as a real SD block device
// instead — on img_mounted, sector by sector via sd_rd, into the SAME SDRAM
// word offsets the read side already expects (dskReadAddrInt/Ext in
// rtl/addrController_top.v), so nothing downstream of SDRAM changes.
//
// STILL READ-ONLY. No sd_wr, no write-back, no WRTPRT change. Phase 1's gate
// is "boots from floppy exactly as before", so a regression here is provably
// plumbing and nothing else.
//
// SDRAM PATH: this drives the sdram.v DOWNLOAD write port (wr_req/wr_ack),
// not a new requester and not addrController_top's extra slot. Plan §6.3 is
// explicit that a new extra-slot requester is the wrong move — MacPlus lost
// two hardware gates to sdram.v's two-phase RAS/CAS sampling doing exactly
// that. The download port is one of the two already-proven LEVEL-handshake
// requesters, and once floppies are block devices its only other user is the
// ROM at boot, which runs with the CPU in reset. MacLC.sv owns the mux.
//
// DC42 NORMALISATION (plan §6.2, decided 2026-09-14): a DiskCopy 4.2 image
// carries an 84-byte header. It is stripped HERE, while streaming, so SDRAM
// holds pure sector data and guest sector N sits at SDRAM word offset N*256.
// 84 bytes = 42 words, so the write address is simply the file word index
// minus 42 and the first 42 words are dropped — no alignment problem, because
// SDRAM is word-addressed. `raw_img` reports whether this was a raw image:
// stage-1 writes are raw-only, so a DC42 mount must present write-protected.
//
// `done` does not fire until the whole image is resident, so the guest can
// never observe a half-loaded disk — the block-device equivalent of the old
// end-of-download latch.
//
// Ported from MacPlus_MiSTer rtl/floppy_loader.v (branch floppy-write) and
// changed where this core differs: the SDRAM port above, DC42 handling
// (MacPlus has no DC42 support at all), and the 13-bit sd_buff_addr this
// core's WIDE hps_io uses.

module floppy_loader
(
	input             clk_sys,
	input             reset,

	// ── HPS block device (this slot) ──────────────────────────────────────
	input             img_mounted,   // one-shot mount pulse for this slot
	input      [63:0] img_size,      // valid at img_mounted; 0 = unmount
	input             img_readonly,  // valid at img_mounted

	output reg [31:0] sd_lba,
	output reg        sd_rd,
	input             sd_ack,
	input      [12:0] sd_buff_addr,  // AW=12 WIDE hps_io; [7:0] is the 512 B word index
	input      [15:0] sd_buff_dout,
	input             sd_buff_wr,

	// ── SDRAM download write port (level handshake, see sdram.v dl_*) ──────
	input      [23:0] base_addr,     // SDRAM WORD address of this image's slot
	output reg [23:0] wr_addr,       // SDRAM word address for the pending word
	output reg [15:0] wr_data,
	output reg        wr_req,        // LEVEL: held until wr_ack is seen
	input             wr_ack,        // LEVEL

	// ── status ────────────────────────────────────────────────────────────
	output reg        loading,       // high for the whole mount: gates flp_ok
	output reg        done,          // one clk_sys pulse: image fully resident
	output reg [63:0] size,          // latched payload size (DC42 header removed)
	output reg        readonly,      // latched at THIS slot's own mount pulse
	output reg        raw_img        // 1 = raw sector image (writable in stage 1)
);

	// ── sector staging RAM ────────────────────────────────────────────────
	// sd_buff_wr has no rate limit against on-chip RAM, but the SDRAM side is
	// paced by the download slot, so a sector is captured whole and then
	// drained. Load-then-drain, not double-buffered: correctness first.
	reg [15:0] buf_ram [0:255];
	reg  [7:0] drain_idx;

	always @(posedge clk_sys)
		if (sd_buff_wr && sd_ack) buf_ram[sd_buff_addr[7:0]] <= sd_buff_dout;

	localparam S_IDLE   = 3'd0;
	localparam S_RD     = 3'd1;   // sd_rd asserted, waiting for the sector
	localparam S_WAIT   = 3'd2;   // sd_ack fell: sector is in buf_ram
	localparam S_DRAIN  = 3'd3;   // push words to SDRAM
	localparam S_NEXT   = 3'd4;
	localparam S_DONE   = 3'd5;

	reg  [2:0] state;
	reg [31:0] sec_total;         // sectors to stream (file size / 512)
	reg [23:0] file_word;         // word index within the FILE
	reg        dc42;              // this image has a DiskCopy 4.2 header
	reg        dc42_name_ok;
	reg        old_ack;

	// DC42 header words, sampled as sector 0 streams past: word 0's low byte
	// is a Pascal name length (1..63), word 40's low byte is the disk-format
	// byte, word 41 is the 16-bit magic 0x0001 at byte offset 82. Same test
	// the old download path used (MacLC.sv:2529), applied to the same words.
	localparam DC42_HDR_WORDS = 24'd42;   // 84 bytes

	wire [15:0] sw_data = {sd_buff_dout[7:0], sd_buff_dout[15:8]};   // byte swap,
	// matching the old download path's `{ioctl_data[7:0], ioctl_data[15:8]}` —
	// the read side depends on this byte order.

	always @(posedge clk_sys) begin
		old_ack <= sd_ack;
		done    <= 1'b0;

		if (reset) begin
			state    <= S_IDLE;
			sd_rd    <= 1'b0;
			wr_req   <= 1'b0;
			loading  <= 1'b0;
			size     <= 64'd0;
			readonly <= 1'b0;
			raw_img  <= 1'b0;
			dc42     <= 1'b0;
		end else begin

			// ── capture the DC42 signature as sector 0 streams in ──────────
			if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0) begin
				if (sd_buff_addr[7:0] == 8'd0)
					dc42_name_ok <= (sw_data[7:0] >= 8'd1) && (sw_data[7:0] <= 8'd63);
				else if (sd_buff_addr[7:0] == 8'd41 && dc42_name_ok && sw_data == 16'h0001)
					dc42 <= 1'b1;
			end

			case (state)

			S_IDLE: begin
				// A mount pulse with a non-zero size starts a load; a zero size
				// is an UNMOUNT and must not start one. Latch readonly here,
				// at THIS slot's own pulse — per-slot latching is the point
				// (plan Phase 1; precedent UK101.sv:274-277).
				if (img_mounted) begin
					readonly     <= img_readonly;
					dc42         <= 1'b0;
					dc42_name_ok <= 1'b0;
					raw_img      <= 1'b0;
					size         <= 64'd0;
					if (img_size != 64'd0) begin
						sec_total <= img_size[40:9];   // / 512
						sd_lba    <= 32'd0;
						file_word <= 24'd0;
						loading   <= 1'b1;
						sd_rd     <= 1'b1;
						state     <= S_RD;
					end else begin
						loading <= 1'b0;               // unmount: drive goes empty
					end
				end
			end

			S_RD: begin
				// hps_io raises sd_ack for the transfer and drops it when the
				// sector has been delivered.
				if (old_ack && !sd_ack) begin
					sd_rd     <= 1'b0;
					drain_idx <= 8'd0;
					state     <= S_WAIT;
				end
			end

			S_WAIT: begin
				state <= S_DRAIN;      // one cycle for buf_ram's read port
			end

			S_DRAIN: begin
				if (!wr_req) begin
					// Skip the DC42 header entirely: those words are not disk
					// data and must not shift the payload.
					if (dc42 && (file_word < DC42_HDR_WORDS)) begin
						file_word <= file_word + 24'd1;
						drain_idx <= drain_idx + 8'd1;
						if (drain_idx == 8'd255) state <= S_NEXT;
					end else begin
						wr_addr <= base_addr +
						           (dc42 ? (file_word - DC42_HDR_WORDS) : file_word);
						wr_data <= buf_ram[drain_idx];
						wr_req  <= 1'b1;
					end
				end else if (wr_ack) begin
					wr_req    <= 1'b0;     // two-phase: drop req, ack follows
					file_word <= file_word + 24'd1;
					drain_idx <= drain_idx + 8'd1;
					if (drain_idx == 8'd255) state <= S_NEXT;
				end
			end

			S_NEXT: begin
				if (sd_lba + 32'd1 >= sec_total) begin
					state <= S_DONE;
				end else begin
					sd_lba <= sd_lba + 32'd1;
					sd_rd  <= 1'b1;
					state  <= S_RD;
				end
			end

			S_DONE: begin
				// Publish the payload size the guest should see: for DC42 that
				// is the file minus its header. raw_img gates stage-1 writes.
				size    <= dc42 ? (img_size_l - 64'd84) : img_size_l;   // 42 words
				raw_img <= !dc42;
				loading <= 1'b0;
				done    <= 1'b1;         // one pulse, AFTER the image is resident
				state   <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	// img_size is only valid at the mount pulse, so hold it for S_DONE.
	reg [63:0] img_size_l;
	always @(posedge clk_sys)
		if (img_mounted) img_size_l <= img_size;

endmodule
