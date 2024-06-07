const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

// I hate varints.
pub fn writeVarint(buf: []u8, len: usize) usize {
	var i: usize = 0;
	var remaining_len = len;
	while (true) : (i += 1) {
		const b: u8 = @intCast(remaining_len & 0x7F);
		if (remaining_len <= 127) {
			buf[i] = b;
			return i+1;
		}
		buf[i] = b | 0x80;
		remaining_len = remaining_len >> 7;
	}
}

// This returns the varint value (if we have one) AND the length of the varint
pub fn readVarint(buf: []const u8) error{InvalidVarint}!?struct{usize, usize} {
	if (buf.len == 0) {
		return null;
	}

	if (buf[0] < 128) {
		return .{@as(usize, @intCast(buf[0])), 1};
	}

	if (buf.len == 1) {
		return null;
	}

	var total: usize = buf[0] & 0x7f;
	if (buf[1] < 128) {
		return .{total + @as(usize, buf[1]) * 128, 2};
	}

	if (buf.len == 2) {
		return null;
	}
	total += (@as(usize, buf[1]) & 0x7f) * 128;
	if (buf[2] < 128) {
		return .{total + @as(usize, buf[2]) * 16_384, 3};
	}

	if (buf.len == 3) {
		return null;
	}
	total += (@as(usize, buf[2]) & 0x7f) * 16_384;
	if (buf[3] < 128) {
		return .{total + @as(usize, buf[3]) * 2_097_152, 4};
	}

	return error.InvalidVarint;
}

// See writeVarint comment
pub fn lengthOfVarint(len: usize) usize {
	return switch (len) {
		0...127 => 1,
		128...16_383 => 2,
		16_384...2_097_151 => 3,
		2_097_152...268_435_455 => 4,
		else => unreachable,
	};
}

pub inline fn writeInt(comptime T: type, buf: *[@divExact(@typeInfo(T).Int.bits, 8)]u8, value: T) void {
	buf.* = @bitCast(if (native_endian == .big) value else @byteSwap(value));
}

pub inline fn readInt(comptime T: type, buf: *[@divExact(@typeInfo(T).Int.bits, 8)]u8) T {
	const value: T = @bitCast(buf.*);
	return if (native_endian == .big) value else @byteSwap(value);
}

pub fn writeString(buf: []u8, value: []const u8) error{WriteBufferIsFull}!usize {
	const total = value.len + 2;
	if (buf.len < total) {
		return error.WriteBufferIsFull;
	}

	writeInt(u16, buf[0..2], @intCast(value.len));
	@memcpy(buf[2..total], value);
	return total;
}

const t = @import("std").testing;
test "codec: writeVarint" {
	var buf: [4]u8 = undefined;
	try t.expectEqualSlices(u8, &[_]u8{0}, buf[0..writeVarint(&buf, 0)]);
	try t.expectEqualSlices(u8, &[_]u8{1}, buf[0..writeVarint(&buf, 1)]);
	try t.expectEqualSlices(u8, &[_]u8{20}, buf[0..writeVarint(&buf, 20)]);
	try t.expectEqualSlices(u8, &[_]u8{0x7f}, buf[0..writeVarint(&buf, 127)]);
	try t.expectEqualSlices(u8, &[_]u8{0x80, 0x01}, buf[0..writeVarint(&buf, 128)]);
	try t.expectEqualSlices(u8, &[_]u8{0xff, 0x7f}, buf[0..writeVarint(&buf, 16383)]);
	try t.expectEqualSlices(u8, &[_]u8{0x80, 0x80, 0x01}, buf[0..writeVarint(&buf, 16384)]);
	try t.expectEqualSlices(u8, &[_]u8{0xff, 0xff, 0x7f}, buf[0..writeVarint(&buf, 2097151)]);
	try t.expectEqualSlices(u8, &[_]u8{0x80, 0x80, 0x80, 0x01}, buf[0..writeVarint(&buf, 2097152)]);
	try t.expectEqualSlices(u8, &[_]u8{0xff, 0xff, 0xff, 0x7f}, buf[0..writeVarint(&buf, 268435455)]);
}

