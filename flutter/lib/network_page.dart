import 'dart:async';

import 'package:flutter/material.dart';

import 'home_page.dart' show kBg, kPanel, kInput, kBorder, kText, kTextDim, kAccent, kGreen, kRed;
import 'network_scanner.dart';

const _mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Consolas', 'monospace'],
  fontSize: 12.5,
);

class NetworkPage extends StatefulWidget {
  final NetworkScanner scanner;
  const NetworkPage({super.key, required this.scanner});

  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  NetworkScanner get scanner => widget.scanner;

  List<DeviceInfo> devices = [];
  ScanStatus statusInfo =
      ScanStatus(scanning: false, nextInSecs: 0, running: false);
  String query = '';
  final queryCtrl = TextEditingController();

  StreamSubscription? _devSub;
  StreamSubscription? _statSub;

  @override
  void initState() {
    super.initState();
    _devSub = scanner.devices.stream.listen((d) {
      if (mounted) setState(() => devices = d);
    });
    _statSub = scanner.status.stream.listen((s) {
      if (mounted) setState(() => statusInfo = s);
    });
  }

  @override
  void dispose() {
    _devSub?.cancel();
    _statSub?.cancel();
    queryCtrl.dispose();
    super.dispose();
  }

  List<DeviceInfo> get _filtered {
    if (query.isEmpty) return devices;
    final q = query.toLowerCase();
    return devices.where((d) {
      return d.ip.contains(q) ||
          d.mac.toLowerCase().contains(q) ||
          d.vendor.toLowerCase().contains(q) ||
          (d.hostname?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  String _fmtSeen(DateTime t) {
    final l = t.toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}:${p(l.second)}';
  }

  void _toggle() {
    if (scanner.running) {
      scanner.stop();
    } else {
      scanner.start();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          _toolbar(),
          _header(),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      scanner.running
                          ? 'Scanning the local network…'
                          : 'Press Scan to discover devices on your network',
                      style: const TextStyle(color: kTextDim),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) => _row(list[i], i),
                  ),
          ),
          _statusBar(list.length),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        FilledButton(
          onPressed: _toggle,
          style: FilledButton.styleFrom(
            backgroundColor: scanner.running ? kRed : kAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          child: Text(scanner.running ? 'Stop' : 'Scan'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              controller: queryCtrl,
              onChanged: (v) => setState(() => query = v),
              style: const TextStyle(color: kText, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Filter by name, IP, MAC, or manufacturer…',
                hintStyle: const TextStyle(color: kTextDim),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                filled: true,
                fillColor: kInput,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: const BorderSide(color: kBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: const BorderSide(color: kAccent),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: devices.isEmpty ? null : () => scanner.clear(),
          style: OutlinedButton.styleFrom(
            foregroundColor: kText,
            side: const BorderSide(color: kBorder),
            backgroundColor: kInput,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          child: const Text('Clear'),
        ),
      ]),
    );
  }

  static const _wDot = 28.0;
  static const _wIp = 130.0;
  static const _wMac = 160.0;
  static const _wVendor = 200.0;
  static const _wSeen = 170.0;

  Widget _header() {
    Widget h(String t, double w) => SizedBox(
        width: w,
        child: Text(t,
            style: const TextStyle(
                color: kTextDim, fontSize: 11, fontWeight: FontWeight.w600)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        const SizedBox(width: _wDot),
        const Expanded(
            child: Text('Name',
                style: TextStyle(
                    color: kTextDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600))),
        h('IP address', _wIp),
        h('MAC address', _wMac),
        h('Manufacturer', _wVendor),
        h('Last seen', _wSeen),
      ]),
    );
  }

  Widget _row(DeviceInfo d, int i) {
    final name = (d.hostname != null && d.hostname!.isNotEmpty)
        ? d.hostname!
        : (d.isSelf ? 'This Mac' : d.ip);
    return Container(
      color: i.isEven ? kBg : const Color(0xFF22222F),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(children: [
        SizedBox(
          width: _wDot,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: d.online ? kGreen : Colors.transparent,
              border: d.online
                  ? null
                  : Border.all(color: kTextDim, width: 1.2),
            ),
          ),
        ),
        Expanded(
          child: Text(
            d.isSelf ? '$name (local)' : name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: d.isSelf ? FontWeight.w600 : FontWeight.normal),
          ),
        ),
        SizedBox(
            width: _wIp,
            child: Text(d.ip, style: _mono.copyWith(color: kText))),
        SizedBox(
            width: _wMac,
            child: Text(d.mac.isEmpty ? '—' : d.mac,
                style: _mono.copyWith(color: kTextDim))),
        SizedBox(
            width: _wVendor,
            child: Text(d.vendor.isEmpty ? '—' : d.vendor,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kText, fontSize: 12.5))),
        SizedBox(
            width: _wSeen,
            child: Text(_fmtSeen(d.lastSeen),
                style: _mono.copyWith(color: kTextDim, fontSize: 11.5))),
      ]),
    );
  }

  Widget _statusBar(int shown) {
    String msg;
    if (!scanner.running) {
      msg = 'Idle';
    } else if (statusInfo.scanning) {
      msg = 'Scanning…';
    } else if (statusInfo.nextInSecs > 0) {
      msg = 'Next probe in ${statusInfo.nextInSecs} seconds';
    } else {
      msg = 'Running';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        Text('$shown devices',
            style: const TextStyle(color: kTextDim, fontSize: 12)),
        const Spacer(),
        if (statusInfo.scanning)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
          ),
        if (statusInfo.scanning) const SizedBox(width: 8),
        Text(msg, style: const TextStyle(color: kTextDim, fontSize: 12)),
      ]),
    );
  }
}
