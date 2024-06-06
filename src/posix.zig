const std = @import("std");
const mqtt = @import("mqtt.zig");

const posix = std.posix;
const socket_t = posix.socket_t;

pub const Client = mqtt.Client(PosixClient);

const PosixClient = struct {
	socket: socket_t,

	pub fn read(self: PosixClient, buf: []u8) !usize {
		return posix.read(self.socket, buf);
	}

	pub fn write(self: PosixClient, data: []u8) !void {
		var pos: usize = 0;
		const socket = self.socket;
		while (pos < data.len) {
			pos += try posix.write(socket, data[pos..]);
		}
	}

	pub fn close(self: PosixClient) void {
		posix.close(self.socket);
	}
};


