const std = @import("std");
const mqttz = @import("mqtt.zig");
const builtin = @import("builtin");

const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Client = struct {
	// our posix client is a wrapper around the platform-agnostic mqttz.Mqtt client
	// we'll provide  read, write and close implementations (based around std.posix)
	// as well as other higher level functionality.
	mqtt: mqttz.Mqtt(Client),

	// Our own wrapper around std.net.Address. Handles connect timeout and can
	// pickup DNS changes on reconnect.
	address: Address,

	// if we own the read_buffer, it's our job to free it on deinit
	read_buf_own: bool,

	// if we own the write_buffer, it's our job to free it on deinit
	write_buf_own: bool,

	allocator: ?Allocator,

	connect_timeout: i32,

	// set when connect is called, can be unset on error (indicating that we need
	// to reconnect)
	socket: ?posix.socket_t,

	default_retries: u16,
	default_timeout: i32,

	pub const Opts = struct {
		port: u16,

		// either ip or host must be provided
		ip: ?[]const u8 = null,
		host: ?[]const u8 = null,

		connect_timeout: i32 = 10_000,
		default_retries: ?u16 = null,
		default_timeout: ?i32 = null,

		// required if host != null OR read_buffer == null OR write_buffer == null
		allocator: ?Allocator = null,

		// if null, we'll use allocator to create a buffer of read_buffer_size
		read_buf: ?[]u8 = null,
		read_buf_size: u16 = 8192,

		// if null, we'll use allocator to create a buffer of read_buffer_size
		write_buf: ?[]u8 = null,
		write_buf_size: u16 = 8192,
	};

	const ReadWriteOpts = struct {
		retries: ?u16 = null,
		timeout: ?i32 = null,
	};

	pub fn init(opts: Opts) !Client {
		const allocator = opts.allocator;

		if (allocator == null and (opts.ip == null or opts.read_buf == null or opts.write_buf == null)) {
			return error.AllocatorRequired;
		}

		var read_buf_own = false;
		var read_buf = opts.read_buf;
		if (read_buf == null) {
			read_buf_own = true;
			read_buf = try allocator.?.alloc(u8, opts.read_buf_size);
		}
		errdefer if (read_buf_own) allocator.?.free(read_buf.?);

		var write_buf_own = false;
		var write_buf = opts.write_buf;
		if (write_buf == null) {
			write_buf_own = true;
			write_buf = try allocator.?.alloc(u8, opts.write_buf_size);
		}
		errdefer if (write_buf_own) allocator.?.free(write_buf.?);

		const address = try Address.init(opts.host, opts.ip, opts.port);

		return .{
			.socket = null,
			.address = address,
			.allocator = allocator,
			.read_buf_own = read_buf_own,
			.write_buf_own = write_buf_own,
			.connect_timeout = opts.connect_timeout,
			.default_retries = opts.default_retries orelse 1,
			.default_timeout = opts.default_timeout orelse 5_000,
			.mqtt = mqttz.Mqtt(Client).init(read_buf.?, write_buf.?),
		};
	}

	pub fn deinit(self: *Client) void {
		self.close();

		const allocator = self.allocator;
		if (self.read_buf_own) {
			allocator.?.free(self.mqtt.read_buf);
		}

		if (self.write_buf_own) {
			allocator.?.free(self.mqtt.write_buf);
		}
	}

	pub fn lastError(self: *const Client) ?mqttz.ErrorDetail {
		return self.mqtt.last_error;
	}

	pub fn lastReadPacket(self: *const Client) []const u8 {
		return self.mqtt.lastReadPacket();
	}

	pub fn connect(self: *Client, rw: ReadWriteOpts, opts: mqttz.ConnectOpts) !void {
		try self.mqtt.connect(&self.createContext(rw), opts);
	}

	pub fn publish(self: *Client, rw: ReadWriteOpts, opts: mqttz.PublishOpts) !?u16 {
		return self.mqtt.publish(&self.createContext(rw), opts);
	}

	pub fn subscribe(self: *Client, rw: ReadWriteOpts, opts: mqttz.SubscribeOpts) !u16 {
		return self.mqtt.subscribe(&self.createContext(rw), opts);
	}

	pub fn unsubscribe(self: *Client, rw: ReadWriteOpts, opts: mqttz.UnsubscribeOpts) !u16 {
		return self.mqtt.unsubscribe(&self.createContext(rw), opts);
	}

	pub fn puback(self: *Client, rw: ReadWriteOpts, opts: mqttz.PubAckOpts) !void {
		return self.mqtt.puback(&self.createContext(rw), opts);
	}

	pub fn pubrec(self: *Client, rw: ReadWriteOpts, opts: mqttz.PubRecOpts) !void {
		return self.mqtt.pubrec(&self.createContext(rw), opts);
	}

	pub fn pubrel(self: *Client, rw: ReadWriteOpts, opts: mqttz.PubRelOpts) !void {
		return self.mqtt.pubrel(&self.createContext(rw), opts);
	}

	pub fn pubcomp(self: *Client, rw: ReadWriteOpts, opts: mqttz.PubCompOpts) !void {
		return self.mqtt.pubcomp(&self.createContext(rw), opts);
	}

	pub fn ping(self: *Client, rw: ReadWriteOpts) !void {
		return self.mqtt.ping(&self.createContext(rw),);
	}

	pub fn disconnect(self: *Client, rw: ReadWriteOpts, opts: mqttz.DisconnectOpts) !void {
		if (self.socket == null) {
			return;
		}

		// copy so we can mutate
		var rw_copy = rw;
		if (rw.retries == null) {
			// unless a retry is explicit set, let's override the default, since we
			// don't want to reconnect just to disconnect.
			rw_copy.retries = 0;
		}
		return self.mqtt.disconnect(&self.createContext(rw_copy), opts);
	}

	pub fn readPacket(self: *Client, rw: ReadWriteOpts) !?mqttz.Packet {
		return self.mqtt.readPacket(&self.createContext(rw));
	}

	fn getOrConnectSocket(self: *Client) !posix.socket_t {
		return self.socket orelse {
			const socket = try self.address.connect(self.allocator, self.connect_timeout);
			self.socket = socket;
			return socket;
		};
	}

	fn close(self: *Client) void {
		if (self.socket) |socket| {
			posix.close(socket);
			self.socket = null;
		}
	}

	fn createContext(self: *Client, rw: ReadWriteOpts) MqttPlatform.Context {
		return .{
			.client = self,
			.retries = rw.retries orelse self.default_retries,
			.timeout = rw.timeout orelse self.default_timeout,
		};
	}

	pub const MqttPlatform = struct {
		const Context = struct {
			client: *Client,
			retries: u16 = 1,
			timeout: i32 = 10_000,
		};

		// Called by our composed mqtt.Client
		pub fn read(ctx: *const Context, buf: []u8, _: usize) !?usize {
			var client = ctx.client;

			const absolute_timeout = std.time.milliTimestamp() + ctx.timeout;

			// on disconnect, the number of times that we'll try to reconnect and
			// continue. This counts downwards to 0.
			var retries = ctx.retries;

			// If retries > 0 and we detect a disconnect, we'll attempt to reload the
			// socket (hence socket is var, not const).
			var socket = try client.getOrConnectSocket();
			loop: while (true) {
				const n = posix.read(socket, buf) catch |err| {
					switch (err) {
						error.BrokenPipe, error.ConnectionResetByPeer => {
							socket = try handleError(client, &retries);
							continue :loop;
						},
						error.WouldBlock => {
							const timeout: i32 = @intCast(absolute_timeout - std.time.milliTimestamp());
							if (timeout < 0) {
								return null;
							}

							var fds = [1]posix.pollfd{.{.fd = socket, .events = posix.POLL.IN, .revents = 0}};
							if (try posix.poll(&fds, timeout) == 0) {
								return null;
							}

							if (fds[0].revents & posix.POLL.IN != posix.POLL.IN) {
								// handle any other non-POLLOUT event as an error
								socket = try handleError(client, &retries);
							}

							// Either poll has told us we can read without blocking OR
							// poll told us there was a error, but retries > 0 and we managed
							// to reconnect. Either way, we're gonna try to read again.
							continue :loop;
						},
						else => {
							client.close();
							return err;
						},
					}
				};

				if (n != 0) {
					return n;
				}

				socket = try handleError(client, &retries);
			}
		}

		// Called by our composed mqtt.Client
		pub fn write(ctx: *const Context, data: []const u8) !void {
			var client = ctx.client;

			const absolute_timeout = std.time.milliTimestamp() + ctx.timeout;

			// on disconnect, the number of times that we'll try to reconnect and
			// continue. This counts downwards to 0.
			var retries = ctx.retries;

			// If retries > 0 and we detect a disconnect, we'll attempt to reload the
			// socket (hence socket is var, not const).
			var socket = try client.getOrConnectSocket();

			// position in data that we've written to so far (or, put differently,
			// positition in data that our next write starts at)
			var pos: usize = 0;

			loop: while (pos < data.len) {
				pos += posix.write(socket, data[pos..]) catch |err| switch (err) {
					error.WouldBlock => {
						const timeout: i32 = @intCast(std.time.milliTimestamp() - absolute_timeout);
						if (timeout < 0) {
							return error.Timeout;
						}

						var fds = [1]posix.pollfd{.{.fd = socket, .events = posix.POLL.OUT, .revents = 0}};
						if (try posix.poll(&fds, timeout) == 0) {
							return error.Timeout;
						}

						const revents = fds[0].revents;
						if (revents & posix.POLL.OUT != posix.POLL.OUT) {
							// handle any other non-POLLOUT event as an error
							socket = try handleError(client, &retries);
						}

						// Either poll has told us we can write without blocking OR
						// poll told us there was a error, but retries > 0 and we managed
						// to reconnect. Either way, we're gonna try to write again.
						continue :loop;

					},
					error.BrokenPipe, error.ConnectionResetByPeer => {
						socket = try handleError(client, &retries);
						continue :loop;
					},
					else => {
						client.close();
						return err;
					},
				};
			}
		}

		// Called by our composed mqtt.Client
		pub fn close(ctx: *const Context) void {
			ctx.client.close();
		}

		fn handleError(client: *Client, retries: *u16) !posix.socket_t {
			client.close();
			const r = retries.*;
			if (r == 0) {
				return error.Closed;
			}
			const socket = try client.getOrConnectSocket();
			retries.* = r - 1;
			return socket;
		}
	};
};

