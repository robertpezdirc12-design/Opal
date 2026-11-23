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
    /// RenderingControl control URL — volume and mute live on that service, not
    /// on AVTransport. Empty when the renderer does not advertise it.
    rcs_url: [512]u8 = std.mem.zeroes([512]u8),
    rcs_url_len: usize = 0,

    pub fn isDlna(self: *const CastDevice) bool {
        return self.control_url_len > 0;
    }

    pub fn hasVolume(self: *const CastDevice) bool {
        return self.rcs_url_len > 0;
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

fn storeDevice(name: []const u8, ip: []const u8, control_url: ?[]const u8, rcs_url: ?[]const u8) void {
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
    if (rcs_url) |cu| {
        const clen = @min(cu.len, dev.rcs_url.len - 1);
        @memcpy(dev.rcs_url[0..clen], cu[0..clen]);
        dev.rcs_url_len = clen;
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
                        storeDevice(name, ip, null, null);
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

/// One service's control URL from a device description document, absolutized
/// against `location` (the URL the document was fetched from). `service` is the
/// service suffix, e.g. "AVTransport:1" or "RenderingControl:1".
fn serviceControlUrl(location: []const u8, xml: []const u8, service: []const u8, out: []u8) ?[]const u8 {
    // The <service> block for `service`: everything between its serviceType
    // marker and the closing </service> holds this service's controlURL.
    var marker_buf: [96]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "urn:schemas-upnp-org:service:{s}", .{service}) catch return null;
    const st = std.mem.indexOf(u8, xml, marker) orelse return null;
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

    // One bounded HTTP GET per device description document. fetchFresh: the
    // pooled client can hold a socket to this very renderer from an earlier
    // scan/cast that the device has long closed.
    for (locations[0..location_count]) |loc| {
        if (device_count >= devices.len) break;
        var xbuf: [16 * 1024]u8 = undefined;
        const xml = http.fetchFresh(loc, &xbuf, .{ .timeout_secs = 4 }) orelse continue;
        const name = xmlValue(xml, "friendlyName") orelse "DLNA device";
        var cbuf: [512]u8 = undefined;
        const control = serviceControlUrl(loc, xml, "AVTransport:1", &cbuf) orelse continue;
        var rbuf: [512]u8 = undefined;
        const rcs: ?[]const u8 = serviceControlUrl(loc, xml, "RenderingControl:1", &rbuf);

        // ip: the host part of the location (diagnostics only — the control
        // URL is what cast uses).
        const scheme_end = std.mem.indexOf(u8, loc, "://") orelse continue;
        const host_start = scheme_end + 3;
        const path_start = std.mem.indexOfScalarPos(u8, loc, host_start, '/') orelse loc.len;
        storeDevice(name, loc[host_start..path_start], control, rcs);
    }
}

/// One SOAP action against a UPnP service, returning its response body.
/// `rbuf` receives the response and the returned slice points into it.
fn soapServiceResponse(
    control_url: []const u8,
    service: []const u8,
    action: []const u8,
    body: []const u8,
    rbuf: []u8,
    status_out: *?std.http.Status,
) ?[]const u8 {
    var envelope_buf: [4096]u8 = undefined;
    const envelope = std.fmt.bufPrint(
        &envelope_buf,
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" ++
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " ++
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" ++
            "<s:Body>{s}</s:Body></s:Envelope>",
        .{body},
    ) catch return null;

    var action_buf: [160]u8 = undefined;
    const soapaction = std.fmt.bufPrint(
        &action_buf,
        "\"urn:schemas-upnp-org:service:{s}#{s}\"",
        .{ service, action },
    ) catch return null;

    // A fresh connection per SOAP action is not a nicety: renderers close idle
    // sockets within seconds, and a pooled keep-alive write lands on the dead
    // socket — the action silently never runs, and the next one is refused
    // (the TCL answers HTTP 500 "transport still active" because the Stop
    // before it was the one that died). fetchFresh opens a one-shot socket.
    return http.fetchFresh(control_url, rbuf, .{
        .method = .POST,
        .payload = envelope,
        .content_type = "text/xml; charset=\"utf-8\"",
        .extra_headers = &.{.{ .name = "SOAPACTION", .value = soapaction }},
        .timeout_secs = 6,
        .status_out = status_out,
    });
}

/// Fire one SOAP action; true only when the renderer answered 2xx.
fn soapService(control_url: []const u8, service: []const u8, action: []const u8, body: []const u8) bool {
    var rbuf: [8 * 1024]u8 = undefined;
    var status: ?std.http.Status = null;
    _ = soapServiceResponse(control_url, service, action, body, &rbuf, &status) orelse {
        // A non-2xx still lands here (the transport nulls on anything but
        // success), but status_out already carries the real code — say which.
        if (status) |st| {
            std.debug.print("[cast] {s} -> HTTP {d} from {s}\n", .{ action, @intFromEnum(st), control_url });
        } else {
            std.debug.print("[cast] {s} -> no response from {s}\n", .{ action, control_url });
        }
        return false;
    };
    return status == .ok;
}

/// One AVTransport SOAP action.
fn soapAction(control_url: []const u8, action: []const u8, body: []const u8) bool {
    return soapService(control_url, "AVTransport:1", action, body);
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
    // Renderers reject SetAVTransportURI while a transport is still active —
    // the TCL answers HTTP 500 mid-playback, so a channel switch silently
    // never happened and the TV stayed on the previous program. Stop first
    // (harmless on an idle renderer) and give the transport a second to tear
    // down — the same pause the live protocol dance needed — then push the
    // URI, then Play.
    var stop_buf: [512]u8 = undefined;
    const stop_body = std.fmt.bufPrint(
        &stop_buf,
        "<u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID></u:Stop>",
        .{},
    ) catch return false;
    _ = soapAction(control_url, "Stop", stop_body);
    io_global.sleep(1000 * std.time.ns_per_ms);

    // The settling renderer can still miss the URI push (500 or a dropped
    // connection right after the teardown); retry with generous pauses.
    if (!soapAction(control_url, "SetAVTransportURI", set_body)) {
        io_global.sleep(1200 * std.time.ns_per_ms);
        if (!soapAction(control_url, "SetAVTransportURI", set_body)) {
            io_global.sleep(2400 * std.time.ns_per_ms);
            if (!soapAction(control_url, "SetAVTransportURI", set_body)) return false;
        }
    }

    var play_buf: [512]u8 = undefined;
    const play_body = std.fmt.bufPrint(
        &play_buf,
        "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>",
        .{},
    ) catch return false;
    // The renderer can stay busy starting the media right after the URI is set
    // and miss answering the immediate Play; retries after pauses land it.
    if (soapAction(control_url, "Play", play_body)) return true;
    io_global.sleep(1200 * std.time.ns_per_ms);
    if (soapAction(control_url, "Play", play_body)) return true;
    io_global.sleep(2400 * std.time.ns_per_ms);
    return soapAction(control_url, "Play", play_body);
}

// ── Remote control (pause / seek / volume) ──────────────
//
// Once the TV is playing, IT owns the playback: the local mpv has no say in
// it. These calls drive the renderer over the same SOAP endpoints the cast
// used — AVTransport for transport state, pause and seek, RenderingControl for
// volume and mute. Each runs on a worker because a renderer may take seconds
// to answer and the UI thread must never block on the network.
//
// The fields below are written by those workers and polled by the cast panel
// on the UI thread, so they are atomic (CLAUDE.md thread-safety rule).

pub const TransportState = enum(u8) { unknown = 0, playing = 1, paused = 2, stopped = 3 };

pub var cast_transport: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
pub var cast_volume: std.atomic.Value(i16) = std.atomic.Value(i16).init(-1);
pub var cast_muted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var cast_position: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
pub var cast_duration: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
/// True from a successful cast until stopCast(): the TV is the active playback.
/// `is_casting` only covers the moments the cast worker is pushing the URL, so
/// the UI needs this separate, longer-lived flag.
pub var session_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var status_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var status_last_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

pub fn transportState() TransportState {
    const raw = cast_transport.load(.acquire);
    return if (raw <= @intFromEnum(TransportState.stopped)) @enumFromInt(raw) else .unknown;
}

/// Copy the active DLNA renderer's AVTransport control URL into `buf`.
fn activeAvUrl(buf: []u8) ?[]const u8 {
    const idx = active_device_idx orelse return null;
    if (idx >= device_count or idx >= devices.len) return null;
    const dev = devices[idx];
    if (!dev.isDlna()) return null;
    const len = @min(dev.control_url_len, buf.len);
    @memcpy(buf[0..len], dev.control_url[0..len]);
    return buf[0..len];
}

/// Copy the active renderer's RenderingControl URL into `buf`.
fn activeRcsUrl(buf: []u8) ?[]const u8 {
    const idx = active_device_idx orelse return null;
    if (idx >= device_count or idx >= devices.len) return null;
    const dev = devices[idx];
    if (!dev.hasVolume()) return null;
    const len = @min(dev.rcs_url_len, buf.len);
    @memcpy(buf[0..len], dev.rcs_url[0..len]);
    return buf[0..len];
}

/// "HH:MM:SS", "MM:SS" or "SS.mmm" → seconds. Renderers are inconsistent about
/// the leading fields, so every shape is accepted.
pub fn parseClock(text: []const u8) ?u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |raw| {
        if (n >= parts.len) return null;
        const part = if (std.mem.indexOfScalar(u8, raw, '.')) |dot| raw[0..dot] else raw;
        if (part.len == 0 or part.len > 9) return null;
        var v: u32 = 0;
        for (part) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
            v = v * 10 + (ch - '0');
        }
        parts[n] = v;
        n += 1;
    }
    return switch (n) {
        1 => parts[0],
        2 => parts[0] * 60 + parts[1],
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => null,
    };
}

