// While this example uses `std`, `mqttz` does not and so you can use `mqttz`
// without `std` (it's also allocation-free)
const std = @import("std");

const mqttz = @import("mqttz");

// This is an example of of client that subscribes to a topic and then
// receives message. This is a simple, but common example. It's simple because
// we mostly know what type of packets to expect when we call readPacket.
pub fn main() !void {
	const address = blk: {
		// mqttz is allocation-free. But your wrapper doesn't have to be. For example
		// here we need an allocator to resolve the address.
		var buf: [2048]u8 = undefined;
		var fba = std.heap.FixedBufferAllocator.init(&buf);
		const list = try std.net.getAddressList(fba.allocator(), "test.mosquitto.org", 1883);
		defer list.deinit();
		if (list.addrs.len == 0) return error.UnknownHostName;
		break :blk list.addrs[0];
	};

	const stream = try std.net.tcpConnectToAddress(address);
	// will get closed when client.disconnect() is closed

	var read_buf: [4096]u8 = undefined;

	// we never write very big messages. The longest part of our message is
	// the topic name that we subscribe to (plus a few bytes of overhead in the
	// packet structure)
	var write_buf: [256]u8 = undefined;

	var client = Client{
		.socket = stream.handle,
		.mqtt = mqttz.Mqtt5(Client).init(&read_buf, &write_buf),
	};
	defer client.disconnect(.normal);

	// in our connect, we call readPacket and return the mqttz.Packet.Connack
	// this packet might have useful information about the server's capabilities.
	_ = try client.connect(.{
		.maximum_packet_size = 4096,
		.user_properties = &.{
			.{.key = "client", .value = "mqttz"},
			.{.key = "example", .value = "subscriber"},
		}
	});

	try client.subscribe("power/goku");

	// since we're using a public test server, we won't keep this open longer
	// than necessary
	for (0..3) |_| {
		if (try client.readPacket()) |packet| switch (packet) {
			.publish => |*publish| client.handleMessage(publish),
			else => {
				// always have to be mindful of the bi-directional nature of MQTT
				// but in this case, nothing here should be possible.
				// client.readPacket handles `disconnect` and our above connect and
				// subscribe should have handled their corresponing connack and suback
				std.debug.print("unexpected packet: {any}\n", .{packet});
			}
		};
	}
}

// In this example, we use composition. The Client wraps the `Mqtt(T)`.
const Client = struct {
	socket: std.posix.socket_t,
	mqtt: mqttz.Mqtt5(Client),

	// wrap mqtt methods, largely so we can inject the state
	// which, in this case (and in most) is going to be the Client itself.
	fn connect(self: *Client, opts: mqttz.ConnectOpts) !mqttz.Packet.ConnAck {
		try self.mqtt.connect(self, opts);

		// since this simple demo doesn't implement a timeout, readPacket should
		// either fail or returna a packet.
		const packet = (try self.readPacket()) orelse unreachable;

		// after we send a connect, the only valid packets we can get back are
		// connack and disconnect and disconnect is handled by our readPacket
		switch (packet) {
			.connack => |c| {
				if (c.reason_code == .success) {
					return c;
				}
				std.debug.print("failed to connect: {any}\n", .{c.reason_code});
				return error.ConnectionFailed;
			},
			else => {
				std.debug.print("unexpected packet: {any}\n", .{self.mqtt.lastReadPacket()});
				return error.UnexpectPacket;
			},
		}
	}

	fn disconnect(self: *Client, reason: mqttz.ClientDisconnectReason) void {
		self.mqtt.disconnect(self, .{
			.reason = reason
		}) catch {};
	}

	fn subscribe(self: *Client, topic: []const u8) !void {
		const packet_identifier = try self.mqtt.subscribe(self, .{
			.topics = &.{
				.{.filter = topic, .qos = .at_most_once},
			},
		});

		// what's up with this while loop? Well, If we call subscribe multiple times
		// it's possible that calls to readPacket will start getting published messages
		// so we need to loop until we get our suback, processing any publish packets
		//
		// If you need to subscribe to multiple topics, it's MUCH better to do so
		// in a single call to subscribe. Then you avoid this issue.
		// However, if the subscriptions are dynamic, then you might need to take
		// this approach

		while (true) {
			if (try self.readPacket()) |packet| switch (packet) {
				.publish => |*publish| self.handleMessage(publish),
				.suback => |suback| {
					if (suback.packet_identifier != packet_identifier) {
						return error.WrongPacketIdentifier;
					}

					// our implementation asked for at_most_once
					// it should have gotten a suback with at_most_once
					// we can't handle anything more (in this implementation)
					if (try suback.result(0) != .at_most_once) {
						return error.UnexpectedQOS;
					}
					return;
				},
				else => {
					std.debug.print("unexpected packet: {any}\n", .{self.mqtt.lastReadPacket()});
					return error.UnexpectPacket;
				},
			};
		}
	}

	fn handleMessage(_: *Client, publish: *const mqttz.Packet.Publish) void {
		// if publish.qos is .at_least_once or .exactly_once, then we'll need to
		// send purec/pubrel
		std.debug.print("received\ntopic: {s}\n{s}\n\n", .{publish.topic, publish.message});
	}

	// nice thing about composition is that it's easy to apply global handling
	// for various packet types.
	fn readPacket(self: *Client) !?mqttz.Packet {
		if (try self.mqtt.readPacket(self)) |packet| switch (packet) {
			.disconnect => |d| {
				std.debug.print("server disconnected: {any}\n", .{d.reason_code});
				return error.Disconnected;
			},
			else => return packet,
		};

		return null;
	}

	pub const MqttPlatform = struct {
		// We must provide a read function
		pub fn read(self: *Client, buf: []u8, _: usize) !?usize {
			return try std.posix.read(self.socket, buf);
		}

		// We must provide a write function
		pub fn write(self: *Client, data: []const u8) !void {
			var pos: usize = 0;
			const socket = self.socket;
			while (pos < data.len) {
				pos += try std.posix.write(socket, data[pos..]);
			}
		}

		// We must provide a close function
		pub fn close(self: *Client) void {
			std.posix.close(self.socket);
		}
	};
};

