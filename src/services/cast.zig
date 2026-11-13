const std = @import("std");
const state = @import("../core/state.zig");

// ══════════════════════════════════════════════════════════
// Cast — Send media to TV/streamers.
//
// Two transports live here:
//   • Chromecast — via the external `catt` tool (pip install catt), optional.
//   • DLNA/UPnP AVTransport — NATIVE, no external tools: SSDP M-SEARCH finds
//     MediaRenderers on the LAN, the device description XML gives us the
//     AVTransport control URL, and two SOAP calls (SetAVTransportURI + Play)
//     start playback. This is what most Samsung/LG/Philips and Android TVs
//     answer to, so cast works out of the box without installing anything.
// ══════════════════════════════════════════════════════════

const alloc = @import("../core/alloc.zig").allocator;
const http = @import("../core/http.zig");
const io_global = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const lan_bridge = @import("lan_bridge.zig");

pub const CastDevice = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    ip: [46]u8 = std.mem.zeroes([46]u8),
    ip_len: usize = 0,
    /// DLNA devices carry the AVTransport control URL here; catt devices
    /// (control_url_len == 0) are cast by shelling out to catt.
    control_url: [512]u8 = std.mem.zeroes([512]u8),
    control_url_len: usize = 0,

    pub fn isDlna(self: *const CastDevice) bool {
        return self.control_url_len > 0;
    }
};

pub var devices: [16]CastDevice = undefined;
pub var device_count: usize = 0;
// Written by detached workers, polled by the UI thread AND remote.zig's
// connection threads → atomics, not plain bools (CLAUDE.md thread-safety rule).
pub var is_scanning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var is_casting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var active_device_idx: ?usize = null;
/// Set before scanDevices() by the cast button: when the scan lands devices,
/// the active playback auto-casts to the first one (phone-style one-click).
pub var auto_cast_next_scan: bool = false;
/// Set by the catt watchdog when the parent stopped waiting. Module-level, not
/// a stack local: the watchdog outlives the scanning worker's block when catt
/// exits early, and polling a dead frame segfaulted the scan.
var catt_scan_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn storeDevice(name: []const u8, ip: []const u8, control_url: ?[]const u8) void {
    if (device_count >= devices.len) return;
    var dev = &devices[device_count];
    dev.* = .{};
    const nlen = @min(name.len, dev.name.len - 1);
    @memcpy(dev.name[0..nlen], name[0..nlen]);
    dev.name_len = nlen;
    const ilen = @min(ip.len, dev.ip.len - 1);
    @memcpy(dev.ip[0..ilen], ip[0..ilen]);
    dev.ip_len = ilen;
    if (control_url) |cu| {
        const clen = @min(cu.len, dev.control_url.len - 1);
        @memcpy(dev.control_url[0..clen], cu[0..clen]);
        dev.control_url_len = clen;
    }
    device_count += 1;
}

