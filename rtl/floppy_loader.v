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
	output reg        raw_img,       // 1 = raw sector image (writable in stage 1)
	output reg        is_dc42,       // 1 = a DiskCopy 4.2 image was detected
	// ── file block 0's first 42 words, kept for the SD writer (Phase 4b) ──
	// The 84-byte DC42 header is stripped from SDRAM, so it is the one part
	// of file block 0 the SDRAM-sourced writer cannot fetch. Captured here
	// as block 0 streams past at mount, in the INTERNAL (swapped) word
	// convention like everything else in SDRAM. Registered read port:
	// hdr_data is valid the cycle after hdr_addr. Words 36/37 are the data
	// checksum as it stood at mount; the writer substitutes its own.
	input       [5:0] hdr_addr,
	output reg [15:0] hdr_data,
	output reg  [7:0] dc42_fmt       // DC42 byte 0x50: 0=400K 1=800K 2=720K 3=1440K
	                                 // ★ For a DC42 image `size` CANNOT decide the
	                                 // geometry: tags trail the sector data, so an
	                                 // 800K DC42 has 838400 payload bytes, not
	                                 // 819200, and matches no size test. This byte
	                                 // is the discriminator — same as the old
	                                 // download path's dc42_disk_format.
);

	// ── sector staging RAM ────────────────────────────────────────────────
	// sd_buff_wr has no rate limit against on-chip RAM, but the SDRAM side is
	// paced by the download slot, so a sector is captured whole and then
	// drained. Load-then-drain, not double-buffered: correctness first.
	reg [15:0] buf_ram [0:255];
	reg  [7:0] drain_idx;

	// Stored BYTE-SWAPPED. hps_io assigns both paths from the same source —
	// `ioctl_dout <= io_din[DW:0]` (hps_io.sv:692) and
	// `sd_buff_dout <= io_din[DW:0]` (hps_io.sv:405) — so a block-device word
	// packs exactly like a download word, and the read side depends on the
	// swap the old download path applied (MacLC.sv:2544
	// `{ioctl_data[7:0], ioctl_data[15:8]}`). Omitting it transposes every
	// byte pair: the disk mounts and is unreadable.
	always @(posedge clk_sys)
		if (sd_buff_wr && sd_ack) buf_ram[sd_buff_addr[7:0]] <= sw_data;

	// header store: every mount rewrites it (a raw image's "header" is just
	// its first 84 bytes, harmless — the writer only consults it for DC42).
	reg [15:0] hdr_ram [0:63];
	always @(posedge clk_sys) begin
		if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0 &&
		    sd_buff_addr[7:0] < 8'd42)
			hdr_ram[sd_buff_addr[5:0]] <= sw_data;
		hdr_data <= hdr_ram[hdr_addr];
	end

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

	// DC42 header words, sampled as sector 0 streams past.
	//
	// ★ TESTED ON THE RAW DELIVERED WORD, NOT THE SWAPPED ONE. In the HPS
	// word, bit [7:0] is the FIRST byte of the pair (which is why the storage
	// swap is {d[7:0], d[15:8]}). The proven download path tests raw
	// `ioctl_data` (MacLC.sv:2538-2541) and this must match it exactly:
	//   word 0  byte 0  = d[7:0] : Pascal name length, 1..63
	//   word 40 byte 80 = d[7:0] : disk-format byte (DC42 offset 0x50)
	//   word 41         = d      : the magic, 16'h0001
	// Testing the swapped word instead reads byte 1 for the name length and
	// transposes the magic.
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
			is_dc42  <= 1'b0;
			dc42_fmt <= 8'd0;
		end else begin

			// ── capture the DC42 signature as sector 0 streams in ──────────
			if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0) begin
				if (sd_buff_addr[7:0] == 8'd0)
					dc42_name_ok <= (sd_buff_dout[7:0] >= 8'd1) && (sd_buff_dout[7:0] <= 8'd63);
				else if (sd_buff_addr[7:0] == 8'd40)
					dc42_fmt <= sd_buff_dout[7:0];      // DC42 byte 0x50
				else if (sd_buff_addr[7:0] == 8'd41 && dc42_name_ok && sd_buff_dout == 16'h0001)
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
					dc42_fmt     <= 8'd0;
					raw_img      <= 1'b0;
					is_dc42      <= 1'b0;   // an unmount must not leave the old
					                        // container flag standing
					size         <= 64'd0;
					if (img_size != 64'd0) begin
						// COMPLETE blocks only. A DC42 file is 84 + payload
						// bytes and never ends on a block boundary, so its
						// final partial block is never streamed: a tagged
						// image loses nothing (that block is tag section), a
						// TAGLESS one -- every 1440K DC42 -- never loads the
						// last 84 bytes of its last sector. HFS leaves the
						// volume's last block unused, so this is latent; it
						// is documented with the matching write-side limit
						// in floppy_sd_writer.v (LC addition 3).
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
				// hps_io raises sd_ack when it picks the transfer up and drops
				// it once the sector has been delivered. DROP THE REQUEST ON
				// THE RISING EDGE, not at the end: this core's own SCSI does
				// exactly that (rtl/scsi.v:1847 `if(io_ack) io_rd_d <= 1'b0;`,
				// with completion tracked separately off the falling edge).
				// Holding sd_rd up for the whole transfer leaves the request
				// still asserted when hps_io next samples it, and it re-issues
				// the same LBA.
				if (sd_ack) sd_rd <= 1'b0;
				if (old_ack && !sd_ack) begin
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
				is_dc42 <= dc42;
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