// Wraps a std.net.Address so that
// (a) we can handle the fact that host DNS can change and can have multiple IPs
// (b) do a non-blocking connect (so we can timeout)
const Address = struct {
	// null when we're given an ip:port.
	host: ?Host = null,

	// initially null when we're given a host:port
	address: ?net.Address = null,

	const Host = struct {
		port: u16,
		name: []const u8,
	};

	fn init(optional_host: ?[]const u8, optional_ip: ?[]const u8, port: u16) !Address {
		if (optional_ip) |ip| {
			return .{
				// setting a future resolved means, on connect/reconnect we won't try to
				.address = try std.net.Address.parseIp(ip, port),
			};
		}

		const host = optional_host orelse return error.HostOrIPRequired;
		return .{.host = .{.name = host, .port = port}};
	}

	fn connect(self: *Address, allocator: ?Allocator, timeout: i32) !posix.socket_t {
		if (self.address) |addr| {
			// we were given an ip:port, so the address is fixed
			return connectTo(addr, timeout);
		}

		// If we don't have an address, then we were given a host:ip.
		// The address can change (DNS can be updated), and there can be multiple
		// IPs, hence why we don't convert host:ip -> net.Address in init.
		const host = self.host.?;
		const list = try net.getAddressList(allocator.?, host.name, host.port);
		defer list.deinit();

		if (list.addrs.len == 0) {
			return error.UnknownHostName;
		}

		for (list.addrs) |addr| {
			return connectTo(addr, timeout) catch continue;
		}

		return posix.ConnectError.ConnectionRefused;
	}

	fn connectTo(addr: net.Address, timeout: i32) !posix.socket_t {
		const sock_flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
		const socket = try posix.socket(addr.any.family, sock_flags, posix.IPPROTO.TCP);
		errdefer posix.close(socket);

		posix.connect(socket, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
			error.WouldBlock => {
				var fds = [1]posix.pollfd{.{.fd = socket, .events = posix.POLL.OUT, .revents = 0}};
				if (try posix.poll(&fds, timeout) == 0) {
					return error.Timeout;
				}

				if (fds[0].revents & posix.POLL.OUT != posix.POLL.OUT)  {
					return error.ConnectionRefused;
				}

				// if this returns void, then we've successfully connected
				try posix.getsockoptError(socket);
			},
			else => return err,
		};

		return socket;
	}
};

