const codec = @import("codec.zig");
const properties = @import("properties.zig");
const PropertyReader = properties.Reader;

pub const posix = @import("posix.zig");

pub const ProtocolVersion = enum(u8) {
    mqtt_3_1_1 = 4,
    mqtt_5_0 = 5,
};

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
    qos_not_supported,
    use_another_server,
    server_moved,
    shared_subscriptions_not_supported,
    connection_rate_exceeded,
    maximum_connect_time,
    subscription_identifiers_not_supported,
    wildcard_subscriptions_not_supported,
};

// When disconnecting, we give the server one of these reasons.
pub const ClientDisconnectReason = enum(u8) {
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
    packet_identifier_in_use = 145,
    quota_exceeded = 151,
    payload_format_invalid = 153,
};
pub const PubRecReason = PubAckReason;

pub const PubRelReason = enum(u8) {
    success = 0,
    packet_identifier_not_found = 146,
};
pub const PubCompReason = PubRelReason;

pub const UserProperty = struct {
    key: []const u8,
    value: []const u8,
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
    user_properties: ?[]const UserProperty = null,

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
    reason: ClientDisconnectReason,
    session_expiry_interval: ?u32 = null,
    reason_string: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
};

pub const SubscribeOpts = struct {
    packet_identifier: ?u16 = null,
    subscription_identifier: ?usize = null,
    topics: []const Topic,
    user_properties: ?[]const UserProperty = null,

    pub const Topic = struct {
        filter: []const u8,
        qos: QoS = .at_most_once,
        no_local: bool = true,
        retain_as_published: bool = false,
        retain_handling: RetainHandling = .do_not_send_retained,
    };
};

pub const UnsubscribeOpts = struct {
    packet_identifier: ?u16 = null,
    topics: []const []const u8,
};

pub const PublishOpts = struct {
    topic: []const u8,
    message: []const u8,
    dup: bool = false,
    qos: QoS = .at_most_once,
    retain: bool = false,
    packet_identifier: ?u16 = null,
    payload_format: ?PayloadFormat = null,
    message_expiry_interval: ?u32 = null,
    topic_alias: ?u16 = null,
    response_topic: ?[]const u8 = null,
    correlation_data: ?[]const u8 = null,
    subscription_identifier: ?usize = null,
    content_type: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
};

pub const PubAckOpts = struct {
    packet_identifier: u16,
    reason_code: PubAckReason = .success,
    reason_string: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
};

pub const PubRecOpts = struct {
    packet_identifier: u16,
    reason_code: PubRecReason = .success,
    reason_string: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
};

pub const PubRelOpts = struct {
    packet_identifier: u16,
    reason_code: PubRelReason = .success,
    reason_string: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
};

pub const PubCompOpts = struct {
    packet_identifier: u16,
    reason_code: PubCompReason = .success,
    reason_string: ?[]const u8 = null,
    user_properties: ?[]const UserProperty = null,
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

pub fn Mqtt5(comptime T: type) type {
    return Mqtt(T, .mqtt_5_0);
}
pub fn Mqtt311(comptime T: type) type {
    return Mqtt(T, .mqtt_3_1_1);
}
pub fn Mqtt(comptime T: type, comptime protocol_version: ProtocolVersion) type {
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

        last_error: ?ErrorDetail,

        // Many packets take an identifier, we increment this by one on each call
        packet_identifier: u16,

        // Default to true, but might be set to false as a property to connack.
        // If it does get set to false, we'll error on any publish where retain = true
        server_can_retain: bool,

        // If, in connack, the server tells us its maximum supported QoS, we'll
        // reject any publish with a higher QoS.
        server_max_qos: u2,

        const Self = @This();

        pub fn init(read_buf: []u8, write_buf: []u8) Self {
            return .{
                .read_pos = 0,
                .read_len = 0,
                .read_buf = read_buf,
                .write_buf = write_buf,
                .last_error = null,
                .packet_identifier = 1,
                .server_can_retain = true, // we'll set this to false if connack says so
                .server_max_qos = @intFromEnum(QoS.exactly_once), // can be changed based on connack response
            };
        }

        // Intended to be used for debugging
        pub fn lastReadPacket(self: *const Self) []const u8 {
            return self.read_buf[0..self.read_pos];
        }

        pub fn readBuffer(self: *const Self) []u8 {
            return self.read_buf[self.read_pos..self.read_len];
        }

        pub fn lastPartialPacket(self: *const Self) ?PartialPacket {
            const buf = self.readBuffer();

            if (buf.len < 2) {
                return null;
            }

            const remaining_len, const length_of_len = codec.readVarint(buf[1..]) catch {
                return null;
            } orelse return null;

            // +1 for the packet type
            const fixed_header_len = 1 + length_of_len;
            const total_len = fixed_header_len + remaining_len;
            return PartialPacket.decode(buf[0], buf[fixed_header_len..@min(total_len, buf.len)]);
        }

        const WriteError = @typeInfo(@typeInfo(@TypeOf(T.MqttPlatform.write)).@"fn".return_type.?).error_union.error_set;

        pub fn connect(self: *Self, state: anytype, opts: ConnectOpts) (WriteError || error{WriteBufferIsFull})!void {
            const connect_packet = try codec.encodeConnect(self.write_buf, protocol_version, opts);
            try self.writePacket(state, connect_packet);
        }

        pub fn subscribe(self: *Self, state: anytype, opts: SubscribeOpts) (WriteError || error{ Usage, WriteBufferIsFull })!u16 {
            if (opts.topics.len == 0) {
                self.last_error = .{ .details = "must have at least 1 topic" };
                return error.Usage;
            }

            const packet_identifier = self.packetIdentifier(opts.packet_identifier);
            const subscribe_packet = try codec.encodeSubscribe(self.write_buf, protocol_version, packet_identifier, opts);
            try self.writePacket(state, subscribe_packet);
            return packet_identifier;
        }

        pub fn unsubscribe(self: *Self, state: anytype, opts: UnsubscribeOpts) (WriteError || error{ Usage, WriteBufferIsFull })!u16 {
            if (opts.topics.len == 0) {
                self.last_error = .{ .details = "must have at least 1 topic" };
                return error.Usage;
            }

            const packet_identifier = self.packetIdentifier(opts.packet_identifier);
            const unsubscribe_packet = try codec.encodeUnsubscribe(self.write_buf, protocol_version, packet_identifier, opts);
            try self.writePacket(state, unsubscribe_packet);
            return packet_identifier;
        }

        pub fn publish(self: *Self, state: anytype, opts: PublishOpts) (WriteError || error{ Usage, WriteBufferIsFull })!?u16 {
            if (opts.retain == true and self.server_can_retain == false) {
                self.last_error = .{ .details = "server does not support retained messages" };
                return error.Usage;
            }
            if (@intFromEnum(opts.qos) > self.server_max_qos) {
                self.last_error = .{ .details = "server does not support this level of QoS" };
                return error.Usage;
            }

            var packet_identifier: ?u16 = null;
            if (opts.qos != .at_most_once) {
                // when QoS > 0, we include a packet identifier
                packet_identifier = self.packetIdentifier(opts.packet_identifier);
            }

            const publish_packet = try codec.encodePublish(self.write_buf, protocol_version, packet_identifier, opts);
            try self.writePacket(state, publish_packet);
            return packet_identifier;
        }

        pub fn puback(self: *Self, state: anytype, opts: PubAckOpts) (WriteError || error{WriteBufferIsFull})!void {
            const puback_packet = try codec.encodePubAck(self.write_buf, protocol_version, opts);
            try self.writePacket(state, puback_packet);
        }

        pub fn pubrec(self: *Self, state: anytype, opts: PubRecOpts) (WriteError || error{WriteBufferIsFull})!void {
            const pubrec_packet = try codec.encodePubRec(self.write_buf, protocol_version, opts);
            try self.writePacket(state, pubrec_packet);
        }

        pub fn pubrel(self: *Self, state: anytype, opts: PubRelOpts) (WriteError || error{WriteBufferIsFull})!void {
            const pubrel_packet = try codec.encodePubRel(self.write_buf, protocol_version, opts);
            try self.writePacket(state, pubrel_packet);
        }

        pub fn pubcomp(self: *Self, state: anytype, opts: PubCompOpts) (WriteError || error{WriteBufferIsFull})!void {
            const pubcomp_packet = try codec.encodePubComp(self.write_buf, protocol_version, opts);
            try self.writePacket(state, pubcomp_packet);
        }

        pub fn ping(self: *Self, state: anytype) WriteError!void {
            // 1100 000  (packet type + flags)
            // 0         (varing payload length)
            try self.writePacket(state, &.{ 192, 0 });
        }

        pub fn disconnect(self: *Self, state: anytype, opts: DisconnectOpts) (WriteError || error{WriteBufferIsFull})!void {
            defer T.MqttPlatform.close(state);
            const disconnect_packet = try codec.encodeDisconnect(self.write_buf, protocol_version, opts);
            return self.writePacket(state, disconnect_packet);
        }

        fn packetIdentifier(self: *Self, explicit: ?u16) u16 {
            if (explicit) |pi| {
                return pi;
            }
            const pi = self.packet_identifier +% 1;
            self.packet_identifier = pi;
            return pi;
        }

        fn writePacket(_: *Self, state: anytype, data: []const u8) WriteError!void {
            return T.MqttPlatform.write(state, data);
        }

        const ReadError = error{
            Closed,
            ReadBufferIsFull,
            Protocol,
            MalformedPacket,
        } || @typeInfo(@typeInfo(@TypeOf(T.MqttPlatform.read)).@"fn".return_type.?).error_union.error_set;

        pub fn readPacket(self: *Self, state: anytype) ReadError!?Packet {
            const p = (try self.readOrBuffered(state)) orelse return null;
            switch (p) {
                .connack => |*connack| try self.processConnack(state, connack),
                else => {},
            }
            return p;
        }

        fn readOrBuffered(self: *Self, state: anytype) !?Packet {
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

                const n = (try T.MqttPlatform.read(state, buf[pos..], calls)) orelse return null;
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
                    self.last_error = .{ .inner = err };
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
            return Packet.decode(buf[0], buf[fixed_header_len..total_len], protocol_version) catch |err| {
                self.last_error = .{ .inner = err };
                switch (err) {
                    error.UnknownPacketType => return error.Protocol,
                    error.InvalidReasonCode => return error.Protocol,
                    else => return error.MalformedPacket,
                }
            };
        }

        fn processConnack(self: *Self, state: anytype, connack: *const Packet.ConnAck) !void {
            if (connack.session_present) {
                // TODO: since we force clean_start = true, this should always be false
                // but if we support clean_start = false, than this would only be an
                // error if it otps.clean_start == true.

                // MQTT-3.2.2-4
                self.disconnect(state, .{ .reason = .protocol_error }) catch {};
                self.last_error = .{ .details = "connack indicated the presence of a session despite requesting clean_start" };
                return error.Protocol;
            }

            if (connack.retain_available) |ra| {
                self.server_can_retain = ra;
            }

            if (connack.maximum_qos) |max| {
                self.server_max_qos = @intFromEnum(max);
            }
        }
    };
}

