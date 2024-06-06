const mqtt = @import("mqtt.zig");
const codec = @import("codec.zig");
const PropertyReader = @import("properties.zig").Reader;

pub const Packet = union(enum) {
	connack: ConnAck,
	suback: SubAck,
};

pub fn parse(b1: u8, data: []u8) !Packet {
	// data.len has to be > 0
	// TODO: how to assert without std?
	const flags = b1 & 15;
	switch (b1 >> 4) {
		2 => return .{.connack = try ConnAck.parse(data, flags)},
		9 => return .{.suback = try SubAck.parse(data, flags)},
		else => return error.UnknownPacketType, // TODO
	}
}

pub const ConnAck = struct {
	session_present: bool,
	reason_code: u8,
	session_expiry_interval: ?u32 = null,
	receive_maximum: ?u16 = null,
	maximum_qos: ?u8 = null,
	retain_available: ?u8 = null,
	maximum_packet_size: ?u32 = null,
	assigned_client_identifier: ?[]const u8 = null,
	topic_alias_maximum: ?u16 = null,
	reason: ?[]const u8 = null,
	wildcard_subscription_available: ?u8 = null,
	subscription_identifier_available: ?u8 = null,
	shared_subscription_available: ?u8 = null,
	server_keepalive: ?u16 = null,
	response_information: ?[]const u8 = null,
	server_reference: ?[]const u8 = null,
	authentication_method: ?[]const u8 = null,
	authentication_data: ?[]const u8 = null,

	pub fn parse(data: []u8, flags: u8) !ConnAck {
		if (flags != 0) {
			return error.InvalidFlags;
		}

		if (data.len < 3) {
			// must have at least 3 bytes
			// (ConnAct flag, Reason Code, Property Length)
			return error.IncompletePacket;
		}

		const session_present = switch (data[0]) {
			0 => false,
			1 => true,
			else => return error.MalformedPacket,
		};

		var connack = ConnAck{
			.session_present = session_present,
			.reason_code = data[1],
		};

		var properties = try PropertyReader.init(data[2..]);
		while (try properties.next()) |prop| {
			switch (prop) {
				.session_expiry_interval => |v| connack.session_expiry_interval = v,
				.receive_maximum => |v| connack.receive_maximum = v,
				.maximum_qos => |v| connack.maximum_qos = v,
				.retain_available => |v| connack.retain_available = v,
				.maximum_packet_size => |v| connack.maximum_packet_size = v,
				.assigned_client_identifier => |v| connack.assigned_client_identifier = v,
				.topic_alias_maximum => |v| connack.topic_alias_maximum = v,
				.reason => |v| connack.reason = v,
				.wildcard_subscription_available => |v| connack.wildcard_subscription_available = v,
				.subscription_identifier_available => |v| connack.subscription_identifier_available = v,
				.shared_subscription_available => |v| connack.shared_subscription_available = v,
				.server_keepalive => |v| connack.server_keepalive = v,
				.response_information => |v| connack.response_information = v,
				.server_reference => |v| connack.server_reference = v,
				.authentication_method => |v| connack.authentication_method = v,
				.authentication_data => |v| connack.authentication_data = v,
				.user_property => {}, // TODO: handle
				else => return error.InvalidProperty,
			}
		}

		return connack;
	}
};

pub const SubAck = struct {
	packet_identifier: u16,
	reason: ?[]const u8 = null,
	results: []const u8,

	pub fn parse(data: []u8, flags: u8) !SubAck {
		if (flags != 0) {
			return error.InvalidFlags;
		}

		if (data.len < 4) {
			// must have at least 4 bytes
			// 2 for the packet identifier
			// at least 1 for a 0-length property list
			// at least 1 for 1 reason code in the body
			return error.IncompletePacket;
		}

		var suback = SubAck{
			.packet_identifier = codec.readInt(u16, data[0..2]),
			.results = undefined,
		};

		var properties = try PropertyReader.init(data[2..]);
		while (try properties.next()) |prop| {
			switch (prop) {
				.reason => |v| suback.reason = v,
				.user_property => {}, // TODO: handle
				else => return error.InvalidProperty,
			}
		}

		// the rest of the packet is the payload, and the payload is 1 or more
		// 1 byte reason codes. 1 reason code per subscribed topic (in the same order)
		// So if you subscribed to 2 topics and want to know the result of the 2nd one
		// you would check suback.results[1].
		suback.results = data[2 + properties.len..];
		return suback;
	}

	const Status = union(enum) {
		granted: mqtt.QoS,
		err: Error,
		invalid_index: void,

		const Error = enum {
			unspecified_error,
			implementation_specific_error,
			not_authorized,
			topic_filter_invalid,
			packet_identifier_in_use,
			quota_exceeded,
			shared_subscriptions_not_supported,
			subscription_identifier_not_supported,
			wildcard_subscriptions_not_supported,
			unknown,
		};
	};

	pub fn result(self: *const SubAck, topic_index: usize) Status {
		const results = self.results;

		if (topic_index > results.len) {
			return .{.invalid_index = {}};
		}

		switch (results[topic_index]) {
			0 => return .{.granted = .at_most_once},
			1 => return .{.granted = .at_least_once},
			2 => return .{.granted = .exactly_once},
			128 => return .{.err = .unspecified_error},
			131 => return .{.err = .implementation_specific_error},
			135 => return .{.err = .not_authorized},
			143 => return .{.err = .topic_filter_invalid},
			145 => return .{.err = .packet_identifier_in_use},
			151 => return .{.err = .quota_exceeded},
			158 => return .{.err = .shared_subscriptions_not_supported},
			161 => return .{.err = .subscription_identifier_not_supported},
			162 => return .{.err = .wildcard_subscriptions_not_supported},
			else => return .{.err = .unknown},
		}
	}
};