const t = std.testing;

test {
	const address = try net.Address.parseIp("127.0.0.1", 6588);
	const socket = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
	errdefer posix.close(socket);

	try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
	try posix.bind(socket, &address.any, address.getOsSockLen());
	try posix.listen(socket, 2);
	const thread = try std.Thread.spawn(.{}, TestServer.run, .{socket});
	thread.detach();
}

test "Client: invalid config" {
	try t.expectError(error.HostOrIPRequired, Client.init(.{.port = 0, .allocator = t.allocator}));

	// host specified
	try t.expectError(error.AllocatorRequired, Client.init(.{.port = 0, .host = "123", .read_buf = &[_]u8{}, .write_buf = &[_]u8{}}));

	// no read_buf
	try t.expectError(error.AllocatorRequired, Client.init(.{.port = 0, .ip = "", .write_buf = &[_]u8{}}));

	// no write_buf
	try t.expectError(error.AllocatorRequired, Client.init(.{.port = 0, .ip = "", .read_buf = &[_]u8{}}));
}

test "Client: connect timeout" {
	var client = try Client.init(.{
		.port = 1883,
		.ip = "10.255.255.1", // unroutable
		.connect_timeout = 10,
		.allocator = t.allocator,
	});

	defer client.deinit();

	const start = std.time.milliTimestamp();
	try t.expectError(error.Timeout, client.connect(.{}, .{}));

	const elapsed = std.time.milliTimestamp() - start;
	try t.expectEqual(true, elapsed >= 10 and elapsed < 15);
}