/// Discover cast devices: `catt scan` (Chromecast, optional tool) merged with
/// the native SSDP/DLNA discovery (works everywhere, no tools needed).
pub fn scanDevices() void {
    if (is_scanning.load(.acquire)) return;
    is_scanning.store(true, .release);
    device_count = 0;

    if (workers.spawnLegacy(struct {
        fn worker() void {
            defer is_scanning.store(false, .release);

            // ── native DLNA (SSDP + AVTransport) FIRST ──
            // Bounded (probe windows are fixed), needs no tools. catt must not
            // run before it: see below.
            dlnaScan();

            if (auto_cast_next_scan) {
                auto_cast_next_scan = false;
                if (device_count > 0) castActiveTo(preferredDevice());
            }

            // ── catt (Chromecast) — optional, HARD-BOUNDED ──
            // catt 0.13+ has no timeout option on `scan` and on some networks
            // hangs indefinitely; the unbounded wait pinned this whole worker
            // behind it, so the button scan never completed and auto-cast
            // never fired even though DLNA was ready. Kill the child after
            // the window and parse whatever it printed (usually nothing).
            const CATT_SCAN_WINDOW_MS: i64 = 12_000;
            const argv = [_][]const u8{ "catt", "scan" };
            var child = io_global.Child.init(&argv, alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            // A DLNA renderer already answered: skip the optional Chromecast
            // scan. catt has no timeout of its own and can block this worker
            // indefinitely, which left the button stuck on "scanning".
            if (device_count == 0) {
            if (child.spawn()) |_| {
                catt_scan_done.store(false, .release);
                if (child.id) |cid| {
                    if (workers.spawnLegacy(struct {
                        fn watchdog(id: io_global.Child.Id, done: *std.atomic.Value(bool)) void {
                            var waited: i64 = 0;
                            while (waited < CATT_SCAN_WINDOW_MS) : (waited += 250) {
                                if (done.load(.acquire)) return;
                                io_global.sleep(250 * std.time.ns_per_ms);
                            }
                            // TerminateProcess on the child HANDLE (no PID
                            // reuse risk); an already-exited child just
                            // fails harmlessly. The parent still reaps.
                            io_global.terminateProcess(id);
                        }
                    }.watchdog, .{ cid, &catt_scan_done })) |wt| {
                        workers.release(wt);
                    } else |_| {}
                }

                var buf: [4096]u8 = undefined;
                const n = if (child.stdout) |*stdout| io_global.readAll(stdout, &buf) catch 0 else 0;
                catt_scan_done.store(true, .release);
                _ = child.wait() catch {};

                // Parse output: each line is "DeviceName - IP:port"
                var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
                while (lines.next()) |line| {
                    if (line.len < 5) continue;
                    if (std.mem.indexOf(u8, line, " - ")) |dash_pos| {
                        const name = line[0..dash_pos];
                        const ip_part = line[dash_pos + 3 ..];
                        // Strip port if present
                        const ip = if (std.mem.indexOf(u8, ip_part, ":")) |col| ip_part[0..col] else ip_part;
                        storeDevice(name, ip, null);
                    }
                }
            } else |_| {
                // catt not installed — native DLNA above already ran.
            }
            }

            if (auto_cast_next_scan) {
                // DLNA found nothing; a Chromecast may have landed late.
                auto_cast_next_scan = false;
                if (device_count > 0) castActiveTo(preferredDevice());
            }

            if (device_count > 0) {
                var msg: [64]u8 = undefined;
                const toast = std.fmt.bufPrint(&msg, "Found {d} cast device(s)", .{device_count}) catch "Devices found";
                state.showToast(toast);
            } else {
                state.showToast("No cast devices found");
            }
        }
    }.worker, .{})) |t| workers.release(t) else |_| {}
}

// ── native DLNA (SSDP + UPnP AVTransport) ────────────────

/// First value of `tag` inside `src` (no namespaces, trimmed). UPnP device
/// description XML is small and regular — a scan beats dragging in a parser.
fn xmlValue(src: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [48]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, src, open) orelse return null;
    const rest = src[start + open.len ..];
    var close_buf: [48]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const end = std.mem.indexOf(u8, rest, close) orelse return null;
    return std.mem.trim(u8, rest[0..end], " \t\r\n");
}

/// Escape `src` into `out` so it is a valid XML text node (URLs carry &).
fn xmlEscape(src: []const u8, out: []u8) ?[]const u8 {
    var w: usize = 0;
    for (src) |ch| {
        const rep: ?[]const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => null,
        };
        if (rep) |r| {
            if (w + r.len > out.len) return null;
            @memcpy(out[w .. w + r.len], r);
            w += r.len;
        } else {
            if (w + 1 > out.len) return null;
            out[w] = ch;
            w += 1;
        }
    }
    return out[0..w];
}

/// The AVTransport control URL from a device description document, absolutized
/// against `location` (the URL the document was fetched from).
fn avtransportControlUrl(location: []const u8, xml: []const u8, out: []u8) ?[]const u8 {
    // The <service> block for AVTransport: everything between its serviceType
    // marker and the closing </service> holds this service's controlURL.
    const st = std.mem.indexOf(u8, xml, "urn:schemas-upnp-org:service:AVTransport:1") orelse return null;
    const block_end = std.mem.indexOf(u8, xml[st..], "</service>") orelse (xml.len - st);
    const block = xml[st .. st + block_end];
    const raw = xmlValue(block, "controlURL") orelse return null;

    // Absolutize against the location's scheme://host[:port] prefix.
    const scheme_end = std.mem.indexOf(u8, location, "://") orelse return null;
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalar(u8, location[host_start..], '/') orelse location.len;
    const base_len = host_start + path_start;
    if (raw.len == 0 or base_len + raw.len + 1 > out.len) return null;
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) {
        if (raw.len > out.len) return null;
        @memcpy(out[0..raw.len], raw);
        return out[0..raw.len];
    }
    // The base (`scheme://host[:port]`) comes from the location, not from the
    // service's controlURL. Leaving it unfilled produced a control URL with
    // garbage where the host belongs, so every SOAP cast failed.
    @memcpy(out[0..base_len], location[0..base_len]);
    if (raw[0] != '/') {
        out[base_len] = '/';
        const after = base_len + 1;
        if (after + raw.len > out.len) return null;
        @memcpy(out[after .. after + raw.len], raw);
        return out[0 .. after + raw.len];
    }
    @memcpy(out[base_len .. base_len + raw.len], raw);
    return out[0 .. base_len + raw.len];
}