/// Seconds → "H:MM:SS" / "M:SS" (the shape a Seek target wants).
pub fn formatClock(buf: []u8, secs: u32) []const u8 {
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    return if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch ""
    else
        std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "";
}

fn transportStateCode(text: []const u8) u8 {
    if (std.mem.indexOf(u8, text, "PAUSED") != null) return @intFromEnum(TransportState.paused);
    if (std.mem.indexOf(u8, text, "PLAYING") != null) return @intFromEnum(TransportState.playing);
    if (std.mem.indexOf(u8, text, "STOPPED") != null or std.mem.indexOf(u8, text, "NO_MEDIA") != null) return @intFromEnum(TransportState.stopped);
    return @intFromEnum(TransportState.unknown);
}

/// Poll the renderer for transport state, position and volume. Throttled to
/// roughly once a second and never concurrent with itself: the cast panel calls
/// this every frame while it is open, and each SOAP round trip is a real HTTP
/// request to the TV.
pub fn refreshStatus() void {
    if (!session_active.load(.acquire)) return;
    const now = io_global.milliTimestamp();
    if (now - status_last_ms.load(.acquire) < 900) return;
    if (status_busy.swap(true, .acquire)) return;
    status_last_ms.store(now, .release);

    var abuf: [512]u8 = undefined;
    const av_src = activeAvUrl(&abuf) orelse {
        status_busy.store(false, .release);
        return;
    };
    const av = alloc.dupe(u8, av_src) catch {
        status_busy.store(false, .release);
        return;
    };
    var rbuf_url: [512]u8 = undefined;
    const rcs_src = activeRcsUrl(&rbuf_url);
    const rcs: ?[]u8 = if (rcs_src) |u| (alloc.dupe(u8, u) catch null) else null;

    if (workers.spawnLegacy(struct {
        fn worker(av_url: []u8, rcs_url: ?[]u8) void {
            defer {
                status_busy.store(false, .release);
                alloc.free(av_url);
                if (rcs_url) |r| alloc.free(r);
            }

            var info_buf: [4096]u8 = undefined;
            var info_status: ?std.http.Status = null;
            const info_body =
                "<u:GetTransportInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                "<InstanceID>0</InstanceID></u:GetTransportInfo>";
            if (soapServiceResponse(av_url, "AVTransport:1", "GetTransportInfo", info_body, &info_buf, &info_status)) |resp| {
                if (xmlValue(resp, "CurrentTransportState")) |st| cast_transport.store(transportStateCode(st), .release);
            }

            var pos_buf: [8192]u8 = undefined;
            var pos_status: ?std.http.Status = null;
            const pos_body =
                "<u:GetPositionInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                "<InstanceID>0</InstanceID></u:GetPositionInfo>";
            if (soapServiceResponse(av_url, "AVTransport:1", "GetPositionInfo", pos_body, &pos_buf, &pos_status)) |resp| {
                if (xmlValue(resp, "RelTime")) |t| {
                    if (parseClock(t)) |secs| cast_position.store(secs, .release);
                }
                if (xmlValue(resp, "TrackDuration")) |t| {
                    if (parseClock(t)) |secs| cast_duration.store(secs, .release);
                }
            }

            if (rcs_url) |r| {
                var vol_buf: [4096]u8 = undefined;
                var vol_status: ?std.http.Status = null;
                const vol_body =
                    "<u:GetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">" ++
                    "<InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>";
                if (soapServiceResponse(r, "RenderingControl:1", "GetVolume", vol_body, &vol_buf, &vol_status)) |resp| {
                    if (xmlValue(resp, "CurrentVolume")) |v| {
                        if (std.fmt.parseInt(i16, v, 10)) |n| {
                            cast_volume.store(std.math.clamp(n, 0, 100), .release);
                        } else |_| {}
                    }
                }
                var mute_buf: [4096]u8 = undefined;
                var mute_status: ?std.http.Status = null;
                const mute_body =
                    "<u:GetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">" ++
                    "<InstanceID>0</InstanceID><Channel>Master</Channel></u:GetMute>";
                if (soapServiceResponse(r, "RenderingControl:1", "GetMute", mute_body, &mute_buf, &mute_status)) |resp| {
                    if (xmlValue(resp, "CurrentMute")) |m| {
                        cast_muted.store(std.mem.eql(u8, m, "1") or std.ascii.eqlIgnoreCase(m, "true"), .release);
                    }
                }
            }
        }
    }.worker, .{ av, rcs })) |t| workers.release(t) else |_| {
        status_busy.store(false, .release);
        alloc.free(av);
        if (rcs) |r| alloc.free(r);
    }
}

