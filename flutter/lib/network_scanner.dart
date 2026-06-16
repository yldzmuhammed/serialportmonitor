import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

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
/// comes from the bundled IEEE OUI database; names from reverse DNS.
///
/// Passive observation only — like the serial capture buffer, scanning never
/// changes anything on the network beyond ordinary ICMP/ARP traffic.
class NetworkScanner {
  static const pingPool = 64;
  static const dnsPool = 32;

  final Map<String, String> _oui = {};
  bool _ouiLoaded = false;

  // ip -> device, persists across scans so offline devices stay listed
  final Map<String, DeviceInfo> _devices = {};

  final StreamController<List<DeviceInfo>> devices =
      StreamController<List<DeviceInfo>>.broadcast();

  // status
  final StreamController<ScanStatus> status =
      StreamController<ScanStatus>.broadcast();

  bool _running = false;
  bool _scanning = false;
  Timer? _idleTimer;
  int _intervalSecs = 30;

  bool get running => _running;

  Future<void> _loadOui() async {
    if (_ouiLoaded) return;
    try {
      final raw = await rootBundle.loadString('assets/oui.csv');
      for (final line in raw.split('\n')) {
        final c = line.indexOf(',');
        if (c <= 0) continue;
        _oui[line.substring(0, c)] = line.substring(c + 1);
      }
    } catch (_) {
      // vendor column just stays blank
    }
    _ouiLoaded = true;
  }

  String _vendorFor(String mac) {
    final hex = mac.replaceAll(RegExp('[^0-9a-fA-F]'), '').toUpperCase();
    if (hex.length < 6) return '';
    return _oui[hex.substring(0, 6)] ?? '';
  }

  /// Local IPv4 + /24 base ("192.168.1"), or null if no usable interface.
  Future<({String selfIp, String base})?> _localSubnet() async {
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
          return (selfIp: ip, base: '${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    }
    return null;
  }

  Future<void> start({int intervalSecs = 30}) async {
    if (_running) return;
    _running = true;
    _intervalSecs = intervalSecs;
    await _loadOui();
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    status.add(ScanStatus(scanning: false, nextInSecs: 0, running: false));
  }

  /// Forget every device and clear the table.
  void clear() {
    _devices.clear();
    devices.add([]);
  }

  Future<void> _loop() async {
    while (_running) {
      await _scanOnce();
      if (!_running) break;
      // idle countdown until the next sweep
      for (var s = _intervalSecs; s > 0 && _running; s--) {
        status.add(ScanStatus(
            scanning: false, nextInSecs: s, running: true));
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

      // 1. Ping sweep to populate the ARP cache (pooled).
      final hosts = [for (var i = 1; i <= 254; i++) '${net.base}.$i'];
      await _pool(hosts, pingPool, _ping);

      // 2. Read ARP table → ip/mac pairs.
      final arp = await _readArp();

      // 3. Reverse-DNS the responders (pooled).
      final names = <String, String?>{};
      await _pool(arp.keys.toList(), dnsPool, (ip) async {
        names[ip] = await _reverse(ip);
      });

      final now = DateTime.now();
      final seen = <String>{net.selfIp};

      // self entry — ARP usually omits the local interface
      _devices.putIfAbsent(
          net.selfIp,
          () => DeviceInfo(
              ip: net.selfIp, lastSeen: now, isSelf: true));
      final self = _devices[net.selfIp]!
        ..online = true
        ..lastSeen = now
        ..hostname = 'This Mac';

      for (final entry in arp.entries) {
        final ip = entry.key;
        final mac = entry.value;
        seen.add(ip);
        final dev = _devices.putIfAbsent(
            ip, () => DeviceInfo(ip: ip, lastSeen: now));
        dev
          ..mac = mac
          ..vendor = _vendorFor(mac)
          ..hostname = names[ip] ?? dev.hostname
          ..lastSeen = now
          ..online = true;
      }
      // self vendor stays blank but keep self in list
      self.online = true;

      // mark everything not seen this round offline (keep in table)
      for (final dev in _devices.values) {
        if (!seen.contains(dev.ip)) dev.online = false;
      }

      _emit();
    } catch (_) {
      // a failed sweep just leaves the previous table in place
    } finally {
      _scanning = false;
    }
  }

  void _emit() {
    final list = _devices.values.toList()
      ..sort((a, b) => a.ipSortKey.compareTo(b.ipSortKey));
    devices.add(list);
  }

  Future<void> _ping(String ip) async {
    try {
      await Process.run('/sbin/ping', ['-c', '1', '-t', '1', '-q', ip]);
    } catch (_) {}
  }

  /// Parses `arp -a -n` output: "? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 …"
  Future<Map<String, String>> _readArp() async {
    final out = <String, String>{};
    try {
      final res = await Process.run('/usr/sbin/arp', ['-a', '-n']);
      final re = RegExp(r'\(([\d.]+)\) at ([0-9a-fA-F:]+)');
      for (final line in (res.stdout as String).split('\n')) {
        if (line.contains('incomplete')) continue;
        final m = re.firstMatch(line);
        if (m == null) continue;
        final ip = m.group(1)!;
        if (ip.endsWith('.255') || ip.endsWith('.0')) continue;
        // IPv4 multicast 224.0.0.0–239.255.255.255
        final first = int.tryParse(ip.split('.').first) ?? 0;
        if (first >= 224 && first <= 239) continue;
        final mac = _normalizeMac(m.group(2)!);
        // skip broadcast (FF:FF:…) and multicast (01:00:5E:…) MACs
        if (mac.startsWith('FF:FF') || mac.startsWith('01:00:5E')) continue;
        out[ip] = mac;
      }
    } catch (_) {}
    return out;
  }

  static String _normalizeMac(String mac) {
    return mac
        .split(':')
        .map((o) => o.padLeft(2, '0').toUpperCase())
        .join(':');
  }

  Future<String?> _reverse(String ip) async {
    try {
      final r = await InternetAddress(ip)
          .reverse()
          .timeout(const Duration(milliseconds: 600));
      return r.host == ip ? null : r.host;
    } catch (_) {
      return null;
    }
  }

  /// Runs [task] over [items] with at most [size] in flight.
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