/// Extract every IPv4 address from `text` (label-language independent: parses
/// the dotted quads, not the localized labels). Skips loopback, link-local
/// APIPA and multicast/reserved ranges — those never host a LAN renderer.
fn appendIPv4s(text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (std.ascii.isDigit(text[i])) {
            var octets: [4]u32 = undefined;
            var j: usize = 0;
            var valid = true;
            var end = i;
            while (j < 4) : (j += 1) {
                if (end >= text.len or !std.ascii.isDigit(text[end])) { valid = false; break; }
                const start = end;
                while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
                const v = std.fmt.parseInt(u32, text[start..end], 10) catch { valid = false; break; };
                if (v > 255) { valid = false; break; }
                octets[j] = v;
                if (j < 3) {
                    if (end >= text.len or text[end] != '.') { valid = false; break; }
                    end += 1;
                }
            }
            if (valid) {
                const a = octets[0]; const b = octets[1];
                const skip = a == 127 or (a == 169 and b == 254) or a == 0 or a >= 224;
                if (!skip) {
                    const ip = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] });
                    var dup = false;
                    for (out.items) |prev| if (std.mem.eql(u8, prev, ip)) { dup = true; };
                    if (dup) alloc.free(ip) else try out.append(alloc, ip);
                }
                i = end;
                continue;
            }
        }
        i += 1;
    }
}

/// Every non-loopback local IPv4 address, probed for SSDP on multi-homed
/// machines (VPN/virtual adapters steal the default multicast route — the
/// real LAN is then unreachable from 0.0.0.0-bound sockets).
fn localIPv4Candidates() std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .windows => &.{"ipconfig"},
        .macos => &.{"ifconfig"},
        else => &.{ "ip", "-4", "addr" },
    };
    var child = io_global.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return list;
    var buf: [64 * 1024]u8 = undefined;
    const n = if (child.stdout) |*so| io_global.readAll(so, &buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return list;
    appendIPv4s(buf[0..n], &list) catch {};
    return list;
}

/// SSDP M-SEARCH for MediaRenderers, then one HTTP GET per device to read the
/// friendlyName + AVTransport control URL. Appends to `devices`.
fn dlnaProbe(io: std.Io, local_ip: ?[]const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize, window_ms: i64) void {
    // Zig's std.Io has no UDP receive-with-timeout on Windows: net_receive with
    // a timeout answers error.ConcurrencyUnavailable, so the SSDP socket never
    // read a single reply and scans found no devices. WinSock with SO_RCVTIMEO
    // is the working path there.
    if (@import("builtin").os.tag == .windows) {
        dlnaProbeWindows(local_ip, locations, loc_buf, location_count, window_ms);
        return;
    }
    const local = if (local_ip) |ip|
        std.Io.net.IpAddress.parseIp4(ip, 0) catch return
    else
        std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return;
    var sock = local.bind(io, .{ .mode = .dgram, .allow_broadcast = true }) catch return;
    defer sock.close(io);

    const msearch =
    "M-SEARCH * HTTP/1.1\r\n" ++
    "HOST: 239.255.255.250:1900\r\n" ++
    "MAN: \"ssdp:discover\"\r\n" ++
    "MX: 2\r\n" ++
    "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" ++
    "\r\n";
    var maddr = std.Io.net.IpAddress.parseIp4("239.255.255.250", 1900) catch return;
    // Two sends: single-shot discovery routinely misses slow responders.
    sock.send(io, &maddr, msearch) catch return;
    sock.send(io, &maddr, msearch) catch {};
    // Some access points drop multicast between clients while the TV still
    // answers the limited broadcast address (observed on a TCL renderer).
    var baddr = std.Io.net.IpAddress.parseIp4("255.255.255.255", 1900) catch return;
    sock.send(io, &baddr, msearch) catch {};
    sock.send(io, &baddr, msearch) catch {};

    const deadline = io_global.monotonicMilliTimestamp() + window_ms;
    while (io_global.monotonicMilliTimestamp() < deadline and location_count.* < locations.len) {
        var rbuf: [1500]u8 = undefined;
        const msg = sock.receiveTimeout(
            io,
            &rbuf,
            .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } },
        ) catch continue;
        const resp = msg.data;
        var it = std.mem.splitScalar(u8, resp, '\n');
        while (it.next()) |line| {
            const ll = std.mem.trim(u8, line, " \r");
            if (ll.len < 10 or ll.len > 250) continue;
            if (std.ascii.startsWithIgnoreCase(ll, "LOCATION:")) {
                const loc = std.mem.trim(u8, ll["LOCATION:".len..], " \r");
                if (loc.len == 0 or !std.mem.startsWith(u8, loc, "http")) continue;
                var dup = false;
                for (locations[0..location_count.*]) |seen| {
                    if (std.mem.eql(u8, seen, loc)) dup = true;
                }
                if (dup) continue;
                @memcpy(loc_buf[location_count.*][0..loc.len], loc);
                locations[location_count.*] = loc_buf[location_count.*][0..loc.len];
                location_count.* += 1;
            }
        }
    }
}