/// Pause or resume the TV, whichever the opposite of its current state is.
pub fn castTogglePause() void {
    var buf: [512]u8 = undefined;
    const src = activeAvUrl(&buf) orelse return;
    const url = alloc.dupe(u8, src) catch return;
    const pause_now = transportState() != .paused;
    if (workers.spawnLegacy(struct {
        fn worker(control_url: []u8, pause: bool) void {
            defer alloc.free(control_url);
            var body_buf: [512]u8 = undefined;
            const body = if (pause)
                std.fmt.bufPrint(
                    &body_buf,
                    "<u:Pause xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                        "<InstanceID>0</InstanceID></u:Pause>",
                    .{},
                ) catch return
            else
                std.fmt.bufPrint(
                    &body_buf,
                    "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                        "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>",
                    .{},
                ) catch return;
            const action = if (pause) "Pause" else "Play";
            if (soapService(control_url, "AVTransport:1", action, body)) {
                cast_transport.store(@intFromEnum(if (pause) TransportState.paused else TransportState.playing), .release);
                status_last_ms.store(0, .release);
            } else {
                state.showToast(if (pause) "TV refused to pause" else "TV refused to play");
            }
        }
    }.worker, .{ url, pause_now })) |t| workers.release(t) else |_| alloc.free(url);
}

