# MQTT Client for Zig

This is a [hopefully] embed-friendly MQTT client library for Zig. Currently, the focus is on writing a foundation that can be extended, based on needs and the capacity of the platform. The library does not use the standard library and thus requires users to provide some of the implementation.

A higher-level wrapper that uses the standard library is planned.

## Overview
The approach of `mqtt.Mqtt(T)` is to have T provide the `read`, `write` and `close` functions. This decouples the `Mqtt(T)` library from the platform implementation.

Unlike most generic implementations, `Mqtt(T)` never references `T`. It merely calls `T.read()`, `T.write()` and `T.close()` with a per-call specific `anytype`. This provides greater flexibility and facilitates composition.

Consider this partial example which wraps `Mqtt(T)` using `std`:

```zig
const Client = struct {
    mqtt: mqtt.Mqtt(Client),
    socket: std.posix.socket_t,

    // wrap mqtt.subscribe
    pub fn subscribe(self: *Client, opts: mqtt.SubscribeOpts) !usize {
        // the first parameter is an anytype and will be passed to the
        // read/write/close function as is
        return self.mqtt.subscribe(self, opts);
    }

    // One of the three methods we must implement
    pub fn write(self: *Client, data: []const u8) !void {
        return std.posix.write(self.socket, data);
    }
}
```

There's something slightly deceiving about this example. When calling `mqtt.subscribe` our first parameter is `self: *Client`. The first parameter to `write` is also `self: *Client`. It's tempting to think that this is necessary since `mqtt` is of type `mqtt.Mqtt(Client)`, but this is not the case. The following is equally valid:

```zig
const Client = struct {
    mqtt: mqtt.Mqtt(Client),
    socket: std.posix.socket_t,

    // wrap mqtt.publish
    pub fn publish(self: *Client, topic: []const u8, message: []const u8) !usize {
        const ctx = Client.Context{
            .client = self,
            .method = .publish,
        };

        return self.mqtt.publish(ctx, .{
            .topic = topic,
            .message = .message,
        });
    }

    // One of the three methods we must implement
    pub fn write(ctx: Client.Context, data: []const u8) !void {
        std.posix.write(ctx.client.socket, data) catch |err| {
            if (ctx.method == .publish) {
                // maybe we want to retry for publish only?
            }
            ...
        };
    }
}
```

While it's common that the state you pass into the various `Mqtt(T)` methods will be of type `*T`, this is not required. As we see from this example, we can leverage the `anytype` to include additional context.

## Flow
Without being able to make assumptions about the environment and given the fact that MQTT is optionally bidirectional, the library can only provide building blocks. Specifically, while the main methods of `Mqtt(T)` will write the request (relying on `T.write` to do the actual writing), none attempt to read the response. It is the responsibility of the implementation to call `readPacket` either when expecting a response, or periodically when consuming messages.

In cases, where you're either writing just a publisher or just a consumer, the flow is straightforward (and probably could be handled by the library). However, where a single connection is used to both publish and subscribe the flow isn't as straight forward. Essentially, whenever you `readPacket`, depending on your specific used case, you have to be ready to handle different types of packets.

```zig
var read_buf: [1024]u8 = undefined;
var write_buf: [1024]u8 = undefined;

var mqtt = try mqtt.Mqtt(Client).init(&read_buf, &write_buf);
try mqtt.connect(.{});
switch (try mqtt.readPacket()) {
    .connack => |connack| {
        // maybe check some of connack's fields to see
        // what capabilities the server has?
    },
    .disconnect => |disconnect| {
        // maybe check disconnect.reason_code
        // and the optional disconnect.reason_string
        return;
    },
    else => // TODO: this should not be possible the server should 
            // not send any other type of packet at this point
}
```

After initializing the connection and calling `connect`, which sends a `CONNACK` packet, the only possible response packets are `connack` or `disconnect`. Next, we subscribe:

```zig
const packet_identifier = try mqtt.subscribe(some_state, .{
    .topics = &.{
        .{.filter = "topic1"}
    }
});
switch (try mqtt.readPacket()) {
    .suback => |suback| {
        std.debug.assert(suback.packet_identifier == packet_identifier)
    },
    .disconnect => return,
    else => // TODO: this should not be possible the server should 
            // not send any other type of packet at this point
}
```

Again, only a `suback` or `disconnect` should be possible at this point. And, the `suback.packet_identifier` should be equal to the `packet_identifier` returned by `subscribe`.

Finally, let's make another subscription:

```zig
const packet_identifier = try mqtt.subscribe(some_state, .{
    .topics = &.{
        .{.filter = "topic2"}
    }
});

switch (try mqtt.readPacket()) {
    .suback => |suback| {
        std.debug.assert(suback.packet_identifier == packet_identifier)
    },
    .publish => |publish| {
        // TODO
    }
    .disconnect => return,
    else => // TODO: this should not be possible the server should 
            // not send any other type of packet at this point
}
```