/// Record every LOCATION: in an SSDP reply, ignoring duplicates.
fn collectLocations(resp: []const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize) void {
    var it = std.mem.splitScalar(u8, resp, '\n');
    while (it.next()) |line| {
        const ll = std.mem.trim(u8, line, " \r");
        if (ll.len < 10 or ll.len > 250) continue;
        if (!std.ascii.startsWithIgnoreCase(ll, "LOCATION:")) continue;
        const loc = std.mem.trim(u8, ll["LOCATION:".len..], " \r");
        if (loc.len == 0 or !std.mem.startsWith(u8, loc, "http")) continue;
        var dup = false;
        for (locations[0..location_count.*]) |seen| {
            if (std.mem.eql(u8, seen, loc)) dup = true;
        }
        if (dup) continue;
        @memcpy(loc_buf[location_count.*][0..loc.len], loc);
        locations[location_count.*] = loc_buf[location_count.*][0..loc.len];
        location_count.* += 1;
    }
}

/// WinSock SSDP probe (Windows). `std.Io` cannot do a timed UDP receive there,
/// so this opens a WinSock datagram socket with SO_RCVTIMEO instead.
fn dlnaProbeWindows(local_ip: ?[]const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize, window_ms: i64) void {
    const SOCKET = usize;
    const invalid_socket: SOCKET = ~@as(SOCKET, 0);
    const sockaddr_in = extern struct {
        family: u16,
        port: u16,
        addr: u32,
        pad: [8]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const ws2_32 = struct {
        extern "ws2_32" fn WSAStartup(ver: u16, data: *anyopaque) c_int;
        extern "ws2_32" fn socket(af: c_int, typ: c_int, proto: c_int) SOCKET;
        extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, opt: c_int, val: *const anyopaque, len: c_int) c_int;
        extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, len: c_int) c_int;
        extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int, to: *const anyopaque, tolen: c_int) c_int;
        extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int, from: ?*anyopaque, fromlen: ?*c_int) c_int;
        extern "ws2_32" fn closesocket(s: SOCKET) c_int;
        extern "ws2_32" fn WSAGetLastError() c_int;
    };
    const af_inet: c_int = 2;
    const sock_dgram: c_int = 2;
    const ipproto_udp: c_int = 17;
    const sol_socket: c_int = 0xffff;
    const so_broadcast: c_int = 32;
    const so_rcvtimeo: c_int = 0x1006;
    const wsaetimedout: c_int = 10060;

    var wsa: [512]u8 align(8) = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa);
    const s = ws2_32.socket(af_inet, sock_dgram, ipproto_udp);
    if (s == invalid_socket) return;
    defer _ = ws2_32.closesocket(s);

    var one: c_int = 1;
    _ = ws2_32.setsockopt(s, sol_socket, so_broadcast, &one, @sizeOf(c_int));
    var tmo: u32 = 250;
    _ = ws2_32.setsockopt(s, sol_socket, so_rcvtimeo, &tmo, @sizeOf(u32));

    var host: u32 = 0;
    if (local_ip) |ip| host = parseIp4Native(ip) orelse return;
    var local = sockaddr_in{ .family = @intCast(af_inet), .port = 0, .addr = host };
    if (ws2_32.bind(s, &local, @sizeOf(sockaddr_in)) != 0) return;

    const msearch =
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: 2\r\n" ++
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" ++
        "\r\n";
    var dest = sockaddr_in{ .family = @intCast(af_inet), .port = std.mem.nativeToBig(u16, 1900), .addr = ip4Native4(239, 255, 255, 250) };
    _ = ws2_32.sendto(s, msearch.ptr, @intCast(msearch.len), 0, &dest, @sizeOf(sockaddr_in));
    dest.addr = ip4Native4(255, 255, 255, 255);
    _ = ws2_32.sendto(s, msearch.ptr, @intCast(msearch.len), 0, &dest, @sizeOf(sockaddr_in));

    // SO_RCVTIMEO bounds each read, so the window is a packet budget.
    const waits: i64 = @max(1, @divTrunc(window_ms, 250));
    var waited: i64 = 0;
    while (waited < waits and location_count.* < locations.len) {
        var buf: [2048]u8 = undefined;
        const n = ws2_32.recvfrom(s, &buf, @intCast(buf.len), 0, null, null);
        if (n < 0) {
            const err = ws2_32.WSAGetLastError();
            if (err != wsaetimedout) {
                // A group send that drew an ICMP refusal (WSAECONNRESET is the
                // classic Windows one) poisons the next read; aborting the
                // probe on it would drop replies that were already in flight.
                std.debug.print("[cast] ssdp recvfrom err={d} (local={s})\n", .{ err, local_ip orelse "0.0.0.0" });
            }
            waited += 1;
            continue;
        }
        collectLocations(buf[0..@intCast(n)], locations, loc_buf, location_count);
    }
}

/// Dotted quad → the little-endian u32 a sockaddr_in holds.
fn parseIp4Native(ip: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, ip, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4 or part.len == 0 or part.len > 3) return null;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return ip4Native4(octets[0], octets[1], octets[2], octets[3]);
}

