const codec = @import("codec.zig");
const properties = @import("properties.zig");
const PropertyReader = properties.Reader;

const MIN_BUF_SIZE = 256;

pub const QoS = enum(u2) {
	at_most_once = 0,
	at_least_once = 1,
	exactly_once = 2,
};

pub const RetainHandling = enum(u2) {
	send_retained_on_subscribe = 0,
	send_retained_on_new_subscribe = 1,
	do_not_send_retained = 2,
};

pub const PayloadFormat = enum(u1) {
	unspecified = 0,
	utf8 = 1,
};

// MQTT has ~128 error reasons, here they are.
pub const ErrorReasonCode = enum {
	unknown,
	unspecified_error,
	malformed_packet,
	protocol_error,
	implementation_specific_error,
	unsupported_protocol_version,
	client_identifier_not_valid,
	bad_user_name_or_password,
	not_authorized,
	server_unavailable,
	server_busy,
	banned,
	server_shutting_down,
	bad_authentication_method,
	keep_alive_timeout,
	session_taken_over,
	topic_filter_invalid,
	topic_name_invalid,
	packet_identifier_in_use,
	packet_identifier_not_found,
	receive_maximum_exceeded,
	topic_alias_invalid,
	packet_too_large,
	message_rate_too_high,
	quota_exceeded,
	administrative_action,
	payload_format_invalid,
	retain_not_supported,
	qo_s_not_supported,
	use_another_server,
	server_moved,
	shared_subscriptions_not_supported,
	connection_rate_exceeded,
	maximum_connect_time,
	subscription_identifiers_not_supported,
	wildcard_subscriptions_not_supported,
};

// When disconnecting, we give the server one of these reasons.
pub const DisconnectReason = enum(u8) {
	normal = 0,
	disconnect_with_will_message = 4,
	unspecified_error = 128,
	malformed_packet = 129,
	protocol_error = 130,
	implementation_specific_error = 131,
	topic_name_invalid = 144,
	receive_maximum_exceeded = 147,
	topic_alias_invalid = 148,
	packet_too_large = 149,
	message_rate_too_high = 150,
	quota_exceeded = 151,
	administrative_action = 152,
	payload_format_invalid = 153,
};

pub const PubAckReason = enum(u8) {
	success = 0,
	no_matching_subscribers = 16,
	unspecified_error = 128,
	implementation_specific_error = 131,
	not_authorized = 135,
	topic_name_invalid = 144,
	quota_exceeded = 151,
	payload_format_invalid = 153,
};

pub const ConnectOpts = struct {
	client_id: ?[]const u8 = null,
	username: ?[]const u8 = null,
	password: ?[]const u8 = null,
	will: ?Will = null,
	keepalive_sec: u16 = 0,
	session_expiry_interval: ?u32 = null,
	receive_maximum: ?u16 = null,
	maximum_packet_size: ?u32 = null,

	pub const Will = struct {
		topic: []const u8,
		message: []const u8,
		qos: QoS,
		retain: bool,
		delay_interval: ?u32 = null,
		payload_format: ?PayloadFormat = null,
		message_expiry_interval: ?u32 = null,
		content_type: ?[]const u8 = null,
		response_topic: ?[]const u8 = null,
		correlation_data: ?[]const u8 = null,
	};
};

pub const DisconnectOpts = struct {
	reason: DisconnectReason,
	session_expiry_interval: ?u32 = null,
	reason_string: ?[]const u8 = null,
};

pub const SubscribeOpts = struct {
	packet_identifier: ?u16 = null,
	subscription_identifier: ?usize = null,
	topics: []const Topic,

	pub const Topic = struct {
		filter: []const u8,
		qos: QoS = .at_most_once,
		no_local: bool = true,
		retain_as_published: bool = false,
		retain_handling: RetainHandling = .do_not_send_retained,
	};
};

pub const PublishOpts = struct {
	message: []const u8,
	topic: []const u8,
	dup: bool = false,
	qos: QoS = .at_most_once,
	retain: bool = false,
	packet_identifier: ?u16 = null,
	payload_format: ?PayloadFormat = null,
	message_expiry_interval: ?u32 = null,
	topic_alias: ?u16 = null,
	response_topic: ?[]const u8 = null,
	correlation_data: ?[]const u8 = null,
	subscription_identifier:? usize = null,
	content_type: ?[]const u8 = null,
};

pub const PubAckOpts = struct {
	packet_identifier: u16,
	reason_code: PubAckReason = .success,
	reason_string: ?[]const u8 = null,
};

// This is my attempt at dealing with Zig's lack of error payload. I'm trying to
// balance returning relatively specific errors while making it easy for users
// to handle errors (which I think is something users will want to do in some cases).
// Those two goals aren't aligned - the more specific errors we have, the more
// cumbersome is it to write error handling. So our public methods will return
// higher level errors, things like "Write" or "MalformedPacket" and, when
// applicable, set last_error to some more detailed error.
pub const ErrorDetail = union(enum) {
	inner: anyerror,
	details: []const u8,
	reason: ErrorReasonCode,
};

