const std = @import("std");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const range_parser = @import("../player/stream_proxy_range_pure.zig");
// Pure URL/host helpers + their unit tests.
const pure = @import("lan_bridge_pure.zig");
pub const isRemoteUrl = pure.isRemoteUrl;
pub const pickHostIp = pure.pickHostIp;

// ══════════════════════════════════════════════════════════
// Opal — LAN bridge for casting LOCAL files to a TV.
//
// A DLNA renderer can only fetch media over HTTP, but the active playback is
// often a plain filesystem path (C:\… or /home/…) that no TV can open. This
// bridge serves ONE local file on a LAN-reachable port with a random path
// token, byte-range support (demuxers probe the tail for container indexes)
// and DLNA streaming headers, so cast.zig can push
//   http://<pc-lan-ip>:<port>/s/<token>
// to the TV's SetAVTransportURI instead of an unreadable local path.
//
// Single share at a time — a new cast replaces the previous one; stopShare()
// runs when casting stops. Mirrors the accept/token/teardown design of
// player/stream_proxy.zig (which serves torrent bytes on 127.0.0.1 only).
// ══════════════════════════════════════════════════════════

const CHUNK_SIZE: usize = 512 * 1024;
const PORT_RANGE_START: u16 = 45688;
const PORT_RANGE_END: u16 = 45788; // exclusive
const TOKEN_HEX_LEN: usize = 32;

// Probe a port to get the concrete listener type — std.Io 0.16 doesn't
// expose this directly, so we recover it via @TypeOf on a known-good call.
const ListenerT = @TypeOf(blk: {
    const a = std.Io.net.IpAddress.parseIp4("127.0.0.1", PORT_RANGE_START) catch unreachable;
    break :blk a.listen(io_g.io(), .{ .reuse_address = true }) catch unreachable;
});

const Share = struct {
    in_use: bool = false,
    id: u32 = 0,
    port: u16 = 0,
    token: [TOKEN_HEX_LEN]u8 = std.mem.zeroes([TOKEN_HEX_LEN]u8),
    file: ?std.Io.File = null,
    file_size: i64 = 0,
    file_name: [256]u8 = std.mem.zeroes([256]u8),
    file_name_len: usize = 0,
    host_ip: [46]u8 = std.mem.zeroes([46]u8),
    host_ip_len: usize = 0,
    stop: bool = false,
    thread: ?std.Thread = null,
    listener: ?ListenerT = null,
};

var share: Share = .{};
var share_mutex = sync.Mutex{};
var next_share_id: u32 = 1;

var csprng_init: bool = false;
var csprng: std.Random.DefaultCsprng = undefined;
var csprng_mutex = sync.Mutex{};

fn seedCsprng() void {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    // Platform entropy (\Device\CNG on Windows, arc4random_buf on macOS,
    // getrandom on Linux). Same fallback discipline as stream_proxy: the weak
    // time/pid mix stays only for platforms std cannot serve.
    const seeded = io_g.randomSecure(&seed);
    if (!seeded) {
        const t = io_g.milliTimestamp();
        const tid = std.Thread.getCurrentId();
        var i: usize = 0;
        while (i < seed.len) : (i += 1) {
            const mix: u64 = @as(u64, @bitCast(t)) ^ tid ^ (i *% 0x9e3779b97f4a7c15);
            seed[i] = @truncate(mix >> @as(u6, @intCast(i % 8)) * 8);
        }
    }
    csprng = std.Random.DefaultCsprng.init(seed);
}