fn ip4Native4(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

/// LAN hosts this machine has recently spoken to (the ARP cache), minus the
/// machine's own addresses. The unicast SSDP fallback probes these directly:
/// access points that drop multicast/broadcast between clients still deliver
/// a unicast M-SEARCH, and every UPnP renderer must answer one (the AP on this
/// network filters both groups, so the multicast pass found nothing while the
/// TCL answered a direct search on UDP 1900).
fn arpCandidates(exclude: []const []const u8) std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .linux => &.{ "ip", "neigh", "show" },
        else => &.{ "arp", "-a" },
    };
    var child = io_global.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return list;
    var buf: [64 * 1024]u8 = undefined;
    const n = if (child.stdout) |*so| io_global.readAll(so, &buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return list;
    appendIPv4s(buf[0..n], &list) catch {};
    // Filter in place: drop our own addresses (nothing to discover there),
    // keeping list ownership of the survivors for the caller's defer.
    var keep: usize = 0;
    for (list.items) |ip| {
        var mine = false;
        for (exclude) |own| if (std.mem.eql(u8, ip, own)) { mine = true; };
        if (mine) {
            alloc.free(ip);
            continue;
        }
        list.items[keep] = ip;
        keep += 1;
    }
    list.shrinkRetainingCapacity(keep);
    return list;
}

/// Unicast M-SEARCH to every ARP candidate (Windows): bind 0.0.0.0, a search
/// per candidate on UDP 1900, three rounds so slow responders land (the TCL
/// answered only on the third attempt of a bare probe). Replies are read on
/// the same socket; collectLocations records them like any other probe.
fn unicastProbeWindows(candidates: []const []const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize) void {
    const SOCKET = usize;
    const invalid_socket: SOCKET = ~@as(SOCKET, 0);
    const sockaddr_in = extern struct {
        family: u16,
        port: u16,
        addr: u32,
        pad: [8]u8 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const ws2_32 = struct {
        extern "ws2_32" fn WSAStartup(ver: u16, data: *anyopaque) c_int;
        extern "ws2_32" fn socket(af: c_int, typ: c_int, proto: c_int) SOCKET;
        extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, opt: c_int, val: *const anyopaque, len: c_int) c_int;
        extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, len: c_int) c_int;
        extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int, to: *const anyopaque, tolen: c_int) c_int;
        extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int, from: ?*anyopaque, fromlen: ?*c_int) c_int;
        extern "ws2_32" fn closesocket(s: SOCKET) c_int;
        extern "ws2_32" fn WSAGetLastError() c_int;
    };
    const af_inet: c_int = 2;
    const sock_dgram: c_int = 2;
    const ipproto_udp: c_int = 17;
    const sol_socket: c_int = 0xffff;
    const so_rcvtimeo: c_int = 0x1006;

    var wsa: [512]u8 align(8) = undefined;
    _ = ws2_32.WSAStartup(0x0202, &wsa);
    const s = ws2_32.socket(af_inet, sock_dgram, ipproto_udp);
    if (s == invalid_socket) return;
    defer _ = ws2_32.closesocket(s);

    var tmo: u32 = 250;
    _ = ws2_32.setsockopt(s, sol_socket, so_rcvtimeo, &tmo, @sizeOf(u32));
    var local = sockaddr_in{ .family = @intCast(af_inet), .port = 0, .addr = 0 };
    if (ws2_32.bind(s, &local, @sizeOf(sockaddr_in)) != 0) return;

    const msearch =
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: 2\r\n" ++
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" ++
        "\r\n";

    // The search goes to each candidate three times; one listen window per
    // round bounds the whole pass at ~3.5s for a full ARP table.
    const ROUNDS = 3;
    var round: usize = 0;
    while (round < ROUNDS and location_count.* < locations.len) : (round += 1) {
        for (candidates) |ip| {
            const host = parseIp4Native(ip) orelse continue;
            var dest = sockaddr_in{ .family = @intCast(af_inet), .port = std.mem.nativeToBig(u16, 1900), .addr = host };
            _ = ws2_32.sendto(s, msearch.ptr, @intCast(msearch.len), 0, &dest, @sizeOf(sockaddr_in));
        }
        var waited: i64 = 0;
        while (waited < 4 and location_count.* < locations.len) {
            var buf: [2048]u8 = undefined;
            const n = ws2_32.recvfrom(s, &buf, @intCast(buf.len), 0, null, null);
            if (n < 0) {
                // Timeout or an ICMP-triggered error: either way the round's
                // budget pays for it, so a hostile reset cannot spin the loop.
                waited += 1;
                continue;
            }
            collectLocations(buf[0..@intCast(n)], locations, loc_buf, location_count);
        }
    }
}