pub fn Mqtt(comptime S: type) type {
	// Normally, you'd expect Mqtt to be created with a struct, like Mqtt(Client).
	// Especially since all we do with S is call functions on it (we never store
	// an S).
	// But there are reasons why you might want to use a pointer, like Mqtt(*Client)
	// such as in our test, where you want to S to compose a client:
	//    const Client = struct {
	//      mqtt: Mqtt(Client),
	//    }
	// But that won't compile (depending on what version of Zig, it'll just crash
	// the compiler). But Mqtt(*Client) _will_ work.
	const Impl = switch (@typeInfo(S)) {
		.Struct => S,
		.Pointer => |ptr| ptr.child,
		else => @compileError("S must be a struct or pointer to struct"),
	};

	return struct {
		// buffer used for reading messages from the server. If a single message
		// is larger than this, methods will return a error.ReadBufferIsFull
		read_buf: []u8,

		// when we read a message, we can over-read (reading part/all of the next message)
		// so we need to keep track of where in read_buf our next message starts
		// and how much valid data we have in it.
		read_pos: usize,
		read_len: usize,

		// buffer used when writing messages to the server. When trying to write a
		// message larger than this, methods will return an error.WriteBufferIsFull
		write_buf: []u8,

		disconnected: bool,

		last_error: ?ErrorDetail,

		// Many packets take an identifier, we increment this by one on each call
		packet_identifier: u16,

		// Default to true, but might be set to false as a property to connack.
		// If it does get set to false, we'll error on any publish where retain = true
		server_can_retain: bool,

		const Self = @This();

		pub fn init(read_buf: []u8, write_buf: []u8) !Self {
			if (read_buf.len < MIN_BUF_SIZE) {
				return error.ReadBufferTooSmall;
			}

			if (write_buf.len < MIN_BUF_SIZE) {
				return error.WriteBufferTooSmall;
			}

			return .{
				.read_pos = 0,
				.read_len = 0,
				.read_buf = read_buf,
				.write_buf = write_buf,
				.last_error = null,
				.packet_identifier = 1,
				.disconnected = false, // we assume
				.server_can_retain = true,  // we'll set this to false if connack says so
			};
		}

		// Intended to be used for debugging
		pub fn lastReadPacket(self: *Self) []const u8 {
			return self.read_buf[0..self.read_pos];
		}

		pub fn connect(self: *Self, state: anytype, opts: ConnectOpts) error{Encoding, Write}!void {
			const connect_packet = encodeConnect(self.write_buf, opts) catch |err| {
				self.last_error = .{.inner = err};
				return error.Encoding;
			};
			try self.writePacket(state, connect_packet);
		}

		pub fn subscribe(self: *Self, state: anytype, opts: SubscribeOpts) error{Usage, Encoding, Write}!usize {
			if (opts.topics.len == 0) {
				self.last_error = .{.details = "must have at least 1 topic"};
				return error.Usage;
			}

			const packet_identifier = self.packetIdentifier(opts.packet_identifier);
			const subscribe_packet = encodeSubscribe(self.write_buf, packet_identifier, opts) catch |err| {
				self.last_error = .{.inner = err};
				return error.Encoding;
			};
			try self.writePacket(state, subscribe_packet);
			return packet_identifier;
		}

		pub fn publish(self: *Self, state: anytype, opts: PublishOpts) error{Usage, Encoding, Write}!usize {
			if (opts.retain == true and self.server_can_retain == false) {
				self.last_error = .{.details = "server does not support retained messages"};
				return error.Usage;
			}
			const packet_identifier = self.packetIdentifier(opts.packet_identifier);
			const publish_packet = encodePublish(self.write_buf, packet_identifier, opts) catch |err| {
				self.last_error = .{.inner = err};
				return error.Encoding;
			};
			try self.writePacket(state, publish_packet);
			return packet_identifier;
		}

		pub fn puback(self: *Self, state: anytype, opts: PubAckOpts) error{Encoding, Write}!void {
			const puback_packet = encodePubAck(self.write_buf, opts) catch |err| {
				self.last_error = .{.inner = err};
				return error.Encoding;
			};
			try self.writePacket(state, puback_packet);
		}

		pub fn disconnect(self: *Self, state: anytype, opts: DisconnectOpts) error{Encoding, Write}!void {
			if (self.disconnected == true) {
				return;
			}

			self.disconnected = true;
			defer Impl.close(state);

			const disconnect_packet = encodeDisconnect(self.write_buf, opts) catch |err| {
				self.last_error = .{.inner = err};
				return error.Encoding;
			};
			return self.writePacket(state, disconnect_packet);
		}

		fn packetIdentifier(self: *Self, explicit: ?u16) u16 {
			if (explicit) |pi| {
				return pi;
			}
			const pi = self.packet_identifier + 1;
			self.packet_identifier = pi;
			return pi;
		}

		fn writePacket(self: *Self, state: anytype, data: []const u8) error{Write}!void {
			return Impl.write(state, data) catch |err| {
				self.last_error = .{.inner = err};
				return error.Write;
			};
		}

		const ReadError = error {
			Read,
			Closed,
			ReadBufferIsFull,
			Server,
			Protocol,
			MalformedPacket,
			Response,
		};
		pub fn readPacket(self: *Self, state: anytype) ReadError!Packet {
			const p = try self.readOrBuffered(state);
			switch (p) {
				.connack => |*connack| try self.processConnack(state, connack),
				else => {}
			}
			return p;
		}

		fn readOrBuffered(self: *Self, state: anytype) !Packet {
			if (try self.bufferedPacket()) |p| {
				return p;
			}

			var buf = self.read_buf;
			var pos = self.read_len;

			if (pos > 0 and pos == self.read_pos) {
				// optimize, our last readPacket read exactly 1 packet
				// we can reset all our indexes to 0 so that we have the full buffer
				// available
				pos = 0;
				self.read_pos = 0;
				self.read_len = 0;
			}

			var calls: usize = 1;
			while (true) {
				if (pos == buf.len) {
					const read_pos = self.read_pos;
					// we have no more space in our buffer ...
					if (read_pos == 0) {
						// ... and we started reading this packet from the start of our
						// buffer, so we really have no more space
						return error.ReadBufferIsFull;
					}

					// ... and we didn't start reading this message from the start of our
					// buffer, so if we move things around, we'll have new free space.

					// std.mem.copyForward. can't use @memcpy because these potentially overlap
					pos = self.read_len - read_pos;
					for (buf[0..pos], buf[read_pos..]) |*d, s| {
						d.* = s;
					}
					self.read_pos = 0;
					self.read_len = pos;
				}

				const n = Impl.read(state, buf[pos..], calls) catch |err| {
					self.last_error = .{.inner = err};
					return error.Read;
				};

				if (n == 0) {
					return error.Closed;
				}

				pos += n;
				self.read_len += n;

				// bufferedPacket() will set read_pos
				if (try self.bufferedPacket()) |p| {
					return p;
				}

				calls += 1;
			}
		}

		// see if we have a full packet in our read_buf already
		fn bufferedPacket(self: *Self) !?Packet {
			const buf = self.read_buf[self.read_pos..self.read_len];

			// always has to be at least 2 bytes
			//  1 for the packet type and at least 1 for the length.
			if (buf.len < 2) {
				return null;
			}

			const remaining_len, const length_of_len = codec.readVarint(buf[1..]) catch |err| switch (err) {
				error.InvalidVarint => {
					self.last_error = .{.inner = err};
					return error.MalformedPacket;
				},
			} orelse return null;

			// +1 for the packet type
			const fixed_header_len = 1 + length_of_len;

			const total_len = fixed_header_len + remaining_len;
			if (buf.len < total_len) {
				// don't have a full packet yet
				return null;
			}

			self.read_pos += total_len;
			return decodePacket(buf[0], buf[fixed_header_len..total_len]) catch |err| {
				self.last_error = .{.inner = err};
				switch (err) {
					error.UnknownPacketType => return error.Protocol,
					else => return error.MalformedPacket,
				}
			};
		}

		fn processConnack(self: *Self, state: anytype, connack: *const Packet.ConnAck) !void {
			switch (connack.reason_code) {
				0 => {}, // success
				1...127 => return self.receivedInvalidReason(state),        // returns an error.Protocol
				128...255 => |n| return self.receivedErrorReason(state, n), // returns an error.Response
			}

			if (connack.session_present) {
				// TODO: since we force clean_start = true, this should always be false
				// but if we support clean_start = false, than this would only be an
				// error if it otps.clean_start == true.

				// MQTT-3.2.2-4
				self.disconnect(state, .{.reason = .protocol_error}) catch {};
				self.last_error = .{.details = "connack indicated the presence of a session despite requesting clean_start"};
				return error.Protocol;
			}

			if (connack.retain_available) |ra| {
				self.server_can_retain = ra;
			}
		}

		fn receivedInvalidReason(self: *Self, state: anytype) error{Protocol} {
			self.disconnect(state, .{.reason = .protocol_error}) catch {};
			self.last_error = .{.details = "received an invalid reason code"};
			return error.Protocol;
		}

		fn receivedErrorReason(self: *Self, state: anytype, code: u8) error{Response} {
			// MQTT-3.2.2-7
			Impl.close(state);
			const reason: ErrorReasonCode = switch (code) {
				128 => .unspecified_error,
				129 => .malformed_packet,
				130 => .protocol_error,
				131 => .implementation_specific_error,
				132 => .unsupported_protocol_version,
				133 => .client_identifier_not_valid,
				134 => .bad_user_name_or_password,
				135 => .not_authorized,
				136 => .server_unavailable,
				137 => .server_busy,
				138 => .banned,
				139 => .server_shutting_down,
				140 => .bad_authentication_method,
				141 => .keep_alive_timeout,
				142 => .session_taken_over,
				143 => .topic_filter_invalid,
				144 => .topic_name_invalid,
				145 => .packet_identifier_in_use,
				146 => .packet_identifier_not_found,
				147 => .receive_maximum_exceeded,
				148 => .topic_alias_invalid,
				149 => .packet_too_large,
				150 => .message_rate_too_high,
				151 => .quota_exceeded,
				152 => .administrative_action,
				153 => .payload_format_invalid,
				154 => .retain_not_supported,
				155 => .qo_s_not_supported,
				156 => .use_another_server,
				157 => .server_moved,
				158 => .shared_subscriptions_not_supported,
				159 => .connection_rate_exceeded,
				160 => .maximum_connect_time,
				161 => .subscription_identifiers_not_supported,
				162 => .wildcard_subscriptions_not_supported,
				else => .unknown,
			};
			self.last_error = .{.reason = reason};
			return error.Response;
		}
	};
}