fn randomToken(out: *[TOKEN_HEX_LEN]u8) void {
    csprng_mutex.lock();
    defer csprng_mutex.unlock();
    if (!csprng_init) {
        seedCsprng();
        csprng_init = true;
    }
    var bytes: [TOKEN_HEX_LEN / 2]u8 = undefined;
    csprng.fill(&bytes);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// True when a URL can be pushed to a TV as-is (it names a network resource).
/// Everything else — Windows paths, UNC, POSIX paths, file:// — is a local
/// file the TV cannot open and needs the bridge. (In `lan_bridge_pure.zig`.)

/// Share `path` over the LAN. `host_ip` is the interface IP the URL will use
/// (chosen by the caller — it knows the TV's subnet). A previously shared
/// file is stopped first: one cast at a time. Returns false when the file
/// cannot be opened or no port is free.
pub fn startShare(path_in: []const u8, host_ip: []const u8) bool {
    // file:// URLs name the same local file; strip the scheme.
    var path = path_in;
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path["file://".len..];
        // file://localhost/… keeps a leading slash (POSIX absolute path).
        if (std.mem.startsWith(u8, path, "localhost/")) path = path["localhost".len..];
    }
    if (path.len == 0 or path.len > 1024 or host_ip.len == 0 or host_ip.len > 45) return false;

    stopShare();

    const file = io_g.openFileAbsolute(path, .{}) catch {
        logs.pushLog("error", "cast", "LAN bridge: cannot open local file", false);
        return false;
    };
    const size: i64 = @intCast(file.length(io_g.io()) catch {
        io_g.closeFile(file);
        return false;
    });
    if (size <= 0) {
        io_g.closeFile(file);
        return false;
    }

    share_mutex.lock();

    share.file = file;
    share.file_size = size;
    share.id = next_share_id;
    next_share_id +%= 1;
    if (next_share_id == 0) next_share_id = 1;
    randomToken(&share.token);
    @memcpy(share.host_ip[0..host_ip.len], host_ip);
    share.host_ip_len = host_ip.len;
    const name_len = @min(path.len, share.file_name.len);
    @memcpy(share.file_name[0..name_len], path[0..name_len]);
    share.file_name_len = name_len;
    share.in_use = true;
    share.stop = false;

    // Probe ports from a rotating cursor.
    var bound: u16 = 0;
    var probe: u16 = PORT_RANGE_START;
    var tried: u16 = 0;
    const span: u16 = PORT_RANGE_END - PORT_RANGE_START;
    while (tried < span) : (tried += 1) {
        const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", probe) catch {
            probe = nextProbe(probe);
            continue;
        };
        if (addr.listen(io_g.io(), .{ .reuse_address = true })) |listener| {
            share.listener = listener;
            bound = probe;
            break;
        } else |_| {}
        probe = nextProbe(probe);
    }
    if (bound == 0) {
        share.in_use = false;
        io_g.closeFile(share.file.?);
        share.file = null;
        share_mutex.unlock();
        logs.pushLog("error", "cast", "LAN bridge: no free port in 45688-45787", false);
        return false;
    }
    share.port = bound;

    share.thread = @import("../core/workers.zig").spawnLegacy(acceptLoop, .{}) catch {
        if (share.listener) |*l| l.deinit(io_g.io());
        share.listener = null;
        share.port = 0;
        share.in_use = false;
        io_g.closeFile(share.file.?);
        share.file = null;
        share_mutex.unlock();
        logs.pushLog("error", "cast", "LAN bridge: failed to spawn server thread", false);
        return false;
    };

    share_mutex.unlock();
    logs.pushLog("info", "cast", "LAN bridge serving local file for cast", false);
    return true;
}

fn nextProbe(p: u16) u16 {
    const n = p + 1;
    return if (n >= PORT_RANGE_END) PORT_RANGE_START else n;
}

/// URL for the TV: http://<host-ip>:<port>/s/<token>. Null when nothing is
/// shared. Valid until stopShare().
pub fn getShareUrl(buf: []u8) ?[]const u8 {
    share_mutex.lock();
    defer share_mutex.unlock();
    if (!share.in_use or share.port == 0) return null;
    return std.fmt.bufPrint(
        buf,
        "http://{s}:{d}/s/{s}",
        .{ share.host_ip[0..share.host_ip_len], share.port, share.token[0..] },
    ) catch null;
}

pub fn hasActiveShare() bool {
    share_mutex.lock();
    defer share_mutex.unlock();
    return share.in_use;
}

