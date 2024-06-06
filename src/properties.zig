const codec = @import("codec.zig");

pub const PropertyType = enum(u8) {
	payload_format = 1,
	message_expiry_interval = 2,
	content_type = 3,
	response_topic = 8,
	correlation_data = 9,
	subscription_identifier = 11,
	session_expiry_interval = 17,
	assigned_client_identifier = 18,
	server_keepalive = 19,
	authentication_method = 21,
	authentication_data = 22,
	request_problem_information = 23,
	delay_interval = 24,
	request_response_information = 25,
	response_information = 26,
	server_reference = 28,
	reason = 31,
	receive_maximum = 33,
	topic_alias_maximum = 34,
	topic_alias = 35,
	maximum_qos = 36,
	retain_available = 37,
	user_property = 38,
	maximum_packet_size = 39,
	wildcard_subscription_available = 40,
	subscription_identifier_available = 41,
	shared_subscription_available = 42,
};

pub const Property = union(PropertyType) {
	payload_format: u8,
	message_expiry_interval: u32,
	content_type: []const u8,
	response_topic: []const u8,
	correlation_data: []const u8,
	// We use usize for a varint.
	// Have I mentioned that I hate varints?
	subscription_identifier: usize,
	session_expiry_interval: u32,
	assigned_client_identifier: []const u8,
	server_keepalive: u16,
	authentication_method: []const u8,
	authentication_data: []const u8,
	request_problem_information: u8,
	delay_interval: u32,
	request_response_information: u8,
	response_information: []const u8,
	server_reference: []const u8,
	reason: []const u8,
	receive_maximum: u16,
	topic_alias_maximum: u16,
	topic_alias: u16,
	maximum_qos: u8,
	retain_available: u8,
	user_property: []const u8,
	maximum_packet_size: u32,
	wildcard_subscription_available: u8,
	subscription_identifier_available: u8,
	shared_subscription_available: u8,
};

// Given an struct, like ConnectOpts, extracts the property fields determines,
// what the final length of our serialized properties will be and writes them
// into buf.
// This is done this way to give a cleaner API to users. MQTT makes a distinction
// between properties and other data, but that has more to do with serialization
// efficiency (i.e. properties, being fixed, are identified with a 1 byte identifier).
// There's no reason to make that distinction in our API.
pub const CONNECT = [_]PropertyType{
	.session_expiry_interval,
	.receive_maximum,
	.maximum_packet_size,
};

pub const WILL = [_]PropertyType{
	.delay_interval,
	.payload_format,
	.message_expiry_interval,
	.content_type,
	.response_topic,
	.correlation_data,
};

pub const DISCONNECT = [_]PropertyType{
	.session_expiry_interval,
	.reason,
};

pub const SUBSCRIBE = [_]PropertyType{
	.subscription_identifier,
};

pub fn write(buf: []u8, value: anytype, comptime properties: []const PropertyType) error{WriteBufferIsFull}!usize {
	const properties_len = writeLen(value, properties);
	const length_of_len = codec.lengthOfVarint(properties_len);
	if (properties_len + length_of_len > buf.len) {
		return error.WriteBufferIsFull;
	}

	_ = codec.writeVarint(buf, properties_len);
	var pos: usize = length_of_len;
	inline for (properties) |property| {
		if (@field(value, @tagName(property))) |v| {
			buf[pos] = @intFromEnum(property);

			pos += 1;
			switch (@TypeOf(v)) {
				u16 => {
					const end = pos + 2;
					codec.writeInt(u16, buf[pos..end][0..2], v);
					pos = end;
				},
				u32 => {
					const end = pos + 4;
					codec.writeInt(u32, buf[pos..end][0..4], v);
					pos = end;
				},
				[]const u8 => {
					const len_end = pos + 2;
					codec.writeInt(u16, buf[pos..len_end][0..2], @intCast(v.len));
					const end = len_end + v.len;
					@memcpy(buf[len_end..end], v);
					pos = end;
				},
				else => {
					switch (@typeInfo(@TypeOf(v))) {
						.Enum => {
							buf[pos] = @intFromEnum(v);
							pos += 1;
						},
						else => unreachable,
					}
				},
			}
		}
	}

	return properties_len + length_of_len;
}

fn writeLen(value: anytype, comptime properties: []const PropertyType) usize {
	var l: usize = 0;
	inline for (properties) |property| {
		// all fields are nullable, null properties aren't serialized
		if (@field(value, @tagName(property))) |v| {
			// +1 for the identifier
			l += 1 + switch (@TypeOf(v)) {
				u16 => 2,
				u32 => 4,
				[]const u8 => 2 + v.len, // + 2 for the length prefix
				else => blk: {
					switch (@typeInfo(@TypeOf(v))) {
						.Enum => break :blk 1,
						else => unreachable,
					}
				},
			};
		}
	}
	return l;
}