const PublishFlags = packed struct(u4) {
	dup: bool,
	qos: QoS,
	retain: bool,
};

fn encodeConnect(buf: []u8, opts: ConnectOpts) ![]u8 {
	var connect_flags = packed struct(u8) {
		_reserved: bool = false,
		clean_start: bool = true,
		will: bool = false,
		will_qos: QoS = .at_most_once,
		will_retain: bool = false,
		username: bool,
		password: bool,
	}{
		.username = opts.username != null,
		.password = opts.password != null,
	};

	if (opts.will) |w| {
		connect_flags.will = true;
		connect_flags.will_qos = w.qos;
		connect_flags.will_retain = w.retain;
	}

	// reserve 1 byte for the packet type
	// reserve 4 bytes for the packet length (which might be less than 4 bytes)
	buf[5] = 0;
	buf[6] = 4;  // length of string, 4: MQTT
	buf[7] = 'M';
	buf[8] = 'Q';
	buf[9] = 'T';
	buf[10] = 'T';

	buf[11] = 5; // protocol

	buf[12] = @as([*]u8, @ptrCast(@alignCast(&connect_flags)))[0];

	codec.writeInt(u16, buf[13..15], opts.keepalive_sec);

	// everything above is safe, since buf is at least MIN_BUF_SIZE.

	const PROPERTIES_OFFSET = 15;
	const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.CONNECT);

	// Start payload
	var pos = PROPERTIES_OFFSET + properties_len;
	pos += try codec.writeString(buf[pos..], opts.client_id orelse "");

	if (opts.will) |will| {
		pos += try properties.write(buf[pos..], will, &properties.WILL);
	}

	if (opts.username) |u| {
		pos += try codec.writeString(buf[pos..], u);
	}

	if (opts.password) |p| {
		pos += try codec.writeString(buf[pos..], p);
	}
	return encodePacketHeader(buf[0..pos], 1, 0);
}

fn encodeDisconnect(buf: []u8, opts: DisconnectOpts) ![]u8 {
	// reserve 1 byte for the packet type
	// reserve 4 bytes for the packet length (which might be less than 4 bytes)
	buf[5] = @intFromEnum(opts.reason);
	const PROPERTIES_OFFSET = 6;
	const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.DISCONNECT);

	return encodePacketHeader(buf[0..PROPERTIES_OFFSET + properties_len], 14, 0);
}

