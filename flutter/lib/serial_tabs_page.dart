import 'dart:async';

import 'package:flutter/material.dart';

import 'home_page.dart'
    show HomePage, kBg, kPanel, kInput, kBorder, kText, kTextDim, kAccent, kGreen;
import 'mcp_server.dart';
import 'serial_service.dart';
import 'settings_store.dart';

class _Session {
  final SerialService serial;
  final GlobalKey key = GlobalKey();
  StreamSubscription? sub;
  _Session(AppSettings settings) : serial = SerialService(settings);
  _Session.adopt(this.serial);
}

/// Holds one serial session per tab. Each tab is an independent port with its
/// own capture buffer and UI. The active tab is the one MCP acts on.
class SerialTabsPage extends StatefulWidget {
  final AppSettings settings;
  final McpServer mcp;

  /// First tab adopts this already-built session (the app's MCP boot target).
  final SerialService boot;
  const SerialTabsPage(
      {super.key,
      required this.settings,
      required this.mcp,
      required this.boot});

  @override
  State<SerialTabsPage> createState() => _SerialTabsPageState();
}

class _SerialTabsPageState extends State<SerialTabsPage> {
  final List<_Session> _sessions = [];
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _addSession(adopt: widget.boot);
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.sub?.cancel();
      s.serial.close(silent: true);
    }
    super.dispose();
  }

  void _addSession({SerialService? adopt}) {
    final s = adopt != null
        ? _Session.adopt(adopt)
        : _Session(widget.settings);
    // refresh tab labels when this session connects/disconnects
    s.sub = s.serial.events.stream.listen((_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _sessions.add(s);
      _active = _sessions.length - 1;
    });
    _retargetMcp();
  }

  void _closeSession(int i) {
    final s = _sessions[i];
    s.sub?.cancel();
    s.serial.close(silent: true);
    setState(() {
      _sessions.removeAt(i);
      if (_sessions.isEmpty) {
        _addSession();
        return;
      }
      if (_active >= _sessions.length) _active = _sessions.length - 1;
    });
    _retargetMcp();
  }

  void _select(int i) {
    setState(() => _active = i);
    _retargetMcp();
  }

  // Keep MCP's view of all sessions and the active one in sync.
  void _retargetMcp() {
    widget.mcp.sessions = _sessions.map((e) => e.serial).toList();
    widget.mcp.active =
        _sessions.isEmpty ? null : _sessions[_active].serial;
  }

  String _titleFor(_Session s, int i) {
    final cfg = s.serial.activeConfig;
    if (cfg != null) {
      final base = cfg.path.split('/').last;
      return base.isEmpty ? cfg.path : base;
    }
    return 'Port ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _tabBar(),
      Expanded(
        child: IndexedStack(
          index: _active,
          children: [
            for (final s in _sessions)
              HomePage(
                key: s.key,
                serial: s.serial,
                mcp: widget.mcp,
                settings: widget.settings,
              ),
          ],
        ),
      ),
    ]);
  }

  Widget _tabBar() {
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _sessions.length,
            itemBuilder: (c, i) => _tab(i),
          ),
        ),
        IconButton(
          onPressed: _addSession,
          icon: const Icon(Icons.add, size: 18, color: kTextDim),
          tooltip: 'New port tab',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
        ),
      ]),
    );
  }

  Widget _tab(int i) {
    final s = _sessions[i];
    final active = i == _active;
    final connected = s.serial.connected;
    return InkWell(
      onTap: () => _select(i),
      child: Container(
        constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: active ? kPanel : kBg,
          border: Border(
            right: const BorderSide(color: kBorder),
            bottom: BorderSide(
                color: active ? kAccent : Colors.transparent, width: 2),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? kGreen : kInput,
              border: connected
                  ? null
                  : Border.all(color: kTextDim, width: 1),
            ),
          ),
          Flexible(
            child: Text(
              _titleFor(s, i),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: active ? kText : kTextDim,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal),
            ),
          ),
          InkWell(
            onTap: () => _closeSession(i),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 13, color: kTextDim),
            ),
          ),
        ]),
      ),
    );
  }
}
