import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:multicast_dns/multicast_dns.dart';

class DeviceInfo {
  final String ip;
  String mac;
  String vendor;
  String? hostname;
  DateTime lastSeen;
  bool online;
  final bool isSelf;

  DeviceInfo({
    required this.ip,
    this.mac = '',
    this.vendor = '',
    this.hostname,
    required this.lastSeen,
    this.online = true,
    this.isSelf = false,
  });

  /// Sortable numeric form of the IPv4 address.
  int get ipSortKey {
    final parts = ip.split('.');
    if (parts.length != 4) return 0;
    var v = 0;
    for (final p in parts) {
      v = (v << 8) | (int.tryParse(p) ?? 0);
    }
    return v;
  }
}

/// Discovers devices on the local /24 by sweeping it with pings (to populate
/// the ARP cache), then reading the ARP table for IP↔MAC pairs. Manufacturer
/// comes from the bundled IEEE OUI database; names from mDNS/Bonjour with a
/// reverse-DNS fallback. Runs on macOS, Linux, and Windows.
///
/// Passive observation only — like the serial capture buffer, scanning never
/// changes anything on the network beyond ordinary ICMP/ARP/mDNS traffic.
class NetworkScanner {
  static const pingPool = 64;
  static const dnsPool = 24;

  final Map<String, String> _oui = {};
  bool _ouiLoaded = false;

  // ip -> device, persists across scans so offline devices stay listed
  final Map<String, DeviceInfo> _devices = {};

  final StreamController<List<DeviceInfo>> devices =
      StreamController<List<DeviceInfo>>.broadcast();
  final StreamController<ScanStatus> status =
      StreamController<ScanStatus>.broadcast();

  bool _running = false;
  bool _scanning = false;
  int _intervalSecs = 30;

  bool get running => _running;

  // ---------- OUI vendor database ----------

  Future<void> _loadOui() async {
    if (_ouiLoaded) return;
    try {
      final raw = await rootBundle.loadString('assets/oui.csv');
      for (final line in raw.split('\n')) {
        final c = line.indexOf(',');
        if (c <= 0) continue;
        _oui[line.substring(0, c)] = line.substring(c + 1);
      }
    } catch (_) {}
    _ouiLoaded = true;
  }

  String _vendorFor(String mac) {
    final hex = mac.replaceAll(RegExp('[^0-9a-fA-F]'), '').toUpperCase();
    if (hex.length < 6) return '';
    return _oui[hex.substring(0, 6)] ?? '';
  }

  // ---------- subnet / self ----------

