const builtin = @import("builtin");
const std = @import("std");

const posix = std.posix;
const windows = std.os.windows;
pub const system = posix.system;
const native_os = builtin.os.tag;

pub const fd_t = posix.fd_t;
pub const SOCK = posix.SOCK;
pub const pollfd = system.pollfd;
pub const POLL = posix.POLL;
pub const IPPROTO = posix.IPPROTO;
pub const F = posix.F;
pub const O = posix.O;

pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// reading a timerfd with CANCEL_ON_SET will lead to this error
    /// when the clock goes through a discontinuous change
    Canceled,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to read from it.
    AccessDenied,

    /// This error occurs in Linux if the process to be read from
    /// no longer exists.
    ProcessNotFound,

    /// Unable to read file due to lock.
    LockViolation,
} || posix.UnexpectedError;

pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    if (native_os == .windows) {
        return windows.ReadFile(fd, buf, null);
    }

    // Prevents EINVAL.
    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => return error.Unexpected,
        }
    }
}

pub fn write(fd: fd_t, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    if (native_os == .windows) {
        return windows.WriteFile(fd, bytes, null);
    }

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => return error.Unexpected,
        }
    }
}

pub const PollError = posix.PollError;

pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    if (native_os == .windows) {
        switch (windows.poll(fds.ptr, @intCast(fds.len), timeout)) {
            windows.ws2_32.SOCKET_ERROR => switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENOBUFS => return error.SystemResources,
                // TODO: handle more errors
                else => |err| return windows.unexpectedWSAError(err),
            },
            else => |rc| return @intCast(rc),
        }
    }
    while (true) {
        const fds_count = std.math.cast(posix.nfds_t, fds.len) orelse return error.SystemResources;
        const rc = system.poll(fds.ptr, fds_count, timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .FAULT => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    unreachable;
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) !usize {
    while (true) {
        const rc = posix.system.fcntl(fd, cmd, arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => return error.Unexpected,
        }
    }
}