/// Unicast M-SEARCH to every ARP candidate (POSIX mirrors dlnaProbe's shape).
fn unicastProbePosix(candidates: []const []const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize) void {
    const io = io_global.io();
    const any = std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return;
    var sock = any.bind(io, .{ .mode = .dgram }) catch return;
    defer sock.close(io);

    const msearch =
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: 2\r\n" ++
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" ++
        "\r\n";

    const ROUNDS = 3;
    var round: usize = 0;
    while (round < ROUNDS and location_count.* < locations.len) : (round += 1) {
        for (candidates) |ip| {
            var dest = std.Io.net.IpAddress.parseIp4(ip, 1900) catch continue;
            sock.send(io, &dest, msearch) catch {};
        }
        var waited: i64 = 0;
        while (waited < 4 and location_count.* < locations.len) : (waited += 1) {
            var rbuf: [1500]u8 = undefined;
            const msg = sock.receiveTimeout(
                io,
                &rbuf,
                .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } },
            ) catch continue;
            collectLocations(msg.data, locations, loc_buf, location_count);
        }
    }
}

/// SSDP M-SEARCH across every local IPv4 interface (default route first),
/// then one HTTP GET per device to read the friendlyName + AVTransport
/// control URL. Appends to `devices`.
fn dlnaScan() void {
    const io = io_global.io();
    var locations: [8][]const u8 = undefined;
    var location_count: usize = 0;
    var loc_buf: [8][256]u8 = undefined;

    dlnaProbe(io, null, &locations, &loc_buf, &location_count, 2000);
    var candidates = localIPv4Candidates();
    defer {
        for (candidates.items) |ip| alloc.free(ip);
        candidates.deinit(alloc);
    }
    for (candidates.items) |ip| {
        if (location_count >= locations.len) break;
        dlnaProbe(io, ip, &locations, &loc_buf, &location_count, 1500);
    }

    // Nothing answered the group searches? Some APs (this network's included)
    // drop multicast and broadcast between wireless clients while every
    // renderer still answers a direct, unicast M-SEARCH. The ARP cache names
    // the hosts worth asking — the TV among them.
    if (location_count == 0 and candidates.items.len > 0) {
        var arp = arpCandidates(candidates.items);
        defer {
            for (arp.items) |ip| alloc.free(ip);
            arp.deinit(alloc);
        }
        if (arp.items.len > 0) {
            if (@import("builtin").os.tag == .windows) {
                unicastProbeWindows(arp.items, &locations, &loc_buf, &location_count);
            } else {
                unicastProbePosix(arp.items, &locations, &loc_buf, &location_count);
            }
        }
    }

    // One bounded HTTP GET per device description document.
    for (locations[0..location_count]) |loc| {
        if (device_count >= devices.len) break;
        var xbuf: [16 * 1024]u8 = undefined;
        const xml = http.fetch(loc, &xbuf, .{ .timeout_secs = 4 }) orelse continue;
        const name = xmlValue(xml, "friendlyName") orelse "DLNA device";
        var cbuf: [512]u8 = undefined;
        const control = avtransportControlUrl(loc, xml, &cbuf) orelse continue;

        // ip: the host part of the location (diagnostics only — the control
        // URL is what cast uses).
        const scheme_end = std.mem.indexOf(u8, loc, "://") orelse continue;
        const host_start = scheme_end + 3;
        const path_start = std.mem.indexOfScalarPos(u8, loc, host_start, '/') orelse loc.len;
        storeDevice(name, loc[host_start..path_start], control);
    }
}

/// One SOAP action against an AVTransport control URL.
fn soapAction(control_url: []const u8, action: []const u8, body: []const u8) bool {
    var envelope_buf: [4096]u8 = undefined;
    const envelope = std.fmt.bufPrint(
        &envelope_buf,
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" ++
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " ++
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" ++
            "<s:Body>{s}</s:Body></s:Envelope>",
        .{body},
    ) catch return false;

    var action_buf: [128]u8 = undefined;
    const soapaction = std.fmt.bufPrint(
        &action_buf,
        "\"urn:schemas-upnp-org:service:AVTransport:1#{s}\"",
        .{action},
    ) catch return false;

    var rbuf: [8 * 1024]u8 = undefined;
    var status: ?std.http.Status = null;
    // A fresh connection per SOAP action: the descriptor GET already left a
    // pooled keep-alive connection to the same renderer, and reusing it for the
    // POST (a body-bearing request) failed against real TVs while a fresh
    // connection succeeds.
    _ = http.fetchDirect(control_url, &rbuf, .{
        .method = .POST,
        .payload = envelope,
        .content_type = "text/xml; charset=\"utf-8\"",
        .extra_headers = &.{.{ .name = "SOAPACTION", .value = soapaction }},
        .timeout_secs = 6,
        .status_out = &status,
    }) orelse {
        std.debug.print("[cast] {s} -> no response from {s}\n", .{ action, control_url });
        return false;
    };
    return status == .ok;
}