/// Seek the TV by `delta_secs` (negative rewinds). DLNA only seeks to an
/// absolute REL_TIME, so the worker reads the renderer's position first.
pub fn castSeekBy(delta_secs: i32) void {
    var buf: [512]u8 = undefined;
    const src = activeAvUrl(&buf) orelse return;
    const url = alloc.dupe(u8, src) catch return;
    if (workers.spawnLegacy(struct {
        fn worker(control_url: []u8, delta: i32) void {
            defer alloc.free(control_url);
            var pos_buf: [8192]u8 = undefined;
            var pos_status: ?std.http.Status = null;
            const pos_body =
                "<u:GetPositionInfo xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                "<InstanceID>0</InstanceID></u:GetPositionInfo>";
            const resp = soapServiceResponse(control_url, "AVTransport:1", "GetPositionInfo", pos_body, &pos_buf, &pos_status) orelse {
                state.showToast("TV did not report its position");
                return;
            };
            const current = if (xmlValue(resp, "RelTime")) |t| (parseClock(t) orelse 0) else 0;
            var target: i64 = @as(i64, current) + delta;
            if (target < 0) target = 0;
            const duration = cast_duration.load(.acquire);
            if (duration > 2 and target > @as(i64, duration) - 2) target = @as(i64, duration) - 2;
            var target_buf: [32]u8 = undefined;
            const stamp = formatClock(&target_buf, @intCast(target));
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "<u:Seek xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
                    "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{s}</Target></u:Seek>",
                .{stamp},
            ) catch return;
            if (soapService(control_url, "AVTransport:1", "Seek", body)) {
                cast_position.store(@intCast(target), .release);
            } else {
                state.showToast("TV refused to seek");
            }
        }
    }.worker, .{ url, delta_secs })) |t| workers.release(t) else |_| alloc.free(url);
}