fn encodeSubscribe(buf: []u8, packet_identifier: u16, opts: SubscribeOpts) ![]u8 {
	const SubscriptionOptions = packed struct(u8) {
		qos: QoS,
		no_local: bool,
		retain_as_published: bool,
		retain_handling: RetainHandling,
		_reserved: u2 = 0,
	};

	// reserve 1 byte for the packet type
	// reserve 4 bytes for the packet length (which might be less than 4 bytes)

	codec.writeInt(u16, buf[5..7], packet_identifier);
	const PROPERTIES_OFFSET = 7;
	const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.SUBSCRIBE);

	var pos = PROPERTIES_OFFSET + properties_len;
	for (opts.topics) |topic| {
		pos += try codec.writeString(buf[pos..], topic.filter);
		var subscription_options = SubscriptionOptions{
			.qos = topic.qos,
			.no_local = topic.no_local,
			.retain_as_published = topic.retain_as_published,
			.retain_handling = topic.retain_handling,
		};
		buf[pos] = @as([*]u8, @ptrCast(@alignCast(&subscription_options)))[0];
		pos += 1;
	}

	return encodePacketHeader(buf[0..pos], 8, 2);
}

fn encodePublish(buf: []u8, packet_identifier: u16, opts: PublishOpts) ![]u8 {
	var publish_flags = PublishFlags{
		.dup = opts.dup,
		.qos = opts.qos,
		.retain = opts.retain,
	};

	// reserve 1 byte for the packet type
	// reserve 4 bytes for the packet length (which might be less than 4 bytes)
	const VARIABLE_HEADER_OFFSET = 5;
	const topic_len = try codec.writeString(buf[VARIABLE_HEADER_OFFSET..], opts.topic);

	const packet_identifer_offset = VARIABLE_HEADER_OFFSET + topic_len;
	const properties_offset = packet_identifer_offset + 2;
	codec.writeInt(u16, buf[packet_identifer_offset..properties_offset][0..2], packet_identifier);
	const properties_len = try properties.write(buf[properties_offset..], opts, &properties.PUBLISH);

	const payload_offset = properties_offset + properties_len;
	const payload_len = try codec.writeString(buf[payload_offset..], opts.message);

	return encodePacketHeader(buf[0..payload_offset + payload_len], 3, @as([*]u4, @ptrCast(@alignCast(&publish_flags)))[0]);
}

fn encodePubAck(buf: []u8, opts: PubAckOpts) ![]u8 {
	// reserve 1 byte for the packet type
	// reserve 4 bytes for the packet length (which might be less than 4 bytes)
	codec.writeInt(u16,  buf[5..7], opts.packet_identifier);
	buf[7] = @intFromEnum(opts.reason_code);
	const PROPERTIES_OFFSET = 8;
	const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.PUBACK);

	if (opts.reason_code == .success and properties_len == 1) {
		// special case, if the reason code is 0 and ther are no properties
		// we can ommit both, and thus we only have a packet with
		// type+flag, length (of 2), 2 byte packet_identifier
		buf[3] = 64; // packet type (0100) + flags (0000)
		buf[4] = 2;  // remaining length
		return buf[3..7];
	}

	return encodePacketHeader(buf[0..PROPERTIES_OFFSET + properties_len], 4, 0);
}

fn encodePacketHeader(buf: []u8, packet_type: u8, packet_flags: u8) []u8 {
	const remaining_len = buf.len - 5;
	const length_of_len = codec.lengthOfVarint(remaining_len);

	// This is where, in buf, our packet is actually going to start. You'd think
	// it would start at buf[0], but the package length is variable, so it'll
	// only start at buf[0] in the [unlikely] case where the length took 4 bytes.
	const start = 5 - length_of_len - 1;

	buf[start] = (packet_type << 4) | packet_flags;
	_ = codec.writeVarint(buf[start+1..], remaining_len);
	return buf[start..];
}