  Future<({String selfIp, String base, String iface})?> _localSubnet() async {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('169.254.')) continue; // link-local
        final parts = ip.split('.');
        if (parts.length == 4) {
          return (
            selfIp: ip,
            base: '${parts[0]}.${parts[1]}.${parts[2]}',
            iface: iface.name,
          );
        }
      }
    }
    return null;
  }

  /// MAC of the local interface (platform-specific; blank if unavailable).
  Future<String> _selfMac(String iface) async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('/sbin/ifconfig', [iface]);
        final m =
            RegExp(r'ether ([0-9a-fA-F:]+)').firstMatch(r.stdout as String);
        if (m != null) return _normalizeMac(m.group(1)!);
      } else if (Platform.isLinux) {
        final r = await Process.run('ip', ['-o', 'link', 'show', iface]);
        final m = RegExp(r'link/ether ([0-9a-fA-F:]+)')
            .firstMatch(r.stdout as String);
        if (m != null) return _normalizeMac(m.group(1)!);
      } else if (Platform.isWindows) {
        final r = await Process.run('getmac', ['/fo', 'csv', '/nh']);
        final m = RegExp(r'([0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})')
            .firstMatch(r.stdout as String);
        if (m != null) return _normalizeMac(m.group(1)!.replaceAll('-', ':'));
      }
    } catch (_) {}
    return '';
  }

  // ---------- lifecycle ----------

  Future<void> start({int intervalSecs = 30}) async {
    if (_running) return;
    _running = true;
    _intervalSecs = intervalSecs;
    await _loadOui();
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    status.add(ScanStatus(scanning: false, nextInSecs: 0, running: false));
  }

  void clear() {
    _devices.clear();
    devices.add([]);
  }

  Future<void> _loop() async {
    while (_running) {
      await _scanOnce();
      if (!_running) break;
      for (var s = _intervalSecs; s > 0 && _running; s--) {
        status.add(ScanStatus(scanning: false, nextInSecs: s, running: true));
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _scanOnce() async {
    if (_scanning) return;
    _scanning = true;
    status.add(ScanStatus(scanning: true, nextInSecs: 0, running: true));

    try {
      final net = await _localSubnet();
      if (net == null) {
        _scanning = false;
        return;
      }

      // 1. Ping sweep to populate the ARP cache (pooled), and browse Bonjour
      //    for friendly device names concurrently.
      final hosts = [for (var i = 1; i <= 254; i++) '${net.base}.$i'];
      final bonjourFuture = _bonjourNames();
      await _pool(hosts, pingPool, _ping);

      // 2. ARP table → ip/mac pairs.
      final arp = await _readArp();

      // 3. Resolve names: reverse mDNS, reverse DNS fallback (pooled).
      final names = <String, String?>{};
      final mdns = MDnsClient();
      var mdnsUp = false;
      try {
        await mdns.start();
        mdnsUp = true;
      } catch (_) {}
      await _pool(arp.keys.toList(), dnsPool, (ip) async {
        names[ip] =
            (mdnsUp ? await _mdnsName(mdns, ip) : null) ?? await _reverse(ip);
      });
      if (mdnsUp) mdns.stop();

      // Friendly Bonjour names win over reverse lookups.
      final bonjour = await bonjourFuture;
      String? nameFor(String ip) => bonjour[ip] ?? names[ip];

      final now = DateTime.now();
      final seen = <String>{net.selfIp};

      // self entry — ARP usually omits the local interface
      final selfMac = await _selfMac(net.iface);
      final self = _devices.putIfAbsent(
          net.selfIp, () => DeviceInfo(ip: net.selfIp, isSelf: true, lastSeen: now))
        ..online = true
        ..lastSeen = now
        ..mac = selfMac
        ..vendor = _vendorFor(selfMac)
        ..hostname = nameFor(net.selfIp) ?? Platform.localHostname;

      for (final entry in arp.entries) {
        final ip = entry.key;
        final mac = entry.value;
        seen.add(ip);
        final dev =
            _devices.putIfAbsent(ip, () => DeviceInfo(ip: ip, lastSeen: now));
        dev
          ..mac = mac
          ..vendor = _vendorFor(mac)
          ..hostname = nameFor(ip) ?? dev.hostname
          ..lastSeen = now
          ..online = true;
      }

      for (final dev in _devices.values) {
        if (!seen.contains(dev.ip)) dev.online = false;
      }
      self.online = true;

      _emit();
    } catch (_) {
    } finally {
      _scanning = false;
    }
  }

  void _emit() {
    final list = _devices.values.toList()
      ..sort((a, b) => a.ipSortKey.compareTo(b.ipSortKey));
    devices.add(list);
  }

  // ---------- platform commands ----------

  Future<void> _ping(String ip) async {
    try {
      if (Platform.isWindows) {
        await Process.run('ping', ['-n', '1', '-w', '500', ip]);
      } else if (Platform.isLinux) {
        await Process.run('ping', ['-c', '1', '-W', '1', '-q', ip]);
      } else {
        await Process.run('/sbin/ping', ['-c', '1', '-t', '1', '-q', ip]);
      }
    } catch (_) {}
  }

  /// Reads the ARP/neighbour table into ip→MAC, filtering broadcast/multicast.
  Future<Map<String, String>> _readArp() async {
    final out = <String, String>{};
    void add(String ip, String rawMac) {
      if (ip.endsWith('.255') || ip.endsWith('.0')) return;
      final first = int.tryParse(ip.split('.').first) ?? 0;
      if (first >= 224 && first <= 239) return; // multicast
      final mac = _normalizeMac(rawMac);
      if (mac.length != 17) return;
      if (mac.startsWith('FF:FF') || mac.startsWith('01:00:5E')) return;
      out[ip] = mac;
    }

    try {
      if (Platform.isWindows) {
        final r = await Process.run('arp', ['-a']);
        final re = RegExp(r'([\d.]+)\s+([0-9a-fA-F-]{17})\s+\w+');
        for (final m in re.allMatches(r.stdout as String)) {
          add(m.group(1)!, m.group(2)!.replaceAll('-', ':'));
        }
      } else if (Platform.isLinux) {
        // prefer modern `ip neigh`; fall back to `arp -n`
        var text = '';
        try {
          final r = await Process.run('ip', ['neigh', 'show']);
          text = r.stdout as String;
        } catch (_) {}
        if (text.trim().isEmpty) {
          final r = await Process.run('arp', ['-n']);
          text = r.stdout as String;
        }
        final re1 =
            RegExp(r'([\d.]+) dev \S+ lladdr ([0-9a-fA-F:]+)'); // ip neigh
        final re2 =
            RegExp(r'([\d.]+)\s+\S+\s+([0-9a-fA-F:]{17})'); // arp -n
        for (final m in re1.allMatches(text)) {
          add(m.group(1)!, m.group(2)!);
        }
        for (final m in re2.allMatches(text)) {
          add(m.group(1)!, m.group(2)!);
        }
      } else {
        final r = await Process.run('/usr/sbin/arp', ['-a', '-n']);
        final re = RegExp(r'\(([\d.]+)\) at ([0-9a-fA-F:]+)');
        for (final line in (r.stdout as String).split('\n')) {
          if (line.contains('incomplete')) continue;
          final m = re.firstMatch(line);
          if (m != null) add(m.group(1)!, m.group(2)!);
        }
      }
    } catch (_) {}
    return out;
  }

  static String _normalizeMac(String mac) =>
      mac.split(':').map((o) => o.padLeft(2, '0').toUpperCase()).join(':');

  // ---------- name resolution ----------

  /// Reverse mDNS (Bonjour) PTR lookup — yields friendly `.local` names like
  /// "Byrons-MacBook-Pro" or "iPhone" when the device advertises them.
  Future<String?> _mdnsName(MDnsClient client, String ip) async {
    final ptrName = '${ip.split('.').reversed.join('.')}.in-addr.arpa';
    try {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(ptrName))
          .timeout(const Duration(milliseconds: 900))) {
        var n = ptr.domainName;
        if (n.endsWith('.local')) n = n.substring(0, n.length - 6);
        if (n.endsWith('.')) n = n.substring(0, n.length - 1);
        if (n.isNotEmpty) return n;
      }
    } catch (_) {}
    return null;
  }

  // ---------- forward Bonjour browsing ----------

  // Identity-rich service types, ordered best-name-first. The instance label
  // of these is the human name ("Byron's MacBook Pro", "Living Room").
  static const _serviceTypes = [
    '_companion-link._tcp.local', // Apple devices
    '_airplay._tcp.local',
    '_raop._tcp.local', // AirPlay audio: "MAC@Name"
    '_googlecast._tcp.local', // Chromecast (friendly name in TXT fn=)
    '_smb._tcp.local',
    '_afpovertcp._tcp.local',
    '_ssh._tcp.local',
    '_sftp-ssh._tcp.local',
    '_workstation._tcp.local', // avahi: "host [mac]"
    '_device-info._tcp.local',
    '_spotify-connect._tcp.local',
    '_printer._tcp.local',
    '_ipp._tcp.local',
  ];

  /// Browses Bonjour service types, resolves each instance to its IPv4
  /// address, and returns ip→friendly-name. Best-effort within a time budget.
  Future<Map<String, String>> _bonjourNames() async {
    final result = <String, String>{};
    final client = MDnsClient();
    try {
      await client.start();
    } catch (_) {
      return result;
    }
    try {
      await Future.wait(
          _serviceTypes.map((t) => _browse(client, t, result)));
    } catch (_) {}
    client.stop();
    return result;
  }

  Future<void> _browse(
      MDnsClient client, String type, Map<String, String> result) async {
    try {
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(type))
          .timeout(const Duration(seconds: 3), onTimeout: (s) => s.close())) {
        final instance = ptr.domainName;
        final friendly = _friendlyName(instance, type, client);
        // resolve instance → host → IPv4
        try {
          await for (final srv in client
              .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(instance))
              .timeout(const Duration(milliseconds: 1200),
                  onTimeout: (s) => s.close())) {
            await for (final a in client
                .lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target))
                .timeout(const Duration(milliseconds: 1200),
                    onTimeout: (s) => s.close())) {
              if (a.address.type == InternetAddressType.IPv4) {
                final name = await friendly;
                if (name != null && name.isNotEmpty) {
                  result.putIfAbsent(a.address.address, () => name);
                }
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Derives the human name for a Bonjour instance. For googlecast the label
  /// is a GUID, so the TXT `fn=` field is used instead.
  Future<String?> _friendlyName(
      String instance, String type, MDnsClient client) async {
    final suffix = '.$type';
    var label = instance.endsWith(suffix)
        ? instance.substring(0, instance.length - suffix.length)
        : instance;
    label = _unescapeDns(label);

    if (type.contains('_raop') && label.contains('@')) {
      label = label.split('@').last; // "AABBCC@Living Room" → "Living Room"
    }
    if (type.contains('_workstation')) {
      label = label.replaceFirst(RegExp(r'\s*\[[0-9a-fA-F:]+\]\s*$'), '');
    }
    if (type.contains('_googlecast')) {
      try {
        await for (final txt in client
            .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance))
            .timeout(const Duration(milliseconds: 1000),
                onTimeout: (s) => s.close())) {
          final m = RegExp(r'fn=(.+)').firstMatch(txt.text);
          if (m != null) return m.group(1)!.trim();
        }
      } catch (_) {}
    }
    return label;
  }

  /// Decodes DNS-SD escapes (`\032` decimal, `\.`, `\\`) in instance labels.
  static String _unescapeDns(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (s[i] == r'\'[0] && i + 1 < s.length) {
        final rest = s.substring(i + 1);
        final dec = RegExp(r'^\d{3}').firstMatch(rest);
        if (dec != null) {
          b.writeCharCode(int.parse(dec.group(0)!));
          i += 3;
        } else {
          b.write(s[i + 1]);
          i += 1;
        }
      } else {
        b.write(s[i]);
      }
    }
    return b.toString();
  }

  Future<String?> _reverse(String ip) async {
    try {
      final r = await InternetAddress(ip)
          .reverse()
          .timeout(const Duration(milliseconds: 600));
      var h = r.host;
      if (h == ip) return null;
      if (h.endsWith('.local')) h = h.substring(0, h.length - 6);
      return h;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pool<T>(
      List<T> items, int size, Future<void> Function(T) task) async {
    var i = 0;
    Future<void> worker() async {
      while (true) {
        final idx = i++;
        if (idx >= items.length) return;
        await task(items[idx]);
      }
    }

    await Future.wait([for (var w = 0; w < size; w++) worker()]);
  }

  void dispose() {
    stop();
    devices.close();
    status.close();
  }
}

class ScanStatus {
  final bool scanning;
  final int nextInSecs;
  final bool running;
  ScanStatus(
      {required this.scanning,
      required this.nextInSecs,
      required this.running});
}
