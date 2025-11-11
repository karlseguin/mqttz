# MQTT Client for Zig

This is a embedding-friendly MQTT client library for Zig. The library has two client: a platform-agnostic low level MQTT client where you bring your own read/write/close function and a higher level client based on Zig's stdlib.

## Examples
These example connect to [test.mosquitto.org](https://test.mosquitto.org/), so please be respectful.

The `example` folder contains examples of using both clients. The low-level client is implemented using Zig's standard library. This implementation is very basic and not as feature rich as `mqtt.posix.Client5` (i.e. no timeouts) . It is only included to show how to integrate the low-level client within your own platform.

To run the low-level clients:
Start the subscriber via: `zig build example_low_level_subscriber`. 
Then start the publisher via: `zig build example_low_level_publisher`. 

To run the posix clients:
Start the subscriber via: `zig build example_posix_subscriber`. 
Then start the publisher via: `zig build example_posix_publisher`. 

In either case, you should see 3 messages printed in your subscriber, then both programs will exit. 

## Overview
Both clients are single-threaded and follow the same paradigm. You'll call functions like `connect`, `subscribe` and `publish` to send messages to the server and call `readPacket`, as needed, to receive messages.

The "as needed" part of `readPacket` is where things get interesting. MQTT is bidirectional. If you write a `subscribe` message, you'd reasonably expect to receive a `suback`, but you could also get a `disconnect` AND, if you had previously subscribed to another topic, you could get a `publish`.

This is why even the higher level client doesn't run a background "read" thread nor does it expose a more linear request->response API (e.g. why the return value of `subscribe(...)` isn't a `Packet.Suback`). The message received after "subscribe" might not be "suback".

If you're just publishing, the flow is straightforward (especially if you're using the default `at_most_once` QoS). Things are similarly straightforward if you're subscribing (possibly to more than 1 topic, but in a single `subscribe` message) and then receiving.

This generally means that you need to call `readPacket` in a loop (until you get the expected message) and defensively handle different packet types. If you're subscribed to topics, you'll need to periodically (say, every second) call `readPacket` to check for new messages.

See the examples in the `example` folder.

## MQTT Version
The library supports both MQTT 5 and MQTT 3.1.1. This readme and the examples use the `Mqtt5(T)` generic which is the MQTT 5.0 driver. Use `Mqtt311(T)` instead for MQTT 3.1.1 support.

By default `Mqtt311(T)` will return an error if a 5.0 option is used which is not supported by 3.1.1. To avoid this runtime check, use `Mqtt311NoCheck(T)` instead. This is a good option if you want forward compatibility with 5.0 or understand the risks [of having parameters silently] ignored and want to avoid the runtime checks.

Similarly, there's a `Client5`, `Client311` and `ClientNoCheck`.

## mqtt.posix.Client5
`mqtt.posix.Client5` is a higher level library that uses Zig's standard library and should be the preferred client to use if Zig's standard library is available.

The client supports timeouts and automatic reconnects. It can optionally be configured without an allocator.