// These are only the packets that a client can receive
// For packets that the client sends, we write the Opts (e.g. ConnectionOpts)
// directly to the write_buf
pub const Packet = union(enum) {
	connack: ConnAck,
	suback: SubAck,
	publish: Publish,
	puback: PubAck,

	pub const ConnAck = struct {
		session_present: bool,
		reason_code: u8,
		session_expiry_interval: ?u32 = null,
		receive_maximum: ?u16 = null,
		maximum_qos: ?QoS = null,
		retain_available: ?bool = null,
		maximum_packet_size: ?u32 = null,
		assigned_client_identifier: ?[]const u8 = null,
		topic_alias_maximum: ?u16 = null,
		reason_string: ?[]const u8 = null,
		wildcard_subscription_available: ?bool = null,
		subscription_identifier_available: ?bool = null,
		shared_subscription_available: ?bool = null,
		server_keepalive: ?u16 = null,
		response_information: ?[]const u8 = null,
		server_reference: ?[]const u8 = null,
		authentication_method: ?[]const u8 = null,
		authentication_data: ?[]const u8 = null,
	};

	pub const SubAck = struct {
		packet_identifier: u16,
		reason_string: ?[]const u8 = null,
		results: []const u8,

		const Result = union(enum) {
			granted: QoS,
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

		pub fn result(self: *const SubAck, topic_index: usize) Result {
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

	pub const Publish = struct {
		dup: bool,
		qos: QoS,
		// not sure what this means in the context of a received message
		// maybe it's never set, or maybe it indicates that the server is publishing
		// a message which it retains?
		retain: bool,

		topic: []const u8,
		message: []const u8,
		packet_identifier: u16,

		payload_format: ?PayloadFormat = null,
		message_expiry_interval: ?u32 = null, // does a server ever send this?
		topic_alias: ?u16 = null,
		response_topic: ?[]const u8 = null,
		correlation_data: ?[]const u8 = null,
		subscription_identifier: ?usize = null,
		content_type: ?[]const u8 = null,
	};

	pub const PubAck = struct {
		packet_identifier: u16,
		reason_code: PubAckReason,
		reason_string: ?[]const u8 = null,
	};
};

fn decodePacket(b1: u8, data: []u8) !Packet {
	// data.len has to be > 0
	// TODO: how to assert without std?
	const flags: u4 = @intCast(b1 & 15);
	switch (b1 >> 4) {
		2 => return .{.connack = try decodeConnAck(data, flags)},
		3 => return .{.publish = try decodePublish(data, flags)},
		4 => return .{.puback = try decodePubAck(data, flags)},
		9 => return .{.suback = try decodeSubAck(data, flags)},
		else => return error.UnknownPacketType, // TODO
	}
}

 fn decodeConnAck(data: []u8, flags: u4) !Packet.ConnAck {
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

	var connack = Packet.ConnAck{
		.session_present = session_present,
		.reason_code = data[1],
	};

	var props = try PropertyReader.init(data[2..]);
	while (try props.next()) |prop| {
		switch (prop) {
			.session_expiry_interval => |v| connack.session_expiry_interval = v,
			.receive_maximum => |v| connack.receive_maximum = v,
			.maximum_qos => |v| connack.maximum_qos = v,
			.retain_available => |v| connack.retain_available = v,
			.maximum_packet_size => |v| connack.maximum_packet_size = v,
			.assigned_client_identifier => |v| connack.assigned_client_identifier = v,
			.topic_alias_maximum => |v| connack.topic_alias_maximum = v,
			.reason_string => |v| connack.reason_string = v,
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

fn decodeSubAck(data: []u8, flags: u4) !Packet.SubAck {
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

	var suback = Packet.SubAck{
		.packet_identifier = codec.readInt(u16, data[0..2]),
		.results = undefined,
	};

	var props = try PropertyReader.init(data[2..]);
	while (try props.next()) |prop| {
		switch (prop) {
			.reason_string => |v| suback.reason_string = v,
			.user_property => {}, // TODO: handle
			else => return error.InvalidProperty,
		}
	}

	// the rest of the packet is the payload, and the payload is 1 or more
	// 1 byte reason codes. 1 reason code per subscribed topic (in the same order)
	// So if you subscribed to 2 topics and want to know the result of the 2nd one
	// you would check suback.results[1].
	suback.results = data[2 + props.len..];
	return suback;
}

fn decodePublish(data: []u8, flags: u4) !Packet.Publish {
	if (data.len < 5) {
		// 2 for the packet identifier
		// 1 for an empty property list
		// 2 for an empty message
		return error.IncompletePacket;
	}

	const publish_flags: *PublishFlags = @constCast(@ptrCast(&flags));

	const topic, const packet_identifier_offset = try codec.readString(data);
	const properties_offset = packet_identifier_offset + 2;

	var publish = Packet.Publish{
		.dup = publish_flags.dup,
		.qos = publish_flags.qos,
		.retain = publish_flags.retain,
		.topic = topic,
		.message = undefined,
		.packet_identifier = codec.readInt(u16, data[packet_identifier_offset..properties_offset][0..2]),
	};

	var props = try PropertyReader.init(data[properties_offset..]);
	while (try props.next()) |prop| {
		switch (prop) {
			.payload_format => |v| publish.payload_format = v,
			.message_expiry_interval => |v| publish.message_expiry_interval = v,
			.topic_alias => |v| publish.topic_alias = v,
			.response_topic => |v| publish.response_topic = v,
			.correlation_data => |v| publish.correlation_data = v,
			.subscription_identifier => |v| publish.subscription_identifier = v,
			.content_type => |v| publish.content_type = v,
			.user_property => {}, // TODO: handle
			else => return error.InvalidProperty,
		}
	}

	publish.message, _ = try codec.readString(data[properties_offset + props.len..]);
	return publish;
}

fn decodePubAck(data: []u8, flags: u4) !Packet.PubAck {
	if (flags != 0) {
		return error.InvalidFlags;
	}

	if (data.len < 2) {
		return error.IncompletePacket;
	}

	const packet_identifier = codec.readInt(u16, data[0..2]);
	if (data.len == 2) {
		// special puback with just a packet_identifier
		// reason_code is implicitly success
		// no properties
		return .{
			.reason_code = .success,
			.packet_identifier = packet_identifier,
		};
	}

	const reason_code: PubAckReason = switch (data[2]) {
		0 => .success,
		16 => .no_matching_subscribers,
		128 => .unspecified_error,
		131 => .implementation_specific_error,
		135 => .not_authorized,
		144 => .topic_name_invalid,
		151 => .quota_exceeded,
		153 => .payload_format_invalid,
		else => return error.MalformedPacket,
	};

	var puback = Packet.PubAck{
		.packet_identifier = packet_identifier,
		.reason_code = reason_code,
	};

	var props = try PropertyReader.init(data[3..]);
	while (try props.next()) |prop| {
		switch (prop) {
			.reason_string => |v| puback.reason_string = v,
			.user_property => {}, // TODO: handle
			else => return error.InvalidProperty,
		}
	}
	return puback;
}

const t = @import("std").testing;

test "Client: connect" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;
	{
		// basic connect call
		try client.connect(&ctx, .{});
		try ctx.expectWritten(1, &.{
			16,                        // packet type
			13,                        // payload length
			0, 4, 'M', 'Q', 'T', 'T',  // protocol name
			5,                         // protocol version
			2,                         // connect flags (0, 0, 0, 0, 0, 0, 1, 0)
			0, 0,                      // keepalive sec
			0,                         // properties length
			0, 0                       // client_id length
		});
	}

	{
		// more advanced connect call
		ctx.reset();
		try client.connect(&ctx,  .{
			.client_id = "the-client",
			.username = "the-username",
			.password = "the-passw0rd",
			.will = .{
				.topic = "the topic",
				.message = "the message",
				.qos = .exactly_once,
				.retain = true,
				.delay_interval = 948824,
				.payload_format = .utf8,
				.message_expiry_interval = 225768392,
				.content_type = "test/type",
				.response_topic = "test-topic",
				.correlation_data = "over 9000!!",
			},
			.keepalive_sec = 300,
			.session_expiry_interval = 20,
			.receive_maximum = 300,
			.maximum_packet_size = 4000,
		});
		try ctx.expectWritten(1, &.{
			16,                        // packet type
			116,                       // payload length
			0, 4, 'M', 'Q', 'T', 'T',  // protocol name
			5,                         // protocol version
			246,                       // connect flags (1, 1, 1, 1, 0, 1, 1, 0)
			                           //               the last 0 is reserved, the middle 0 comes from the "2" (1, 0) of the will qos.
			1, 44,                     // keepalive sec

			13,                             // properties length
			0x11, 0, 0, 0, 0x14,            // session expiry interval property
			0x21, 0x01, 0x2c,               // receive maximum property
			0x27, 0x00, 0x00, 0x0f, 0xa0,   // maximum packet size interval property

			// payload
			0, 10,                     // client_id length
			't', 'h', 'e', '-', 'c', 'l', 'i', 'e', 'n', 't',

			// WILL properties
			51,                           // will length
			0x18, 0x00, 0x0E, 0x7A, 0x58, // delay interval
			0x01, 0x01,                   // payload_format
			0x02, 0x0D, 0x74, 0xF3, 0xC8, // message_expiry_interval

			// text values have a 2 byte length prefix after the identifier
			0x03, 0x00, 0x09, 't', 'e', 's', 't', '/', 't', 'y', 'p', 'e',
			0x08, 0x00, 0x0A, 't', 'e', 's', 't', '-', 't', 'o', 'p', 'i', 'c',
			0x09, 0x00, 0x0B, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!', '!',


			0, 12,                      // username length
			't', 'h', 'e', '-', 'u', 's', 'e', 'r', 'n', 'a', 'm', 'e',
			0, 12,                      // password length
			't', 'h', 'e', '-', 'p', 'a', 's', 's', 'w', '0', 'r', 'd'
		});
	}
}

test "Client: subscribe" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;

	{
		// empty topic
		try t.expectError(error.Usage, client.subscribe(&ctx, .{.topics = &.{}}));
		try t.expectEqualSlices(u8, "must have at least 1 topic", client.last_error.?.details);
	}

	{
		const pi = try client.subscribe(&ctx, .{
			.packet_identifier = 10,
			.topics = &.{.{.filter = "topic1"}},  // always need 1 topic
		});

		try t.expectEqual(10, pi);

		try ctx.expectWritten(1, &.{
			130,                       // packet type (1000 0010)  (8 for the packet type, and 2 for the flag, the flag is always 2)
			12,                        // payload length
			0, 10,                     // packet identifier
			0,                         // property length
			0, 6, 't', 'o', 'p', 'i', 'c', '1',
			36                         // subscription options
		});
	}
}

test "Client: publish" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;

	{
		// can't publish with retain if server doesn't support retain
		// (the server should treat this as an error, so we might as well catch it in the library)
		client.server_can_retain = false;
		try t.expectError(error.Usage, client.publish(&ctx, .{.retain = true, .topic = "", .message = ""}));
		try t.expectEqualSlices(u8, "server does not support retained messages", client.last_error.?.details);
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// publish
		ctx.reset();
		const pi = try client.publish(&ctx, .{
			.packet_identifier = 20,
			.topic = "power/goku",
			.message = "over 9000!!",
		});

		try t.expectEqual(20, pi);

		try ctx.expectWritten(1, &.{
			48,                        // packet type (0011 0000)  (3 for the packet type, 0 since no flag is set)
			28,                        // payload length
			0, 10, 'p', 'o', 'w', 'e', 'r', '/', 'g', 'o', 'k', 'u',
			0, 20,                     // packet identifier
			0,                         // property length
			0, 11, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!', '!' // payload (the message)
		});
	}

	{
		// full
		ctx.reset();
		client.server_can_retain = true;
		const pi = try client.publish(&ctx, .{
			.packet_identifier = 30,
			.topic = "t1",
			.message = "m2z",
			.dup = true,
			.qos = .exactly_once,
			.retain = true,
			.payload_format = .utf8,
			.message_expiry_interval = 10
		});

		try t.expectEqual(30, pi);

		try ctx.expectWritten(1, &.{
			61,                        // packet type (0011 1 10 1)  (3 for the packet type, 1 for dup, 2 for qos, 1 for retain)
			19,                        // payload length
			0, 2, 't', '1',
			0, 30,                     // packet identifier
			7,                         // property length
			1, 1,                      //payload format
			2, 0, 0, 0, 10,            // message expiry interval
			0, 3, 'm', '2', 'z'        // payload (the message)
		});
	}
}

test "Client: puback" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;

	{
		// puback special short (success with no properties)
		ctx.reset();
		try client.puback(&ctx, .{.packet_identifier = 5});

		try ctx.expectWritten(1, &.{
			64,                       // packet type (0100 0000)  (4 for the packet type, 0 for flags)
			2,                        // payload length
			0, 5                      // packet identifier
		});
	}

	{
		// puback with non-success reason code
		ctx.reset();
		try client.puback(&ctx, .{.packet_identifier = 1, .reason_code = .quota_exceeded});

		try ctx.expectWritten(1, &.{
			64,                       // packet type (0100 0000)  (4 for the packet type, 0 for flags)
			4,                        // payload length
			0, 1,                     // packet identifier
			151,                      // reason code
			0,                        // properties length
		});
	}

	{
		// puback with properties
		ctx.reset();
		try client.puback(&ctx, .{.packet_identifier = 1, .reason_string = "ok"});

		try ctx.expectWritten(1, &.{
			64,                       // packet type (0100 0000)  (4 for the packet type, 0 for flags)
			9,                        // payload length
			0, 1,                     // packet identifier
			0,                        // reason code
			5,                        // properties length
			31, 0, 2, 'o', 'k'
		});
	}
}

test "Client: disconnect" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;
	{
		// basic
		try client.disconnect(&ctx, .{.reason = .normal});
		try ctx.expectWritten(1, &.{
			224,                       // packet type
			2,                         // payload length
			0,                         // reason
			0,                         // property length
		});
	}

	{
		// full
		ctx.reset();
		try client.disconnect(&ctx, .{
			.reason = .message_rate_too_high,
			.session_expiry_interval = 999998,
			.reason_string = "tea time",
		});

		try ctx.expectWritten(1, &.{
			224,                          // packet type
			18,                           // payload length
			150,                          // reason
			16,                           // property length
			0x11, 0x00, 0x0f, 0x42, 0x3e, //sessione expiry interval
			0x1f, 0x00, 0x08, 't', 'e', 'a', ' ', 't', 'i', 'm', 'e'
		});
	}
}

test "Client: readPacket close" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	ctx.reset();
	// the way our test client works is that if we try to read more data then
	// we've setup, it return 0 (0 bytes read), which should mean closed.
	ctx.reply(&.{32, 10, 0, 0, 7});

	var client = &ctx.client;
	try t.expectError(error.Closed, client.readPacket(&ctx));
}

