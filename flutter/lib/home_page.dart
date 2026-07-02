import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mcp_server.dart';
import 'serial_service.dart';
import 'settings_store.dart';

const kBg = Color(0xFF1E1E2E);
const kPanel = Color(0xFF27273A);
const kInput = Color(0xFF313147);
const kBorder = Color(0xFF3D3D56);
const kText = Color(0xFFD9DBE8);
const kTextDim = Color(0xFF8A8CA3);
const kAccent = Color(0xFF4F9CF9);
const kGreen = Color(0xFF4ADE80);
const kRed = Color(0xFFF87171);
const kYellow = Color(0xFFFBBF24);
const kTxColor = Color(0xFF7DD3FC);
const kAgentColor = Color(0xFFC4B5FD);
const kMcpPanel = Color(0xFF2D2742);

const _monoStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono', 'monospace'],
  fontSize: 12.5,
  height: 1.45,
);

class OutputLine {
  final String type; // rx | tx | agent | sys
  final String? ts;
  final String dir;
  String payload;
  final String? hexPart;
  OutputLine(this.type, this.ts, this.dir, this.payload, [this.hexPart]);
}

/// Browses the capture buffer: every line the app has recorded (RX and TX,
/// up to 5000 entries), independent of what the live display shows.
class HistoryDialog extends StatefulWidget {
  final SerialService serial;
  const HistoryDialog({super.key, required this.serial});

  @override
  State<HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<HistoryDialog> {
  final queryCtrl = TextEditingController();
  String direction = 'both';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // keep the view live while data streams in
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    queryCtrl.dispose();
    super.dispose();
  }