// These are only the packets that a client can receive
// For packets that the client sends, we write the Opts (e.g. ConnectionOpts)
// directly to the write_buf
pub const Packet = union(enum) {
    connack: ConnAck,
    suback: SubAck,
    unsuback: UnsubAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    disconnect: Disconnect,
    pong: void,

    pub const ConnAck = struct {
        session_present: bool,
        reason_code: ReasonCode,
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
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const ConnAck) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }

        pub const ReasonCode = enum(u8) {
            success = 0,
            unspecified_error = 128,
            malformed_packet = 129,
            protocol_error = 130,
            implementation_specific_error = 131,
            unsupported_protocol_version = 132,
            client_identifier_not_valid = 133,
            bad_user_name_or_password = 134,
            not_authorized = 135,
            server_unavailable = 136,
            server_busy = 137,
            banned = 138,
            bad_authentication_method = 140,
            topic_name_invalid = 144,
            packet_too_large = 149,
            quota_exceeded = 151,
            payload_format_invalid = 153,
            retain_not_supported = 154,
            qos_not_supported = 155,
            use_another_server = 156,
            server_moved = 157,
            connection_rate_exceeded = 159,
        };
    };

    pub const SubAck = struct {
        packet_identifier: u16,
        reason_string: ?[]const u8 = null,
        results: []const u8,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const SubAck) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }

        const Error = error{
            Protocol,
            Unspecified,
            ImplementationSpecific,
            NotAuthorized,
            TopicFilterInvalid,
            PacketIdentifierInUse,
            QuotaExceeded,
            SharedSubscriptionsNotSupported,
            SubscriptionIdentifierNotSupported,
            WildcardSubscriptionsNotSupported,
        };

        pub fn result(self: *const SubAck, topic_index: usize) SubAck.Error!QoS {
            const results = self.results;

            switch (results[topic_index]) {
                0 => return .at_most_once,
                1 => return .at_least_once,
                2 => return .exactly_once,
                128 => return error.Unspecified,
                131 => return error.ImplementationSpecific,
                135 => return error.NotAuthorized,
                143 => return error.TopicFilterInvalid,
                145 => return error.PacketIdentifierInUse,
                151 => return error.QuotaExceeded,
                158 => return error.SharedSubscriptionsNotSupported,
                161 => return error.SubscriptionIdentifierNotSupported,
                162 => return error.WildcardSubscriptionsNotSupported,
                else => return error.Protocol,
            }
        }
    };

    pub const UnsubAck = struct {
        packet_identifier: u16,
        reason_string: ?[]const u8 = null,
        results: []const u8,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const UnsubAck) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }

        const Error = error{
            Protocol,
            NoSubscriptionExisted,
            Unspecified,
            ImplementationSpecific,
            NotAuthorized,
            TopicFilterInvalid,
            PacketIdentifierInUse,
        };

        pub fn result(self: *const UnsubAck, topic_index: usize) UnsubAck.Error!void {
            const results = self.results;

            switch (results[topic_index]) {
                0 => return,
                17 => return error.NoSubscriptionExisted,
                128 => return error.Unspecified,
                131 => return error.ImplementationSpecific,
                135 => return error.NotAuthorized,
                143 => return error.TopicFilterInvalid,
                145 => return error.PacketIdentifierInUse,
                else => return error.Protocol,
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
        // null when qos is .at_least_once
        packet_identifier: ?u16,

        payload_format: ?PayloadFormat = null,
        message_expiry_interval: ?u32 = null, // does a server ever send this?
        topic_alias: ?u16 = null,
        response_topic: ?[]const u8 = null,
        correlation_data: ?[]const u8 = null,
        subscription_identifier: ?usize = null,
        content_type: ?[]const u8 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const Publish) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }
    };

    pub const PubAck = struct {
        packet_identifier: u16,
        reason_code: PubAckReason,
        reason_string: ?[]const u8 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const PubAck) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }
    };

    pub const PubRec = struct {
        packet_identifier: u16,
        reason_code: PubRecReason,
        reason_string: ?[]const u8 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const PubRec) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }
    };

    pub const PubRel = struct {
        packet_identifier: u16,
        reason_code: PubRelReason,
        reason_string: ?[]const u8 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const PubRel) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }
    };

    pub const PubComp = struct {
        packet_identifier: u16,
        reason_code: PubCompReason,
        reason_string: ?[]const u8 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const PubComp) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }
    };

    pub const Disconnect = struct {
        reason_code: ReasonCode,
        reason_string: ?[]const u8 = null,
        // not sure this is ever set by the server
        session_expiry_interval: ?u32 = null,
        _user_properties: ?[]const u8 = null,

        pub fn userProperties(self: *const Disconnect) properties.UserPropertyIterator {
            return properties.UserPropertyIterator.init(self._user_properties orelse "");
        }

        pub const ReasonCode = enum(u8) {
            normal = 0,
            unspecified_error = 128,
            malformed_packet = 129,
            protocol_error = 130,
            implementation_specific_error = 131,
            not_authorized = 135,
            server_busy = 137,
            server_shutting_down = 139,
            keepalive_timeout = 141,
            session_taken_over = 142,
            topic_filter_invalid = 143,
            topic_name_invlaid = 144,
            receive_maximum_exceeded = 147,
            topic_alias_invalid = 148,
            packet_too_large = 149,
            message_rate_too_high = 150,
            quota_exceeded = 151,
            administrative_action = 152,
            payload_format_invalid = 153,
            retain_not_supported = 154,
            qos_not_supported = 155,
            use_another_server = 156,
            server_moved = 157,
            shared_subscriptions_not_supported = 158,
            connection_rate_exceeded = 159,
            maximum_connect_time = 160,
            subscription_identifiers_not_supported = 161,
            wildcard_subscriptions_not_supported = 162,
        };
    };

    pub fn decode(b1: u8, data: []u8, comptime protocol_version: ProtocolVersion) !Packet {
        // data.len has to be > 0
        // TODO: how to assert without std?
        const flags: u4 = @intCast(b1 & 15);
        switch (b1 >> 4) {
            2 => return .{ .connack = try decodeConnAck(data, flags, protocol_version) },
            3 => return .{ .publish = try decodePublish(data, flags, protocol_version) },
            4 => return .{ .puback = try decodePubAck(data, flags, protocol_version) },
            5 => return .{ .pubrec = try decodePubRec(data, flags, protocol_version) },
            6 => return .{ .pubrel = try decodePubRel(data, flags, protocol_version) },
            7 => return .{ .pubcomp = try decodePubComp(data, flags, protocol_version) },
            9 => return .{ .suback = try decodeSubAck(data, flags, protocol_version) },
            11 => return .{ .unsuback = try decodeUnsubAck(data, flags, protocol_version) },
            13 => return if (flags == 0) .{ .pong = {} } else error.InvalidFlags,
            14 => return .{ .disconnect = try decodeDisconnect(data, flags, protocol_version) },
            else => return error.UnknownPacketType, // TODO
        }
    }
};