test "Client: readPacket fuzz" {
	// testing that we support under-reads (requiring more than 1 read to get
	// a whole packet) and over-reads (reading more than 1 packet per read).
	// Our Testclient's read is random, so hopefully by iterating a few times
	// we'll cover the cases.

	var ctx = TestContext.init();
	defer ctx.deinit();

	for (0..1000) |_| {
		ctx.reset();
		ctx.reply(&.{
			32, 10, 0, 0, 7, 21, 0, 4, 'n', 'o', 'n', 'e', // connack with authentication method property
			144, 5, 1, 3, 0, 0, 1,                         // suback with 2 response codes
			144, 252, 1, 0, 2, 0,                          // suback with 0 properties and...
			                                               // 249 response codes..we want to test packets that push the limit of our buffer
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
		});

		var client = &ctx.client;
		const connack = (try client.readPacket(&ctx)).connack;
		try t.expectEqualSlices(u8, "none", connack.authentication_method.?);

		const suback1 = (try client.readPacket(&ctx)).suback;
		try t.expectEqual(259, suback1.packet_identifier);
		try t.expectEqualSlices(u8, &.{0, 1}, suback1.results);

		const suback2 = (try client.readPacket(&ctx)).suback;
		try t.expectEqual(2, suback2.packet_identifier);
		try t.expectEqualSlices(u8, &([_]u8{0} ** 249), suback2.results);
	}
}