### ReadWriteOpts
All methods are thin wrappers around the lower-level `mqtt.Mqtt5(t)`. However, an additional optional parameter has been added (Zig doesn't make composing options easy, so I opted for just adding another parameter - sorry!).

Where the low-level signature is `publish(opts: SubscribeOpts)` the higher-level signature is: `publish(rw: ReadWriteOpts, opts: SubscribeOpts)`. `ReadWriteOpts` allows overriding the default `retries` and `timeout`.

```zig
client.publish(.{
    .retries 3,
    .timeout = 10_000,
}, .{
    .topic = "saiyan/goku/power",
    .message = "over 9000!",
});
```

If a timeout is reached when writing a packet, `error.Timeout` will be returned. If a timeout is reached when `readPacket` is called, `null` will be returned. This allows clients to use a short timeout to periodically check for new packet.

The client will automatically attempt to reconnect and continue the operation when `retries > 0`. When `retries` reaches 0, the underlying error is returned. At this point, the `client` can still be used as any subsequent write/reads will automatically attempt to reconnect.

### init(opts: Client5.Opts) !Client5
Initializes the client. This does not open a TCP connection to the server. 

Options are:

* `port: u16` - required
* `ip: ?[]const u8 = null` - Either `ip` or `host` is required
* `host: ?[]const u8 = null` -  - Either `ip` or `host` is required
* `connect_timeout: i32 = 10_000` - Time in milliseconds to try to connect
* `default_retries: ?u16 = null` - When either reading/writing data from/to the server, the default number of times to automatically reconnect and retry on connection failure. Can be overridden on a per-call basis.
* `default_timeout: ?i32 = null` - When either reading/writing data from/to the server, the default timeout in milliseconds, to block. Can be overridden on a per-call basis.
* `allocator: ?Allocator = null` - Optional if `ip` is used instead of `host` and both `read_buf` and `write_buf` are provided.
* `read_buf: ?[]u8 = null` - The buffer to read messages from the server into. If unspecified, the provided `allocator` will be used to create a buffer of `read_buf_size`. 
* `read_buf_size: u16 = 8192` - See `read_buf`.
* `write_buf: ?[]u8 = null` - The buffer to write messages to the server into. If unspecified, the provided `allocator` will be used to create a buffer of `write_buf_size`. 
* `write_buf_size: u16 = 8192` - See `write_buf`.

When `host` is specified, `std.net.getAddressList` is used to resolve and try each possible address. This happens on each reconnection attempt. This is why an `allocator` must be provided when `host` is used.

Trying to read a message from the server which is larger than `read_buf` (or `read_buf_size` will result in an `error.ReadBufferIsFull`. Similarly, trying to write a message larger than `write_buf` (or `write_buf_size`) will result in an `error.WriteBufferIsFull`.

If you get an `error.ReadBufferIsFull`, you can try to use `client.lastPartialPacket()` which returns a `?PartialPacket`. This is primarily meant to expose the `packet_identifier` of the message which was too large. (Note that, for a Publish message, the packet_identifier comes _after_ the topic, so a very large topic, or a very small `read_buf` will return a `null` value).

## deinit(self: \*Client5) void
Closes the socket (if it's still open) and releases the `read_buf` and `write_buf` if they are owned by the client.

For a clean shutdown, you might want to call `disconnect` before calling `deinit`.

### lastError(self: \*Client5) ?mqttz.ErrorDetail
The library attempts to make errors easy to manage while still providing some detail. The library typically returns a handful of higher-level errors (which makes it easier) while optionally exposing an error payload. The `lastErorr` method returns the error payload. (See the [errors section](#errors).

### lastReadPacket(self: \*Client5) []const u8
The last read packet. Only meant to be used for debugging. Only valid until the next call to `readPacket`.

### connect(self: \*Client5, rw: ReadWriteOpts, opts: ConnectOpts) !void
Sends a connect packet.

### publish(self: \*Client5, rw: ReadWriteOpts, opts: PublishOpts) !?u16
Sends a publish packet. If `opts.qos` was either `at_least_once` or `exactly_once`, then the returned value is the packet identifier, else it is null. The packet identifier is used to pair this publish with `puback`, `pubrec`, `pubrel` or `pubcomp` packets received from `readPacket`.

The packet identifier is an incrementing integer. It can also be explicitly set via `opts.packet_identifier`.

### subscribe(self: \*Client5, rw: ReadWriteOpts, opts: SubscribeOpts) !u16
Sends a subscribe packet. The return value is a packet identifier used to pair this message with the corresponding suback message read via `readPacket`. 

The packet identifier is an incrementing integer. It can also be explicitly set via `opts.packet_identifier`.

### unsubscribe(self: \*Client5, rw: ReadWriteOpts, opts: UnsubscribeOpts) !u16
Sends a unsubscribe packet. The return value is a packet identifier used to pair this message with the corresponding unsuback message read via `readPacket`. 

The packet identifier is an incrementing integer. It can also be explicitly set via `opts.packet_identifier`.

### puback(self: \*Client5, rw: ReadWriteOpts, opts: PubAckOpts) !void
Sends a puback packet. `opts.packet_identifier` must be set. `opts.reason_code` defaults to `.success`.

### pubrec(self: \*Client5, rw: ReadWriteOpts, opts: PubRecOpts) !void
Sends a pubrec packet. `opts.packet_identifier` must be set. `opts.reason_code` defaults to `.success`.

### pubrel(self: \*Client5, rw: ReadWriteOpts, opts: PubRelOpts) !void
Sends a pubrel packet. `opts.packet_identifier` must be set. `opts.reason_code` defaults to `.success`.

### pubcomp(self: \*Client5, rw: ReadWriteOpts, opts: PubCompOpts) !void
Sends a pubcomb packet. `opts.packet_identifier` must be set. `opts.reason_code` defaults to `.success`.

### ping(self: \*Client5, rw: ReadWriteOpts) !void
Sends a ping packet.

### disconnect(self: \*Client5, rw: ReadWriteOpts, opts: DisconnectOpts) !void
Sends a disconnect packet. `opts.reason` must be set. This is a no-op if the socket is known to be disconnected (which isn't always the case).

If `rw.retries` is not set, `0` will be set, overriding the default (why retry to connect just to disconnect?).

### readPacket(self: \*Client5, rw: ReadWriteOpts) !?mqttz.Packet
Reads a packet from the server.

## mqtt.Mqtt5(T)
The approach of `mqtt.Mqtt5(T)` is to have T provide the `MqttPlatform.read`, `MqttPlatform.write` and `MqttPlatform.close` functions. This decouples the `Mqtt5(T)` library from platform details.

Unlike most generic implementations, `Mqtt5(T)` never references `T`. It merely calls `T.MqttPlatform.read()`, `T.MqttPlatform.write()` and `T.MqttPlatform.close()` with a per-call specific `anytype`. This provides greater flexibility and facilitates composition.

Consider this partial example which wraps `Mqtt5(T)` using `std`:

```zig
const Client = struct {
    mqtt: mqtt.Mqtt5(Client),
    socket: std.posix.socket_t,

    // wrap mqtt.subscribe
    pub fn subscribe(self: *Client, opts: mqtt.SubscribeOpts) !usize {
        // the first parameter is an anytype and will be passed to the
        // read/write/close function as is
        return self.mqtt.subscribe(MqttPlatform.Context{
            .client = self,
            .timeout = 5000,
        }, opts);
    }

    pub const MqttPlatform = struct {
        const Context = struct {
            client: *Client,
            timeout: i32,
        };

        pub fn write(ctx: *Context, data: []const u8) !void {
            // todo implement timeout using ctx.timeout
            // (the real mqtt.posix.Client has timeout support)
            return std.posix.write(ctx.client.socket, data);
        }

        pub fn read(ctx: *Context, buf: [] u8) !?usize {
            // todo implement timeout using ctx.timeout
            // (the real mqtt.posix.Client has timeout support)
            return try std.posix.read(ctx.client.socket, buf);
        }

        pub fn close(ctx: *Context) void {
            std.posix.close(cts.socket);
        }
    };
}
```

While it's common that the state you pass into the various `Mqtt5(T)` methods will be of type `*T`, as we can see from the above, this is not required. 

The `read`, `write` and `close` functions are wrapped in the `MqttPlatform` container structure only to help avoid conflicts with any `read`, `write` and `close` function you might want on your own type.

## T.MqttPlatform.
T must expose `MqttPlatform.read`, `MqttPlatform.write` and `MqttPlatform.close` functions.

The first parameter to these functions is the same `anytype` that was passed into the `Mqtt5(T)` function that triggered it.

### T.MqttPlatform.read(state: anytype, buf: []u8, calls: usize) !?usize
Reads data into `buf` - presumably from a socket referenced directly or indirectly by `state`. Returns the number of bytes read. If `0` is returned, assumes the connection is closed. 

If `null` is returned, then `null` will be returned from `readPacket`. Returning `null` is how timeouts should be implemented, to indicate that there is currently no more data.

Only `Mqtt5(T).readPacket` can currently trigger a call to `read`. For a single call to `Mqtt5(T).readPacket`, `read` might be called 0 or more times. It would be called 0 times if a previous call to `readPacket` had caused multiple packets to be read. The `calls` parameter indicates the number of times `read` has been called for a single call to `readPacket` (it can be ignored in most cases).

### T.MqttPlatform.write(state: anytype, data: []const u8) !void
Writes `data` - presumably from a socket referenced directly or indirectly by `state`. `write` must write all of `data`.

### T.MqttPlatform.close(state: anytype) !void
Called with `Mqtt5(T).disconnect` is called.

This can be called internally, via `disconnect`, by the library as required by the specification (e.g. when a `connack` response is received with indicating that a session is present, but `clean_start` was specified).

Since `Mqtt5(T)` is relatively stateless, it's possible for `close` to be called when your implementations' socket is already closed.

## Errors
`Mqtt5(T)` methods return errors which are meant to be easy(ish) to manage. The `last_error` field is an optional tagged union that can include additional information. The ideas is to provide a manageable number of error values without sacrificing additional details (which might traditionally be handled by having a much larger error set, which is harder to handle).

For example, the only errors `subscribe` can return are: `error.Usage`, `error.WriteBufferIsFull` or any error your `T.write` method returns. If an error is returned, in most cases the optional `last_error` field will be set. 


# Mqtt5(T)
As a consequence of being a foundation, `Mqtt5(T)` has a simple interface.

## init(read_buf: []u8, write_buf: []u8) Mqtt5(T)
Initializes an instance. 

`read_buf` must remain valid for the lifetime of the returned `Mqtt5(T)` value. `read_buf` must be big enough to handle any message received by the server. If you're only publishing message, than `read_buf` can be relatively small. If you're receiving message, then you'll have to size `read_buf` accordingly. `error.ReadBufferIsFull` is returned from reading functions (i.e. `readPacket`) if `read_buf` is too small to accommodate the packet.

`write_buf` must remain valid for the lifetime of the returned `Mqtt5(T)` value. `write_buf` must be big enough to handle any message sent to the server. If you're only only receiving messages, then `write_buf` can be relatively small. If you're sending message, then you'll have to size `write_buf` accordingly. `error.WriteBufferIsFull` is returned from writing functions (i.e. `connect`, `subscribe`, `publish`, ...) if `write_buf` is too small to accommodate the packet.

MQTT is a compact protocol. To figure out the size you'll need, you can generally add up the length of your longest strings (like the name of the topic + the message) and add a few bytes of overhead.

## connect(state: anytype, opts: ConnectOpts) !void
None of the `opts` field are required. 

Will call T.write(state, data) exactly once.

Possible errors are: `error.WriteBufferIsFull`, any error returned from your `T.MqttPlatform.write`.

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

Possible errors are: `error.WriteBufferIsFull`, `error.Usage`, any error returned from your `T.MqttPlatform.write`. `error.Usage` happens if no topic is provided.

Returns the `packet_identifier`. The `packet_identifier` can be set explicitly via the `packet_identifier: ?u16 = null` field of the `SubscribeOpts`. Otherwise, an incrementing integer is used. The `packet_identifier` is used to pair the `subscribe` with corresponding `suback` which can be retrieved via `readPacket()`.

## unsubscribe(state: anytype, opts: UnsubscribeOpts) !usize
`opts` must include at least 1 topic :

```zig
mqtt.unsubscribe(&ctx, .{
    .topics = &.{"a/b"},
}
```

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, `error.Usage` any error returned from your `T.MqttPlatform.write`. `error.Usage` happens if no topic is provided.

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

Possible errors are: `error.WriteBufferIsFull`, `error.Usage` any error returned from your `T.MqttPlatform.write`. `error.Usage` happens if the `retain` flag is set, but the server announced (via the `connack` message) that it did not support retained messages.

Returns the `packet_identifier`. The `packet_identifier` can be set explicitly via the `packet_identifier: ?u16 = null` field of the `PublishOpts`. Otherwise, an incrementing integer is used. The `packet_identifier` is used to pair the `publish` with corresponding `pubrec` or `pubrel` assuming the `qos` option is set.

## puback(state: anytype, opts: PubAckOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`,  any error returned from your `T.MqttPlatform.write`.

## pubrec(state: anytype, opts: PubRecOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`, any error returned from your `T.MqttPlatform.write`.

## pubrel(state: anytype, opts: PubRelOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`,  any error returned from your `T.MqttPlatform.write`.

## pubcomp(state: anytype, opts: PubCompOpts) !void
`opts` must include the `packet_identifer` of the `publish` this message is in response to.

This will call `T.write(state, data)` exactly once.

Possible errors are: `error.WriteBufferIsFull`,  any error returned from your `T.MqttPlatform.write`.

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

Possible errors are: any error returned from your `T.MqttPlatform.write`.

## ping(state: anytype) !void
This will call `T.write(state, data)` exactly once.

Possible errors are: any error returned from your `T.MqttPlatform.write`.

## readPacket(state: anytype) !void
Attempts to read a packet from the server.

This may call `T.read(state, buf, calls)` 0 or more times. It will call it 0 times if there is already a packet in `read_buf` (from a previous call to `T.read` which read more than 1 packet). `calls` is the number of times (starting at 1) that `T.read` has been called in this single invocation of `readPacket`. This could be used, for example, to control a timeout (in most cases, you'll probably just ignore `calls`).

Possible errors are: 
- `error.Closed` - `T.read` returned 0
- `error.ReadBufferIsFull` - The packet was too large to fit in `read_buf`
- `error.Protocol` - A valid packet was received but, from this libraries point of view, the packet didn't make sense. For example, the packet might have had a `reason_code` which was not valid (not one of the allowed u8 values). If you're using a robust server implementation, this is likely a bug/oversight in this library
- `error.MalformedPacket` - An invalid packet was received which could not be parsed. If you're using a robust server implementation, this is likely a bug/oversight in this library.

Plus any error returned by your `T.read`.

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

### User Properties
All of these packets, except `pong` might have user properties. These are exposes as an iterator:

```zig
var it = suback.userPropertis();
while (it.next()) |up| {
    // up.key
    // up.value
}
```

The key and value are only valid as long as the packet is valid (which is only valid until the next call to readPacket).

## lastReadPacket() []const u8
Returns the full raw packet from the last call to `readPacket`. Might be useful when debugging.