/// Stop the shared file (no-op when nothing is shared). Joins the accept
/// thread after waking it with a local connection, mirroring stream_proxy.
pub fn stopShare() void {
    share_mutex.lock();
    if (!share.in_use) {
        share_mutex.unlock();
        return;
    }
    share.stop = true;
    const port = share.port;
    share_mutex.unlock();

    // Kick accept() awake with one local connection.
    if (port > 0) {
        if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |addr| {
            if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn| {
                var c2 = conn;
                c2.close(io_g.io());
            } else |_| {}
        } else |_| {}
    }

    share_mutex.lock();
    const thread = share.thread;
    share_mutex.unlock();
    if (thread) |t| t.join();
    // acceptLoop has already reset the slot on exit.
}

pub fn stopAll() void {
    stopShare();
}

const ConnArgs = struct {
    conn: std.Io.net.Stream,
    stream_id: u32,
};

fn acceptLoop() void {
    while (true) {
        share_mutex.lock();
        const stop_now = share.stop or !share.in_use;
        share_mutex.unlock();
        if (stop_now) break;

        const conn = share.listener.?.accept(io_g.io()) catch continue;

        share_mutex.lock();
        const stop2 = share.stop;
        const id_now = share.id;
        share_mutex.unlock();
        if (stop2) {
            var c2 = conn;
            c2.close(io_g.io());
            break;
        }

        const args = ConnArgs{ .conn = conn, .stream_id = id_now };
        if (@import("../core/workers.zig").spawnLegacy(handleConnectionThread, .{args})) |t| {
            @import("../core/workers.zig").release(t);
        } else |_| {
            handleConnection(args) catch {};
            var c2 = conn;
            c2.close(io_g.io());
        }
    }

    // Teardown: close listener + file, mark slot free.
    share_mutex.lock();
    if (share.listener) |*l| l.deinit(io_g.io());
    share.listener = null;
    if (share.file) |f| io_g.closeFile(f);
    share.file = null;
    share = .{};
    share_mutex.unlock();
}

fn handleConnectionThread(args: ConnArgs) void {
    var conn = args.conn;
    defer conn.close(io_g.io());
    handleConnection(args) catch {};
}

fn writeStatus(stream: std.Io.net.Stream, status: []const u8) void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    _ = io_g.streamWriteAll(stream, line) catch {};
}