This time when calling `readPacket` we also handle the possibility of a `publish` packet. This is necessary because we previously subscribed to `topic1`.

### TL;DR
Implementations are responsible for calling `mqtt.readPacket()`. If your flow is straightforward (e.g. subscribe and then get published messages, or just publishing messages), then mqttz's usage is simple.

## T.read, T.write & T.close
T must expose `read`, `write` and `close` functions.

The first parameter to these functions is the same `anytype` that was passed into the `Mqtt(T)` function that triggered it.

### T.read(state: anytype, buf: []u8, calls: usize) !usize
Reads data into `buf` - presumably from a socket referenced directly or indirectly by `state`. Returns the number of bytes read. If 0 is returned, assumes the connection is closed.

Only `Mqtt(T).readPacket` can currently trigger a call to `T.read`. For a single call to `Mqtt(T).readPacket`, `T.read` might be called 0 or more times. It would be called 0 times if a previous call to `readPacket` had caused multiple packets to be read. The `calls` parameter indicates the number of times `T.read` has been called for a single call to `readPacket`

### T.write(state: anytype, data: []const u8) !void
Writes `data` - presumably from a socket referenced directly or indirectly by `state`. `T.write` must write all of `data`.

### T.close(state: anytype) !void
Called with `Mqtt(T).disconnect` is called. `disconnect` (and thus `T.close`).

This can be called internally, via `disconnect`, by the library as required by the specification (e.g. when a `connack` response is received with indicating that a session is present, but `clean_start` was specified).

## Errors
`Mqtt(T)` methods return errors which are meant to be easy(ish) to manage. The `last_error` field is an optional tagged union that can include additional information. The ideas is to provide a manageable number of error values without sacrificing additional details (which might traditionally be handled by having a much larger error set, which is harder to handle).

For example, the only errors `subscribe` can return are: `error.Usage`, `error.WriteBufferIsFull` or `error.Write`. If an error is returned, in most cases the optional `last_error` field will be set. Above, we saw that `T.write(...) !void` can return any error. If `T.write` does return an error, `subscribe` will map this to `error.Write` and set `last_error.?.inner` to the actual error returned by `T.write`.

# Mqtt(T)
As a consequence of being a foundation, `Mqtt(T)` has a simple interface.

## init(read_buf: []u8, write_buf: []u8) Mqtt(T)
Initializes an instance. 

`read_buf` must remain valid for the lifetime of the returned `Mqtt(T)` value. `read_buf` must be big enough to handle any message received by the server. If you're only publishing message, than `read_buf` can be relatively small. If you're receiving message, then you'll have to size `read_buf` accordingly. `error.ReadBufferIsFull` is returned from reading functions (i.e. `readPacket`) if `read_buf` is too small to accommodate the packet.

`write_buf` must remain valid for the lifetime of the returned `Mqtt(T)` value. `write_buf` must be big enough to handle any message sent to the server. If you're only only receiving messages, then `write_buf` can be relatively small. If you're sending message, then you'll have to size `write_buf` accordingly. `error.WriteBufferIsFull` is returned from writing functions (i.e. `connect`, `subscribe`, `publish`, ...) if `write_buf` is too small to accommodate the packet.

MQTT is a compact protocol. To figure out the size you'll need, you can generally add up the length of your longest strings (like the name of the topic + the message) and add a few bytes of overhead.

## connect(state: anytype, opts: ConnectOpts) !void
None of the `opts` field are required. 