/// MIME type for the renderer's `protocolInfo`, from the media's extension.
/// `*` is the legal wildcard and still better than an unparseable guess.
fn mediaMime(hint: []const u8) []const u8 {
    const path = if (std.mem.indexOfScalar(u8, hint, '?')) |q| hint[0..q] else hint;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "*";
    const ext = path[dot + 1 ..];
    const pairs = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = "mp4", .mime = "video/mp4" },
        .{ .ext = "m4v", .mime = "video/mp4" },
        .{ .ext = "mkv", .mime = "video/x-matroska" },
        .{ .ext = "webm", .mime = "video/webm" },
        .{ .ext = "avi", .mime = "video/x-msvideo" },
        .{ .ext = "mov", .mime = "video/quicktime" },
        .{ .ext = "ts", .mime = "video/mp2t" },
        .{ .ext = "m2ts", .mime = "video/mp2t" },
        .{ .ext = "mpg", .mime = "video/mpeg" },
        .{ .ext = "mpeg", .mime = "video/mpeg" },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(ext, p.ext)) return p.mime;
    return "*";
}

/// Item title for the DIDL-Lite entry, from the local path or the URL path.
fn mediaTitle(hint: []const u8) []const u8 {
    const path = if (std.mem.indexOfScalar(u8, hint, '?')) |q| hint[0..q] else hint;
    var start: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| start = slash + 1;
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |bs| start = @max(start, bs + 1);
    if (start >= path.len) return "Opal";
    return path[start..];
}

fn dlnaCast(control_url: []const u8, url: []const u8, media_hint: []const u8) bool {
    var uri_buf: [2048]u8 = undefined;
    const uri = xmlEscape(url, &uri_buf) orelse return false;
    // DIDL-Lite metadata is not decoration: a renderer can accept the URI,
    // report PLAYING, and never demux the stream without `protocolInfo`.
    // A TCL showed duration/position 0 with empty metadata and played the same
    // LAN-bridge URL once this item was included.
    var title_buf: [256]u8 = undefined;
    const title = xmlEscape(mediaTitle(media_hint), &title_buf) orelse "Opal";
    var didl_buf: [1024]u8 = undefined;
    const didl = std.fmt.bufPrint(
        &didl_buf,
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " ++
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " ++
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" ++
            "<item id=\"0\" parentID=\"-1\" restricted=\"1\">" ++
            "<dc:title>{s}</dc:title>" ++
            "<upnp:class>object.item.videoItem</upnp:class>" ++
            "<res protocolInfo=\"http-get:*:{s}:*\">{s}</res></item></DIDL-Lite>",
        .{ title, mediaMime(media_hint), uri },
    ) catch return false;
    var meta_buf: [2048]u8 = undefined;
    const meta = xmlEscape(didl, &meta_buf) orelse return false;
    var body_buf: [4096]u8 = undefined;
    const set_body = std.fmt.bufPrint(
        &body_buf,
        "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID><CurrentURI>{s}</CurrentURI>" ++
            "<CurrentURIMetaData>{s}</CurrentURIMetaData></u:SetAVTransportURI>",
        .{ uri, meta },
    ) catch return false;
    if (!soapAction(control_url, "SetAVTransportURI", set_body)) return false;

    var play_buf: [512]u8 = undefined;
    const play_body = std.fmt.bufPrint(
        &play_buf,
        "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>",
        .{},
    ) catch return false;
    // The renderer can stay busy starting the media right after the URI is set
    // and miss answering the immediate Play; one retry after a pause lands it.
    if (soapAction(control_url, "Play", play_body)) return true;
    io_global.sleep(1200 * std.time.ns_per_ms);
    return soapAction(control_url, "Play", play_body);
}

// ── cast / stop ──────────────────────────────────────────

