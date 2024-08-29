const mqtt = @import("mqtt.zig");
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
	reason_string = 31,
	receive_maximum = 33,
	topic_alias_maximum = 34,
	topic_alias = 35,
	maximum_qos = 36,
	retain_available = 37,
	user_properties = 38,
	maximum_packet_size = 39,
	wildcard_subscription_available = 40,
	subscription_identifier_available = 41,
	shared_subscription_available = 42,
};

pub const Property = union(PropertyType) {
	payload_format: mqtt.PayloadFormat,
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
	request_problem_information: bool,
	delay_interval: u32,
	request_response_information: u8,
	response_information: []const u8,
	server_reference: []const u8,
	reason_string: []const u8,
	receive_maximum: u16,
	topic_alias_maximum: u16,
	topic_alias: u16,
	maximum_qos: mqtt.QoS,
	retain_available: bool,
	user_properties: []const u8,
	maximum_packet_size: u32,
	wildcard_subscription_available: bool,
	subscription_identifier_available: bool,
	shared_subscription_available: bool,
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
	.user_properties,
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
	.reason_string,
	.user_properties,
};

pub const SUBSCRIBE = [_]PropertyType{
	.subscription_identifier,
	.user_properties,
};

pub const PUBLISH = [_]PropertyType{
	.payload_format,
	.message_expiry_interval,
	.topic_alias,
	.response_topic,
	.correlation_data,
	.subscription_identifier,
	.content_type,
	.user_properties,
};

pub const PUBACK = [_]PropertyType{
	.reason_string,
	.user_properties,
};
pub const PUBREC = PUBACK;
pub const PUBREL = PUBACK;
pub const PUBCOMP = PUBACK;

// it only accepts user data, which we don't support (yet)
pub const UNSUBSCRIBE = [_]PropertyType{};

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
			switch (@TypeOf(v)) {
				u16 => {
					buf[pos] = @intFromEnum(property);
					pos += 1;
					const end = pos + 2;
					codec.writeInt(u16, buf[pos..end][0..2], v);
					pos = end;
				},
				u32 => {
					buf[pos] = @intFromEnum(property);
					pos += 1;
					const end = pos + 4;
					codec.writeInt(u32, buf[pos..end][0..4], v);
					pos = end;
				},
				[]const u8 => {
					buf[pos] = @intFromEnum(property);
					pos += 1;
					pos += try codec.writeString(buf[pos..], v);
				},
				[]const mqtt.UserProperty => for (v) |up| {
					buf[pos] = @intFromEnum(property);
					pos += 1;
					pos += try codec.writeString(buf[pos..], up.key);
					pos += try codec.writeString(buf[pos..], up.value);
				},
				else => {
					switch (@typeInfo(@TypeOf(v))) {
						.@"enum" => {
							buf[pos] = @intFromEnum(property);
							buf[pos + 1] = @intFromEnum(v);
							pos += 2;
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
			// these all have a +1 for the extra property type
			// except user.UserProperty which has a +1 for each value
			switch (@TypeOf(v)) {
				u16 => l += 3,
				u32 => l += 5,
				[]const u8 => l += 3 + v.len, // + 2 for the length prefix
				[]const mqtt.UserProperty => for (v) |up| {
					// + 4 for the two length prefixes
					// + 1 for the property type
					l += up.key.len + up.value.len + 5;
				},
				else => {
					switch (@typeInfo(@TypeOf(v))) {
						.@"enum" => l += 2,
						else => unreachable,
					}
				},
			}
		}
	}
	return l;
}

pub const Reader = struct {
	len: usize,
	buf: []const u8,

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
		if (property_type == 38) {
			// special handling for user_properties
			// See Iterator documentation

			if (buf.len < 5) {
				// 2 for the key length
				// 2 fo the value length
				// 1 for the property_type (which we already know is there)
				return error.InvalidPropertyValue;
			}

			const key_len = codec.readInt(u16, buf[1..3]);
			// 1 for the propety_type
			// 2 for key length (like the 2 bytes of the length itself)
			const val_len_offset = 3 + key_len;
			const val_len_end = val_len_offset + 2;
			if (buf.len < val_len_end) {
				return error.InvalidPropertyValue;
			}
			const val_len = codec.readInt(u16, buf[val_len_offset..val_len_end][0..2]);

			const property_end = val_len_end + val_len;
			self.buf = buf[property_end..];
			return .{.user_properties = buf};
		} else {
			inline for (@typeInfo(Property).@"union".fields) |field| {
				if (property_type == @intFromEnum(@field(PropertyType, field.name))) {
					const value, const len = try readValue(field.type, buf[1..]);

					// + 1 for the property type
					self.buf = buf[1 + len..];
					return @unionInit(Property, field.name, value);
				}
			}
		}
		return error.UnknownProperty;
	}
};