pub const PartialPacket = union(enum) {
    connack: ConnAck,
    suback: SubAck,
    unsuback: UnsubAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    disconnect: Disconnect,
    pong: void,

    pub const ConnAck = struct {};

    pub const SubAck = struct {
        packet_identifier: u16,
    };

    pub const UnsubAck = struct {
        packet_identifier: u16,
    };

    pub const Publish = struct {
        dup: bool,
        qos: QoS,
        // not sure what this means in the context of a received message
        // maybe it's never set, or maybe it indicates that the server is publishing
        // a message which it retains?
        retain: bool,

        topic: []const u8,
        // null when qos is .at_least_once
        packet_identifier: ?u16,
    };

    pub const PubAck = struct {
        packet_identifier: u16,
    };

    pub const PubRec = struct {
        packet_identifier: u16,
    };

    pub const PubRel = struct {
        packet_identifier: u16,
    };

    pub const PubComp = struct {
        packet_identifier: u16,
    };

    pub const Disconnect = struct {};

    pub fn decode(b1: u8, data: []const u8) ?PartialPacket {
        // data.len has to be > 0
        // TODO: how to assert without std?
        const flags: u4 = @intCast(b1 & 15);
        switch (b1 >> 4) {
            2 => return .{ .connack = .{} },
            3 => return .{ .publish = decodePartialPublish(data, flags) orelse return null },
            4 => return .{ .puback = decodePartialPubAck(data, flags) orelse return null },
            5 => return .{ .pubrec = decodePartialPubRec(data, flags) orelse return null },
            6 => return .{ .pubrel = decodePartialPubRel(data, flags) orelse return null },
            7 => return .{ .pubcomp = decodePartialPubComp(data, flags) orelse return null },
            9 => return .{ .suback = decodePartialSubAck(data, flags) orelse return null },
            11 => return .{ .unsuback = decodePartialUnsubAck(data, flags) orelse return null },
            13 => if (flags == 0) return .{ .pong = {} } else return null,
            14 => return .{ .disconnect = .{} },
            else => return null, // TODO
        }
    }
};

fn decodeConnAck(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.ConnAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    const min_len: usize = if (comptime protocol_version == .mqtt_3_1_1) 2 else 3;
    if (data.len < min_len) {
        // MQTT 3.1.1: must have at least 2 bytes (ConnAck flag, Return Code)
        // MQTT 5.0: must have at least 3 bytes (ConnAck flag, Reason Code, Property Length)
        return error.IncompletePacket;
    }

    const session_present = switch (data[0]) {
        0 => false,
        1 => true,
        else => return error.MalformedPacket,
    };

    const reason_code: Packet.ConnAck.ReasonCode = switch (data[1]) {
        0 => .success,
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
        140 => .bad_authentication_method,
        144 => .topic_name_invalid,
        149 => .packet_too_large,
        151 => .quota_exceeded,
        153 => .payload_format_invalid,
        154 => .retain_not_supported,
        155 => .qos_not_supported,
        156 => .use_another_server,
        157 => .server_moved,
        159 => .connection_rate_exceeded,
        else => return error.InvalidReasonCode,
    };

    var connack = Packet.ConnAck{
        .session_present = session_present,
        .reason_code = reason_code,
    };

    // MQTT 5.0: read properties
    if (comptime protocol_version == .mqtt_5_0) {
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
                .user_properties => |v| {
                    if (connack._user_properties == null) {
                        connack._user_properties = v;
                    }
                },
                else => return error.InvalidProperty,
            }
        }
    }

    return connack;
}