test "Client: read error" {
	var client = testClient(.{});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "close", .message = ""});
	try t.expectEqual(error.Closed, client.readPacket(.{.retries = 0}));
}

test "Client: retry1" {
	var client = testClient(.{});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "retry1", .message = ""});
	const publish = (try client.readPacket(.{.retries = 1})).?.publish;
	try t.expectEqualSlices(u8, "retry1-ok", publish.topic);
}

test "Client: retry1 - no alloc" {
	// This test is testing that the client works when no allocator is provided,
	// so long as the correct initialize arguments are included

	var buf: [128]u8 = undefined;
	var client = try Client.init(.{
		.port = 6588,
		.ip = "127.0.0.1",
		.read_buf = &buf,  // should not be the same!
		.write_buf = &buf, // should not be the same!
	});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "retry1", .message = ""});
	const publish = (try client.readPacket(.{.retries = 1})).?.publish;
	try t.expectEqualSlices(u8, "retry1-ok", publish.topic);
}

test "Client: retry2" {
	var client = testClient(.{});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "retry2", .message = ""});
	const publish = (try client.readPacket(.{.retries = 2})).?.publish;
	try t.expectEqualSlices(u8, "retry2-ok", publish.topic);
}

test "Client: read timeout" {
	var client = testClient(.{});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "timeout", .message = ""});

	const start = std.time.milliTimestamp();
	try t.expectEqual(null, try client.readPacket(.{.retries = 0, .timeout = 50}));
	const elapsed = std.time.milliTimestamp() - start;
	try t.expectEqual(true, elapsed >= 50 and elapsed < 100);
}

test "Client: read invalid response" {
	var client = testClient(.{});
	defer client.deinit();

	_ = try client.publish(.{}, .{.topic = "invalid", .message = ""});
	try t.expectError(error.Protocol, client.readPacket(.{}));
	try t.expectEqual(error.UnknownPacketType, client.lastError().?.inner);
	try t.expectEqualSlices(u8, &.{0, 1, 10}, client.lastReadPacket());
}

const TestServer = struct {
	// runs in a thread, but our TestServer itself is single threaded as, currently,
	// each test only needs 1 connection to the server at a time.
	fn run(server: posix.socket_t) void {
		var state = State{};

		while (true) {
			var address: std.net.Address = undefined;
			var address_len: posix.socklen_t = @sizeOf(std.net.Address);
			const socket = posix.accept(server, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
				std.debug.print("failed to accept socket: {}", .{err});
				continue;
			};
			defer posix.close(socket);

			var conn = TestConn{
				.buf = undefined,
				.socket = socket,
			};
			conn.handle(&state) catch |err| {
				std.debug.print("TestConn handle: {}\n", .{err});
				unreachable;
			};
		}
	}

	// Some tests happen across calls (like when testing timeouts) and some across
	// connections (like retries). This is a global state that we'll pass into
	// each connection handler to use as it wants. All of this only works because
	// our tests are single-threaded.
	const State = struct {
		name: []const u8 = "",
	};
};

