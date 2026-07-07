import 'dart:async';

import 'package:flutter/material.dart';

import 'home_page.dart'
    show HomePage, kBg, kPanel, kInput, kBorder, kText, kTextDim, kAccent, kGreen;
import 'mcp_server.dart';
import 'serial_service.dart';
import 'settings_store.dart';

class _Session {
  final SerialService serial;
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
  int _active = 0; // left pane / MCP-active tab
  bool _split = false;
  int _rightActive = 0; // right pane when split

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
      if (_rightActive >= _sessions.length) {
        _rightActive = _sessions.length - 1;
      }
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
      // serial → device name; socket → "tcp host:port"
      final base = cfg.label.split('/').last;
      return base.isEmpty ? cfg.label : base;
    }
    return 'Port ${i + 1}';
  }

  // A pane = an IndexedStack over all sessions so every tab stays alive; the
  // side prefix keeps left/right widget keys distinct.
  Widget _pane(String side, int index) {
    return IndexedStack(
      index: index.clamp(0, _sessions.isEmpty ? 0 : _sessions.length - 1),
      children: [
        for (var i = 0; i < _sessions.length; i++)
          HomePage(
            key: ValueKey('$side$i'),
            serial: _sessions[i].serial,
            mcp: widget.mcp,
            settings: widget.settings,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _tabBar(),
      Expanded(
        child: _split
            ? Row(children: [
                Expanded(child: _pane('L', _active)),
                const VerticalDivider(width: 1, color: kBorder),
                Expanded(child: _pane('R', _rightActive)),
              ])
            : _pane('L', _active),
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
        // tabs take only the width they need…
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [for (var i = 0; i < _sessions.length; i++) _tab(i)],
            ),
          ),
        ),
        // …and the "+" fills the remaining space to the right edge.
        Expanded(
          child: InkWell(
            onTap: _addSession,
            child: Container(
              height: 36,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 10),
              child: const Icon(Icons.add, size: 18, color: kTextDim),
            ),
          ),
        ),
        IconButton(
          onPressed: () => setState(() {
            _split = !_split;
            if (_split && _rightActive == _active && _sessions.length > 1) {
              _rightActive = (_active + 1) % _sessions.length;
            }
          }),
          icon: Icon(Icons.vertical_split,
              size: 18, color: _split ? kAccent : kTextDim),
          tooltip: _split
              ? 'Single pane'
              : 'Split view (right-click a tab for the right pane)',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
        ),
      ]),
    );
  }

  Widget _tab(int i) {
    final s = _sessions[i];
    final isLeft = i == _active;
    final isRight = _split && i == _rightActive;
    final active = isLeft || isRight;
    final connected = s.serial.connected;
    return InkWell(
      onTap: () => _select(i),
      // right-click assigns the tab to the right pane (auto-enables split)
      onSecondaryTap: () => setState(() {
        _split = true;
        _rightActive = i;
      }),
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
          if (_split && isLeft)
            const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('L',
                    style: TextStyle(
                        color: kAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700))),
          if (_split && isRight)
            const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('R',
                    style: TextStyle(
                        color: kAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700))),
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
