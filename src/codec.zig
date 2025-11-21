const mqttz = @import("mqtt.zig");
const properties = @import("properties.zig");

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

// Error for using MQTT 5.0 properties with strict MQTT 3.1.1
pub const Mqtt311Error = error{
    UnsupportedPropertyForMqtt311,
};

// I hate varints.
pub fn writeVarint(buf: []u8, len: usize) usize {
    var i: usize = 0;
    var remaining_len = len;
    while (true) : (i += 1) {
        const b: u8 = @intCast(remaining_len & 0x7F);
        if (remaining_len <= 127) {
            buf[i] = b;
            return i + 1;
        }
        buf[i] = b | 0x80;
        remaining_len = remaining_len >> 7;
    }
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

// This returns the varint value (if we have one) AND the length of the varint
pub fn readVarint(buf: []const u8) error{InvalidVarint}!?struct { usize, usize } {
    if (buf.len == 0) {
        return null;
    }

    if (buf[0] < 128) {
        return .{ @as(usize, @intCast(buf[0])), 1 };
    }

    if (buf.len == 1) {
        return null;
    }

    var total: usize = buf[0] & 0x7f;
    if (buf[1] < 128) {
        return .{ total + @as(usize, buf[1]) * 128, 2 };
    }

    if (buf.len == 2) {
        return null;
    }
    total += (@as(usize, buf[1]) & 0x7f) * 128;
    if (buf[2] < 128) {
        return .{ total + @as(usize, buf[2]) * 16_384, 3 };
    }

    if (buf.len == 3) {
        return null;
    }
    total += (@as(usize, buf[2]) & 0x7f) * 16_384;
    if (buf[3] < 128) {
        return .{ total + @as(usize, buf[3]) * 2_097_152, 4 };
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

pub inline fn writeInt(comptime T: type, buf: *[@divExact(@typeInfo(T).int.bits, 8)]u8, value: T) void {
    buf.* = @bitCast(if (native_endian == .big) value else @byteSwap(value));
}

pub inline fn readInt(comptime T: type, buf: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    const value: T = @bitCast(buf.*);
    return if (native_endian == .big) value else @byteSwap(value);
}

pub fn readString(buf: []const u8) error{InvalidString}!struct { []const u8, usize } {
    if (buf.len < 2) {
        return error.InvalidString;
    }
    const len = readInt(u16, buf[0..2]);
    const end = len + 2;
    if (buf.len < end) {
        return error.InvalidString;
    }
    return .{ buf[2..end], end };
}

// Validation functions for strict MQTT 3.1.1 mode
fn validateConnectOptsFor311(opts: mqttz.ConnectOpts) Mqtt311Error!void {
    if (opts.session_expiry_interval != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.receive_maximum != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.maximum_packet_size != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;

    if (opts.will) |will| {
        if (will.delay_interval != null) return error.UnsupportedPropertyForMqtt311;
        if (will.payload_format != null) return error.UnsupportedPropertyForMqtt311;
        if (will.message_expiry_interval != null) return error.UnsupportedPropertyForMqtt311;
        if (will.content_type != null) return error.UnsupportedPropertyForMqtt311;
        if (will.response_topic != null) return error.UnsupportedPropertyForMqtt311;
        if (will.correlation_data != null) return error.UnsupportedPropertyForMqtt311;
    }
}

fn validateDisconnectOptsFor311(opts: mqttz.DisconnectOpts) Mqtt311Error!void {
    // In MQTT 3.1.1, DISCONNECT has no variable header, so all fields are 5.0 only
    // Check if any MQTT 5.0 properties are set
    if (opts.reason != .normal) return error.UnsupportedPropertyForMqtt311;
    if (opts.session_expiry_interval != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.reason_string != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

fn validateSubscribeOptsFor311(opts: mqttz.SubscribeOpts) Mqtt311Error!void {
    if (opts.subscription_identifier != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;

    for (opts.topics) |topic| {
        // In 3.1.1, these options don't exist (only QoS exists)
        if (topic.no_local != true) return error.UnsupportedPropertyForMqtt311;
        if (topic.retain_as_published != false) return error.UnsupportedPropertyForMqtt311;
        if (topic.retain_handling != .do_not_send_retained) return error.UnsupportedPropertyForMqtt311;
    }
}

fn validatePublishOptsFor311(opts: mqttz.PublishOpts) Mqtt311Error!void {
    if (opts.payload_format != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.message_expiry_interval != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.topic_alias != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.response_topic != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.correlation_data != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.subscription_identifier != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.content_type != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

fn validatePubAckOptsFor311(opts: mqttz.PubAckOpts) Mqtt311Error!void {
    if (opts.reason_string != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

fn validatePubRecOptsFor311(opts: mqttz.PubRecOpts) Mqtt311Error!void {
    if (opts.reason_string != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

fn validatePubRelOptsFor311(opts: mqttz.PubRelOpts) Mqtt311Error!void {
    if (opts.reason_string != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

fn validatePubCompOptsFor311(opts: mqttz.PubCompOpts) Mqtt311Error!void {
    if (opts.reason_string != null) return error.UnsupportedPropertyForMqtt311;
    if (opts.user_properties != null) return error.UnsupportedPropertyForMqtt311;
}

pub fn encodeConnect(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.ConnectOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validateConnectOptsFor311(opts);
    }

    var connect_flags = packed struct(u8) {
        _reserved: bool = false,
        clean_start: bool = true,
        will: bool = false,
        will_qos: mqttz.QoS = .at_most_once,
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
    buf[6] = 4; // length of string, 4: MQTT
    buf[7] = 'M';
    buf[8] = 'Q';
    buf[9] = 'T';
    buf[10] = 'T';

    buf[11] = protocol_version.byte();

    buf[12] = @bitCast(connect_flags);

    writeInt(u16, buf[13..15], opts.keepalive_sec);

    // everything above is safe, since buf is at least MIN_BUF_SIZE.

    const PROPERTIES_OFFSET = 15;
    const properties_len = if (comptime protocol_version == .mqtt_5_0)
        try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.CONNECT)
    else
        0; // MQTT 3.1.1 has no properties

    // Start payload
    var pos: usize = PROPERTIES_OFFSET + properties_len;
    pos += try writeString(buf[pos..], opts.client_id orelse "");

    if (opts.will) |will| {
        pos += if (comptime protocol_version == .mqtt_5_0)
            try properties.write(buf[pos..], will, &properties.WILL)
        else
            0; // MQTT 3.1.1 has no will properties
        pos += try writeString(buf[pos..], will.topic);
        pos += try writeString(buf[pos..], will.message);
    }

    if (opts.username) |u| {
        pos += try writeString(buf[pos..], u);
    }

    if (opts.password) |p| {
        pos += try writeString(buf[pos..], p);
    }
    return encodePacketHeader(buf[0..pos], 1, 0);
}

pub fn encodeDisconnect(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.DisconnectOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validateDisconnectOptsFor311(opts);
    }

    // In MQTT 3.1.1, DISCONNECT has no variable header (only fixed header)
    if (comptime protocol_version == .mqtt_3_1_1) {
        return encodePacketHeader(buf[0..5], 14, 0);
    }

    // MQTT 5.0: has reason code and properties
    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    buf[5] = @intFromEnum(opts.reason);
    const PROPERTIES_OFFSET = 6;
    const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.DISCONNECT);

    return encodePacketHeader(buf[0 .. PROPERTIES_OFFSET + properties_len], 14, 0);
}

pub fn encodeSubscribe(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, packet_identifier: u16, opts: mqttz.SubscribeOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validateSubscribeOptsFor311(opts);
    }

    const SubscriptionOptions = packed struct(u8) {
        qos: mqttz.QoS,
        no_local: bool,
        retain_as_published: bool,
        retain_handling: mqttz.RetainHandling,
        _reserved: u2 = 0,
    };

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)

    writeInt(u16, buf[5..7], packet_identifier);
    const PROPERTIES_OFFSET = 7;
    const properties_len = if (comptime protocol_version == .mqtt_5_0)
        try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.SUBSCRIBE)
    else
        0; // MQTT 3.1.1 has no properties

    var pos: usize = PROPERTIES_OFFSET + properties_len;
    for (opts.topics) |topic| {
        pos += try writeString(buf[pos..], topic.filter);
        if (comptime protocol_version == .mqtt_5_0) {
            const subscription_options = SubscriptionOptions{
                .qos = topic.qos,
                .no_local = topic.no_local,
                .retain_as_published = topic.retain_as_published,
                .retain_handling = topic.retain_handling,
            };
            buf[pos] = @bitCast(subscription_options);
            pos += 1;
        } else {
            // MQTT 3.1.1: just QoS byte
            buf[pos] = @intFromEnum(topic.qos);
            pos += 1;
        }
    }

    return encodePacketHeader(buf[0..pos], 8, 2);
}

pub fn encodeUnsubscribe(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, packet_identifier: u16, opts: mqttz.UnsubscribeOpts) ![]u8 {
    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    writeInt(u16, buf[5..7], packet_identifier);
    const PROPERTIES_OFFSET = 7;
    const properties_len = if (comptime protocol_version == .mqtt_5_0)
        try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.UNSUBSCRIBE)
    else
        0; // MQTT 3.1.1 has no properties

    var pos = PROPERTIES_OFFSET + properties_len;
    for (opts.topics) |topic| {
        pos += try writeString(buf[pos..], topic);
    }

    return encodePacketHeader(buf[0..pos], 10, 2);
}

pub fn encodePublish(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, packet_identifier: ?u16, opts: mqttz.PublishOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validatePublishOptsFor311(opts);
    }

    const publish_flags = PublishFlags{
        .dup = opts.dup,
        .qos = opts.qos,
        .retain = opts.retain,
    };

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    const VARIABLE_HEADER_OFFSET = 5;
    const topic_len = try writeString(buf[VARIABLE_HEADER_OFFSET..], opts.topic);

    var properties_offset = VARIABLE_HEADER_OFFSET + topic_len;
    if (packet_identifier) |pi| {
        const packet_identifier_offset = properties_offset;
        properties_offset += 2;
        writeInt(u16, buf[packet_identifier_offset..properties_offset][0..2], pi);
    }

    const properties_len = if (comptime protocol_version == .mqtt_5_0)
        try properties.write(buf[properties_offset..], opts, &properties.PUBLISH)
    else
        0; // MQTT 3.1.1 has no properties

    const payload_offset = properties_offset + properties_len;
    const message = opts.message;
    const end = payload_offset + message.len;
    if (end > buf.len) {
        return error.WriteBufferIsFull;
    }
    @memcpy(buf[payload_offset..end], message);
    return encodePacketHeader(buf[0..end], 3, @as(u4, @bitCast(publish_flags)));
}

pub fn encodePubAck(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.PubAckOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validatePubAckOptsFor311(opts);
    }

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    writeInt(u16, buf[5..7], opts.packet_identifier);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    if (comptime protocol_version == .mqtt_3_1_1) {
        buf[3] = 64; // packet type (0100) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    // MQTT 5.0: has reason code and properties
    buf[7] = @intFromEnum(opts.reason_code);
    const PROPERTIES_OFFSET = 8;
    const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.PUBACK);

    if (opts.reason_code == .success and properties_len == 1) {
        // special case, if the reason code is 0 and ther are no properties
        // we can ommit both, and thus we only have a packet with
        // type+flag, length (of 2), 2 byte packet_identifier
        buf[3] = 64; // packet type (0100) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    return encodePacketHeader(buf[0 .. PROPERTIES_OFFSET + properties_len], 4, 0);
}

pub fn encodePubRec(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.PubRecOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validatePubRecOptsFor311(opts);
    }

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    writeInt(u16, buf[5..7], opts.packet_identifier);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    if (comptime protocol_version == .mqtt_3_1_1) {
        buf[3] = 80; // packet type (0101) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    // MQTT 5.0: has reason code and properties
    buf[7] = @intFromEnum(opts.reason_code);
    const PROPERTIES_OFFSET = 8;
    const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.PUBREC);

    if (opts.reason_code == .success and properties_len == 1) {
        // special case, if the reason code is 0 and ther are no properties
        // we can ommit both, and thus we only have a packet with
        // type+flag, length (of 2), 2 byte packet_identifier
        buf[3] = 80; // packet type (0101) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    return encodePacketHeader(buf[0 .. PROPERTIES_OFFSET + properties_len], 5, 0);
}

pub fn encodePubRel(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.PubRelOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validatePubRelOptsFor311(opts);
    }

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    writeInt(u16, buf[5..7], opts.packet_identifier);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    if (comptime protocol_version == .mqtt_3_1_1) {
        buf[3] = 98; // packet type (0110) + flags (0010)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    // MQTT 5.0: has reason code and properties
    buf[7] = @intFromEnum(opts.reason_code);
    const PROPERTIES_OFFSET = 8;
    const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.PUBREL);

    if (opts.reason_code == .success and properties_len == 1) {
        // special case, if the reason code is 0 and ther are no properties
        // we can ommit both, and thus we only have a packet with
        // type+flag, length (of 2), 2 byte packet_identifier
        buf[3] = 98; // packet type (0110) + flags (0010)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    return encodePacketHeader(buf[0 .. PROPERTIES_OFFSET + properties_len], 6, 2);
}

pub fn encodePubComp(buf: []u8, comptime protocol_version: mqttz.ProtocolVersion, opts: mqttz.PubCompOpts) ![]u8 {
    // Validate that no MQTT 5.0 properties are used in strict 3.1.1 mode
    if (comptime protocol_version.is_strict()) {
        try validatePubCompOptsFor311(opts);
    }

    // reserve 1 byte for the packet type
    // reserve 4 bytes for the packet length (which might be less than 4 bytes)
    writeInt(u16, buf[5..7], opts.packet_identifier);

    // MQTT 3.1.1: only packet identifier (2 bytes)
    if (comptime protocol_version == .mqtt_3_1_1) {
        buf[3] = 112; // packet type (0111) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    // MQTT 5.0: has reason code and properties
    buf[7] = @intFromEnum(opts.reason_code);
    const PROPERTIES_OFFSET = 8;
    const properties_len = try properties.write(buf[PROPERTIES_OFFSET..], opts, &properties.PUBCOMP);

    if (opts.reason_code == .success and properties_len == 1) {
        // special case, if the reason code is 0 and ther are no properties
        // we can ommit both, and thus we only have a packet with
        // type+flag, length (of 2), 2 byte packet_identifier
        buf[3] = 112; // packet type (0111) + flags (0000)
        buf[4] = 2; // remaining length
        return buf[3..7];
    }

    return encodePacketHeader(buf[0 .. PROPERTIES_OFFSET + properties_len], 7, 0);
}

pub fn encodePacketHeader(buf: []u8, packet_type: u8, packet_flags: u8) []u8 {
    const remaining_len = buf.len - 5;
    const length_of_len = lengthOfVarint(remaining_len);

    // This is where, in buf, our packet is actually going to start. You'd think
    // it would start at buf[0], but the package length is variable, so it'll
    // only start at buf[0] in the [unlikely] case where the length took 4 bytes.
    const start = 5 - length_of_len - 1;

    buf[start] = (packet_type << 4) | packet_flags;
    _ = writeVarint(buf[start + 1 ..], remaining_len);
    return buf[start..];
}

pub const PublishFlags = packed struct(u4) {
    dup: bool,
    qos: mqttz.QoS,
    retain: bool,
};

const t = @import("std").testing;
test "codec: writeVarint" {
    var buf: [4]u8 = undefined;
    try t.expectEqualSlices(u8, &[_]u8{0}, buf[0..writeVarint(&buf, 0)]);
    try t.expectEqualSlices(u8, &[_]u8{1}, buf[0..writeVarint(&buf, 1)]);
    try t.expectEqualSlices(u8, &[_]u8{20}, buf[0..writeVarint(&buf, 20)]);
    try t.expectEqualSlices(u8, &[_]u8{0x7f}, buf[0..writeVarint(&buf, 127)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, buf[0..writeVarint(&buf, 128)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0xff, 0x7f }, buf[0..writeVarint(&buf, 16383)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80, 0x01 }, buf[0..writeVarint(&buf, 16384)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0x7f }, buf[0..writeVarint(&buf, 2097151)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80, 0x80, 0x01 }, buf[0..writeVarint(&buf, 2097152)]);
    try t.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0x7f }, buf[0..writeVarint(&buf, 268435455)]);
}

test "codec: writeString" {
    var buf: [400]u8 = undefined;
    try t.expectError(error.WriteBufferIsFull, writeString(buf[0..0], ""));
    try t.expectError(error.WriteBufferIsFull, writeString(buf[0..1], ""));

    {
        const n = try writeString(buf[0..2], "");
        try t.expectEqualSlices(u8, &.{ 0, 0 }, buf[0..n]);
    }

    {
        const n = try writeString(&buf, "over 9000!");
        try t.expectEqualSlices(u8, &.{ 0, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!' }, buf[0..n]);
    }

    {
        const n = try writeString(&buf, "a" ** 300);
        try t.expectEqualSlices(u8, [_]u8{ 1, 44 } ++ "a" ** 300, buf[0..n]);
    }
}

test "codec: readVarint" {
    // have I mentioned I hate varings?
    try t.expectEqual(.{ 0, 1 }, readVarint(&[_]u8{0}));
    try t.expectEqual(.{ 1, 1 }, readVarint(&[_]u8{1}));
    try t.expectEqual(.{ 20, 1 }, readVarint(&[_]u8{20}));
    try t.expectEqual(.{ 127, 1 }, readVarint(&[_]u8{0x7f}));
    try t.expectEqual(.{ 128, 2 }, readVarint(&[_]u8{ 0x80, 0x01 }));
    try t.expectEqual(.{ 16383, 2 }, readVarint(&[_]u8{ 0xff, 0x7f }));
    try t.expectEqual(.{ 16384, 3 }, readVarint(&[_]u8{ 0x80, 0x80, 0x01 }));
    try t.expectEqual(.{ 2097151, 3 }, readVarint(&[_]u8{ 0xff, 0xff, 0x7f }));
    try t.expectEqual(.{ 2097152, 4 }, readVarint(&[_]u8{ 0x80, 0x80, 0x80, 0x01 }));
    try t.expectEqual(.{ 268435455, 4 }, readVarint(&[_]u8{ 0xff, 0xff, 0xff, 0x7f }));

    // same as above, but with extra data (which readVarint ignores)
    try t.expectEqual(.{ 0, 1 }, readVarint(&[_]u8{ 0, 0, 9 }));
    try t.expectEqual(.{ 1, 1 }, readVarint(&[_]u8{ 1, 0, 9 }));
    try t.expectEqual(.{ 20, 1 }, readVarint(&[_]u8{ 20, 0, 9 }));
    try t.expectEqual(.{ 127, 1 }, readVarint(&[_]u8{ 0x7f, 10, 9 }));
    try t.expectEqual(.{ 128, 2 }, readVarint(&[_]u8{ 0x80, 0x01, 200, 9 }));
    try t.expectEqual(.{ 16383, 2 }, readVarint(&[_]u8{ 0xff, 0x7f, 0, 9 }));
    try t.expectEqual(.{ 16384, 3 }, readVarint(&[_]u8{ 0x80, 0x80, 0x01, 128, 9 }));
    try t.expectEqual(.{ 2097151, 3 }, readVarint(&[_]u8{ 0xff, 0xff, 0x7f, 129, 9 }));
    try t.expectEqual(.{ 2097152, 4 }, readVarint(&[_]u8{ 0x80, 0x80, 0x80, 0x01, 0, 9 }));
    try t.expectEqual(.{ 268435455, 4 }, readVarint(&[_]u8{ 0xff, 0xff, 0xff, 0x7f, 0, 9 }));

    // incomplete
    try t.expectEqual(null, readVarint(&[_]u8{}));
    try t.expectEqual(null, readVarint(&[_]u8{128}));
    try t.expectEqual(null, readVarint(&[_]u8{ 128, 128 }));
    try t.expectEqual(null, readVarint(&[_]u8{ 128, 128, 128 }));
    try t.expectError(error.InvalidVarint, readVarint(&[_]u8{ 128, 128, 128, 128 }));
}

test "codec: lengthOfVarint" {
    try t.expectEqual(1, lengthOfVarint(0));
    try t.expectEqual(1, lengthOfVarint(127));
    try t.expectEqual(2, lengthOfVarint(128));
    try t.expectEqual(2, lengthOfVarint(16383));
    try t.expectEqual(3, lengthOfVarint(16384));
    try t.expectEqual(3, lengthOfVarint(2097151));
    try t.expectEqual(4, lengthOfVarint(2097152));
    try t.expectEqual(4, lengthOfVarint(268435455));
}

test "codec: readString" {
    try t.expectError(error.InvalidString, readString(&.{}));
    try t.expectError(error.InvalidString, readString(&.{0}));
    try t.expectError(error.InvalidString, readString(&.{ 0, 1 }));

    {
        const str, const len = try readString(&.{ 0, 0 });
        try t.expectEqual(2, len);
        try t.expectEqualSlices(u8, "", str);
    }

    {
        const str, const len = try readString(&.{ 0, 1, 'a' });
        try t.expectEqual(3, len);
        try t.expectEqualSlices(u8, "a", str);
    }

    {
        const str, const len = try readString(&.{ 0, 2, 'a', 'z', 1, 2, 3 });
        try t.expectEqual(4, len);
        try t.expectEqualSlices(u8, "az", str);
    }
}