Will call T.write(state, data) exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`.

## subscribe(state: anytype, opts: SubscribeOpts) !usize
`opts` must include at least 1 topic which must contain a filter:

```zig
mqtt.subscribe(&ctx, .{
    .topics = &.{
        .{.filter = "a/b"},
    },
}
```

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`, `error.Usage`. `error.Usage` happens if no topic is provided.

Returns the `packet_identifier`. The `packet_identifier` can be set explicitly via the `packet_identifier: ?u16 = null` field of the `SubscribeOpts`. Otherwise, an incrementing integer is used. The `packet_identifier` is used to pair the `subscribe` with corresponding `suback` which can be retrieved via `readPacket()`.

## unsubscribe(state: anytype, opts: UnsubscribeOpts) !usize
`opts` must include at least 1 topic :

```zig
mqtt.unsubscribe(&ctx, .{
    .topics = &.{"a/b"},
}
```

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`, `error.Usage`. `error.Usage` happens if no topic is provided.

Returns the `packet_identifier`. The `packet_identifier` can be set explicitly via the `packet_identifier: ?u16 = null` field of the `UnsubscribeOpts`. Otherwise, an incrementing integer is used. The `packet_identifier` is used to pair the `unsubscribe` with corresponding `unsuback` which can be retrieved via `readPacket()`.

## publish(state: anytype, opts: PublishOpts) !usize
`opts` must include at a `topic` and `message`. These can be empty (an empty `topic` is common if `topic_alias` is set.)

```zig
mqtt.public(&ctx, .{
    .topics = "power/goku",
    .message = "over 9000!"
}
```

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`, `error.Usage`. `error.Usage` happens if the `retain` flag is set, but the server announced (via the `connack` message) that it did not support retained messages.

Returns the `packet_identifier`. The `packet_identifier` can be set explicitly via the `packet_identifier: ?u16 = null` field of the `PublishOpts`. Otherwise, an incrementing integer is used. The `packet_identifier` is used to pair the `publish` with corresponding `pubrec` or `pubrel` assuming the `qos` option is set.

## puback(state: anytype, opts: PubAckOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`.

## pubrec(state: anytype, opts: PubRecOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`.

## pubrel(state: anytype, opts: PubRelOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`.

## pubcomp(state: anytype, opts: PubCompOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Write`.

## disconnect(state: anytype. opts: DisconnectOpts) !void
`opts` must include the `reason` for the disconnect. This is an enum.

```zig
* `normal`
* `disconnect_with_will_message`
* `unspecified`
* `malformed_packet`
* `protocol_error`
* `implementation_specific`
* `topic_name_invalid`
* `receive_maximum_exceeded`
* `topic_alias_invalid`
* `packet_too_large`
* `message_rate_too_high`
* `quota_exceeded`
* `administrative_action`
* `payload_format_invalid`
```

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.Write`.

## ping(state: anytype) !void
This will call `T.write(state, data)` exactly once.

Possible errors are: `error.Write`.

## readPacket(state: anytype) !void
Attempts to read a packet from the server.

This may call `T.read(state, buf, calls)` 0 or more times. It will call it 0 times if there is already a packet in `read_buf` (from a previous call to `T.read` which read more than 1 packet). `calls` is the number of times (starting at 1) that `T.read` has been called in this single invocation of `readPacket`. This could be used, for example, to control a timeout (in most cases, you'll probably just ignore `calls`).

Possible errors are: 
- `error.Read` - `T.read` returned an error (see `last_error.?.inner` for the actual error it returned)
- `error.Closed` - `T.read` returned 0
- `error.ReadBufferIsFull` - The packet was too large to fit in `read_buf`
- `error.Protocol` - A valid packet was received but, from this libraries point of view, the packet didn't make sense. For example, the packet might have had a `reason_code` which was not valid (not one of the allowed u8 values). If you're using a robust server implementation, this is likely a bug/oversight in this library
- `error.MalformedPacket` - An invalid packet was received which could not be parsed. If you're using a robust server implementation, this is likely a bug/oversight in this library.
- `error.Reason` - A valid response was received, but with an error reason. Use `last_error.?.reason` to get the enum reason. In many cases, this will be followed by the server closing the connection.

On success, `readPacket` returns a tagged union. This union has the following tags:

* `connack: mqtt.Packet.ConnAck`
* `suback: mqtt.Packet.SubAck`
* `unsuback: mqtt.Packet.UnsubAck`
* `publish: mqtt.Packet.Publish`
* `puback: mqtt.Packet.PubAck`
* `pubrec: mqtt.Packet.PubRec`
* `pubrel: mqtt.Packet.PubRel`
* `pubcomp: mqtt.Packet.PubComp`
* `disconnect: mqtt.Packet.Disconnect`
* `pong: void` - called `pingresp` in the spec, but why?

`[]const u8` values in the above structures are only valid until the next call to `readPacket`.

See the [Flow](#flow) for more information.

### Packet.SubAck
The `subscribe` method allows multiple topics to be specified. The corresponding `suback` contains 1 reason code per topic. If you subscribed to 3 topics, the corresponding `suback.results.len` should equal 3. However, `suback.results` is a `[]const u8`, representing the numeric reason code. Use `suback.result(idx) ?mqtt.QoS` to get a more meaningful result.

When the subscription is success, you'll get a `mqtt.Qos` enum value indicating the QoS level of the subscription. Else you'll get one of these errors:

* `error.Protocol`
* `error.Unspecified`
* `error.ImplementationSpecific`
* `error.NotAuthorized`
* `error.TopicFilterInvalid`
* `error.PacketIdentifierInUse`
* `error.QuotaExceeded`
* `error.SharedSubscriptionsNotSupported`
* `error.SubscriptionIdentifierNotSupported`
* `error.WildcardSubscriptionsNotSupported`

### Packet.UnsubAck
Like `subscribe` and `suback`, `unsubscribe` and `unsuback` also allow multiple topics to be specified. Again, `unsuback.results` is a `[]const u8` representing the underlying integer code for each unsubscribed topic. Use `unsuback.result(idx)` to get a meaningful error. On success, this returns nothing. Else you'll get an error:

* `error.Protocol`
* `error.NoSubscriptionExisted`
* `error.Unspecified`
* `error.ImplementationSpecific`
* `error.NotAuthorized`
* `error.TopicFilterInvalid`
* `error.PacketIdentifierInUse`

## lastReadPacket() []const u8
Returns the full raw packet from the last call to `readPacket`. Might be useful when debugging.