fn decodeSubAck(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.SubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    const min_len: usize = if (comptime protocol_version == .mqtt_3_1_1) 3 else 4;
    if (data.len < min_len) {
        // MQTT 3.1.1: 2 for packet identifier, at least 1 for QoS byte
        // MQTT 5.0: 2 for packet identifier, at least 1 for property list, at least 1 for reason code
        return error.IncompletePacket;
    }

    var suback = Packet.SubAck{
        .packet_identifier = codec.readInt(u16, data[0..2]),
        .results = undefined,
    };

    var payload_offset: usize = 2;

    // MQTT 5.0: read properties
    if (comptime protocol_version == .mqtt_5_0) {
        var props = try PropertyReader.init(data[2..]);
        while (try props.next()) |prop| {
            switch (prop) {
                .reason_string => |v| suback.reason_string = v,
                .user_properties => |v| {
                    if (suback._user_properties == null) {
                        suback._user_properties = v;
                    }
                },
                else => return error.InvalidProperty,
            }
        }
        payload_offset = 2 + props.len;
    }

    // the rest of the packet is the payload, and the payload is 1 or more
    // 1 byte reason codes. 1 reason code per subscribed topic (in the same order)
    // So if you subscribed to 2 topics and want to know the result of the 2nd one
    // you would check suback.results[1], or better for an enum value: suback.result(1).
    suback.results = data[payload_offset..];
    return suback;
}
fn decodePartialSubAck(data: []const u8, flags: u4) ?PartialPacket.SubAck {
    if (flags != 0) {
        return null;
    }

    if (data.len < 4) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

fn decodeUnsubAck(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.UnsubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    const min_len: usize = if (comptime protocol_version == .mqtt_3_1_1) 2 else 4;
    if (data.len < min_len) {
        // MQTT 3.1.1: just 2 bytes for packet identifier (no payload)
        // MQTT 5.0: 2 for packet identifier, at least 1 for property list, at least 1 for reason code
        return error.IncompletePacket;
    }

    var unsuback = Packet.UnsubAck{
        .packet_identifier = codec.readInt(u16, data[0..2]),
        .results = undefined,
    };

    var payload_offset: usize = 2;

    // MQTT 5.0: read properties
    if (comptime protocol_version == .mqtt_5_0) {
        var props = try PropertyReader.init(data[2..]);
        while (try props.next()) |prop| {
            switch (prop) {
                .reason_string => |v| unsuback.reason_string = v,
                .user_properties => |v| {
                    if (unsuback._user_properties == null) {
                        unsuback._user_properties = v;
                    }
                },
                else => return error.InvalidProperty,
            }
        }
        payload_offset = 2 + props.len;
    }

    // MQTT 5.0: the rest of the packet is the payload with reason codes
    // MQTT 3.1.1: no payload (empty results)
    unsuback.results = data[payload_offset..];
    return unsuback;
}
fn decodePartialUnsubAck(data: []const u8, flags: u4) ?PartialPacket.UnsubAck {
    if (flags != 0) {
        return null;
    }

    if (data.len < 4) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

fn decodePublish(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.Publish {
    const min_len: usize = if (comptime protocol_version == .mqtt_3_1_1) 2 else 5;
    if (data.len < min_len) {
        // MQTT 3.1.1: 2 for topic length (empty topic + empty message)
        // MQTT 5.0: 2 for topic, 1 for property list, 2 for message
        return error.IncompletePacket;
    }

    const publish_flags: *codec.PublishFlags = @constCast(@ptrCast(&flags));

    const topic, var message_offset = try codec.readString(data);
    var publish = Packet.Publish{
        .dup = publish_flags.dup,
        .qos = publish_flags.qos,
        .retain = publish_flags.retain,
        .topic = topic,
        .message = undefined,
        .packet_identifier = null,
    };

    if (publish.qos != .at_most_once) {
        const packet_identifier_offset = message_offset;
        message_offset += 2;
        publish.packet_identifier = codec.readInt(u16, data[packet_identifier_offset..message_offset][0..2]);
    }

    // MQTT 5.0: read properties
    if (comptime protocol_version == .mqtt_5_0) {
        var props = try PropertyReader.init(data[message_offset..]);
        while (try props.next()) |prop| {
            switch (prop) {
                .payload_format => |v| publish.payload_format = v,
                .message_expiry_interval => |v| publish.message_expiry_interval = v,
                .topic_alias => |v| publish.topic_alias = v,
                .response_topic => |v| publish.response_topic = v,
                .correlation_data => |v| publish.correlation_data = v,
                .subscription_identifier => |v| publish.subscription_identifier = v,
                .content_type => |v| publish.content_type = v,
                .user_properties => |v| {
                    if (publish._user_properties == null) {
                        publish._user_properties = v;
                    }
                },
                else => return error.InvalidProperty,
            }
        }
        message_offset += props.len;
    }

    publish.message = data[message_offset..];
    return publish;
}
fn decodePartialPublish(data: []const u8, flags: u4) ?PartialPacket.Publish {
    if (data.len < 5) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    const publish_flags: *codec.PublishFlags = @constCast(@ptrCast(&flags));

    const topic, var properties_offset = codec.readString(data) catch {
        return null;
    };
    var publish = PartialPacket.Publish{
        .dup = publish_flags.dup,
        .qos = publish_flags.qos,
        .retain = publish_flags.retain,
        .topic = topic,
        .packet_identifier = null,
    };

    if (publish.qos != .at_most_once) {
        const packet_identifier_offset = properties_offset;
        properties_offset += 2;
        publish.packet_identifier = codec.readInt(u16, data[packet_identifier_offset..properties_offset][0..2]);
    }

    return publish;
}

fn decodePubAck(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.PubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const packet_identifier = codec.readInt(u16, data[0..2]);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    // MQTT 5.0: can be just packet identifier if reason code is success and no properties
    if (data.len == 2 or protocol_version == .mqtt_3_1_1) {
        return .{
            .reason_code = .success,
            .packet_identifier = packet_identifier,
        };
    }

    // MQTT 5.0: has reason code and properties
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
            .user_properties => |v| {
                if (puback._user_properties == null) {
                    puback._user_properties = v;
                }
            },
            else => return error.InvalidProperty,
        }
    }
    return puback;
}
fn decodePartialPubAck(data: []const u8, flags: u4) ?PartialPacket.PubAck {
    if (flags != 0) {
        return null;
    }

    if (data.len < 2) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

fn decodePubRec(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.PubRec {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const packet_identifier = codec.readInt(u16, data[0..2]);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    // MQTT 5.0: can be just packet identifier if reason code is success and no properties
    if (data.len == 2 or protocol_version == .mqtt_3_1_1) {
        return .{
            .reason_code = .success,
            .packet_identifier = packet_identifier,
        };
    }

    // MQTT 5.0: has reason code and properties
    const reason_code: PubRecReason = switch (data[2]) {
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

    var pubrec = Packet.PubRec{
        .packet_identifier = packet_identifier,
        .reason_code = reason_code,
    };

    var props = try PropertyReader.init(data[3..]);
    while (try props.next()) |prop| {
        switch (prop) {
            .reason_string => |v| pubrec.reason_string = v,
            .user_properties => |v| {
                if (pubrec._user_properties == null) {
                    pubrec._user_properties = v;
                }
            },
            else => return error.InvalidProperty,
        }
    }
    return pubrec;
}
fn decodePartialPubRec(data: []const u8, flags: u4) ?PartialPacket.PubRec {
    if (flags != 0) {
        return null;
    }

    if (data.len < 2) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

fn decodePubRel(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.PubRel {
    if (flags != 2) {
        // what's up with this? Why does this flag have to be 2??
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const packet_identifier = codec.readInt(u16, data[0..2]);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    // MQTT 5.0: can be just packet identifier if reason code is success and no properties
    if (data.len == 2 or protocol_version == .mqtt_3_1_1) {
        return .{
            .reason_code = .success,
            .packet_identifier = packet_identifier,
        };
    }

    // MQTT 5.0: has reason code and properties
    const reason_code: PubRelReason = switch (data[2]) {
        0 => .success,
        146 => .packet_identifier_not_found,
        else => return error.MalformedPacket,
    };

    var pubrel = Packet.PubRel{
        .packet_identifier = packet_identifier,
        .reason_code = reason_code,
    };

    var props = try PropertyReader.init(data[3..]);
    while (try props.next()) |prop| {
        switch (prop) {
            .reason_string => |v| pubrel.reason_string = v,
            .user_properties => |v| {
                if (pubrel._user_properties == null) {
                    pubrel._user_properties = v;
                }
            },
            else => return error.InvalidProperty,
        }
    }
    return pubrel;
}
fn decodePartialPubRel(data: []const u8, flags: u4) ?PartialPacket.PubRel {
    if (flags != 0) {
        return null;
    }

    if (data.len < 2) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

// If you've gotten this far and are thinking: does he plan on DRYing this stuff?
// The answer is [obviously]..apparently not.
fn decodePubComp(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.PubComp {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const packet_identifier = codec.readInt(u16, data[0..2]);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    // MQTT 5.0: can be just packet identifier if reason code is success and no properties
    if (data.len == 2 or protocol_version == .mqtt_3_1_1) {
        return .{
            .reason_code = .success,
            .packet_identifier = packet_identifier,
        };
    }

    // MQTT 5.0: has reason code and properties
    const reason_code: PubCompReason = switch (data[2]) {
        0 => .success,
        146 => .packet_identifier_not_found,
        else => return error.MalformedPacket,
    };

    var pubcomp = Packet.PubComp{
        .packet_identifier = packet_identifier,
        .reason_code = reason_code,
    };

    var props = try PropertyReader.init(data[3..]);
    while (try props.next()) |prop| {
        switch (prop) {
            .reason_string => |v| pubcomp.reason_string = v,
            .user_properties => |v| {
                if (pubcomp._user_properties == null) {
                    pubcomp._user_properties = v;
                }
            },
            else => return error.InvalidProperty,
        }
    }
    return pubcomp;
}
fn decodePartialPubComp(data: []const u8, flags: u4) ?PartialPacket.PubComp {
    if (flags != 0) {
        return null;
    }

    if (data.len < 2) {
        // must have at least 4 bytes
        // 2 for the packet identifier
        // at least 1 for a 0-length property list
        // at least 1 for 1 reason code in the body
        return null;
    }
    return .{ .packet_identifier = codec.readInt(u16, data[0..2]) };
}

fn decodeDisconnect(data: []u8, flags: u4, comptime protocol_version: ProtocolVersion) !Packet.Disconnect {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    // MQTT 3.1.1: DISCONNECT has no variable header (data.len == 0)
    if (comptime protocol_version == .mqtt_3_1_1) {
        return .{ .reason_code = .normal };
    }

    // MQTT 5.0: has reason code and properties
    if (data.len < 2) {
        // 1 for reason code
        // 1 for 0 length properties
        return error.IncompletePacket;
    }

    const reason_code: Packet.Disconnect.ReasonCode = switch (data[0]) {
        0 => .normal,
        128 => .unspecified_error,
        129 => .malformed_packet,
        130 => .protocol_error,
        131 => .implementation_specific_error,
        135 => .not_authorized,
        137 => .server_busy,
        139 => .server_shutting_down,
        141 => .keepalive_timeout,
        142 => .session_taken_over,
        143 => .topic_filter_invalid,
        144 => .topic_name_invlaid,
        147 => .receive_maximum_exceeded,
        148 => .topic_alias_invalid,
        149 => .packet_too_large,
        150 => .message_rate_too_high,
        151 => .quota_exceeded,
        152 => .administrative_action,
        153 => .payload_format_invalid,
        154 => .retain_not_supported,
        155 => .qos_not_supported,
        156 => .use_another_server,
        157 => .server_moved,
        158 => .shared_subscriptions_not_supported,
        159 => .connection_rate_exceeded,
        160 => .maximum_connect_time,
        161 => .subscription_identifiers_not_supported,
        162 => .wildcard_subscriptions_not_supported,
        else => return error.InvalidReasonCode,
    };

    var disconnect = Packet.Disconnect{
        .reason_code = reason_code,
    };

    var props = try PropertyReader.init(data[1..]);
    while (try props.next()) |prop| {
        switch (prop) {
            .reason_string => |v| disconnect.reason_string = v,
            .session_expiry_interval => |v| disconnect.session_expiry_interval = v,
            .user_properties => |v| {
                if (disconnect._user_properties == null) {
                    disconnect._user_properties = v;
                }
            },
            else => return error.InvalidProperty,
        }
    }

    return disconnect;
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
            16, // packet type
            13, // payload length
            0, 4, 'M', 'Q', 'T', 'T', // protocol name
            5, // protocol version
            2, // connect flags (0, 0, 0, 0, 0, 0, 1, 0)
            0, 0, // keepalive sec
            0, // properties length
            0,
            0, // client_id length
        });
    }

    {
        // more advanced connect call
        ctx.reset();
        try client.connect(&ctx, .{ .client_id = "the-client", .username = "the-username", .password = "the-passw0rd", .will = .{
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
        }, .keepalive_sec = 300, .session_expiry_interval = 20, .receive_maximum = 300, .maximum_packet_size = 4000, .user_properties = &.{
            .{ .key = "k1", .value = "value-1" },
            .{ .key = "key-2", .value = "v2" },
        } });
        try ctx.expectWritten(1, &.{
            16, // packet type
            166, 1, // payload length
            0, 4, 'M', 'Q', 'T', 'T', // protocol name
            5, // protocol version
            246, // connect flags (1, 1, 1, 1, 0, 1, 1, 0)
            //               the last 0 is reserved, the middle 0 comes from the "2" (1, 0) of the will qos.
            1, 44, // keepalive sec
            39, // properties length
            17, 0, 0, 0, 20, // session expiry interval property
            33, 1, 44, // receive maximum property
            39,  0,   0,   15,  160, // maximum packet size interval property
            38,  0,   2,   'k', '1',
            0,   7,   'v', 'a', 'l',
            'u', 'e', '-', '1', 38,
            0,   5,   'k', 'e', 'y',
            '-', '2', 0,   2,   'v',
            '2',

            // payload
            0,   10, // client_id length
            't', 'h',
            'e', '-',
            'c', 'l',
            'i', 'e',
            'n',
            't',

            // WILL properties
            51, // will length
            0x18, 0x00, 0x0E, 0x7A, 0x58, // delay interval
            0x01, 0x01, // payload_format
            0x02, 0x0D, 0x74, 0xF3, 0xC8, // message_expiry_interval

            // text values have a 2 byte length prefix after the identifier
            0x03, 0x00, 0x09, 't',  'e',
            's',  't',  '/',  't',  'y',
            'p',  'e',  0x08, 0x00, 0x0A,
            't',  'e',  's',  't',  '-',
            't',  'o',  'p',  'i',  'c',
            0x09, 0x00, 0x0B, 'o',  'v',
            'e',  'r',  ' ',  '9',  '0',
            '0',  '0',  '!',  '!',
            0, 9,   // topic length,
            't', 'h', 'e', ' ', 't', 'o', 'p', 'i', 'c',
            0, 11,   // message length,
            't', 'h', 'e', ' ', 'm', 'e', 's', 's', 'a', 'g', 'e',
            0,   12, // username length
            't', 'h',
            'e', '-',
            'u', 's',
            'e', 'r',
            'n', 'a',
            'm', 'e',
            0,   12, // password length
            't', 'h',
            'e', '-',
            'p', 'a',
            's', 's',
            'w', '0',
            'r', 'd',
        });
    }
}

test "Client: subscribe" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // empty topic
        try t.expectError(error.Usage, client.subscribe(&ctx, .{ .topics = &.{} }));
        try t.expectEqualSlices(u8, "must have at least 1 topic", client.last_error.?.details);
    }

    {
        const pi = try client.subscribe(&ctx, .{
            .packet_identifier = 10,
            .topics = &.{.{ .filter = "topic1" }}, // always need 1 topic
        });

        try t.expectEqual(10, pi);

        try ctx.expectWritten(1, &.{
            130, // packet type (1000 0010)  (8 for the packet type, and 2 for the flag, the flag is always 2)
            12, // payload length
            0, 10, // packet identifier
            0, // property length
            0,
            6,
            't',
            'o',
            'p',
            'i',
            'c',
            '1',
            36, // subscription options
        });
    }
}

test "Client: unsubscribe" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // empty topic
        try t.expectError(error.Usage, client.unsubscribe(&ctx, .{ .topics = &.{} }));
        try t.expectEqualSlices(u8, "must have at least 1 topic", client.last_error.?.details);
    }

    {
        const pi = try client.unsubscribe(&ctx, .{
            .packet_identifier = 10,
            .topics = &.{"topic11!"}, // always need 1 topic
        });

        try t.expectEqual(10, pi);

        try ctx.expectWritten(1, &.{
            162, // packet type (1010 0010)  (10 for the packet type, and 2 for the flag, the flag is always 2)
            13, // payload length
            0, 10, // packet identifier
            0, // property length
            0,
            8,
            't',
            'o',
            'p',
            'i',
            'c',
            '1',
            '1',
            '!',
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
        try t.expectError(error.Usage, client.publish(&ctx, .{ .retain = true, .topic = "", .message = "" }));
        try t.expectEqualSlices(u8, "server does not support retained messages", client.last_error.?.details);
    }

    {
        // can't publish wih higher QoS than server supports
        // (the server should treat this as an error, so we might as well catch it in the library)
        client.server_max_qos = @intFromEnum(QoS.at_most_once);
        try t.expectError(error.Usage, client.publish(&ctx, .{ .qos = .at_least_once, .topic = "", .message = "" }));
        try t.expectEqualSlices(u8, "server does not support this level of QoS", client.last_error.?.details);
    }

    {
        // publish qos = .at_least_once (no packet identifier)
        ctx.reset();
        const pi = try client.publish(&ctx, .{
            .packet_identifier = 20,
            .topic = "power/goku",
            .message = "over 9000!!",
        });

        try t.expectEqual(null, pi);

        try ctx.expectWritten(1, &.{
            48, // packet type (0011 0000)  (3 for the packet type, 0 since no flag is set)
            24, // payload length
            0,
            10,
            'p',
            'o',
            'w',
            'e',
            'r',
            '/',
            'g',
            'o',
            'k',
            'u',
            0, // property length
            'o',
            'v',
            'e',
            'r',
            ' ',
            '9',
            '0',
            '0',
            '0',
            '!',
            '!', // payload (the message)
        });
    }

    {
        // full
        ctx.reset();
        client.server_can_retain = true;
        const pi = try client.publish(&ctx, .{ .packet_identifier = 30, .topic = "t1", .message = "m2z", .dup = true, .qos = .exactly_once, .retain = true, .payload_format = .utf8, .message_expiry_interval = 10 });

        try t.expectEqual(30, pi);

        try ctx.expectWritten(1, &.{
            61, // packet type (0011 1 10 1)  (3 for the packet type, 1 for dup, 2 for qos, 1 for retain)
            17, // payload length
            0,
            2,
            't',
            '1',
            0, 30, // packet identifier
            7, // property length
            1, 1, //payload format
            2, 0, 0, 0, 10, // message expiry interval
            'm', '2', 'z', // payload (the message)
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
        try client.puback(&ctx, .{ .packet_identifier = 5 });

        try ctx.expectWritten(1, &.{
            64, // packet type (0100 0000)  (4 for the packet type, 0 for flags)
            2, // payload length
            0,
            5, // packet identifier
        });
    }

    {
        // puback with non-success reason code
        ctx.reset();
        try client.puback(&ctx, .{ .packet_identifier = 1, .reason_code = .quota_exceeded });

        try ctx.expectWritten(1, &.{
            64, // packet type (0100 0000)  (4 for the packet type, 0 for flags)
            4, // payload length
            0, 1, // packet identifier
            151, // reason code
            0, // properties length
        });
    }

    {
        // puback with properties
        ctx.reset();
        try client.puback(&ctx, .{ .packet_identifier = 1, .reason_string = "ok" });

        try ctx.expectWritten(1, &.{
            64, // packet type (0100 0000)  (4 for the packet type, 0 for flags)
            9, // payload length
            0, 1, // packet identifier
            0, // reason code
            5, // properties length
            31,
            0,
            2,
            'o',
            'k',
        });
    }
}

test "Client: pubrec" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // pubrec special short (success with no properties)
        ctx.reset();
        try client.pubrec(&ctx, .{ .packet_identifier = 5 });

        try ctx.expectWritten(1, &.{
            80, // packet type (0101 0000)  (5 for the packet type, 0 for flags)
            2, // payload length
            0,
            5, // packet identifier
        });
    }

    {
        // pubrec with non-success reason code
        ctx.reset();
        try client.pubrec(&ctx, .{ .packet_identifier = 1, .reason_code = .quota_exceeded });

        try ctx.expectWritten(1, &.{
            80, // packet type (0101 0000)  (5 for the packet type, 0 for flags)
            4, // payload length
            0, 1, // packet identifier
            151, // reason code
            0, // properties length
        });
    }

    {
        // pubrec with properties
        ctx.reset();
        try client.pubrec(&ctx, .{ .packet_identifier = 1, .reason_string = "ok" });

        try ctx.expectWritten(1, &.{
            80, // packet type (0101 0000)  (5 for the packet type, 0 for flags)
            9, // payload length
            0, 1, // packet identifier
            0, // reason code
            5, // properties length
            31,
            0,
            2,
            'o',
            'k',
        });
    }
}

test "Client: pubrel" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // pubrel special short (success with no properties)
        ctx.reset();
        try client.pubrel(&ctx, .{ .packet_identifier = 5 });

        try ctx.expectWritten(1, &.{
            98, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            2, // payload length
            0,
            5, // packet identifier
        });
    }

    {
        // pubrel with non-success reason code
        ctx.reset();
        try client.pubrel(&ctx, .{ .packet_identifier = 1, .reason_code = .packet_identifier_not_found });

        try ctx.expectWritten(1, &.{
            98, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            4, // payload length
            0, 1, // packet identifier
            146, // reason code
            0, // properties length
        });
    }

    {
        // pubrel with properties
        ctx.reset();
        try client.pubrel(&ctx, .{ .packet_identifier = 1, .reason_string = "ok" });

        try ctx.expectWritten(1, &.{
            98, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            9, // payload length
            0, 1, // packet identifier
            0, // reason code
            5, // properties length
            31,
            0,
            2,
            'o',
            'k',
        });
    }
}

test "Client: pubcomp" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // pubcomp special short (success with no properties)
        ctx.reset();
        try client.pubcomp(&ctx, .{ .packet_identifier = 5 });

        try ctx.expectWritten(1, &.{
            112, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            2, // payload length
            0,
            5, // packet identifier
        });
    }

    {
        // pubcomp with non-success reason code
        ctx.reset();
        try client.pubcomp(&ctx, .{ .packet_identifier = 1, .reason_code = .packet_identifier_not_found });

        try ctx.expectWritten(1, &.{
            112, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            4, // payload length
            0, 1, // packet identifier
            146, // reason code
            0, // properties length
        });
    }

    {
        // pubcomp with properties
        ctx.reset();
        try client.pubcomp(&ctx, .{ .packet_identifier = 1, .reason_string = "ok" });

        try ctx.expectWritten(1, &.{
            112, // packet type (0100 0020)  (6 for the packet type, 2 for flags)
            9, // payload length
            0, 1, // packet identifier
            0, // reason code
            5, // properties length
            31,
            0,
            2,
            'o',
            'k',
        });
    }
}

