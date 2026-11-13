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

            // ── catt (Chromecast) — optional ──
            // catt 0.13+ has no timeout option on `scan` — plain scan, the UI
            // polls is_scanning for completion.
            const argv = [_][]const u8{ "catt", "scan" };
            var child = io_global.Child.init(&argv, alloc);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            if (child.spawn()) |_| {
                var buf: [4096]u8 = undefined;
                const n = if (child.stdout) |*stdout| io_global.readAll(stdout, &buf) catch 0 else 0;
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
                // catt not installed — native DLNA below still runs.
            }

            // ── native DLNA (SSDP + AVTransport) ──
            dlnaScan();

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
                    if (!dup) try out.append(alloc, ip);
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
fn localIPv4Candidates() []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .windows => &.{"ipconfig"},
        .macos => &.{"ifconfig"},
        else => &.{ "ip", "-4", "addr" },
    };
    var child = io_global.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return list.items;
    var buf: [64 * 1024]u8 = undefined;
    const n = if (child.stdout) |*so| io_global.readAll(so, &buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return list.items;
    appendIPv4s(buf[0..n], &list) catch {};
    return list.items;
}

/// SSDP M-SEARCH for MediaRenderers, then one HTTP GET per device to read the
/// friendlyName + AVTransport control URL. Appends to `devices`.
fn dlnaProbe(io: std.Io, local_ip: ?[]const u8, locations: *[8][]const u8, loc_buf: *[8][256]u8, location_count: *usize, window_ms: i64) void {
    const local = if (local_ip) |ip|
        std.Io.net.IpAddress.parseIp4(ip, 0) catch return
    else
        std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return;
    var sock = local.bind(io, .{ .mode = .dgram }) catch return;
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

/// SSDP M-SEARCH across every local IPv4 interface (default route first),
/// then one HTTP GET per device to read the friendlyName + AVTransport
/// control URL. Appends to `devices`.
fn dlnaScan() void {
    const io = io_global.io();
    var locations: [8][]const u8 = undefined;
    var location_count: usize = 0;
    var loc_buf: [8][256]u8 = undefined;

    dlnaProbe(io, null, &locations, &loc_buf, &location_count, 2000);
    const candidates = localIPv4Candidates();
    for (candidates) |ip| {
        if (location_count >= locations.len) break;
        dlnaProbe(io, ip, &locations, &loc_buf, &location_count, 1500);
    }
    alloc.free(candidates);

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
    _ = http.fetch(control_url, &rbuf, .{
        .method = .POST,
        .payload = envelope,
        .content_type = "text/xml; charset=\"utf-8\"",
        .extra_headers = &.{.{ .name = "SOAPACTION", .value = soapaction }},
        .timeout_secs = 6,
        .status_out = &status,
    }) orelse return false;
    return status == .ok;
}

fn dlnaCast(control_url: []const u8, url: []const u8) bool {
    var uri_buf: [2048]u8 = undefined;
    const uri = xmlEscape(url, &uri_buf) orelse return false;
    var body_buf: [2560]u8 = undefined;
    const set_body = std.fmt.bufPrint(
        &body_buf,
        "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID><CurrentURI>{s}</CurrentURI>" ++
            "<CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI>",
        .{uri},
    ) catch return false;
    if (!soapAction(control_url, "SetAVTransportURI", set_body)) return false;

    var play_buf: [512]u8 = undefined;
    const play_body = std.fmt.bufPrint(
        &play_buf,
        "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" ++
            "<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>",
        .{},
    ) catch return false;
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

    // Allocate copies for the thread
    const url_copy = alloc.dupe(u8, url) catch return;
    const name_copy = alloc.dupe(u8, device_name) catch return;
    const control_copy: ?[]u8 = if (dlna_control) |cu| (alloc.dupe(u8, cu) catch return) else null;

    if (workers.spawnLegacy(struct {
        fn worker(u: []const u8, dev: []const u8, control: ?[]u8) void {
            defer {
                is_casting.store(false, .release);
                alloc.free(u);
                alloc.free(dev);
                if (control) |cc| alloc.free(cc);
            }

            if (control) |cc| {
                // Native DLNA: push the URL, then Play.
                if (dlnaCast(cc, u)) {
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
    }.worker, .{ url_copy, name_copy, control_copy })) |t| workers.release(t) else |_| {}
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
            is_casting.store(false, .release);
            active_device_idx = null;
            state.showToast("Cast stopped");
        }
    }.worker, .{control_copy})) |t| workers.release(t) else |_| {}
}
