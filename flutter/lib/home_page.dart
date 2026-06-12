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
  List<PortInfo> ports = [];
  String? selectedPort;
  String baudSel = '115200';
  final customBaudCtrl = TextEditingController();
  String dataBits = '8';
  String parity = 'none';
  String stopBits = '1';
  String flow = 'none';
  bool connected = false;

  // view bar
  String viewMode = 'ascii'; // ascii | hex | both
  late String rxLineEnding = settings.rxLineEnding;
  bool timestamps = true;
  bool autoscroll = true;
  bool echoTx = true;

  // output
  final List<OutputLine> lines = [];
  OutputLine? _openLine;
  String _rxLineBuffer = '';
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
  }

  @override
  void dispose() {
    _portRefreshTimer?.cancel();
    _chunkSub?.cancel();
    _eventSub?.cancel();
    scrollCtrl.dispose();
    sendCtrl.dispose();
    sendFocus.dispose();
    customBaudCtrl.dispose();
    mcpPortCtrl.dispose();
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

  void _onChunk(Uint8List bytes) {
    setState(() {
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

      // ASCII mode: split into lines, keep the partial line open so chunks
      // join naturally. A CRLF pair can be split across two chunks — hold a
      // trailing \r back until the next chunk shows whether it pairs with \n.
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

      _rxLineBuffer += chunk;
      final splitter = switch (rxLineEnding) {
        'lf' => RegExp(r'\n'),
        'cr' => RegExp(r'\r'),
        'crlf' => RegExp(r'\r\n'),
        _ => RegExp(r'\r\n|\n|\r'),
      };
      final parts = _rxLineBuffer.split(splitter);
      _rxLineBuffer = parts.removeLast();

      for (final part in parts) {
        if (_openLine != null) {
          _openLine!.payload += _printable(part);
          _openLine = null;
        } else {
          _appendLine(OutputLine(
              'rx', timestamps ? _ts() : null, 'RX<', _printable(part)));
        }
      }

      if (_rxLineBuffer.isNotEmpty) {
        if (_openLine != null) {
          _openLine!.payload += _printable(_rxLineBuffer);
        } else {
          _openLine = OutputLine(
              'rx', timestamps ? _ts() : null, 'RX<', _printable(_rxLineBuffer));
          _appendLine(_openLine!);
        }
        _rxLineBuffer = '';
      }
    });
    _scrollAfterFrame();
  }

  // ---------- events ----------

  void _onEvent(SerialEvent event) {
    switch (event.type) {
      case 'opened':
        final payload = event.payload as Map;
        final cfg = payload['config'] as SerialConfig;
        final byAgent = payload['byAgent'] as bool;
        setState(() {
          connected = true;
          _syncControls(cfg);
        });
        _appendSystem(byAgent
            ? 'Port opened by agent: ${cfg.path} @ ${cfg.baudRate} baud'
            : 'Opened ${cfg.path} @ ${cfg.baudRate} baud');
      case 'closed':
        setState(() => connected = false);
        _appendSystem('Port closed');
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

  void _syncControls(SerialConfig cfg) {
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
      _label('Port'),
      _dropdown(
        selectedPort ?? '',
        ports.isEmpty
            ? [const DropdownMenuItem(value: '', child: Text('No ports found'))]
            : [
                for (final p in ports)
                  DropdownMenuItem(
                    value: p.path,
                    child: Text(p.description.isEmpty
                        ? p.path
                        : '${p.path} — ${p.description}'),
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
        [..._items(baudRates.map((b) => b.toString()).toList()),
         const DropdownMenuItem(value: 'custom', child: Text('Custom…'))],
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
          _items(['none', 'even', 'odd', 'mark', 'space'],
              {'none': 'None', 'even': 'Even', 'odd': 'Odd', 'mark': 'Mark', 'space': 'Space'}),
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
    ]);
  }

  Widget _segButton(String label, String mode) {
    final active = viewMode == mode;
    return InkWell(
      onTap: () => setState(() {
        viewMode = mode;
        _openLine = null;
        _rxLineBuffer = '';
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
          _rxLineBuffer = '';
          _heldCR = '';
        });
        settings.rxLineEnding = v!;
        await settings.save();
      }),
      _check('Timestamps', timestamps, (v) => setState(() => timestamps = v)),
      _check('Autoscroll', autoscroll, (v) => setState(() => autoscroll = v)),
      _check('Echo TX', echoTx, (v) => setState(() => echoTx = v)),
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
          onPressed: _saveLog,
          style: _outlinedStyle(),
          child: const Text('Save Log')),
      OutlinedButton(
        onPressed: () => setState(() {
          lines.clear();
          _openLine = null;
          _rxLineBuffer = '';
          _heldCR = '';
        }),
        style: _outlinedStyle(),
        child: const Text('Clear'),
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
    return Container(
      color: kBg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: SelectionArea(
        child: ListView.builder(
          controller: scrollCtrl,
          itemCount: lines.length,
          itemBuilder: (context, i) => _lineWidget(lines[i]),
        ),
      ),
    );
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
    return Text.rich(TextSpan(children: [
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
    ]));
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
    final statusText = connected && serial.activeConfig != null
        ? 'Connected — ${serial.activeConfig!.path} @ ${serial.activeConfig!.baudRate} baud, '
            '${serial.activeConfig!.dataBits}${serial.activeConfig!.parity[0].toUpperCase()}${serial.activeConfig!.stopBits}'
        : 'Disconnected';
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
        Text(statusText,
            style: const TextStyle(color: kTextDim, fontSize: 12)),
        const Spacer(),
        Text(
          mcp.running ? 'MCP ${mcp.url}' : 'MCP off',
          style: _monoStyle.copyWith(
              fontSize: 11, color: mcp.running ? kAgentColor : kTextDim),
        ),
      ]),
    );
  }
}