// represents the client from the Server's point of view
const TestConn = struct {
	buf: [1024]u8,
	socket: posix.socket_t,

	const codec = @import("codec.zig");

	// This isn't anywhere close to a proper MQTT server. Its behavior is completely
	// controlled by the message it receives. For example it can receive a
	// "subscribe to topic 'close'" message and the server would use that received
	// message to identify what it should do: in this case, close the connection.
	// To this end, connections don't even need to send an initial "connect" packet..
	// These aren't integration tests, these are unit tests covering specific and
	// hard to mock behaviors.
	fn handle(self: *TestConn, state: *TestServer.State) !void {
		if (std.mem.eql(u8, state.name, "retry1")) {
			state.name = "";
			const reply = try codec.encodePublish(&self.buf, 0, .{.topic = "retry1-ok", .message = ""});
			_ = try posix.write(self.socket, reply);
		} else if (std.mem.eql(u8, state.name, "retry2-a")) {
			// move the state forward, and close the connection to see if it'll retry again
			state.name = "retry2-b";
			return;
		} else if (std.mem.eql(u8, state.name, "retry2-b")) {
			state.name = "";
			const reply = try codec.encodePublish(&self.buf, 0, .{.topic = "retry2-ok", .message = ""});
			_ = try posix.write(self.socket, reply);
		}

		while (true) {
			const packet = self.readPacket() catch |err| {
				if (err == error.Closed) {
					return;
				}
				std.debug.print("TestConn readPacket: {}\n", .{err});
				return err;
			};

			switch (packet) {
				.publish => |p| {
					// We use the publish packet to test various edge cases.
					if (std.mem.eql(u8, p.topic, "close")) {
						// simple, just close the connection
						return;
					}

					if (std.mem.eql(u8, p.topic, "retry1")) {
						// set our state, so that on reconnect, we know what to do
						state.name = "retry1";
						return; // closes the connection
					}

					if (std.mem.eql(u8, p.topic, "retry2")) {
						// set our state, so that on reconnect, we know what to do
						state.name = "retry2-a";
						return; // closes the connection
					}

					if (std.mem.eql(u8, p.topic, "timeout")) {
						std.time.sleep(std.time.ns_per_ms * 75);
						continue;
					}

					if (std.mem.eql(u8, p.topic, "invalid")) {
						// we're being asked to write ssome invalid data
						_ = try posix.write(self.socket, &.{0, 1, 10, 22});
						continue;
					}

					std.debug.print("unknown publish topic: {s}\n", .{p.topic});
					unreachable;
				},
				else => unreachable,
			}
		}
	}

	// This isn't efficient. Rather than reading as much data as we can, we'll read
	// 1 exact packet by always doing 2 reads. 1 to get the length and then 1 to get
	// the packet. Could be tricky since the length is varint, but since this is just
	// for testing, we have control over the received message and, for example, know
	// that none will require more than a 2 byte length.
	fn readPacket(self: *TestConn) !mqttz.Packet{
		var buf = &self.buf;

		while (true) {
			try self.readFill(buf[0..3]);
			const remaining_len, const length_of_len = (try codec.readVarint(buf[1..3])) orelse unreachable;

			const missing = switch (length_of_len) {
				1 => buf[3..2 + remaining_len],
				2 => buf[3..3 + remaining_len],
				else => unreachable,
			};

			try self.readFill(missing);
			const b1 = buf[0];
			const data = buf[1 + length_of_len .. 1 + length_of_len + remaining_len];
			return mqttz.Packet.decode(b1, data);
		}
	}

	// fills buf
	fn readFill(self: *const TestConn, buf: []u8) !void {
		var pos: usize = 0;
		while (true) {
			const n = try posix.read(self.socket, buf[pos..]);
			if (n == 0) {
				return error.Closed;
			}
			pos += n;
			if (pos == buf.len) {
				return;
			}
		}
	}
};

fn testClient(opts: anytype) Client {
	_ = opts; // not currently used
	return Client.init(.{
		.port = 6588,
		.ip = "127.0.0.1",
		.allocator = t.allocator,
	}) catch unreachable;
}