fn readValue(comptime T: type, buf: []const u8) !struct{T, usize} {
	switch (T) {
		bool => {
			if (buf.len == 0 or buf[0] > 1) {
				return error.InvalidPropertyValue;
			}
			return .{buf[0] == 1 , 1};
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
		[]const u8 => return codec.readString(buf) catch return error.InvalidPropertyValue,
		usize => {
			const value, const length_of_len = (try codec.readVarint(buf)) orelse return error.InvalidPropertyValue;
			return .{value, length_of_len};
		},
		mqtt.PayloadFormat => {
			if (buf.len == 0 or buf[0] > 1) {
				return error.InvalidPropertyValue;
			}
			return .{if (buf[0] == 0) .unspecified else .utf8 , 1};
		},
		mqtt.QoS => {
			if (buf.len == 0) {
				return error.InvalidPropertyValue;
			}
			switch (buf[0]) {
				0 => return .{.at_most_once, 1},
				1 => return .{.at_least_once, 1},
				2 => return .{.exactly_once, 1},
				else => return error.InvalidPropertyValue,
			}
		},
		else => unreachable,
	}
}

// I need to write this down, 'cuz if I come back to this in a month (or even
// tomorrow), I'll be confused.
// The User Property property is special because it can appear more than once
// AND, as far as I can tell, they don't need to be grouped together
// The easy way to handle it would be to ignore it.
// The next easiest way to handle it would be to allocate an array to hold
// the values as we iterate through it in Reader.next(). But we don't want to
// allocate, especially for something most people won't care about.
// Instead, this iterator is like Reader (it wraps reader in fact) but where
// reader treats User Properties as a blob that largely gets skipped over, this
// skips over every other field and only handles User Properties.
// As an optimization, the first User Property we see when doing Reader.next
// because, from the point of view of this iterator, the beginning of our
// property list.

// For example, imagine we have this property list:
//
// 31, 0, 2, 'n', 'o',             <- reason string: "no"
// 38, 0, 1, 'a', 0, 1, 'b',       <- user property a=1
// 1, 1,                           <- property format: 1
// 38, 0, 2, 'a', 'b' 0, 1, 'z'    <- user property ab=z
//
// When iterating through Reader.next(), on the first user property, we'll
// store a slice of our buffer starting from that property, so it'll look like:
//
// 38, 0, 1, 'a', 0, 1, 'b',       <- user property a=1
// 1, 1,                           <- property format: 1
// 38, 0, 2, 'a', 'b' 0, 1, 'z'    <- user property ab=z
//
// Now when we iterate through this slice, using the same Reader, we at least
// don't have to process any of the properties that can before our first user
// property.
// skipped every

pub const UserPropertyIterator = struct {
	reader: Reader,

	pub fn init(buf: []const u8) UserPropertyIterator {
		return .{
			.reader = .{.buf = buf, .len = buf.len},
		};
	}

	pub fn next(self: *UserPropertyIterator) ?mqtt.UserProperty {
		while (true) {
			const property = (self.reader.next() catch return null) orelse return null;
			if (property != .user_properties) {
				continue;
			}
			const raw = property.user_properties;
			if (raw.len < 1) {
				// weird.
				return null;
			}
			const key, const key_len = codec.readString(raw[1..]) catch return null;
			const value, _ = codec.readString(raw[key_len+1..]) catch return null;
			return .{
				.key = key,
				.value = value,
			};
		}
	}
};

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
			23, 1,                       // request problem info (u8),
			19, 0x30, 0x65,               // server keepalive (u16),
			2, 0x77, 0x35, 0x94, 0x01,    // message_expiry_interval (u32),
			11, 0x81, 0x0a,               // subscription_identifier (varint (usize)),
			9, 0, 3, 't', 'e', 'g'        // correlation_data ([]const u8)
		}));
		try t.expectEqual(20, r.len);
		try t.expectEqual(true, (try r.next()).?.request_problem_information);
		try t.expectEqual(12389, (try r.next()).?.server_keepalive);
		try t.expectEqual(2000000001, (try r.next()).?.message_expiry_interval);
		try t.expectEqual(1281, (try r.next()).?.subscription_identifier);
		try t.expectEqualSlices(u8, "teg", (try r.next()).?.correlation_data);
		try t.expectEqual(null, r.next());
	}
}
