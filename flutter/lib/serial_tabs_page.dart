import 'dart:async';

import 'package:flutter/material.dart';

import 'home_page.dart'
    show HomePage, kBg, kPanel, kInput, kBorder, kText, kTextDim, kAccent, kGreen;
import 'mcp_server.dart';
import 'serial_service.dart';
import 'settings_store.dart';

class _Session {
  final SerialService serial;
  final GlobalKey key = GlobalKey(); // preserves UI state when moved between groups
  StreamSubscription? sub;
  _Session(AppSettings settings) : serial = SerialService(settings);
  _Session.adopt(this.serial);
}

/// A split pane: an ordered set of tabs with one active.
class _Group {
  final List<_Session> tabs;
  int active = 0;
  _Group(this.tabs);
}

/// VSCode-style tab groups. Each group is a split pane with its own tab strip.
/// Drag a tab onto another group to move it there, or onto the right edge to
/// split it into a new group. Every tab is an independent connection.
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
  final List<_Session> _sessions = []; // all, for lifecycle
  final List<_Group> _groups = [];
  _Session? _focused; // MCP-active tab

  @override
  void initState() {
    super.initState();
    final s = _wrap(widget.boot);
    _groups.add(_Group([s]));
    _focused = s;
    _retargetMcp();
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.sub?.cancel();
      s.serial.close(silent: true);
    }
    super.dispose();
  }

  _Session _wrap(SerialService? adopt) {
    final s = adopt != null ? _Session.adopt(adopt) : _Session(widget.settings);
    s.sub = s.serial.events.stream.listen((_) {
      if (mounted) setState(() {}); // refresh tab labels/dots
    });
    _sessions.add(s);
    return s;
  }

  // MCP sees all sessions; acts on the focused tab.
  void _retargetMcp() {
    widget.mcp.sessions = _sessions.map((e) => e.serial).toList();
    widget.mcp.active = _focused?.serial;
  }

  void _addTab(_Group g) {
    final s = _wrap(null);
    setState(() {
      g.tabs.add(s);
      g.active = g.tabs.length - 1;
      _focused = s;
    });
    _retargetMcp();
  }

  void _focus(_Group g, int i) {
    setState(() {
      g.active = i;
      _focused = g.tabs[i];
    });
    _retargetMcp();
  }

  _Group _groupOf(_Session s) => _groups.firstWhere((g) => g.tabs.contains(s));

  void _removeFromGroup(_Session s) {
    final g = _groupOf(s);
    final idx = g.tabs.indexOf(s);
    g.tabs.removeAt(idx);
    if (g.active >= g.tabs.length) g.active = g.tabs.length - 1;
    if (g.tabs.isEmpty && _groups.length > 1) _groups.remove(g);
  }

  void _moveToGroup(_Session s, _Group target) {
    if (target.tabs.contains(s) && target.tabs.length == 1) return;
    setState(() {
      _removeFromGroup(s);
      target.tabs.add(s);
      target.active = target.tabs.length - 1;
      _focused = s;
    });
    _retargetMcp();
  }

  void _moveToNewGroup(_Session s) {
    final src = _groupOf(s);
    if (src.tabs.length == 1) return; // already alone — nothing to split
    setState(() {
      _removeFromGroup(s);
      _groups.add(_Group([s]));
      _focused = s;
    });
    _retargetMcp();
  }

  void _closeTab(_Session s) {
    setState(() {
      _removeFromGroup(s);
      s.sub?.cancel();
      s.serial.close(silent: true);
      _sessions.remove(s);
      if (_sessions.isEmpty) {
        final ns = _wrap(null);
        _groups
          ..clear()
          ..add(_Group([ns]));
        _focused = ns;
      } else if (_focused == s) {
        final g = _groups.first;
        _focused = g.tabs[g.active];
      }
    });
    _retargetMcp();
  }

  String _titleFor(_Session s, int i) {
    final cfg = s.serial.activeConfig;
    if (cfg != null) {
      final base = cfg.label.split('/').last;
      return base.isEmpty ? cfg.label : base;
    }
    return 'Port ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var gi = 0; gi < _groups.length; gi++) ...[
        if (gi > 0) const VerticalDivider(width: 1, color: kBorder),
        Expanded(child: _groupView(_groups[gi])),
      ],
      _newGroupDropZone(),
    ]);
  }

  Widget _groupView(_Group g) {
    return Column(children: [
      _tabStrip(g),
      Expanded(
        child: IndexedStack(
          index: g.active.clamp(0, g.tabs.isEmpty ? 0 : g.tabs.length - 1),
          children: [
            for (final s in g.tabs)
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

  Widget _tabStrip(_Group g) {
    return DragTarget<_Session>(
      onWillAcceptWithDetails: (d) => !g.tabs.contains(d.data),
      onAcceptWithDetails: (d) => _moveToGroup(d.data, g),
      builder: (context, candidate, rejected) => Container(
        height: 36,
        decoration: BoxDecoration(
          color: candidate.isNotEmpty ? kInput : kBg,
          border: const Border(bottom: BorderSide(color: kBorder)),
        ),
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < g.tabs.length; i++) _tab(g, i),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: () => _addTab(g),
            icon: const Icon(Icons.add, size: 18, color: kTextDim),
            tooltip: 'New tab in this group',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ]),
      ),
    );
  }

  Widget _tab(_Group g, int i) {
    final s = g.tabs[i];
    final active = i == g.active;
    final focused = s == _focused;
    final connected = s.serial.connected;

    final tabInner = Container(
      constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: active ? kPanel : kBg,
        border: Border(
          right: const BorderSide(color: kBorder),
          bottom: BorderSide(
              color: focused
                  ? kAccent
                  : (active ? kBorder : Colors.transparent),
              width: 2),
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
            border: connected ? null : Border.all(color: kTextDim, width: 1),
          ),
        ),
        Flexible(
          child: Text(
            _titleFor(s, _sessions.indexOf(s)),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: active ? kText : kTextDim,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal),
          ),
        ),
        InkWell(
          onTap: () => _closeTab(s),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.close, size: 13, color: kTextDim),
          ),
        ),
      ]),
    );

    return Draggable<_Session>(
      data: s,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: kPanel,
              border: Border.all(color: kAccent),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(_titleFor(s, _sessions.indexOf(s)),
                style: const TextStyle(color: kText, fontSize: 12)),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tabInner),
      child: InkWell(onTap: () => _focus(g, i), child: tabInner),
    );
  }

  /// Right-edge target: drop a tab here to split it into a new group.
  Widget _newGroupDropZone() {
    return DragTarget<_Session>(
      onWillAcceptWithDetails: (d) => _groupOf(d.data).tabs.length > 1,
      onAcceptWithDetails: (d) => _moveToNewGroup(d.data),
      builder: (context, candidate, rejected) => Container(
        width: candidate.isNotEmpty ? 80 : 22,
        decoration: BoxDecoration(
          color: candidate.isNotEmpty ? kInput : kPanel,
          border: const Border(left: BorderSide(color: kBorder)),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.splitscreen,
            size: 16,
            color: candidate.isNotEmpty ? kAccent : kTextDim),
      ),
    );
  }
}
