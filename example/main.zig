const std = @import("std");
const mqttz = @import("mqttz");

pub fn main() !void {
	const address = try std.net.Address.parseIp("127.0.0.1", 1883);
	var stream = try std.net.tcpConnectToAddress(address);
	defer stream.close();

	var read_buf: [4098]u8 = undefined;
	var write_buf: [4098]u8 = undefined;
	const posix_client = PosixClient{.socket = stream.handle};

	var mqtt_client = try mqttz.Client(PosixClient).init(posix_client, &read_buf, &write_buf);
	const connack = try mqtt_client.connect(.{});
	std.debug.print("{any}\n", .{connack});
}

// There's already a mqttz.posix.Client that does this.
// But in this example, we're using the lower level, generic, mqttz.Client to
// show how it can be used for platforms that don't have the std lib.
const PosixClient = struct {
	socket: std.posix.socket_t,

	pub fn read(self: PosixClient, buf: []u8) !usize {
		const n = try std.posix.read(self.socket, buf);
		std.debug.print("READ: {any}\n", .{buf[0..n]});
		return n;
	}

	pub fn write(self: PosixClient, data: []u8) !void {
		std.debug.print("WRITE: {any}\n", .{data});
		var pos: usize = 0;
		const socket = self.socket;
		while (pos < data.len) {
			pos += try std.posix.write(socket, data[pos..]);
		}
	}

	pub fn close(self: PosixClient) void {
		std.posix.close(self.socket);
	}
};