test "Client: readPacket connack" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;

	{
		// return with error reason code
		ctx.reset();
		ctx.reply(&.{32, 3, 0, 133, 0});
		try t.expectError(error.Response, client.readPacket(&ctx));
		try t.expectEqual(.client_identifier_not_valid, client.last_error.?.reason);
		try t.expectEqual(1, ctx.close_count);
	}

	{
		// return with invalid reason code
		ctx.reset();
		ctx.reply(&.{32, 3, 0, 100, 0});
		try t.expectError(error.Protocol, client.readPacket(&ctx));
		try t.expectEqual("received an invalid reason code", client.last_error.?.details);
		try t.expectEqual(1, ctx.close_count);
	}

	{
		// session_present = true
		// (this is currently always invalid, since we force clean_start = true)
		ctx.reset();
		ctx.reply(&.{32, 3, 1, 0, 0});
		try t.expectError(error.Protocol, client.readPacket(&ctx));
		try t.expectEqual("connack indicated the presence of a session despite requesting clean_start", client.last_error.?.details);
		try t.expectEqual(1, ctx.close_count);
	}

	{
		// success, basic reply
		// session_present = false
		// reason code = 0
		// 0 properties
		ctx.reset();
		ctx.reply(&.{32, 3, 0, 0, 0});

		const connack = (try client.readPacket(&ctx)).connack;

		// the default if the server doesn't send up a retain_available property
		try t.expectEqual(true, client.server_can_retain);

		try t.expectEqual(0, ctx.close_count);
		try t.expectEqual(false, connack.session_present);
		try t.expectEqual(0, connack.reason_code);
		try t.expectEqual(null, connack.session_expiry_interval);
		try t.expectEqual(null, connack.receive_maximum);
		try t.expectEqual(null, connack.maximum_qos);
		try t.expectEqual(null, connack.retain_available);
		try t.expectEqual(null, connack.maximum_packet_size);
		try t.expectEqual(null, connack.assigned_client_identifier);
		try t.expectEqual(null, connack.topic_alias_maximum);
		try t.expectEqual(null, connack.reason_string);
		try t.expectEqual(null, connack.wildcard_subscription_available);
		try t.expectEqual(null, connack.subscription_identifier_available);
		try t.expectEqual(null, connack.shared_subscription_available);
		try t.expectEqual(null, connack.server_keepalive);
		try t.expectEqual(null, connack.response_information);
		try t.expectEqual(null, connack.server_reference);
		try t.expectEqual(null, connack.authentication_method);
		try t.expectEqual(null, connack.authentication_data);
	}

	{
		// success
		// session_present = false
		// reason code = 0
		// retain_available = 0
		// server_keepalive property
		ctx.reset();
		ctx.reply(&.{32, 8, 0, 0, 5, 19, 0, 60, 37, 0});

		const connack = (try client.readPacket(&ctx)).connack;

		// server told us it won't/can't retain
		try t.expectEqual(false, client.server_can_retain);
		try t.expectEqual(0, ctx.close_count);

		try t.expectEqual(false, connack.session_present);
		try t.expectEqual(0, connack.reason_code);
		try t.expectEqual(null, connack.session_expiry_interval);
		try t.expectEqual(null, connack.receive_maximum);
		try t.expectEqual(null, connack.maximum_qos);
		try t.expectEqual(false, connack.retain_available.?);
		try t.expectEqual(null, connack.maximum_packet_size);
		try t.expectEqual(null, connack.assigned_client_identifier);
		try t.expectEqual(null, connack.topic_alias_maximum);
		try t.expectEqual(null, connack.reason_string);
		try t.expectEqual(null, connack.wildcard_subscription_available);
		try t.expectEqual(null, connack.subscription_identifier_available);
		try t.expectEqual(null, connack.shared_subscription_available);
		try t.expectEqual(60, connack.server_keepalive.?);
		try t.expectEqual(null, connack.response_information);
		try t.expectEqual(null, connack.server_reference);
		try t.expectEqual(null, connack.authentication_method);
		try t.expectEqual(null, connack.authentication_data);

		try t.expectEqualSlices(u8, &.{32, 8, 0, 0, 5, 19, 0, 60, 37, 0}, client.lastReadPacket());
	}
}

