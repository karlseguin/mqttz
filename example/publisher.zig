// While this example uses `std`, `mqttz` does not and so you can use `mqttz`
// without `std` (it's also allocation-free)
const std = @import("std");
const mqttz = @import("mqttz");

// This is an example of of client that publishes message.
// This is a simple, but common example. By default we publish using
// mqttz.QoS.at_most_once. If we used a higher level, then things would get
// more complicated: after publishing we'd need to get a pubrel/pubrec and deal
// with potential timeouts and such.

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
	// will get closed when client.disconnect() is called

	// we never read very large messages
	var read_buf: [256]u8 = undefined;
	// this has to be at least big enough to hold our largest message + the topic
	// name + a few bytes of overhead
	var write_buf: [1024]u8 = undefined;

	var client = Client{
		.socket = stream.handle,
		.mqtt = mqttz.Mqtt(Client).init(&read_buf, &write_buf),
	};
	defer client.disconnect(.normal);

	// in our connect, we call readPacket and return the mqttz.Packet.Connack
	// this packet might have useful information about the server's capabilities.
	_ = try client.connect(.{
		.user_properties = &.{
			.{.key = "client", .value = "mqttz"},
			.{.key = "example", .value = "publisher"},
		}
	});

	var buf: [50]u8 = undefined;
	for (9000..9003) |i| {
		try client.publish("power/goku", try std.fmt.bufPrint(&buf, "over {d}!", .{i}));
		std.time.sleep(std.time.ns_per_s);
	}
}

// In this example, we use composition. The Client wraps the `Mqtt(T)`.
const Client = struct {
	socket: std.posix.socket_t,
	mqtt: mqttz.Mqtt(Client),

	// wrap mqtt methods, largely so we can inject the state
	// which, in this case (and in most) is going to be the Client itself.
	fn connect(self: *Client, opts: mqttz.ConnectOpts) !mqttz.Packet.ConnAck {
		try self.mqtt.connect(self, opts);

		// after we send a connect, the only valid packets we can get back are
		// connack and disconnect and disconnect is handled by our readPacket
		switch (try self.readPacket()) {
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

	pub fn publish(self: *Client, topic: []const u8, message: []const u8) !void {
		// because we're using the default QoS, QoS.at_most_once, we won't need
		// to receive a pubrel/pubrec. So we don't care about the returned packet_identifier.
		// This is fire-and-forget.
		_ = try self.mqtt.publish(self, .{
			.topic = topic,
			.message = message,
			.qos = .at_most_once, // this is the default, but let's be explicit
		});
	}

	// nice thing about composition is that it's easy to apply global handling
	// for various packet types.
	fn readPacket(self: *Client) !mqttz.Packet {
		switch (try self.mqtt.readPacket(self)) {
			.disconnect => |d| {
				std.debug.print("server disconnected: {any}\n", .{d.reason_code});
				return error.Disconnected;
			},
			else => |packet| return packet,
		}
	}

	pub const MqttPlatform = struct {
		// We must provide a read function
		pub fn read(self: *Client, buf: []u8, _: usize) !usize {
			return std.posix.read(self.socket, buf);
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