/// Step the TV's master volume by `delta` (percent), clamped to 0–100.
pub fn castVolumeStep(delta: i16) void {
    var buf: [512]u8 = undefined;
    const src = activeRcsUrl(&buf) orelse {
        state.showToast("This TV does not expose volume");
        return;
    };
    const url = alloc.dupe(u8, src) catch return;
    if (workers.spawnLegacy(struct {
        fn worker(rcs_url: []u8, step: i16) void {
            defer alloc.free(rcs_url);
            var current: i16 = cast_volume.load(.acquire);
            if (current < 0) current = 30;
            const next: i16 = std.math.clamp(current + step, 0, 100);
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "<u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">" ++
                    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{d}</DesiredVolume></u:SetVolume>",
                .{next},
            ) catch return;
            if (soapService(rcs_url, "RenderingControl:1", "SetVolume", body)) {
                cast_volume.store(next, .release);
                if (next > 0) cast_muted.store(false, .release);
            } else {
                state.showToast("TV refused the volume change");
            }
        }
    }.worker, .{ url, delta })) |t| workers.release(t) else |_| alloc.free(url);
}

/// Toggle mute on the TV.
pub fn castToggleMute() void {
    var buf: [512]u8 = undefined;
    const src = activeRcsUrl(&buf) orelse {
        state.showToast("This TV does not expose mute");
        return;
    };
    const url = alloc.dupe(u8, src) catch return;
    const mute_now = !cast_muted.load(.acquire);
    if (workers.spawnLegacy(struct {
        fn worker(rcs_url: []u8, mute: bool) void {
            defer alloc.free(rcs_url);
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "<u:SetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">" ++
                    "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>{d}</DesiredMute></u:SetMute>",
                .{@intFromBool(mute)},
            ) catch return;
            if (soapService(rcs_url, "RenderingControl:1", "SetMute", body)) {
                cast_muted.store(mute, .release);
            } else {
                state.showToast("TV refused the mute change");
            }
        }
    }.worker, .{ url, mute_now })) |t| workers.release(t) else |_| alloc.free(url);
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
                    // The TV now owns playback: mark the session and seed the
                    // remote so the cast panel shows sensible values at once.
                    cast_position.store(0, .release);
                    cast_duration.store(0, .release);
                    cast_muted.store(false, .release);
                    cast_transport.store(@intFromEnum(TransportState.playing), .release);
                    status_last_ms.store(0, .release);
                    session_active.store(true, .release);
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
    session_active.store(false, .release);
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
            session_active.store(false, .release);
            cast_transport.store(@intFromEnum(TransportState.unknown), .release);
            cast_position.store(0, .release);
            cast_duration.store(0, .release);
            active_device_idx = null;
            state.showToast("Cast stopped");
        }
    }.worker, .{control_copy})) |t| workers.release(t) else |_| {}
}