pub const Reader = struct {
	len: usize,
	buf: []u8,

	const Value = struct {
		type: u8,
		data: []u8,
	};

	pub fn init(buf: []u8) !Reader {
		const properties_len, const length_of_len = try codec.readVarint(buf) orelse return error.ReadProtocolError;
		const total_len = properties_len + length_of_len;

		if (buf.len < total_len) {
			return error.InvalidPropertyList;
		}

		return .{
			.len = total_len,
			.buf = buf[length_of_len..total_len],
		};
	}

	pub fn next(self: *Reader) !?Property {
		const buf = self.buf;
		if (buf.len == 0) {
			return null;
		}

		// Technically, property_type can be a varint, but, in the currenct spec
		// all legal values are < 128 (hence, 1 byte).

		const property_type = buf[0];
		inline for (@typeInfo(Property).Union.fields) |field| {
			if (property_type == @intFromEnum(@field(PropertyType, field.name))) {
				const value, const len = try readValue(field.type, buf[1..]);

				// + 1 for the property type
				self.buf = buf[1 + len..];
				return @unionInit(Property, field.name, value);
			}
		}

		return error.UnknownProperty;
	}
};

fn readValue(comptime T: type, buf: []u8) !struct{T, usize} {
	switch (T) {
		u8 => {
			if (buf.len == 0) {
				return error.InvalidPropertyValue;
			}
			return .{buf[0], 1};
		},
		u16 => {
			if (buf.len < 2) {
				return error.InvalidPropertyValue;
			}
			return .{codec.readInt(u16, buf[0..2]), 2};
		},
		u32 => {
			if (buf.len < 4) {
				return error.InvalidPropertyValue;
			}
			return .{codec.readInt(u32, buf[0..4]), 4};
		},
		[]const u8 => {
			if (buf.len < 2) {
				return error.InvalidPropertyValue;
			}
			const len = codec.readInt(u16, buf[0..2]);

			// + 2 for the length prefix
			const total_len = 2 + len;

			if (buf.len < total_len) {
				return error.InvalidPropertyValue;
			}
			return .{buf[2..total_len], total_len};
		},
		usize => {
			const value, const length_of_len = (try codec.readVarint(buf)) orelse return error.InvalidPropertyValue;
			return .{value, length_of_len};
		},
		else => unreachable,
	}
}

const t  = @import("std").testing;
test "properties: write" {
	var buf: [10]u8 = undefined;
	const PROPERTIES = [_]PropertyType{.maximum_qos};

	const Opts = struct {
		maximum_qos: ?[]const u8 = null
	};

	// fits, just.
	try t.expectEqual(10, try write(&buf, Opts{.maximum_qos = "hello "}, &PROPERTIES));

	// nope
	try t.expectError(error.WriteBufferIsFull, write(&buf, Opts{.maximum_qos = "hello w"}, &PROPERTIES));
}

test "properties: Reader" {
	try t.expectError(error.ReadProtocolError, Reader.init(&.{}));

	{
		var r = try Reader.init(@constCast(&[_]u8{0}));
		try t.expectEqual(1, r.len);
		try t.expectEqual(null, r.next());
		try t.expectEqual(null, r.next());
	}

	{
		try t.expectError(error.InvalidPropertyList, Reader.init(@constCast(&[_]u8{1})));
	}

	{
		// u8 property but missing value
		var r = try Reader.init(@constCast(&[_]u8{1, 13}));
		try t.expectError(error.UnknownProperty, r.next());
	}

	{
		// u8 property but missing value
		var r = try Reader.init(@constCast(&[_]u8{1, 23}));
		try t.expectError(error.InvalidPropertyValue, r.next());
	}

	{
		// u16 property but missing value
		var r = try Reader.init(@constCast(&[_]u8{2, 19, 30}));
		try t.expectError(error.InvalidPropertyValue, r.next());
	}

	{
		// u32 property but missing value
		var r = try Reader.init(@constCast(&[_]u8{3, 2, 30, 255}));
		try t.expectError(error.InvalidPropertyValue, r.next());
	}

	{
		// usize (varint) property but invalid varint
		var r = try Reader.init(@constCast(&[_]u8{5, 11, 0x80, 0x80, 0x80, 0x80}));
		try t.expectError(error.InvalidVarint, r.next());
	}

	{
		var r = try Reader.init(@constCast(&[_]u8{
			19,                           // length, not including self
			23, 75,                       // request problem info (u8),
			19, 0x30, 0x65,               // server keepalive (u16),
			2, 0x77, 0x35, 0x94, 0x01,    // message_expiry_interval (u32),
			11, 0x81, 0x0a,               // subscription_identifier (varint (usize)),
			9, 0, 3, 't', 'e', 'g'        // correlation_data ([]const u8)
		}));
		try t.expectEqual(20, r.len);
		try t.expectEqual(75, (try r.next()).?.request_problem_information);
		try t.expectEqual(12389, (try r.next()).?.server_keepalive);
		try t.expectEqual(2000000001, (try r.next()).?.message_expiry_interval);
		try t.expectEqual(1281, (try r.next()).?.subscription_identifier);
		try t.expectEqualSlices(u8, "teg", (try r.next()).?.correlation_data);
		try t.expectEqual(null, r.next());
	}
}