  List<CaptureEntry> get _filtered {
    final q = queryCtrl.text.toLowerCase();
    return widget.serial.captureBuffer.where((e) {
      if (direction != 'both' && e.dir != direction) return false;
      if (q.isNotEmpty && !e.text.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  String _fmtTs(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${p(d.hour)}:${p(d.minute)}:${p(d.second)}.${p(d.millisecond, 3)}';
  }

  ButtonStyle get _btn => OutlinedButton.styleFrom(
        foregroundColor: kText,
        side: const BorderSide(color: kBorder),
        backgroundColor: kInput,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        textStyle: const TextStyle(fontSize: 13),
      );

  Widget _dirChip(String label, String value) {
    final active = direction == value;
    return InkWell(
      onTap: () => setState(() => direction = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        color: active ? kAccent : kInput,
        child: Text(label,
            style:
                TextStyle(color: active ? Colors.white : kText, fontSize: 12)),
      ),
    );
  }

  Future<void> _export(List<CaptureEntry> entries) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final location =
        await getSaveLocation(suggestedName: 'serial-history-$stamp.txt');
    if (location == null) return;
    final content =
        '${entries.map((e) => '[${e.ts}] ${e.dir.toUpperCase()} ${e.text}').join('\n')}\n';
    await File(location.path).writeAsString(content);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    final buffer = widget.serial.captureBuffer;

    return Dialog(
      backgroundColor: kPanel,
      child: SizedBox(
        width: 880,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(children: [
                const Text('Capture History',
                    style: TextStyle(
                        color: kText,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Text(
                  '${entries.length} of ${buffer.length} entries'
                  '${buffer.isEmpty ? '' : ' (seq ${buffer.first.seq}–${buffer.last.seq})'}',
                  style: const TextStyle(color: kTextDim, fontSize: 12),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18, color: kTextDim),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: queryCtrl,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: kText, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Filter text…',
                      hintStyle: const TextStyle(color: kTextDim),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
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
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _dirChip('All', 'both'),
                    _dirChip('RX', 'rx'),
                    _dirChip('TX', 'tx'),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: kBg,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: kBorder),
                ),
                padding: const EdgeInsets.all(8),
                child: entries.isEmpty
                    ? const Center(
                        child: Text('No captured data',
                            style: TextStyle(color: kTextDim)))
                    : SelectionArea(
                        child: ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final isTx = e.dir == 'tx';
                          return Text.rich(TextSpan(children: [
                            TextSpan(
                                text: '${e.seq.toString().padLeft(6)}  ',
                                style: _monoStyle.copyWith(
                                    color: kTextDim, fontSize: 11.5)),
                            TextSpan(
                                text: '${_fmtTs(e.ts)}  ',
                                style:
                                    _monoStyle.copyWith(color: kTextDim)),
                            TextSpan(
                                text: isTx ? 'TX> ' : 'RX< ',
                                style: _monoStyle.copyWith(
                                    color: isTx ? kTxColor : kGreen,
                                    fontWeight: FontWeight.w700)),
                            TextSpan(
                                text: e.text,
                                style: _monoStyle.copyWith(
                                    color: isTx ? kTxColor : kText)),
                          ]));
                        },
                      )),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                OutlinedButton(
                  onPressed:
                      entries.isEmpty ? null : () => _export(entries),
                  style: _btn,
                  child: Text(queryCtrl.text.isEmpty && direction == 'both'
                      ? 'Export all'
                      : 'Export filtered (${entries.length})'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: buffer.isEmpty
                      ? null
                      : () => setState(() => widget.serial.clearCapture()),
                  style: _btn.copyWith(
                    foregroundColor: const WidgetStatePropertyAll(kRed),
                  ),
                  child: const Text('Reset Buffer'),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: _btn,
                  child: const Text('Close'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final SerialService serial;
  final McpServer mcp;
  final AppSettings settings;
  const HomePage(
      {super.key,
      required this.serial,
      required this.mcp,
      required this.settings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const maxLines = 5000;
  static const baudRates = [
    300, 1200, 2400, 4800, 9600, 19200, 38400, 57600,
    115200, 230400, 460800, 921600,
  ];

  SerialService get serial => widget.serial;
  McpServer get mcp => widget.mcp;
  AppSettings get settings => widget.settings;

  // toolbar
  String transport = 'serial'; // serial | tcp | udp
  List<PortInfo> ports = [];
  String? selectedPort;
  String baudSel = '115200';
  final customBaudCtrl = TextEditingController();
  String dataBits = '8';
  String parity = 'none';
  String stopBits = '1';
  String flow = 'none';
  final hostCtrl = TextEditingController();
  final netPortCtrl = TextEditingController();
  bool connected = false;

  // view bar
  String viewMode = 'ascii'; // ascii | hex | both
  late String rxLineEnding = settings.rxLineEnding;
  bool timestamps = true;
  bool autoscroll = true;
  bool echoTx = true;
  bool terminalMode = false;
  final outputFocus = FocusNode();

  // output
  final List<OutputLine> lines = [];
  OutputLine? _openLine;
  String _heldCR = '';
  final scrollCtrl = ScrollController();

  // send bar
  final sendCtrl = TextEditingController();
  final sendFocus = FocusNode();
  bool sendHex = false;
  String txLineEnding = '\n';
  final List<String> history = [];
  int historyIndex = 0;

  // MCP bar
  bool mcpBarVisible = false;
  late bool mcpEnabled = settings.mcpEnabled;
  late final mcpPortCtrl =
      TextEditingController(text: settings.mcpPort.toString());

  Timer? _portRefreshTimer;
  StreamSubscription<Uint8List>? _chunkSub;
  StreamSubscription<SerialEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _portRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!connected) _refreshPorts();
    });

    _chunkSub = serial.rxChunks.stream.listen(_onChunk);
    _eventSub = serial.events.stream.listen(_onEvent);
    _uiFlushTimer =
        Timer.periodic(const Duration(milliseconds: 33), (_) => _flushPending());
    outputFocus.addListener(() {
      if (mounted) setState(() {}); // repaint terminal focus border
    });
  }

  @override
  void dispose() {
    _uiFlushTimer?.cancel();
    _portRefreshTimer?.cancel();
    _chunkSub?.cancel();
    _eventSub?.cancel();
    scrollCtrl.dispose();
    sendCtrl.dispose();
    sendFocus.dispose();
    customBaudCtrl.dispose();
    hostCtrl.dispose();
    netPortCtrl.dispose();
    mcpPortCtrl.dispose();
    outputFocus.dispose();
    super.dispose();
  }

  // ---------- helpers ----------

  String _ts() {
    final d = DateTime.now();
    String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${p(d.hour)}:${p(d.minute)}:${p(d.second)}.${p(d.millisecond, 3)}';
  }

  static String _toHex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  // Show control chars as dots (tab stays; line endings are consumed by the
  // splitter, so any CR/LF still here is a stray worth seeing)
  static String _printable(String text) =>
      text.replaceAll(RegExp(r'[\x00-\x08\x0A-\x1F\x7F]'), '·');

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  void _scrollAfterFrame() {
    if (!autoscroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollCtrl.hasClients) {
        scrollCtrl.jumpTo(scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _appendLine(OutputLine line) {
    lines.add(line);
    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
    }
  }

  void _appendSystem(String text) {
    setState(() {
      _openLine = null;
      _appendLine(OutputLine('sys', timestamps ? _ts() : null, '--', text));
    });
    _scrollAfterFrame();
  }

  void _appendTx(String text, String? hexText, {bool agent = false}) {
    setState(() {
      _openLine = null;
      if (echoTx) {
        _appendLine(OutputLine(agent ? 'agent' : 'tx',
            timestamps ? _ts() : null, agent ? 'AI>' : 'TX>', text, hexText));
      }
    });
    _scrollAfterFrame();
  }

  // ---------- RX rendering ----------

  // Serial data can arrive as hundreds of tiny chunks per second; rendering
  // each one individually hammers the engine's text layout. Batch them and
  // paint at most ~30 times per second.
  final List<Uint8List> _pendingChunks = [];
  Timer? _uiFlushTimer;

  void _onChunk(Uint8List bytes) {
    // Just buffer; a periodic timer drains at ~30 fps. A periodic timer (vs a
    // self-rescheduling one-shot) can never get stranded and freeze the view.
    _pendingChunks.add(bytes);
  }

  void _flushPending() {
    if (!mounted || _pendingChunks.isEmpty) return;
    final chunks = List.of(_pendingChunks);
    _pendingChunks.clear();
    setState(() {
      for (final c in chunks) {
        try {
          _renderChunk(c);
        } catch (_) {
          // one malformed chunk must never wedge the render loop
        }
      }
    });
    _scrollAfterFrame();
  }

  void _renderChunk(Uint8List bytes) {
    {
      final text = utf8.decode(bytes, allowMalformed: true);

      if (viewMode == 'hex') {
        _openLine = null;
        _appendLine(OutputLine(
            'rx', timestamps ? _ts() : null, 'RX<', _toHex(bytes)));
        return;
      }

      if (viewMode == 'both') {
        _openLine = null;
        final printable =
            _printable(text.replaceAll('\r', '')).replaceAll('\n', '↵');
        _appendLine(OutputLine('rx', timestamps ? _ts() : null, 'RX<',
            printable, _toHex(bytes)));
        return;
      }

      // ASCII mode: stream chars into the current line, honoring backspace.
      // A CRLF pair can split across chunks — hold a trailing \r until the
      // next chunk shows whether it pairs with \n.
      var chunk = text;
      if (rxLineEnding == 'auto' || rxLineEnding == 'crlf') {
        chunk = _heldCR + chunk;
        _heldCR = '';
        if (chunk.endsWith('\r')) {
          _heldCR = '\r';
          chunk = chunk.substring(0, chunk.length - 1);
        }
      }
      if (chunk.isEmpty) return;

      OutputLine ensureLine() {
        _openLine ??= () {
          final l = OutputLine('rx', timestamps ? _ts() : null, 'RX<', '');
          _appendLine(l);
          return l;
        }();
        return _openLine!;
      }

      for (var i = 0; i < chunk.length; i++) {
        final c = chunk[i];
        final code = chunk.codeUnitAt(i);

        // line terminator per selected ending
        var isEnd = false;
        switch (rxLineEnding) {
          case 'lf':
            isEnd = c == '\n';
          case 'cr':
            isEnd = c == '\r';
          case 'crlf':
            if (c == '\r' && i + 1 < chunk.length && chunk[i + 1] == '\n') {
              isEnd = true;
              i++;
            }
          default: // auto: CR, LF, or CRLF
            if (c == '\n') {
              isEnd = true;
            } else if (c == '\r') {
              if (i + 1 < chunk.length && chunk[i + 1] == '\n') i++;
              isEnd = true;
            }
        }
        if (isEnd) {
          _openLine = null;
          continue;
        }

        // backspace / DEL erases the previous char, like a terminal
        if (code == 0x08 || code == 0x7f) {
          final l = _openLine;
          if (l != null && l.payload.isNotEmpty) {
            l.payload = l.payload.substring(0, l.payload.length - 1);
          }
          continue;
        }

        ensureLine().payload += _printable(c);
      }
    }
  }

  // ---------- events ----------

  void _onEvent(SerialEvent event) {
    switch (event.type) {
      case 'opened':
        final payload = event.payload as Map;
        final cfg = payload['config'] as ConnConfig;
        final byAgent = payload['byAgent'] as bool;
        setState(() {
          connected = true;
          _syncControls(cfg);
        });
        _appendSystem(byAgent
            ? 'Opened by agent: ${cfg.label}'
            : 'Opened ${cfg.label}');
      case 'closed':
        setState(() => connected = false);
        _appendSystem('Port closed');
      case 'note':
        _appendSystem('${event.payload}');
      case 'error':
        _appendSystem('Port error: ${event.payload}');
      case 'agentTx':
        final info = event.payload as Map;
        final isHex = info['hex'] as bool;
        final data = info['data'] as String;
        final bytes = info['bytes'] as int;
        if (isHex) {
          final cleaned = data.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
          final pretty = [
            for (var i = 0; i + 1 < cleaned.length; i += 2)
              cleaned.substring(i, i + 2).toUpperCase()
          ].join(' ');
          _appendTx('$bytes bytes', pretty, agent: true);
        } else {
          _appendTx(data, null, agent: true);
        }
    }
  }

  void _syncControls(ConnConfig cfg) {
    if (cfg is NetConfig) {
      transport = cfg.protocol;
      hostCtrl.text = cfg.host;
      netPortCtrl.text = cfg.port.toString();
      return;
    }
    cfg as SerialConfig;
    transport = 'serial';
    if (!ports.any((p) => p.path == cfg.path)) {
      ports = [...ports, PortInfo(cfg.path, '')];
    }
    selectedPort = cfg.path;
    if (baudRates.contains(cfg.baudRate)) {
      baudSel = cfg.baudRate.toString();
    } else {
      baudSel = 'custom';
      customBaudCtrl.text = cfg.baudRate.toString();
    }
    dataBits = cfg.dataBits.toString();
    parity = cfg.parity;
    stopBits = cfg.stopBits.toString();
    flow = cfg.flowControl;
  }

  // ---------- actions ----------

  void _refreshPorts() {
    final found = serial.listPorts();
    setState(() {
      ports = found;
      if (selectedPort == null || !ports.any((p) => p.path == selectedPort)) {
        selectedPort = ports.isEmpty ? null : ports.first.path;
      }
    });
  }

  int _baudRate() => baudSel == 'custom'
      ? (int.tryParse(customBaudCtrl.text) ?? 0)
      : int.parse(baudSel);

  Future<void> _connectToggle() async {
    if (connected) {
      await serial.close();
      return;
    }

    if (transport != 'serial') {
      final server = transport.endsWith('-server');
      final proto = transport.split('-').first; // tcp | udp
      final host = hostCtrl.text.trim();
      final p = int.tryParse(netPortCtrl.text.trim()) ?? 0;
      if (!server && host.isEmpty) {
        _appendSystem('Enter a host');
        return;
      }
      if (p < 1 || p > 65535) {
        _appendSystem('Invalid port number');
        return;
      }
      final result = await serial.openNet(NetConfig(
          protocol: proto, host: host, port: p, server: server));
      if (result['ok'] != true) {
        _appendSystem('Failed to open $transport: ${result['error']}');
      } else if (server) {
        _appendSystem('Listening on $proto port $p');
      }
      return;
    }

    final port = selectedPort;
    if (port == null) {
      _appendSystem('No port selected');
      return;
    }
    final baud = _baudRate();
    if (baud < 1) {
      _appendSystem('Invalid baud rate');
      return;
    }
    final result = await serial.open(SerialConfig(
      path: port,
      baudRate: baud,
      dataBits: int.parse(dataBits),
      parity: parity,
      stopBits: int.parse(stopBits),
      flowControl: flow,
    ));
    if (result['ok'] != true) {
      _appendSystem('Failed to open $port: ${result['error']}');
    }
  }

  Future<void> _send() async {
    final raw = sendCtrl.text;
    if (raw.isEmpty) return;

    final result = await serial.write(
      data: raw,
      hex: sendHex,
      lineEnding: sendHex ? '' : txLineEnding,
    );

    if (result['ok'] == true) {
      if (sendHex) {
        final cleaned = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
        final pretty = [
          for (var i = 0; i + 1 < cleaned.length; i += 2)
            cleaned.substring(i, i + 2).toUpperCase()
        ].join(' ');
        _appendTx('${result['bytes']} bytes', pretty);
      } else {
        _appendTx(raw, null);
      }
      if (history.isEmpty || history.last != raw) history.add(raw);
      if (history.length > 100) history.removeAt(0);
      historyIndex = history.length;
      sendCtrl.clear();
    } else {
      _appendSystem('Send failed: ${result['error']}');
    }
  }

  KeyEventResult _onSendKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (history.isNotEmpty && historyIndex > 0) {
        historyIndex -= 1;
        sendCtrl.text = history[historyIndex];
        sendCtrl.selection =
            TextSelection.collapsed(offset: sendCtrl.text.length);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (historyIndex < history.length - 1) {
        historyIndex += 1;
        sendCtrl.text = history[historyIndex];
      } else {
        historyIndex = history.length;
        sendCtrl.clear();
      }
      sendCtrl.selection =
          TextSelection.collapsed(offset: sendCtrl.text.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _saveLog() async {
    if (serial.captureBuffer.isEmpty) {
      _appendSystem('Nothing to save yet');
      return;
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final location =
        await getSaveLocation(suggestedName: 'serial-log-$stamp.txt');
    if (location == null) return;
    final content =
        '${serial.captureBuffer.map((e) => '[${e.ts}] ${e.dir.toUpperCase()} ${e.text}').join('\n')}\n';
    try {
      await File(location.path).writeAsString(content);
      _appendSystem('Log saved to ${location.path}');
    } catch (e) {
      _appendSystem('Save failed: $e');
    }
  }

  Future<void> _applyMcpConfig() async {
    final port = int.tryParse(mcpPortCtrl.text) ?? 0;
    if (mcpEnabled && (port < 1 || port > 65535)) {
      _appendSystem('MCP server error: invalid port number');
      return;
    }
    settings.mcpEnabled = mcpEnabled;
    if (port > 0) settings.mcpPort = port;
    await settings.save();

    if (mcpEnabled) {
      final ok = await mcp.start(settings.mcpPort);
      _appendSystem(ok
          ? 'MCP server running at ${mcp.url}'
          : 'MCP server error: ${mcp.error}');
    } else {
      await mcp.stop();
      _appendSystem('MCP server stopped');
    }
    setState(() {});
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          _toolbar(),
          _viewBar(),
          if (mcpBarVisible) _mcpBar(),
          Expanded(child: _output()),
          _sendBar(),
          _statusBar(),
        ],
      ),
    );
  }

  Widget _bar({required List<Widget> children, Color color = kPanel}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        border: const Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }

  Widget _label(String text) =>
      Text(text, style: const TextStyle(color: kTextDim, fontSize: 12));

  Widget _dropdown(String value, List<DropdownMenuItem<String>> items,
      ValueChanged<String?>? onChanged, {double? width}) {
    final dd = DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        items: items,
        onChanged: onChanged,
        isDense: true,
        // In fixed-width mode, fill the box so long labels ellipsize
        // instead of overflowing past it.
        isExpanded: width != null,
        dropdownColor: kInput,
        style: const TextStyle(color: kText, fontSize: 13),
        iconEnabledColor: kTextDim,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kInput,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(5),
      ),
      child: width == null ? dd : SizedBox(width: width, child: dd),
    );
  }

  List<DropdownMenuItem<String>> _items(List<String> values,
          [Map<String, String>? labels]) =>
      [
        for (final v in values)
          DropdownMenuItem(value: v, child: Text(labels?[v] ?? v))
      ];

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: kAccent,
            side: const BorderSide(color: kBorder),
          ),
        ),
        const SizedBox(width: 5),
        _label(label),
      ]),
    );
  }

  Widget _toolbar() {
    final disabled = connected;
    return _bar(children: [
      FilledButton(
        onPressed: _connectToggle,
        style: FilledButton.styleFrom(
          backgroundColor: connected ? kRed : kAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
        child: Text(connected ? 'Disconnect' : 'Connect'),
      ),
      _label('Type'),
      _dropdown(
          transport,
          _items([
            'serial',
            'tcp',
            'udp',
            'tcp-server',
            'udp-server'
          ], {
            'serial': 'Serial',
            'tcp': 'TCP client',
            'udp': 'UDP client',
            'tcp-server': 'TCP server',
            'udp-server': 'UDP server',
          }),
          disabled ? null : (v) => setState(() => transport = v!)),
      if (transport == 'serial') ...[
        _label('Port'),
        _dropdown(
          selectedPort ?? '',
          ports.isEmpty
              ? [
                  const DropdownMenuItem(
                      value: '', child: Text('No ports found'))
                ]
              : [
                  for (final p in ports)
                    DropdownMenuItem(
                      value: p.path,
                      child: Text(
                        p.description.isEmpty
                            ? p.path
                            : '${p.path} — ${p.description}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                ],
          disabled ? null : (v) => setState(() => selectedPort = v),
          width: 260,
        ),
        IconButton(
          onPressed: disabled ? null : _refreshPorts,
          icon: const Icon(Icons.refresh, size: 18, color: kTextDim),
          tooltip: 'Refresh port list',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
        _label('Baud'),
        _dropdown(
          baudSel,
          [
            ..._items(baudRates.map((b) => b.toString()).toList()),
            const DropdownMenuItem(value: 'custom', child: Text('Custom…'))
          ],
          disabled ? null : (v) => setState(() => baudSel = v!),
        ),
        if (baudSel == 'custom')
          SizedBox(
            width: 90,
            child: TextField(
              controller: customBaudCtrl,
              enabled: !disabled,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: kText, fontSize: 13),
              decoration: _inputDecoration('baud'),
            ),
          ),
        _label('Data'),
        _dropdown(dataBits, _items(['5', '6', '7', '8']),
            disabled ? null : (v) => setState(() => dataBits = v!)),
        _label('Parity'),
        _dropdown(
            parity,
            _items(['none', 'even', 'odd', 'mark', 'space'], {
              'none': 'None',
              'even': 'Even',
              'odd': 'Odd',
              'mark': 'Mark',
              'space': 'Space'
            }),
            disabled ? null : (v) => setState(() => parity = v!)),
        _label('Stop'),
        _dropdown(stopBits, _items(['1', '2']),
            disabled ? null : (v) => setState(() => stopBits = v!)),
        _label('Flow'),
        _dropdown(
            flow,
            _items(['none', 'rtscts', 'xonxoff'],
                {'none': 'None', 'rtscts': 'RTS/CTS', 'xonxoff': 'XON/XOFF'}),
            disabled ? null : (v) => setState(() => flow = v!)),
      ] else ...[
        _label(transport.endsWith('-server') ? 'Bind' : 'Host'),
        SizedBox(
          width: 160,
          child: TextField(
            controller: hostCtrl,
            enabled: !disabled,
            style: const TextStyle(color: kText, fontSize: 13),
            decoration: _inputDecoration(
                transport.endsWith('-server') ? '0.0.0.0 (all)' : 'host or IP'),
          ),
        ),
        _label('Port'),
        SizedBox(
          width: 80,
          child: TextField(
            controller: netPortCtrl,
            enabled: !disabled,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: kText, fontSize: 13),
            decoration: _inputDecoration('port'),
          ),
        ),
      ],
    ]);
  }

  Widget _segButton(String label, String mode) {
    final active = viewMode == mode;
    return InkWell(
      onTap: () => setState(() {
        viewMode = mode;
        _openLine = null;
        _heldCR = '';
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        color: active ? kAccent : kInput,
        child: Text(label,
            style: TextStyle(
                color: active ? Colors.white : kText, fontSize: 12)),
      ),
    );
  }

  Widget _viewBar() {
    return _bar(children: [
      _label('View'),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _segButton('ASCII', 'ascii'),
          _segButton('HEX', 'hex'),
          _segButton('Both', 'both'),
        ]),
      ),
      _label('RX line end'),
      _dropdown(
          rxLineEnding,
          _items(['auto', 'lf', 'cr', 'crlf'], {
            'auto': 'Auto (any)',
            'lf': 'LF (\\n)',
            'cr': 'CR (\\r)',
            'crlf': 'CRLF (\\r\\n)'
          }), (v) async {
        setState(() {
          rxLineEnding = v!;
          _openLine = null;
          _heldCR = '';
        });
        settings.rxLineEnding = v!;
        await settings.save();
      }),
      _check('Timestamps', timestamps, (v) => setState(() => timestamps = v)),
      _check('Autoscroll', autoscroll, (v) => setState(() => autoscroll = v)),
      _check('Echo TX', echoTx, (v) => setState(() => echoTx = v)),
      _check('Terminal', terminalMode, (v) {
        setState(() => terminalMode = v);
        if (v) {
          outputFocus.requestFocus();
        } else {
          outputFocus.unfocus();
        }
      }),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: kInput, borderRadius: BorderRadius.circular(4)),
        child: Text('RX ${_fmtBytes(serial.rxTotal)}',
            style: _monoStyle.copyWith(fontSize: 11, color: kTextDim)),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: kInput, borderRadius: BorderRadius.circular(4)),
        child: Text('TX ${_fmtBytes(serial.txTotal)}',
            style: _monoStyle.copyWith(fontSize: 11, color: kTextDim)),
      ),
      OutlinedButton(
          onPressed: lines.isEmpty ? null : _copyAll,
          style: _outlinedStyle(),
          child: const Text('Copy')),
      OutlinedButton(
          onPressed: _saveLog,
          style: _outlinedStyle(),
          child: const Text('Save Log')),
      OutlinedButton(
        onPressed: () => setState(() {
          // display only — captured history stays available under History
          lines.clear();
          _openLine = null;
          _heldCR = '';
        }),
        style: _outlinedStyle(),
        child: const Text('Clear'),
      ),
      OutlinedButton(
        onPressed: () => showDialog(
          context: context,
          builder: (_) => HistoryDialog(serial: serial),
        ),
        style: _outlinedStyle(),
        child: const Text('History'),
      ),
      OutlinedButton(
        onPressed: () => setState(() => mcpBarVisible = !mcpBarVisible),
        style: _outlinedStyle(),
        child: const Text('MCP ⚙'),
      ),
    ]);
  }

  ButtonStyle _outlinedStyle() => OutlinedButton.styleFrom(
        foregroundColor: kText,
        side: const BorderSide(color: kBorder),
        backgroundColor: kInput,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        textStyle: const TextStyle(fontSize: 13),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
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
      );

  Widget _mcpBar() {
    return _bar(color: kMcpPanel, children: [
      _check('Enable MCP server', mcpEnabled,
          (v) => setState(() => mcpEnabled = v)),
      _label('Port'),
      SizedBox(
        width: 80,
        child: TextField(
          controller: mcpPortCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: kText, fontSize: 13),
          decoration: _inputDecoration('port'),
        ),
      ),
      OutlinedButton(
          onPressed: _applyMcpConfig,
          style: _outlinedStyle(),
          child: const Text('Apply')),
      Text(
        mcp.running
            ? 'Running at ${mcp.url}'
            : (mcp.error != null
                ? 'Failed to start: ${mcp.error}'
                : 'Server disabled'),
        style: _monoStyle.copyWith(
            fontSize: 11,
            color: mcp.running
                ? kGreen
                : (mcp.error != null ? kRed : kTextDim)),
      ),
      OutlinedButton(
        onPressed: mcp.running
            ? () {
                Clipboard.setData(ClipboardData(
                    text:
                        'claude mcp add --transport http serial-monitor ${mcp.url}'));
                _appendSystem('Connect command copied to clipboard');
              }
            : null,
        style: _outlinedStyle(),
        child: const Text('Copy connect command'),
      ),
    ]);
  }

  Widget _output() {
    final list = ListView.builder(
      controller: scrollCtrl,
      itemCount: lines.length,
      itemBuilder: (context, i) => _lineWidget(lines[i]),
    );

    // Terminal mode → output takes focus and forwards keystrokes to the port.
    // Otherwise wrap in SelectionArea so you can drag-select text and Cmd-C.
    // (The old text-layout crashes were the libserialport heap double-free,
    // since fixed — not SelectionArea.)
    final body = terminalMode
        ? GestureDetector(
            onTap: () => outputFocus.requestFocus(),
            child: Focus(
              focusNode: outputFocus,
              onKeyEvent: _onTerminalKey,
              child: list,
            ),
          )
        : SelectionArea(child: list);

    return Container(
      color: kBg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: terminalMode && outputFocus.hasFocus
          ? BoxDecoration(
              color: kBg, border: Border.all(color: kAccent, width: 1))
          : const BoxDecoration(color: kBg),
      child: body,
    );
  }

  KeyEventResult _onTerminalKey(FocusNode node, KeyEvent e) {
    if (!terminalMode || !connected) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    String? out;
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      out = '\r';
    } else if (k == LogicalKeyboardKey.backspace) {
      out = '\x7f';
    } else if (k == LogicalKeyboardKey.tab) {
      out = '\t';
    } else if (k == LogicalKeyboardKey.escape) {
      out = '\x1b';
    } else {
      final c = e.character;
      if (c != null && c.isNotEmpty && c.codeUnitAt(0) >= 0x20) out = c;
    }
    if (out == null) return KeyEventResult.ignored;
    serial.write(data: out, lineEnding: '');
    return KeyEventResult.handled;
  }

  String _lineText(OutputLine l) {
    final ts = l.ts != null ? '${l.ts}  ' : '';
    final hex = l.hexPart != null ? '  [${l.hexPart}]' : '';
    return '$ts${l.dir} ${l.payload}$hex';
  }

  Future<void> _copyAll() async {
    final text = lines.map(_lineText).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    _appendSystem('Copied ${lines.length} lines to clipboard');
  }

  Widget _lineWidget(OutputLine line) {
    final dirColor = switch (line.type) {
      'tx' => kTxColor,
      'agent' => kAgentColor,
      'sys' => kYellow,
      _ => kGreen,
    };
    final payloadColor = switch (line.type) {
      'tx' => kTxColor,
      'agent' => kAgentColor,
      'sys' => kYellow,
      _ => kText,
    };
    // Right-click a line to copy just that line; drag-select across lines for
    // partial copies (Cmd-C), or the Copy button for everything.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTap: () {
        Clipboard.setData(ClipboardData(text: line.payload));
        _appendSystem('Copied line to clipboard');
      },
      child: Text.rich(TextSpan(children: [
      if (line.ts != null)
        TextSpan(
            text: '${line.ts}  ',
            style: _monoStyle.copyWith(color: kTextDim)),
      TextSpan(
          text: '${line.dir} ',
          style: _monoStyle.copyWith(
              color: dirColor, fontWeight: FontWeight.w700)),
      TextSpan(
          text: line.payload,
          style: _monoStyle.copyWith(
              color: payloadColor,
              fontStyle:
                  line.type == 'sys' ? FontStyle.italic : FontStyle.normal)),
        if (line.hexPart != null)
          TextSpan(
              text: '  [${line.hexPart}]',
              style: _monoStyle.copyWith(color: kTextDim)),
      ])),
    );
  }

  Widget _sendBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        _dropdown(
            txLineEnding,
            _items(['', '\n', '\r', '\r\n'], {
              '': 'No line ending',
              '\n': 'LF (\\n)',
              '\r': 'CR (\\r)',
              '\r\n': 'CRLF (\\r\\n)'
            }),
            (v) => setState(() => txLineEnding = v!)),
        const SizedBox(width: 10),
        Expanded(
          child: Focus(
            onKeyEvent: _onSendKey,
            child: TextField(
              controller: sendCtrl,
              focusNode: sendFocus,
              enabled: connected,
              style: _monoStyle.copyWith(color: kText),
              decoration: _inputDecoration(
                  'Type data to send… (Up/Down for history)'),
              onSubmitted: (_) {
                _send();
                sendFocus.requestFocus();
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        _check('HEX', sendHex, (v) => setState(() => sendHex = v)),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: connected ? _send : null,
          style: FilledButton.styleFrom(
              backgroundColor: kAccent, foregroundColor: Colors.white),
          child: const Text('Send'),
        ),
      ]),
    );
  }

  Widget _statusBar() {
    final cfg = serial.activeConfig;
    String statusText;
    if (connected && cfg is SerialConfig) {
      statusText = 'Connected — ${cfg.path} @ ${cfg.baudRate} baud, '
          '${cfg.dataBits}${cfg.parity[0].toUpperCase()}${cfg.stopBits}';
    } else if (connected && cfg is NetConfig) {
      statusText = cfg.server
          ? 'Listening — ${cfg.protocol.toUpperCase()} server :${cfg.port}'
          : 'Connected — ${cfg.protocol.toUpperCase()} ${cfg.host}:${cfg.port}';
    } else {
      statusText = 'Disconnected';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected ? kGreen : kRed,
            boxShadow: connected
                ? [const BoxShadow(color: kGreen, blurRadius: 6)]
                : null,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(statusText,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextDim, fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            mcp.running ? 'MCP ${mcp.url}' : 'MCP off',
            overflow: TextOverflow.ellipsis,
            style: _monoStyle.copyWith(
                fontSize: 11, color: mcp.running ? kAgentColor : kTextDim),
          ),
        ),
      ]),
    );
  }
}