fn handleConnection(args: ConnArgs) !void {
    share_mutex.lock();
    const expected_id = args.stream_id;
    const cur_id = share.id;
    const file_size = share.file_size;
    const token = share.token;
    const fname_buf = share.file_name;
    const fname_len = share.file_name_len;
    share_mutex.unlock();

    if (cur_id != expected_id) return; // share was replaced mid-request

    var req_buf: [4096]u8 = undefined;
    const req_len = io_g.streamReadAll(args.conn, &req_buf) catch return;
    if (req_len < 14) return; // shorter than "GET /s/X HTTP/"
    const request = req_buf[0..req_len];

    const is_head = std.mem.startsWith(u8, request, "HEAD ");
    const is_get = std.mem.startsWith(u8, request, "GET ");
    if (!is_head and !is_get) {
        writeStatus(args.conn, "405 Method Not Allowed");
        return;
    }

    const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return;
    const after_method = request[method_end + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after_method, ' ') orelse return;
    const path = after_method[0..sp2];

    // Path must be exactly "/s/<token>".
    const prefix = "/s/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        writeStatus(args.conn, "404 Not Found");
        return;
    }
    const path_token = path[prefix.len..];
    if (path_token.len != TOKEN_HEX_LEN) {
        writeStatus(args.conn, "403 Forbidden");
        return;
    }
    // Constant-time compare to avoid a timing oracle on the token.
    var mismatch: u8 = 0;
    for (path_token, 0..) |ch, i| mismatch |= ch ^ token[i];
    if (mismatch != 0) {
        writeStatus(args.conn, "403 Forbidden");
        return;
    }

    var range_start: i64 = 0;
    var range_end: i64 = file_size - 1;
    var has_range = false;
    switch (range_parser.parse(request, file_size)) {
        .full => {},
        .partial => |range| {
            has_range = true;
            range_start = range.start;
            range_end = range.end;
        },
        .invalid => {
            writeStatus(args.conn, "416 Range Not Satisfiable");
            return;
        },
    }

    const content_length = range_end - range_start + 1;
    const mime = getMimeType(fname_buf[0..fname_len]);

    var hdr_buf: [640]u8 = undefined;
    const status_line = if (has_range) "206 Partial Content" else "200 OK";
    // DLNA.ORG_OP=01 advertises byte-range seeking; TransferMode marks this a
    // streamed AV item (some Samsung/LG renderers expect both).
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Accept-Ranges: bytes\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "TransferMode.dlna.org: Streaming\r\n" ++
            "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0\r\n",
        .{ status_line, mime, content_length },
    ) catch return;
    _ = io_g.streamWriteAll(args.conn, hdr) catch return;

    if (has_range) {
        var range_hdr: [128]u8 = undefined;
        const rh = std.fmt.bufPrint(&range_hdr, "Content-Range: bytes {d}-{d}/{d}\r\n", .{ range_start, range_end, file_size }) catch return;
        _ = io_g.streamWriteAll(args.conn, rh) catch return;
    }

    _ = io_g.streamWriteAll(args.conn, "\r\n") catch return;
    if (is_head) return;

    // Each handler copies the file handle — positional reads on the same fd
    // are independent and concurrent-safe.
    share_mutex.lock();
    const file = share.file;
    share_mutex.unlock();
    var f = file orelse return;

    var offset: i64 = range_start;
    var data_buf: [CHUNK_SIZE]u8 = undefined;

    while (offset <= range_end) {
        share_mutex.lock();
        const should_stop = share.stop or share.id != expected_id;
        share_mutex.unlock();
        if (should_stop) break;

        const remaining: usize = @intCast(range_end - offset + 1);
        const want = @min(remaining, CHUNK_SIZE);
        const read = f.readPositionalAll(io_g.io(), data_buf[0..want], @intCast(offset)) catch return;

        if (read == 0) break; // EOF
        if (read < want) return; // short read: abort so the TV reconnects

        io_g.streamWriteAll(args.conn, data_buf[0..read]) catch return;
        offset += @intCast(read);
    }
}

fn getMimeType(name: []const u8) []const u8 {
    if (name.len == 0) return "application/octet-stream";
    if (std.mem.endsWith(u8, name, ".mkv")) return "video/x-matroska";
    if (std.mem.endsWith(u8, name, ".mp4")) return "video/mp4";
    if (std.mem.endsWith(u8, name, ".avi")) return "video/x-msvideo";
    if (std.mem.endsWith(u8, name, ".mov")) return "video/quicktime";
    if (std.mem.endsWith(u8, name, ".wmv")) return "video/x-ms-wmv";
    if (std.mem.endsWith(u8, name, ".webm")) return "video/webm";
    if (std.mem.endsWith(u8, name, ".flv")) return "video/x-flv";
    if (std.mem.endsWith(u8, name, ".ts")) return "video/mp2t";
    if (std.mem.endsWith(u8, name, ".m4v")) return "video/mp4";
    if (std.mem.endsWith(u8, name, ".mp3")) return "audio/mpeg";
    if (std.mem.endsWith(u8, name, ".flac")) return "audio/flac";
    if (std.mem.endsWith(u8, name, ".m4a")) return "audio/mp4";
    if (std.mem.endsWith(u8, name, ".ogg")) return "audio/ogg";
    if (std.mem.endsWith(u8, name, ".opus")) return "audio/opus";
    if (std.mem.endsWith(u8, name, ".wav")) return "audio/wav";
    if (std.mem.endsWith(u8, name, ".jpg") or std.mem.endsWith(u8, name, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, name, ".png")) return "image/png";
    return "application/octet-stream";
}