test "codec: readVarint" {
	// have I mentioned I hate varings?
	try t.expectEqual(.{0, 1}, readVarint(&[_]u8{0}));
	try t.expectEqual(.{1, 1}, readVarint(&[_]u8{1}));
	try t.expectEqual(.{20, 1}, readVarint(&[_]u8{20}));
	try t.expectEqual(.{127, 1}, readVarint(&[_]u8{0x7f}));
	try t.expectEqual(.{128, 2}, readVarint(&[_]u8{0x80, 0x01}));
	try t.expectEqual(.{16383, 2}, readVarint(&[_]u8{0xff, 0x7f}));
	try t.expectEqual(.{16384, 3}, readVarint(&[_]u8{0x80, 0x80, 0x01}));
	try t.expectEqual(.{2097151, 3}, readVarint(&[_]u8{0xff, 0xff, 0x7f}));
	try t.expectEqual(.{2097152, 4}, readVarint(&[_]u8{0x80, 0x80, 0x80, 0x01}));
	try t.expectEqual(.{268435455, 4}, readVarint(&[_]u8{0xff, 0xff, 0xff, 0x7f}));

	// same as above, but with extra data (which readVarint ignores)
	try t.expectEqual(.{0, 1}, readVarint(&[_]u8{0, 0, 9}));
	try t.expectEqual(.{1, 1}, readVarint(&[_]u8{1, 0, 9}));
	try t.expectEqual(.{20, 1}, readVarint(&[_]u8{20, 0, 9}));
	try t.expectEqual(.{127, 1}, readVarint(&[_]u8{0x7f, 10, 9}));
	try t.expectEqual(.{128, 2}, readVarint(&[_]u8{0x80, 0x01, 200, 9}));
	try t.expectEqual(.{16383, 2}, readVarint(&[_]u8{0xff, 0x7f, 0, 9}));
	try t.expectEqual(.{16384, 3}, readVarint(&[_]u8{0x80, 0x80, 0x01, 128, 9}));
	try t.expectEqual(.{2097151, 3}, readVarint(&[_]u8{0xff, 0xff, 0x7f, 129, 9}));
	try t.expectEqual(.{2097152, 4}, readVarint(&[_]u8{0x80, 0x80, 0x80, 0x01, 0, 9}));
	try t.expectEqual(.{268435455, 4}, readVarint(&[_]u8{0xff, 0xff, 0xff, 0x7f, 0, 9}));

	// incomplete
	try t.expectEqual(null, readVarint(&[_]u8{}));
	try t.expectEqual(null, readVarint(&[_]u8{128}));
	try t.expectEqual(null, readVarint(&[_]u8{128, 128}));
	try t.expectEqual(null, readVarint(&[_]u8{128, 128, 128}));
	try t.expectError(error.InvalidVarint, readVarint(&[_]u8{128, 128, 128, 128}));
}

test "codec: lengthOfVarint"  {
	try t.expectEqual(1, lengthOfVarint(0));
	try t.expectEqual(1, lengthOfVarint(127));
	try t.expectEqual(2, lengthOfVarint(128));
	try t.expectEqual(2, lengthOfVarint(16383));
	try t.expectEqual(3, lengthOfVarint(16384));
	try t.expectEqual(3, lengthOfVarint(2097151));
	try t.expectEqual(4, lengthOfVarint(2097152));
	try t.expectEqual(4, lengthOfVarint(268435455));
}

test "codec: writeString" {
	var buf: [400]u8 = undefined;
	try t.expectError(error.WriteBufferIsFull, writeString(buf[0..0], ""));
	try t.expectError(error.WriteBufferIsFull, writeString(buf[0..1], ""));

	{
		const n = try writeString(buf[0..2], "");
		try t.expectEqualSlices(u8, &.{0, 0}, buf[0..n]);
	}

	{
		const n = try writeString(&buf, "over 9000!");
		try t.expectEqualSlices(u8, &.{0, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!'}, buf[0..n]);
	}

	{
		const n = try writeString(&buf, "a" ** 300);
		try t.expectEqualSlices(u8, [_]u8{1, 44} ++ "a" ** 300, buf[0..n]);
	}
}