test "Client: disconnect" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;
    {
        // basic
        try client.disconnect(&ctx, .{ .reason = .normal });
        try ctx.expectWritten(1, &.{
            224, // packet type
            2, // payload length
            0, // reason
            0, // property length
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
            224, // packet type
            18, // payload length
            150, // reason
            16, // property length
            0x11, 0x00, 0x0f, 0x42, 0x3e, //sessione expiry interval
            0x1f, 0x00, 0x08, 't',  'e',
            'a',  ' ',  't',  'i',  'm',
            'e',
        });
    }
}

test "Client: ping" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;
    {
        try client.ping(&ctx);
        try ctx.expectWritten(1, &.{
            192, // packet type
            0, // payload length
        });
    }
}

test "Client: readPacket close" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    ctx.reset();
    // the way our test client works is that if we try to read more data then
    // we've setup, it return 0 (0 bytes read), which should mean closed.
    ctx.reply(&.{ 32, 10, 0, 0, 7 });

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
            144, 5, 1, 3, 0, 0, 1, // suback with 2 response codes
            144, 252, 1, 0, 2, 0, // suback with 0 properties and...
            // 249 response codes..we want to test packets that push the limit of our buffer
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0, 0, 0, 0,
            0,   0,   0,
        });

        var client = &ctx.client;
        const connack = (try client.readPacket(&ctx)).?.connack;
        try t.expectEqualSlices(u8, "none", connack.authentication_method.?);

        const suback1 = (try client.readPacket(&ctx)).?.suback;
        try t.expectEqual(259, suback1.packet_identifier);
        try t.expectEqualSlices(u8, &.{ 0, 1 }, suback1.results);

        const suback2 = (try client.readPacket(&ctx)).?.suback;
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
        ctx.reply(&.{ 32, 3, 0, 133, 0 });
        const connack = (try client.readPacket(&ctx)).?.connack;
        try t.expectEqual(.client_identifier_not_valid, connack.reason_code);
    }

    {
        // return with invalid reason code
        ctx.reset();
        ctx.reply(&.{ 32, 3, 0, 100, 0 });
        try t.expectError(error.Protocol, client.readPacket(&ctx));
        try t.expectEqual(error.InvalidReasonCode, client.last_error.?.inner);
    }

    {
        // session_present = true
        // (this is currently always invalid, since we force clean_start = true)
        ctx.reset();
        ctx.reply(&.{ 32, 3, 1, 0, 0 });
        try t.expectError(error.Protocol, client.readPacket(&ctx));
        try t.expectEqual("connack indicated the presence of a session despite requesting clean_start", client.last_error.?.details);
    }

    {
        // success, basic reply
        // session_present = false
        // reason code = 0
        // 0 properties
        ctx.reset();
        ctx.reply(&.{ 32, 3, 0, 0, 0 });

        const connack = (try client.readPacket(&ctx)).?.connack;

        // the default if the server doesn't send up a retain_available property
        try t.expectEqual(true, client.server_can_retain);

        try t.expectEqual(false, connack.session_present);
        try t.expectEqual(.success, connack.reason_code);
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
        ctx.reply(&.{ 32, 8, 0, 0, 5, 19, 0, 60, 37, 0 });

        const connack = (try client.readPacket(&ctx)).?.connack;

        // server told us it won't/can't retain
        try t.expectEqual(false, client.server_can_retain);

        try t.expectEqual(false, connack.session_present);
        try t.expectEqual(.success, connack.reason_code);
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

        try t.expectEqualSlices(u8, &.{ 32, 8, 0, 0, 5, 19, 0, 60, 37, 0 }, client.lastReadPacket());
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
        ctx.reply(&.{ 145, 4, 0, 0, 0, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
        try t.expectEqual(error.InvalidFlags, client.last_error.?.inner);
    }

    {
        // wrong packet type
        ctx.reset();
        ctx.reply(&.{ 7, 3, 0, 0, 0 });
        try t.expectError(error.Protocol, client.readPacket(&ctx));
    }

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 144, 3, 0, 0, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // basic response
        ctx.reset();
        ctx.reply(&.{ 144, 4, 1, 2, 0, 1 });
        const suback = (try client.readPacket(&ctx)).?.suback;
        try t.expectEqual(258, suback.packet_identifier);
        try t.expectEqual(null, suback.reason_string);
        try t.expectEqualSlices(u8, &.{1}, suback.results);
        try t.expectEqual(.at_least_once, try suback.result(0));
    }

    {
        // multi-topic response
        ctx.reset();
        ctx.reply(&.{
            144,
            11,
            0, 1, // packet identifier
            5, // property length
            31, 0, 2, 'o', 'k', // reason
            2, 135, 4, // 3 reasons
        });
        const suback = (try client.readPacket(&ctx)).?.suback;
        try t.expectEqual(1, suback.packet_identifier);
        try t.expectEqualSlices(u8, "ok", suback.reason_string.?);
        try t.expectEqualSlices(u8, &.{ 2, 135, 4 }, suback.results);
        try t.expectEqual(.exactly_once, try suback.result(0));
        try t.expectError(error.NotAuthorized, suback.result(1));
    }
}

