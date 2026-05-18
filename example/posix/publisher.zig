const std = @import("std");
const mqttz = @import("mqttz");

// This is an example of of client that publishes message.
// This is a simple, but common example. By default we publish using
// mqttz.QoS.at_most_once. If we used a higher level, then things would get
// more complicated: after publishing we'd need to get a pubrel/pubrec and deal
// with potential timeouts and such.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var client = try mqttz.posix.Client5.init(init.io, .{
        .port = 1883,
        .ip = "127.0.0.1",
        // It IS possible to use the posix client without an allocator, see readme
        .allocator = allocator,
    });

    defer {
        client.disconnect(.{ .timeout = 1000 }, .{ .reason = .normal }) catch {};
        client.deinit();
    }

    _ = try client.connect(.{ .timeout = 2000 }, .{ .user_properties = &.{
        .{ .key = "client", .value = "mqttz" },
        .{ .key = "example", .value = "publisher" },
    } });

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
        },
    };

    var buf: [50]u8 = undefined;
    for (5000..5003) |i| {
        _ = try client.publish(.{}, .{ .topic = "power/vegeta", .message = try std.fmt.bufPrint(&buf, "over {d}!", .{i}) });
        try std.Io.sleep(init.io, .fromSeconds(1), .awake);
    }
}
