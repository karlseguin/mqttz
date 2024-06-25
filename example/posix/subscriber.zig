const std = @import("std");
const mqttz = @import("mqttz");

// This is an example of of client that subscribes to a topic and then
// receives message. This is a simple, but common example. It's simple because
// we mostly know what type of packets to expect when we call readPacket.
pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.detectLeaks();

	var client = try mqttz.posix.Client.init(.{
		.port = 1883,
		.host = "test.mosquitto.org",
		// It IS possible to use the posix client without an allocator, see readme
		.allocator = allocator,
	});

	defer {
		client.disconnect(.{.timeout = 1000}, .{.reason = .normal}) catch {};
		client.deinit();
	}

	_ = try client.connect(.{.timeout = 5000}, .{
		.user_properties = &.{
			.{.key = "client", .value = "mqttz"},
			.{.key = "example", .value = "subscriber"},
		}
	});

	if (try client.readPacket(.{})) |packet| switch (packet) {
		.disconnect => |d| {
			std.debug.print("server disconnected us: {s}", .{@tagName(d.reason_code)});
			return;
		},
		.connack => {
			// TODO: the connack packet can include server capabilities. We might care
			// about these to tweak how our client behaves (like, what is the maximum
			// supported QoS)
		},
		else => {
			// The server should not send any other type of packet at this point
			// HOWEVER, we should probably handle this case better than an `unreachable`
		}
	};

	{
		const packet_identifier = try client.subscribe(.{}, .{
			.topics = &.{.{.filter = "power/vegeta", .qos = .at_most_once}}
		});
		if (try client.readPacket(.{})) |packet| switch (packet) {
			.disconnect => |d| {
				std.debug.print("server disconnected us: {s}", .{@tagName(d.reason_code)});
				return;
			},
			.suback => |s| {
				std.debug.assert(s.packet_identifier == packet_identifier);
			},
			else => {
				// The server should not send any other type of packet at this point
				// HOWEVER, we should probably handle this case better than an `unreachable`
				unreachable;
			}
		};
	}

	// since we're using a public test server, we won't keep this open longer
	// than necessary
	var count: usize = 0;
	loop: while (true) {
		const packet = try client.readPacket(.{.timeout = 1000}) orelse {
			std.debug.print("Still waiting for messages...\n", .{});
			continue :loop;
		};
		switch (packet) {
			.publish => |*publish| {
				std.debug.print("received\ntopic: {s}\n{s}\n\n", .{publish.topic, publish.message});
				count += 1;
				if (count == 3) {
					// our publisher only sends 3 mesages
					return;
				}
			},
			else => {
				// always have to be mindful of the bi-directional nature of MQTT
				// but in this case, nothing here should be possible.
				// client.readPacket handles `disconnect` and our above connect and
				// subscribe should have handled their corresponing connack and suback
				std.debug.print("unexpected packet: {any}\n", .{packet});
			}
		}
	}
}