test "Client: readPacket unsuback" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        ctx.reset();
        // return with invalid packet flags
        // first byte should always be 176. 178 means that the flags were improperly
        // set (they should always be 0 for unsuback)
        ctx.reply(&.{ 178, 4, 0, 0, 0, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
        try t.expectEqual(error.InvalidFlags, client.last_error.?.inner);
    }

    {
        // short packet (must be at least 6 bytes)
        ctx.reset();
        ctx.reply(&.{ 176, 3, 0, 0, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // basic response
        ctx.reset();
        ctx.reply(&.{ 176, 4, 2, 2, 0, 0 });
        const unsuback = (try client.readPacket(&ctx)).?.unsuback;
        try t.expectEqual(514, unsuback.packet_identifier);
        try t.expectEqual(null, unsuback.reason_string);
        try t.expectEqualSlices(u8, &.{0}, unsuback.results);
        try unsuback.result(0); // returns void on success
    }

    {
        // multi-topic response
        ctx.reset();
        ctx.reply(&.{
            176,
            11,
            0, 1, // packet identifier
            5, // property length
            31, 0, 2, 'o', 'k', // reason
            2, 135, 17, // 3 reasons
        });
        const unsuback = (try client.readPacket(&ctx)).?.unsuback;
        try t.expectEqual(1, unsuback.packet_identifier);
        try t.expectEqualSlices(u8, "ok", unsuback.reason_string.?);
        try t.expectEqualSlices(u8, &.{ 2, 135, 17 }, unsuback.results);
        try t.expectError(error.Protocol, unsuback.result(0));
        try t.expectError(error.NotAuthorized, unsuback.result(1));
        try t.expectError(error.NoSubscriptionExisted, unsuback.result(2));
    }
}

test "Client: readPacket publish" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 48, 4, 0, 0, 0, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // qos = at_most_once (won't have property identifier)
        ctx.reset();
        ctx.reply(&.{
            48,
            11,
            0, 3, 'a', '/', 'b', // topic
            0, // property list length
            'h',
            'e',
            'l',
            'l',
            'o', // payload (message)
        });
        const publish = (try client.readPacket(&ctx)).?.publish;
        try t.expectEqual(.at_most_once, publish.qos);
        try t.expectEqual(false, publish.dup);
        try t.expectEqual(false, publish.retain);
        try t.expectEqual(null, publish.packet_identifier);
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

    {
        // qos = at_least_once (with property identifier)
        ctx.reset();
        ctx.reply(&.{
            50,
            13,
            0, 3, 'a', '/', 'b', // topic
            10, 1, // packet identifier
            0, // property list length
            'h',
            'e',
            'l',
            'l',
            'o', // payload (message)
        });
        const publish = (try client.readPacket(&ctx)).?.publish;
        try t.expectEqual(.at_least_once, publish.qos);
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

    {
        // too long
        var buf: [512]u8 = undefined;
        const msg = try codec.encodePublish(&buf, .mqtt_5_0, 9001, .{
            .topic = "hi",
            .qos = .at_least_once,
            .message = "a" ** 300,
        });
        ctx.reset();
        ctx.reply(msg);
        try t.expectError(error.ReadBufferIsFull, client.readPacket(&ctx));
        const publish = client.lastPartialPacket().?.publish;
        try t.expectEqual(9001, publish.packet_identifier.?);
    }
}

test "Client: readPacket puback" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 64, 1, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            64,
            2,
            10, 2, // packet identifier
        });
        const puback = (try client.readPacket(&ctx)).?.puback;
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
            0, 3, // packet identifier
            135, // reason code
            7, // properties length
            31,
            0,
            4,
            'n',
            'o',
            'p',
            'e',
        });
        const puback = (try client.readPacket(&ctx)).?.puback;
        try t.expectEqual(3, puback.packet_identifier);
        try t.expectEqual(.not_authorized, puback.reason_code);
        try t.expectEqualSlices(u8, "nope", puback.reason_string.?);
    }
}