test "Client: readPacket suback" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;

	{
		ctx.reset();
		// return with invalid packet flags
		// first byte should always be 144. 145 means the LSB is set, which it should not be
		// (the flag, the last 4 bits, should always be 0
		ctx.reply(&.{145, 4, 0, 0, 0, 0});
		try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
		try t.expectEqual(error.InvalidFlags, client.last_error.?.inner);
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// wrong packet type
		ctx.reset();
		ctx.reply(&.{7, 3, 0, 0, 0});
		try t.expectError(error.Protocol, client.readPacket(&ctx));
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// short packet
		ctx.reset();
		ctx.reply(&.{144, 3, 0, 0, 0});
		try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// basic response
		ctx.reset();
		ctx.reply(&.{144, 4, 1, 2, 0, 1});
		const suback = (try client.readPacket(&ctx)).suback;
		try t.expectEqual(258, suback.packet_identifier);
		try t.expectEqual(null, suback.reason_string);
		try t.expectEqualSlices(u8, &.{1}, suback.results);
		try t.expectEqual(.at_least_once, suback.result(0).granted);
		try t.expectEqual({}, suback.result(2).invalid_index);
	}

	{
		// multi-topic response
		ctx.reset();
		ctx.reply(&.{
			144,
			11,
			0, 1,  // packet identifier
			5,     // property length
			31, 0, 2, 'o', 'k',  // reason
			2, 135, 4,   // 3 reasons
		});
		const suback = (try client.readPacket(&ctx)).suback;
		try t.expectEqual(1, suback.packet_identifier);
		try t.expectEqualSlices(u8, "ok", suback.reason_string.?);
		try t.expectEqualSlices(u8, &.{2, 135, 4}, suback.results);
		try t.expectEqual(.exactly_once, suback.result(0).granted);
		try t.expectEqual(.not_authorized, suback.result(1).err);
		try t.expectEqual(.unknown, suback.result(2).err);
	}
}

test "Client: readPacket publish" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;


	{
		// short packet
		ctx.reset();
		ctx.reply(&.{48, 4, 0, 0, 0, 0});
		try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// basic response
		ctx.reset();
		ctx.reply(&.{
			48,
			15,
			0, 3, 'a', '/', 'b',      // topic
			10, 1,                    // packet identifier
			0,                        // property list length
			0, 5, 'h', 'e', 'l', 'l', 'o'  // payload (message)
		});
		const publish = (try client.readPacket(&ctx)).publish;
		try t.expectEqual(.at_most_once, publish.qos);
		try t.expectEqual(false, publish.dup);
		try t.expectEqual(false, publish.retain);
		try t.expectEqual(2561, publish.packet_identifier);
		try t.expectEqualSlices(u8, "a/b", publish.topic);
		try t.expectEqualSlices(u8, "hello", publish.message);

		try t.expectEqual(null, publish.payload_format);
		try t.expectEqual(null, publish.message_expiry_interval);
		try t.expectEqual(null, publish.topic_alias);
		try t.expectEqual(null, publish.response_topic);
		try t.expectEqual(null, publish.correlation_data);
		try t.expectEqual(null, publish.subscription_identifier);
		try t.expectEqual(null, publish.content_type);
	}
}

test "Client: readPacket puback" {
	var ctx = TestContext.init();
	defer ctx.deinit();

	var client = &ctx.client;


	{
		// short packet
		ctx.reset();
		ctx.reply(&.{64, 1, 0});
		try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
		try t.expectEqual(0, ctx.close_count);
	}

	{
		// special short response
		ctx.reset();
		ctx.reply(&.{
			64,
			2,
			10, 2,                    // packet identifier
		});
		const puback = (try client.readPacket(&ctx)).puback;
		try t.expectEqual(2562, puback.packet_identifier);
		try t.expectEqual(.success, puback.reason_code);
		try t.expectEqual(null, puback.reason_string);
	}

	{
		// special short response
		ctx.reset();
		ctx.reply(&.{
			64,
			11,
			0, 3,                    // packet identifier
			135,                     // reason code
			7,                       // properties length
			31, 0, 4, 'n', 'o', 'p', 'e'
		});
		const puback = (try client.readPacket(&ctx)).puback;
		try t.expectEqual(3, puback.packet_identifier);
		try t.expectEqual(.not_authorized, puback.reason_code);
		try t.expectEqualSlices(u8, "nope", puback.reason_string.?);
	}
}

const TestContext = struct {
	arena: *std.heap.ArenaAllocator,
	to_read_pos: usize,
	to_read: std.ArrayList(u8),
	written: std.ArrayList(u8),
	write_count: usize,
	close_count: usize,
	_random: ?std.rand.DefaultPrng = null,
	client: Mqtt(*TestContext),

	const std = @import("std");

	fn init() TestContext {
		const arena = t.allocator.create(std.heap.ArenaAllocator) catch unreachable;
		arena.* = std.heap.ArenaAllocator.init(t.allocator);

		const allocator = arena.allocator();

		const read_buf = allocator.alloc(u8, MIN_BUF_SIZE) catch unreachable;
		const write_buf = allocator.alloc(u8, MIN_BUF_SIZE) catch unreachable;

		return .{
			.arena = arena,
			.to_read_pos = 0,
			.to_read = std.ArrayList(u8).init(allocator),
			.written = std.ArrayList(u8).init(allocator),
			.write_count = 0,
			.close_count = 0,
			.client = Mqtt(*TestContext).init(read_buf, write_buf) catch unreachable,
		};
	}

	fn deinit(self: *TestContext) void {
		self.arena.deinit();
		t.allocator.destroy(self.arena);
	}

	fn reset(self: *TestContext) void {
		self.to_read_pos = 0;
		self.write_count = 0;
		self.close_count = 0;
		self.to_read.clearRetainingCapacity();
		self.written.clearRetainingCapacity();

		self.client.disconnected = false;
		self.client.server_can_retain = true;
	}

	fn reply(self: *TestContext, data: []const u8) void {
		self.to_read.appendSlice(self.arena.allocator().dupe(u8, data) catch unreachable) catch unreachable;
	}

	fn read(self: *TestContext, buf: []u8, _: usize) !usize {
		const data = self.to_read.items[self.to_read_pos..];

		if (data.len == 0 or buf.len == 0) {
			return 0;
		}

		// randomly fragment the data
		const to_read = self.random().intRangeAtMost(usize, 1, @min(data.len, buf.len));
		@memcpy(buf[0..to_read], data[0..to_read]);
		self.to_read_pos += to_read;
		return to_read;
	}

	fn write(self: *TestContext, data: []const u8) !void {
		try self.written.appendSlice(data);
		self.write_count += 1;
	}

	fn close(self: *TestContext) void {
		self.close_count += 1;
	}

	fn random(self: *TestContext) std.rand.Random {
		if (self._random == null) {
			var seed: u64 = undefined;
			std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
			self._random = std.rand.DefaultPrng.init(seed);
		}
		return self._random.?.random();
	}

	fn expectWritten(self: *TestContext, count: usize, data: []const u8) !void {
		try t.expectEqual(count, self.write_count);
		try t.expectEqualSlices(u8, data, self.written.items);
	}
};