/// Cast `url` to a discovered device.
///
/// The URL is a PARAMETER, not read from `state.app.players` here: every caller
/// already holds `state.players_mutex` (remote.zig's player tail, the UI thread),
/// and reaching into the player list from this function would have re-read it
/// unlocked. See `castActive` for the convenience wrapper.
pub fn castTo(device_idx: usize, url: []const u8) void {
    if (device_idx >= device_count) return;
    if (url.len == 0) {
        state.showToast("No video loaded to cast");
        return;
    }

    is_casting.store(true, .release);
    active_device_idx = device_idx;
    const device_name = devices[device_idx].name[0..devices[device_idx].name_len];
    const dlna_control: ?[]const u8 = if (devices[device_idx].isDlna())
        devices[device_idx].control_url[0..devices[device_idx].control_url_len]
    else
        null;

    // Allocate copies for the thread. The device IP drives the LAN-bridge URL
    // host pick for local files (the TV must be able to reach it).
    const url_copy = alloc.dupe(u8, url) catch return;
    const name_copy = alloc.dupe(u8, device_name) catch return;
    const control_copy: ?[]u8 = if (dlna_control) |cu| (alloc.dupe(u8, cu) catch return) else null;
    const ip_copy = alloc.dupe(u8, devices[device_idx].ip[0..devices[device_idx].ip_len]) catch return;

    if (workers.spawnLegacy(struct {
        fn worker(u: []const u8, dev: []const u8, control: ?[]u8, dev_ip: []const u8) void {
            defer {
                is_casting.store(false, .release);
                alloc.free(u);
                alloc.free(dev);
                if (control) |cc| alloc.free(cc);
                alloc.free(dev_ip);
            }

            if (control) |cc| {
                // Native DLNA: push the URL, then Play. One cast at a time —
                // a stale LAN-bridge share is replaced. A local path (C:\…,
                // /home/…, file://) is unreadable to the TV — bridge it over
                // the LAN first and push the bridge URL instead. The share
                // stays up while the TV fetches bytes; stopCast() tears it
                // down.
                lan_bridge.stopShare();
                var push_url = u;
                var bridge_buf: [256]u8 = undefined;
                if (!lan_bridge.isRemoteUrl(u)) {
                    var candidates = localIPv4Candidates();
                    defer {
                        for (candidates.items) |ip| alloc.free(ip);
                        candidates.deinit(alloc);
                    }
                    var host_buf: [46]u8 = undefined;
                    const host = lan_bridge.pickHostIp(dev_ip, candidates.items, &host_buf);
                    if (host == null or !lan_bridge.startShare(u, host.?)) {
                        state.showToast("Cast failed (local file)");
                        return;
                    }
                    push_url = lan_bridge.getShareUrl(&bridge_buf) orelse {
                        lan_bridge.stopShare();
                        state.showToast("Cast failed (local file)");
                        return;
                    };
                }

                if (dlnaCast(cc, push_url, u)) {
                    state.showToast("Casting to TV…");
                } else {
                    state.showToast("Cast failed (TV refused)");
                }
                return;
            }

            // Chromecast via catt 0.13+: options go after the subcommand.
            const argv = [_][]const u8{ "catt", "cast", "-d", dev, u };
            var child = io_global.Child.init(&argv, alloc);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            child.spawn() catch {
                state.showToast("Cast failed");
                return;
            };

            state.showToast("Casting…");
            _ = child.wait() catch {};
        }
    }.worker, .{ url_copy, name_copy, control_copy, ip_copy })) |t| workers.release(t) else |_| {}
}

/// Device the one-click Cast button should use: the renderer cast to last,
/// otherwise the first device that is NOT hosted on this machine. Discovery
/// lists a local mock/helper before real TVs often enough that a blind index 0
/// made the Cast button look dead while it happily pushed to the mock.
pub fn preferredDevice() usize {
    if (active_device_idx) |idx| {
        if (idx < device_count) return idx;
    }
    var candidates = localIPv4Candidates();
    defer {
        for (candidates.items) |ip| alloc.free(ip);
        candidates.deinit(alloc);
    }
    for (devices[0..device_count], 0..) |d, i| {
        const ip = d.ip[0..d.ip_len];
        var is_local = false;
        for (candidates.items) |lip| {
            if (!std.mem.startsWith(u8, ip, lip)) continue;
            const rest = ip[lip.len..];
            if (rest.len == 0 or rest[0] == ':') is_local = true;
        }
        if (!is_local) return i;
    }
    return 0;
}

/// Lock-free convenience for callers that do not already hold the players
/// mutex (the scan worker, the cast button): takes the lock itself.
pub fn castActiveTo(device_idx: usize) void {
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    castActive(device_idx);
}

/// Cast whatever the active player is showing. CALLER MUST HOLD
/// `state.players_mutex` — it reads the player list.
pub fn castActive(device_idx: usize) void {
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.showToast("No video loaded to cast");
        return;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    castTo(device_idx, p.current_url[0..p.current_url_len]);
}

/// Stop casting
pub fn stopCast() void {
    // Snapshot the active DLNA control URL before clearing state.
    var control_copy: ?[]u8 = null;
    if (active_device_idx) |idx| {
        if (idx < device_count and devices[idx].isDlna()) {
            control_copy = alloc.dupe(
                u8,
                devices[idx].control_url[0..devices[idx].control_url_len],
            ) catch null;
        }
    }

    if (workers.spawnLegacy(struct {
        fn worker(control: ?[]u8) void {
            defer if (control) |cc| alloc.free(cc);
            if (control) |cc| {
                var stop_buf: [512]u8 = undefined;
                const stop_body = std.fmt.bufPrint(
                    &stop_buf,
                    "<u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                        "<InstanceID>0</InstanceID></u:Stop>",
                    .{},
                ) catch return;
                _ = soapAction(cc, "Stop", stop_body);
            } else {
                const argv = [_][]const u8{ "catt", "stop" };
                var child = io_global.Child.init(&argv, alloc);
                child.spawn() catch return;
                _ = child.wait() catch {};
            }
            // The LAN bridge served the local file for this cast; the TV is
            // stopped, so close it (no-op when the cast was a remote URL).
            lan_bridge.stopShare();
            is_casting.store(false, .release);
            active_device_idx = null;
            state.showToast("Cast stopped");
        }
    }.worker, .{control_copy})) |t| workers.release(t) else |_| {}
}