test "Client: readPacket pubrec" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 80, 1, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            80,
            2,
            10, 2, // packet identifier
        });
        const pubrec = (try client.readPacket(&ctx)).?.pubrec;
        try t.expectEqual(2562, pubrec.packet_identifier);
        try t.expectEqual(.success, pubrec.reason_code);
        try t.expectEqual(null, pubrec.reason_string);
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            80,
            11,
            0, 3, // packet identifier
            135, // reason code
            7, // properties length
            31,
            0,
            4,
            'n',
            'o',
            'p',
            'e',
        });
        const pubrec = (try client.readPacket(&ctx)).?.pubrec;
        try t.expectEqual(3, pubrec.packet_identifier);
        try t.expectEqual(.not_authorized, pubrec.reason_code);
        try t.expectEqualSlices(u8, "nope", pubrec.reason_string.?);
    }
}

test "Client: readPacket pubrel" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 98, 1, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            98,
            2,
            10, 2, // packet identifier
        });
        const pubrel = (try client.readPacket(&ctx)).?.pubrel;
        try t.expectEqual(2562, pubrel.packet_identifier);
        try t.expectEqual(.success, pubrel.reason_code);
        try t.expectEqual(null, pubrel.reason_string);
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            98,
            11,
            0, 3, // packet identifier
            146, // reason code
            7, // properties length
            31,
            0,
            4,
            'n',
            'o',
            'p',
            'e',
        });
        const pubrel = (try client.readPacket(&ctx)).?.pubrel;
        try t.expectEqual(3, pubrel.packet_identifier);
        try t.expectEqual(.packet_identifier_not_found, pubrel.reason_code);
        try t.expectEqualSlices(u8, "nope", pubrel.reason_string.?);
    }
}

