// floppy_sd_writer.v
//
// Persist a checksum-valid, SDRAM-committed sector (see
// floppy_write_committer.v) out to the mounted image on the SD card, via
// hps_io's sd_rd/sd_wr/sd_ack/sd_buff_* block-device protocol. This is Phase
// 4: the first and only module in the floppy write path that touches the
// user's file.
//
// Ported from MacPlus_MiSTer rtl/floppy_sd_writer.v. The depth-2 queue, the
// eject-race interlock and the ack-timeout re-presentation are theirs
// unchanged and hardware-proven there; the LC additions are marked with a
// star. Read their reasoning in place rather than trusting a summary --
// every one of those comments exists because somebody lost time to the thing
// it warns about.
//
// Protocol modelled on scsi.v's io_wr handshake (the only sd_wr producer
// already proven on this core): assert sd_wr with sd_lba valid, drop sd_wr as
// soon as sd_ack rises (hps_io has accepted the request and is now stepping
// sd_buff_addr through the block), then wait for sd_ack to fall again before
// considering the sector durably handed off -- mirroring floppy_loader.v's own
// SD_WAIT_ACK/SD_WAIT_DONE split on the read side. sd_buff_din for this slot
// must stay valid, addressed by the HPS-driven shared sd_buff_addr bus, for
// the whole time sd_ack is high.
//
// A checksum-valid sector never depends on rotational position, so this module
// has no notion of "gap" -- the queue only ever fills on commit_done. It also
// reacts to img_mounted (eject/remount of THIS slot): the queue is dropped so
// a sector captured against the old image never lands, at the old image's
// stale LBA, in whatever gets mounted next -- and, unlike MacPlus, the FSM is
// ABORTED too. See LC addition 5 for why the inherited "leave pstate alone"
// rule became a corruption path here.
//
// Backpressure: the CPU-facing write path can only produce a new commit_done
// roughly once per sector's worth of 16us-paced IWM bytes (~700 encoded bytes
// => >10ms), comfortably longer than a real SD transfer, so the 2-entry queue
// (two shadow buffers, ping-ponged by `tail` on capture, drained in order via
// `head`) is ample. A third commit landing before the first of the previous
// two has drained reuses the still-in-flight buffer: a documented,
// not-expected-in-practice limit, and a stale-data one rather than a torn
// transfer.
//
// ★ LC ADDITION 1 -- write_ok, the backstop.
// MacPlus gates persistence on `readonly` alone. Here the caller also passes
// write_ok, which must be high for a sector to reach the card at all. It
// carries the OSD Floppy Write toggle and the slot's latched img_readonly, so
// that decision lives in ONE place in MacLC.sv rather than being re-derived
// here. Belt and braces over the decoder's own condition, per the plan's
// Phase 4 note and ../UK101_MiSTer/UK101.sv:304. A sector refused here is
// refused silently: the volatile SDRAM commit has already happened, so the
// guest still sees its write, which is exactly the Phase 3b behaviour.
//
// ★ LC ADDITION 2 -- DiskCopy 4.2 containers, and why this is a READ-MODIFY-
// WRITE against the CARD rather than against SDRAM.
//
// A raw image puts sector N at file byte N*512, so one sector is one block and
// the shadow buffer is written out as-is. A DC42 file prefixes an 84-byte
// header, so sector N starts at file byte 84 + N*512 and straddles two blocks:
//
//     block N   = [ 84 bytes: tail of sector N-1 ][ 428 bytes: head of N ]
//     block N+1 = [ 84 bytes: tail of sector N   ][ 428 bytes: head of N+1 ]
//
// The split is CONSTANT (remainder 84 for every N, because 84 < 512) and
// WORD-ALIGNED -- 84 bytes is exactly 42 words and 428 is 214 -- so there is
// no byte-granular work anywhere in this module.
//
// The bytes belonging to the neighbouring sectors have to come from somewhere,
// and the choice matters more than it looks:
//   - SDRAM holds the whole normalised payload and could supply them, but
//     only by making this module a new requester on rtl/sdram.v, the most
//     invariant-laden file in the core.
//   - The CARD already holds them, in the very block about to be rewritten.
//     Reading it costs one extra SD access per block, against a sector rate
//     of one per ~10ms.
// So: read the block, patch the words this sector owns, write it back. No
// sdram.v change at all, and the read side reuses the same sd_rd/sd_buff_wr
// capture floppy_loader.v is already built on.
//
// ★ It is also the more CORRECT source. If the user turns Floppy Write off
// and later back on, SDRAM has moved on but the card has not. Sourcing the
// neighbour bytes from the card means each write changes only the sector it
// was for, and never silently persists sectors the user chose not to. From
// SDRAM it would splice in whatever the guest had done meanwhile.
//
// ★ LC ADDITION 3 -- the file's last block may be PARTIAL, and is refused.
// A DC42 file is 84 + payload bytes, which is never a multiple of 512 (e.g. a
// tagged 800K image is 838484 = 1637 blocks + 340). hps_io writes whole
// blocks, so writing that final partial block would pad the file. file_blocks
// is therefore the count of COMPLETE blocks and anything at or past it is
// refused. For a tagged image this costs nothing -- data sectors end at block
// 1600, far short of the tail, and the tag section is never written, which is
// also why the DC42 TAG checksum stays valid and only the DATA checksum needs
// recomputing. For a TAGLESS DC42 (tagSize 0, 819284 bytes) the final data
// sector's 84-byte tail lands in the partial block and is refused: that one
// sector stays volatile. Documented limit, not a silent one.
//   The read side has the matching gap, and it is older: floppy_loader.v
// floors the block count (`img_size[40:9]`), so those same 84 bytes are never
// LOADED either -- a tagless DC42's last sector has a stale tail in SDRAM
// from the moment it mounts. Every 1440K DC42 is tagless. HFS never uses the
// volume's last block (the alternate MDB is the one before it), which is why
// nobody has noticed. If it is ever closed, note that Main mounts this slot
// non-growable (menu.cpp passes no pre-allocation) and clamps a write at the
// file's end (user_io.cpp, the `sd_image_cangrow` branch), so the tail block
// COULD be written without padding the file -- at the cost of depending on
// that Main behaviour.
//
// ★ LC ADDITION 4 -- the DC42 data checksum, rewritten on eject.
// A DC42 header carries checksums over the data and tag sections, computed as
// `sum = ror32(sum + big_endian_word)` across the whole section. Every word's
// contribution therefore depends on its POSITION, so changing one sector
// cannot be folded into the stored sum incrementally and cannot be undone
// from it either -- there is no way to subtract the old sector's share.
// The only correct answer is to recompute, and the cheapest moment to do that
// is once, when the disk is ejected:
//
//   pass 1  scan file blocks 0..last-data-block, accumulating every word of
//           the DATA section (block 0 contributes only words 42..255, the
//           last one only up to where dataSize ends). dataSize is read out of
//           the header during block 0, which is the first block scanned.
//   pass 2  re-read block 0, substitute the two checksum words on the way
//           back out, write it.
//
// The TAG checksum is deliberately left alone: the committer writes 512 data
// bytes per sector and never touches the tag section, so the stored tag sum
// is still correct. Writing a wrong one would be worse than leaving a right
// one.
//
// The trigger is the GUEST's eject, not an OSD unmount, and that is the only
// point where this can work: the file is still mounted in hps_io, so the slot
// still reaches it. It is also the Mac-authentic order -- a real drive only
// ejects under software control, and the plan's own note is that swapping a
// disk under a live volume is hostile on real hardware too. A disk pulled
// straight out of the OSD without a guest eject keeps its old checksum; the
// DATA is still correct and every emulator that ignores the checksum will
// read it fine, but DiskCopy itself would flag it.
//
// `dirty` gates the whole thing, so a session that never wrote a sector never
// rewrites a header. Two details of the trigger, both found in review
// (2026-09-16) and both pinned by the bench:
//   - the flush is latched on `dirty` OR a non-empty queue, because `dirty`
//     is set when a block LANDS, not when a sector is queued. An eject that
//     arrives while the session's only sector is still queued would otherwise
//     find dirty low and skip the rewrite. Whether to actually scan is decided
//     at P_IDLE, once the queue has drained and dirty is final;
//   - write_ok is NOT part of the condition. `dirty` already proves the
//     writes were permitted when they happened; gating the flush on the
//     toggle's CURRENT state would let "write, switch Floppy Write off, eject"
//     leave changed data under an unchanged checksum.
//
// ★ LC ADDITION 5 -- img_mounted ABORTS the FSM. This is the one place the
// MacPlus port is deliberately NOT "theirs unchanged".
// MacPlus clears the queue on a remount but leaves pstate alone, reasoning
// that a request hps_io is already servicing should be allowed to finish and
// that, with `valid` cleared, the FSM can issue nothing further. Both halves
// were true there because a sector was ONE request. Here a DC42 sector is a
// FOUR-request transaction (read N, write N, read N+1, write N+1) and the
// eject flush is a ~1600-request one, and steps after the first are issued
// from states that never look at `valid`. sd_ack is per SLOT, not per
// requester, so once floppy_loader starts streaming the new image its acks
// are indistinguishable from ours: the loader's first ack moves P_RD_ACK to
// P_RD_DONE, which raises sd_wr -- and sd_wr is not something the loader's
// ownership of sd_lba/sd_rd can mask. Reproduced in the bench (sections 10 and
// 11): the old sector, or the old header block with a garbage checksum, is
// written into the NEW image at whatever LBA the loader happens to be on.
// Exactly the class this module exists to prevent.
//
// The abort is safe because Main is single-threaded: it finishes any transfer
// it has captured before it can send a mount notification, so at the mount
// pulse no request of ours is mid-transfer, and anything still presented has
// not been seen. Dropping it loses nothing that the remount has not already
// lost. The old image's header stays stale, which is already the documented
// outcome of an OSD-first unmount (see LC addition 4). MacLC.sv additionally
// masks the slot's sd_wr while the loader owns it, belt and braces.
module floppy_sd_writer #(
	parameter ACK_TIMEOUT_BITS = 24 // ~0.5s at clk_sys (~32MHz); sim overrides this narrower
) (
	input         clk,
	input         reset,

	input         img_mounted, // this slot's own mount pulse - drop the queue, see header

	// commit tap from floppy_write_committer, via floppy.v
	input             commit_done,
	input      [21:0] commit_addr,     // PAYLOAD byte offset of sector byte 0
	input             commit_buf_wr,
	input      [7:0]  commit_buf_addr, // word index 0..255
	input      [15:0] commit_buf_data,

	input             write_ok,     // see header: the single gate on reaching the card
	input             loader_busy,  // don't touch the slot while floppy_loader owns it
	input             dc42,         // 1 = DiskCopy 4.2 container (84-byte header)
	input             flush_req,    // 1-clk pulse: the guest ejected. See LC addition 4.

	// Count of COMPLETE 512-byte blocks in the FILE (not the payload): for a
	// raw image payload_bytes>>9, for DC42 (payload_bytes+84)>>9. A block at
	// or past this is refused - see LC addition 3.
	input      [12:0] file_blocks,

	output reg [31:0] sd_lba,
	output reg        sd_rd,
	output reg        sd_wr,
	input             sd_ack,

	input      [12:0] sd_buff_addr_i, // HPS-driven shared address, both
	                                  // directions. AW=12 WIDE hps_io; [7:0]
	                                  // is the word index within a 512 B block
	input      [15:0] sd_buff_dout, // card -> here, valid with sd_buff_wr
	input             sd_buff_wr,
	output     [15:0] sd_buff_din,  // here -> card

	output            busy,

	// Witness word for the debug observer (MacLC.sv, USE_DBG_OBSERVER). The
	// hardware gate needs to SEE the two silent failure modes -- a queue
	// overflow (third commit while both buffers are owned: the header's
	// "not expected in practice" limit, now 4x more likely under DC42's four
	// transactions per sector) and a refused sector -- because neither leaves
	// any trace in the guest.
	//   [31:24] overflow count (sat)   [23:16] refused count (sat)
	//   [15:8]  blocks landed (wraps)  [7:4] flushes started (sat)
	//   [3:0]   pstate
	output     [31:0] dbg
);

	wire [7:0] sd_buff_addr = sd_buff_addr_i[7:0];

	localparam SPILL_BASE = 8'd214;  // 256 - HDR_WORDS: the shadow word the
	                                 // sector's spill into the next block starts at
	localparam HDR_WORDS = 8'd42;    // 84 bytes, the DC42 header - and so also
	                                 // the word at which a sector starts inside
	                                 // its first block, and the count of its
	                                 // words that spill into the next one.

	// two independent 256x16 shadow sectors - see header for why two.
	reg [15:0] mem0 [0:255];
	reg [15:0] mem1 [0:255];

	// ★ the read-modify-write scratch: one card block, held in the INTERNAL
	// word convention (even byte in the high half) so that the single output
	// swap below serves both it and the shadow. Same swap floppy_loader.v:123
	// applies on its own read side.
	reg [15:0] rmw [0:255];

	reg        tail;       // buffer currently receiving commit_buf_wr taps
	reg        head;       // buffer currently queued/draining
	reg  [1:0] valid;      // per-buffer: queued or in-flight, not yet drained
	reg [21:0] addr_q [0:1];

	always @(posedge clk) begin
		if (commit_buf_wr) begin
			if (tail == 1'b0) mem0[commit_buf_addr] <= commit_buf_data;
			else              mem1[commit_buf_addr] <= commit_buf_data;
		end
	end

	// The file's big-endian word is the wire word with its halves swapped -
	// the same relation floppy_loader.v:123 encodes. The rmw scratch keeps it
	// in that internal convention; the checksum is defined over exactly this
	// value, so both use it.
	wire [15:0] file_word = {sd_buff_dout[7:0], sd_buff_dout[15:8]};

	always @(posedge clk)
		if (sd_buff_wr && sd_ack)
			rmw[sd_buff_addr] <= file_word;

	// ★ eject-time checksum state (LC addition 4)
	reg         dirty;         // a sector reached the card this mount
	reg  [31:0] cksum;
	reg  [21:0] data_size;     // DC42 header dataSize, bytes
	reg  [12:0] scan_blk;
	reg         scan_active;   // gates the accumulator: only during pass 1

	// Last DATA byte of the file, and where it falls. dataSize counts from
	// file byte 84, so the last data byte is 84 + dataSize - 1 = 83 + dataSize.
	wire [21:0] data_end   = 22'd83 + data_size;
	wire [12:0] last_blk   = data_end[21:9];
	wire  [7:0] last_word  = data_end[8:1];
	// A word counts towards the sum if it is past the header and not past the
	// end of the data section.
	wire        word_in_data = (scan_blk != 13'd0 || sd_buff_addr >= HDR_WORDS)
	                        && (scan_blk <  last_blk || sd_buff_addr <= last_word);

	wire [31:0] cksum_add = cksum + {16'd0, file_word};

	// flush_req is a pulse and the module is usually mid-transfer when it
	// arrives, so latch it. Only a DC42 that was actually written needs one.
	reg flush_pending;


	reg [15:0] mem0_do, mem1_do, rmw_do;
	reg        phase;      // DC42: 0 = the sector's first block, 1 = its second

	// Which source owns the word hps_io is currently asking for.
	//   raw      : always the shadow, word index = sd_buff_addr
	//   DC42 ph0 : words 0..41 are the previous sector's tail (card), words
	//              42..255 are this sector's first 214 words
	//   DC42 ph1 : words 0..41 are this sector's last 42 words, the rest is
	//              the next sector's head (card)
	wire        lo_part  = (sd_buff_addr < HDR_WORDS);
	wire        from_rmw = (dc42 && (phase ? !lo_part : lo_part))
	                    || (pstate == F_HDR_WR) || (pstate == F_HDR_WDONE);
	wire [7:0]  shadow_ix = !dc42  ? sd_buff_addr
	                      : phase  ? (sd_buff_addr + SPILL_BASE)
	                               : (sd_buff_addr - HDR_WORDS);

	always @(posedge clk) begin
		mem0_do <= mem0[shadow_ix];
		mem1_do <= mem1[shadow_ix];
		rmw_do  <= rmw[sd_buff_addr];
	end
	// from_rmw is combinational off sd_buff_addr while the three reads are
	// registered, so it must be delayed to line up with them.
	reg from_rmw_q;
	reg [7:0] sd_buff_addr_q;
	always @(posedge clk) begin
		from_rmw_q     <= from_rmw;
		sd_buff_addr_q <= sd_buff_addr;
	end

	wire [15:0] shadow_do = (head == 1'b0) ? mem0_do : mem1_do;
	// During the header rewrite every word comes from the re-read block 0
	// EXCEPT the two that hold the data checksum. They are substituted here,
	// on the way out, so the rest of the header (name, sizes, format bytes,
	// and the tag checksum) is returned exactly as it was read.
	wire        hdr_wr_now = (pstate == F_HDR_WR) || (pstate == F_HDR_WDONE);
	wire        sub_cs_hi  = hdr_wr_now && (sd_buff_addr_q == 8'd36);
	wire        sub_cs_lo  = hdr_wr_now && (sd_buff_addr_q == 8'd37);
	wire [15:0] word_do   = sub_cs_hi ? cksum[31:16]
	                      : sub_cs_lo ? cksum[15:0]
	                      : from_rmw_q ? rmw_do : shadow_do;
	// hps_io's wire format is the opposite half-order to ours; this swap must
	// mirror floppy_loader.v:123 or every written byte pair comes out
	// transposed in the image on the card.
	assign sd_buff_din = {word_do[7:0], word_do[15:8]};

	localparam P_IDLE      = 4'd0,
	           P_RD_ACK    = 4'd1,   // sd_rd up, waiting for the card
	           P_RD_DONE   = 4'd2,   // block captured into rmw
	           P_WAIT_ACK  = 4'd3,
	           P_WAIT_DONE = 4'd4,
	           // eject-time checksum rewrite (LC addition 4)
	           F_SCAN_RD   = 4'd5,   // sd_rd up for a scan block
	           F_SCAN_END  = 4'd6,   // that block accumulated; next or finish
	           F_HDR_RD    = 4'd7,   // re-read block 0 for the rewrite
	           F_HDR_END   = 4'd8,
	           F_HDR_WR    = 4'd9,
	           F_HDR_WDONE = 4'd10;
	reg [3:0] pstate;

	// P_WAIT_ACK has no bound otherwise: if this slot's request is ever up
	// while HPS isn't servicing it (framework quirk, a mount race on the
	// shared slot) sd_ack never rises and this module would wedge with busy
	// stuck high. ACK_TIMEOUT_BITS defaults to ~0.5s at clk - far longer than
	// any real sd_ack latency, so it never fires in normal operation. On
	// expiry the request is dropped and RE-PRESENTED, not retired - see
	// P_WAIT_ACK for why retiring it would be a data-corruption path rather
	// than a recovery.
	reg [ACK_TIMEOUT_BITS-1:0] ackTimer;
	wire ackTimeout = &ackTimer;

	// Payload offset -> file block. DC42 shifts every sector up by the header,
	// which is what puts the sector across two blocks in the first place.
	wire [21:0] pay_head  = addr_q[head];
	// Sector N starts at file byte 84 + N*512, and 84 < 512, so its FIRST
	// block is N in both containers - the header shifts the offset within the
	// block, not the block index. What DC42 changes is that a second block is
	// always involved.
	wire [12:0] blk_base  = pay_head[21:9];
	wire [12:0] blk_now   = blk_base + (phase ? 13'd1 : 13'd0);
	// Both blocks a DC42 sector touches must be writable, or the sector would
	// land half-written - the torn state that reads back self-consistently.
	// So range-check the PAIR up front, not each block as it comes.
	wire        blk_ok    = (file_blocks != 13'd0) &&
	                        ((dc42 ? (blk_base + 13'd1) : blk_base) < file_blocks);

	assign busy = (pstate != P_IDLE) || valid[0] || valid[1] || flush_pending;

	// debug witness counters (see the dbg port)
	reg [7:0] dbg_ovf, dbg_refused, dbg_landed;
	reg [3:0] dbg_flushes;
	assign dbg = {dbg_ovf, dbg_refused, dbg_landed, dbg_flushes, pstate};

	always @(posedge clk) begin
		if (reset) begin
			pstate <= P_IDLE;
			sd_lba <= 32'd0;
			sd_rd  <= 1'b0;
			sd_wr  <= 1'b0;
			valid  <= 2'b00;
			head   <= 1'b0;
			tail   <= 1'b0;
			phase  <= 1'b0;
			ackTimer <= 0;
			dirty         <= 1'b0;
			flush_pending <= 1'b0;
			scan_active <= 1'b0;
			scan_blk    <= 13'd0;
			cksum       <= 32'd0;
			data_size   <= 22'd0;
			dbg_ovf     <= 8'd0;
			dbg_refused <= 8'd0;
			dbg_landed  <= 8'd0;
			dbg_flushes <= 4'd0;
		end else begin
			// capture side: independent of pstate, always ready to accept the
			// next commit (see header re: the depth-2 queue's limit).
			if (commit_done && write_ok) begin
				valid[tail]  <= 1'b1;
				addr_q[tail] <= commit_addr;
				tail         <= ~tail;
				// a third commit while both buffers are still owned: the
				// in-flight buffer is being overwritten. Count it.
				if (valid[tail] && dbg_ovf != 8'hFF) dbg_ovf <= dbg_ovf + 8'd1;
			end

			// Latch the guest's eject if anything was, or may yet be, written
			// this mount. Whether a rewrite is actually needed is decided at
			// P_IDLE from the final `dirty` (header, LC addition 4). A
			// read-only session (dirty can never set) leaves the file byte for
			// byte alone.
			if (flush_req && dc42 && (dirty || valid[0] || valid[1]))
				flush_pending <= 1'b1;

			// ★ checksum accumulation, pass 1. This lives in the MAIN
			// sequential block on purpose: cksum/data_size are also written by
			// the reset and by the flush entry below, and a second always
			// block driving them is Quartus Error 10028 ("can't resolve
			// multiple constant drivers") - which both Verilator and Icarus
			// accept in silence. It sits before the case so that an explicit
			// assignment there (the flush entry zeroing the sum) still wins.
			if (scan_active && sd_buff_wr && sd_ack) begin
				// dataSize lives in header words 32/33 and is read during
				// block 0, the first block scanned, so it is valid well
				// before the end tests can matter (word 42 onwards).
				if (scan_blk == 13'd0 && sd_buff_addr == 8'd32)
					data_size[21:16] <= file_word[5:0];
				if (scan_blk == 13'd0 && sd_buff_addr == 8'd33)
					data_size[15:0]  <= file_word;
				// sum = ror32(sum + word), the DC42 algorithm exactly as
				// scripts/mk_dc42.py implements it (verified there against
				// four known-good images).
				if (word_in_data) cksum <= {cksum_add[0], cksum_add[31:1]};
			end

			case (pstate)
			// ★ the eject flush outranks a queued sector: the guest has
			// already stopped writing, and anything still queued was captured
			// before the eject, so it will be drained first by the ordinary
			// path below - flush_req only latches here and fires once P_IDLE
			// is reached with the queue empty.
			P_IDLE: if (flush_pending && !valid[0] && !valid[1] && !loader_busy) begin
				if (dirty) begin
					cksum       <= 32'd0;
					data_size   <= 22'd0;
					scan_blk    <= 13'd0;
					scan_active <= 1'b1;
					sd_lba      <= 32'd0;
					sd_rd       <= 1'b1;
					pstate      <= F_SCAN_RD;
					if (dbg_flushes != 4'hF) dbg_flushes <= dbg_flushes + 4'd1;
				end else begin
					// latched on a queued sector that was then refused (or
					// never landed): nothing of ours is in the file, so the
					// stored checksum is still right. Leave the header alone.
					flush_pending <= 1'b0;
				end
			end else if (valid[head] && !loader_busy) begin
				if (!blk_ok) begin
					// past the end of the file (or its last, partial block):
					// retire without writing anything. The decoder bounds-
					// checks the SECTOR against this track's spt, but nothing
					// upstream checks the resulting block against the mounted
					// file's actual length, and `track` is free to reach 0x4F
					// regardless. This is the last place that can refuse.
					valid[head] <= 1'b0;
					head        <= ~head;
					phase       <= 1'b0;
					if (dbg_refused != 8'hFF) dbg_refused <= dbg_refused + 8'd1;
				end else if (dc42) begin
					// read the block first: its other 84 (or 428) bytes belong
					// to a neighbouring sector and must survive untouched.
					sd_lba <= {19'd0, blk_now};
					sd_rd  <= 1'b1;
					pstate <= P_RD_ACK;
				end else begin
					sd_lba <= {19'd0, blk_now};
					sd_wr  <= 1'b1;
					pstate <= P_WAIT_ACK;
				end
			end

			P_RD_ACK: if (sd_ack) begin
				sd_rd  <= 1'b0;
				pstate <= P_RD_DONE;
			end else if (ackTimeout) begin
				sd_rd  <= 1'b0;
				pstate <= P_IDLE;     // re-present, same reasoning as the write
			end else
				ackTimer <= ackTimer + 1'b1;

			// sd_ack falling means the whole block is in rmw. Turn straight
			// around and write it back, patched by the mux above.
			P_RD_DONE: if (!sd_ack) begin
				sd_wr  <= 1'b1;
				pstate <= P_WAIT_ACK;
			end

			P_WAIT_ACK: if (sd_ack) begin
				sd_wr  <= 1'b0; // mirrors scsi.v: io_wr drops as soon as io_ack rises
				pstate <= P_WAIT_DONE;
			end else if (ackTimeout) begin
				// Drop the request and RE-PRESENT it - deliberately without
				// clearing valid[head], advancing `head`, or changing `phase`.
				// Retiring the entry here is not safe: hps_io captures sd_lba
				// during its own poll command and raises sd_ack in a LATER,
				// separate command, so there is no bound on the gap between
				// the two. If the entry were retired and `head` flipped, a
				// late sd_ack would stream the OTHER buffer out to the LBA the
				// HPS had already captured - a full sector of unrelated data
				// written at a perfectly valid offset in the file. Leaving
				// head/valid/phase/sd_lba alone makes the retry idempotent
				// instead.
				sd_wr  <= 1'b0;
				pstate <= P_IDLE;
			end else
				ackTimer <= ackTimer + 1'b1;

			P_WAIT_DONE: if (!sd_ack) begin
				dirty <= 1'b1;           // something of ours is now in the file
				dbg_landed <= dbg_landed + 8'd1;
				if (dc42 && !phase) begin
					// first of the sector's two blocks is down; go round again
					// for the second. The queue entry stays owned until both
					// have landed.
					phase  <= 1'b1;
					pstate <= P_IDLE;
				end else begin
					valid[head] <= 1'b0;
					head        <= ~head;
					phase       <= 1'b0;
					pstate      <= P_IDLE;
				end
			end

			// ── pass 1: scan the data section, accumulating the checksum ──
			// The scan's reads have no ack timeout. sd_rd is a LEVEL that
			// hps_io polls, and it is held until acked, so there is nothing
			// to re-present (an earlier version had a timeout branch here
			// that only re-asserted an already-high sd_rd: dead code). Main
			// answers a read on an empty or errored slot with a blank block
			// rather than silence, and a remount aborts the whole flush (LC
			// addition 5), so no wedge remains for a timeout to escape.
			F_SCAN_RD: if (sd_ack) begin
				sd_rd  <= 1'b0;
				pstate <= F_SCAN_END;
			end

			F_SCAN_END: if (!sd_ack) begin
				if (scan_blk >= last_blk) begin
					// the whole data section is in the sum; go and rewrite
					// the header.
					scan_active <= 1'b0;
					sd_lba      <= 32'd0;
					sd_rd       <= 1'b1;
					pstate      <= F_HDR_RD;
				end else begin
					scan_blk <= scan_blk + 13'd1;
					sd_lba   <= {19'd0, scan_blk + 13'd1};
					sd_rd    <= 1'b1;
					pstate   <= F_SCAN_RD;
				end
			end

			// ── pass 2: block 0 back out with the two checksum words swapped in
			F_HDR_RD: if (sd_ack) begin   // held level, no timeout: as F_SCAN_RD
				sd_rd  <= 1'b0;
				pstate <= F_HDR_END;
			end

			F_HDR_END: if (!sd_ack) begin
				sd_wr  <= 1'b1;
				pstate <= F_HDR_WR;
			end

			F_HDR_WR: if (sd_ack) begin
				sd_wr  <= 1'b0;
				pstate <= F_HDR_WDONE;
			end else if (ackTimeout) begin
				sd_wr  <= 1'b0;
				pstate <= F_HDR_END;   // re-present; idempotent, same block
			end else
				ackTimer <= ackTimer + 1'b1;

			F_HDR_WDONE: if (!sd_ack) begin
				flush_pending <= 1'b0;
				dirty         <= 1'b0;   // the header now matches the data
				pstate        <= P_IDLE;
			end

			default: pstate <= P_IDLE;
			endcase

			if (pstate != P_WAIT_ACK && pstate != P_RD_ACK && pstate != F_HDR_WR)
				ackTimer <= 0;

			// ★ Remount ABORT (LC addition 5). Placed AFTER the case so that
			// it wins over anything the state machine decided this cycle.
			// Drops the queue (a sector captured against the image that is
			// now gone must never land in the one that replaces it), rewinds
			// `tail` to `head` so the next capture cannot land in a buffer
			// that was draining, forgets the flush (the header it would have
			// rewritten belongs to the old image) and returns the FSM to idle
			// with both request lines low. Safe by Main's serialisation: no
			// request of ours can be mid-transfer at the mount pulse, so the
			// only thing dropped is a request nobody has seen.
			if (img_mounted) begin
				valid         <= 2'b00;
				tail          <= head;
				dirty         <= 1'b0;
				flush_pending <= 1'b0;
				scan_active   <= 1'b0;
				phase         <= 1'b0;
				sd_rd         <= 1'b0;
				sd_wr         <= 1'b0;
				pstate        <= P_IDLE;
			end
		end
	end

endmodule