test "Client: readPacket pubcomp" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // short packet
        ctx.reset();
        ctx.reply(&.{ 112, 1, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            112,
            2,
            10, 2, // packet identifier
        });
        const pubcomp = (try client.readPacket(&ctx)).?.pubcomp;
        try t.expectEqual(2562, pubcomp.packet_identifier);
        try t.expectEqual(.success, pubcomp.reason_code);
        try t.expectEqual(null, pubcomp.reason_string);
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{
            112,
            11,
            0, 3, // packet identifier
            146, // reason code
            7, // properties length
            31,
            0,
            4,
            'n',
            'o',
            'p',
            'e',
        });
        const pubcomp = (try client.readPacket(&ctx)).?.pubcomp;
        try t.expectEqual(3, pubcomp.packet_identifier);
        try t.expectEqual(.packet_identifier_not_found, pubcomp.reason_code);
        try t.expectEqualSlices(u8, "nope", pubcomp.reason_string.?);
    }
}

test "Client: readPacket pong" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // wrong flags
        ctx.reset();
        ctx.reply(&.{ 211, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // special short response
        ctx.reset();
        ctx.reply(&.{ 208, 0 });
        try t.expectEqual(true, (try client.readPacket(&ctx)).? == .pong);
    }
}

test "Client: readPacket disconnect" {
    var ctx = TestContext.init();
    defer ctx.deinit();

    var client = &ctx.client;

    {
        // wrong flags
        ctx.reset();
        ctx.reply(&.{ 225, 0 });
        try t.expectError(error.MalformedPacket, client.readPacket(&ctx));
    }

    {
        // short response
        ctx.reset();
        ctx.reply(&.{ 224, 2, 0, 0 });
        const disconnect = (try client.readPacket(&ctx)).?.disconnect;
        try t.expectEqual(.normal, disconnect.reason_code);
        try t.expectEqual(null, disconnect.reason_string);

        var it = disconnect.userProperties();
        try t.expectEqual(null, it.next());
    }

    {
        // with user properties
        ctx.reset();
        ctx.reply(&.{
            224,
            27, // length
            135, // reason code
            25, // properties length
            38, 0, 1, 'a', 0, 3, '1', '2', '3', // one user property
            31, 0, 3, 'b', 'y', 'e', // reason string
            38, 0, 3, 'a', 'b', 'c',
            0, 2, 'z', '!', // another user porperty
        });
        const disconnect = (try client.readPacket(&ctx)).?.disconnect;
        try t.expectEqual(.not_authorized, disconnect.reason_code);
        try t.expectEqualSlices(u8, "bye", disconnect.reason_string.?);

        var it = disconnect.userProperties();
        {
            const up = it.next().?;
            try t.expectEqualSlices(u8, "a", up.key);
            try t.expectEqualSlices(u8, "123", up.value);
        }

        {
            const up = it.next().?;
            try t.expectEqualSlices(u8, "abc", up.key);
            try t.expectEqualSlices(u8, "z!", up.value);
        }

        try t.expectEqual(null, it.next());
    }
}

const TestContext = struct {
    arena: *std.heap.ArenaAllocator,
    to_read_pos: usize,
    to_read: std.ArrayList(u8),
    written: std.ArrayList(u8),
    write_count: usize,
    close_count: usize,
    _random: ?std.Random.DefaultPrng = null,
    client: Mqtt5(TestContext),

    const std = @import("std");

    fn init() TestContext {
        const arena = t.allocator.create(std.heap.ArenaAllocator) catch unreachable;
        arena.* = std.heap.ArenaAllocator.init(t.allocator);

        const allocator = arena.allocator();

        const read_buf = allocator.alloc(u8, 256) catch unreachable;
        const write_buf = allocator.alloc(u8, 256) catch unreachable;

        return .{
            .arena = arena,
            .to_read_pos = 0,
            .to_read = .empty,
            .written = .empty,
            .write_count = 0,
            .close_count = 0,
            .client = Mqtt5(TestContext).init(read_buf, write_buf),
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

        self.client.server_can_retain = true;
        self.client.server_max_qos = @intFromEnum(QoS.exactly_once);
    }

    fn reply(self: *TestContext, data: []const u8) void {
        const arena = self.arena.allocator();
        self.to_read.appendSlice(arena, arena.dupe(u8, data) catch unreachable) catch unreachable;
    }

    const MqttPlatform = struct {
        fn read(self: *TestContext, buf: []u8, _: usize) !?usize {
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
            const arena = self.arena.allocator();
            try self.written.appendSlice(arena, data);
            self.write_count += 1;
        }

        fn close(self: *TestContext) void {
            self.close_count += 1;
        }
    };

    fn random(self: *TestContext) std.Random {
        if (self._random == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            self._random = std.Random.DefaultPrng.init(seed);
        }
        return self._random.?.random();
    }

    fn expectWritten(self: *TestContext, count: usize, data: []const u8) !void {
        try t.expectEqual(count, self.write_count);
        try t.expectEqualSlices(u8, data, self.written.items);
    }
};
