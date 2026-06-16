import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'settings_store.dart';

class PortInfo {
  final String path;
  final String description;
  PortInfo(this.path, this.description);

  Map<String, dynamic> toJson() => {'path': path, 'description': description};
}

/// A connection target — serial device, or TCP/UDP network endpoint.
sealed class ConnConfig {
  String get kind; // serial | tcp | udp
  String get label; // identifier shown in UI and used by MCP `port` targeting
  Map<String, dynamic> toJson();
}

class SerialConfig extends ConnConfig {
  final String path;
  final int baudRate;
  final int dataBits;
  final String parity; // none | even | odd | mark | space
  final int stopBits; // 1 | 2 (libserialport has no 1.5)
  final String flowControl; // none | rtscts | xonxoff

  SerialConfig({
    required this.path,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.parity = 'none',
    this.stopBits = 1,
    this.flowControl = 'none',
  });

  @override
  String get kind => 'serial';
  @override
  String get label => path;

  @override
  Map<String, dynamic> toJson() => {
        'path': path,
        'baudRate': baudRate,
        'dataBits': dataBits,
        'parity': parity,
        'stopBits': stopBits,
        'flowControl': flowControl,
      };
}

class NetConfig extends ConnConfig {
  final String protocol; // tcp | udp
  final String host;
  final int port;

  NetConfig({required this.protocol, required this.host, required this.port});

  @override
  String get kind => protocol;
  @override
  String get label => '$protocol $host:$port';

  @override
  Map<String, dynamic> toJson() =>
      {'protocol': protocol, 'host': host, 'port': port};
}

class CaptureEntry {
  final int seq;
  final String dir; // rx | tx
  final String ts;
  final String text;
  final String hex;
  CaptureEntry(this.seq, this.dir, this.ts, this.text, this.hex);

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'dir': dir, 'ts': ts, 'text': text, 'hex': hex};
}

class SerialEvent {
  final String type; // opened | closed | error | agentTx
  final dynamic payload;
  SerialEvent(this.type, [this.payload]);
}

class SerialService {
  static const captureMaxEntries = 5000;
  static const hexMaxBytes = 256;
  static const rxFlushMs = 300;
  static const rxAssemblyMax = 4096;

  final AppSettings settings;
  SerialService(this.settings);

  // transports (only one live at a time)
  SerialPort? _port;
  Timer? _readTimer;
  Socket? _tcp;
  RawDatagramSocket? _udp;
  InternetAddress? _udpRemote;
  int _udpPort = 0;
  StreamSubscription? _netSub;

  ConnConfig? activeConfig;

  bool get connected =>
      (_port?.isOpen ?? false) || _tcp != null || _udp != null;

  /// Serial path of the active connection, or null when none/network.
  String? get serialPath =>
      activeConfig is SerialConfig ? (activeConfig as SerialConfig).path : null;

  int rxTotal = 0;
  int txTotal = 0;

  // Capture ring buffer shared by the log and the MCP read_data tool.
  // The MCP side only ever reads this — observation never touches the port.
  final List<CaptureEntry> captureBuffer = [];
  int captureSeq = 0;
  List<int> _rxAssembly = [];
  Timer? _rxFlushTimer;

  /// Raw chunks for the live UI display (unassembled, lossless).
  final StreamController<Uint8List> rxChunks =
      StreamController<Uint8List>.broadcast();

  /// Connection lifecycle and agent activity notifications for the UI.
  final StreamController<SerialEvent> events =
      StreamController<SerialEvent>.broadcast();

  List<PortInfo> listPorts() {
    return SerialPort.availablePorts.map((name) {
      var desc = '';
      try {
        final p = SerialPort(name);
        desc = p.description ?? '';
        p.dispose();
      } catch (_) {
        // metadata is best-effort
      }
      return PortInfo(name, desc);
    }).toList();
  }

  static int _parityOf(String p) => switch (p) {
        'even' => SerialPortParity.even,
        'odd' => SerialPortParity.odd,
        'mark' => SerialPortParity.mark,
        'space' => SerialPortParity.space,
        _ => SerialPortParity.none,
      };

  static int _flowOf(String f) => switch (f) {
        'rtscts' => SerialPortFlowControl.rtsCts,
        'xonxoff' => SerialPortFlowControl.xonXoff,
        _ => SerialPortFlowControl.none,
      };

  // Connection labels open across all tabs. Opening the same target twice
  // in-process is blocked (two serial readers fight over one stream; duplicate
  // sockets are pointless).
  static final Set<String> _openPaths = {};

  Future<Map<String, dynamic>> open(SerialConfig cfg,
      {bool byAgent = false}) async {
    if (_openPaths.contains(cfg.label) && activeConfig?.label != cfg.label) {
      return {
        'ok': false,
        'error': '${cfg.path} is already open in another tab'
      };
    }
    await close(silent: true);

    final port = SerialPort(cfg.path);
    if (!port.openReadWrite()) {
      final msg = SerialPort.lastError?.message ?? 'failed to open port';
      port.dispose();
      return {'ok': false, 'error': msg};
    }

    // Best-effort config: virtual ports (ptys) reject modem-control ioctls
    // that real devices accept, so a partial failure shouldn't block opening.
    //
    // OWNERSHIP: the config setter caches this object inside the SerialPort,
    // and port.dispose() frees it. Disposing it here too is a double free
    // that corrupts the heap on every disconnect (random engine crashes).
    String? configWarning;
    final spc = SerialPortConfig()
      ..baudRate = cfg.baudRate
      ..bits = cfg.dataBits
      ..parity = _parityOf(cfg.parity)
      ..stopBits = cfg.stopBits
      ..setFlowControl(_flowOf(cfg.flowControl));
    try {
      port.config = spc;
    } catch (e) {
      configWarning = 'config not fully applied (virtual port?): $e';
    }

    _port = port;
    activeConfig = cfg;
    _openPaths.add(cfg.label);
    rxTotal = 0;
    txTotal = 0;
    _rxAssembly = [];

    // Poll for incoming bytes on the main isolate instead of using
    // SerialPortReader: its background isolate runs a synchronous loop that
    // Isolate.kill() can never stop, so it keeps calling sp_wait() on the
    // port after the port is freed — heap corruption and random crashes.
    // Non-blocking polling every 10 ms is cheap and fully deterministic.
    _readTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final p = _port;
      if (p == null || !p.isOpen) return;
      try {
        final available = p.bytesAvailable;
        if (available <= 0) return;
        final data = p.read(available.clamp(1, 16384), timeout: 100);
        if (data.isEmpty) return;
        _ingest(data);
      } catch (e) {
        events.add(SerialEvent('error', e.toString()));
        close(); // device likely unplugged
      }
    });

    events.add(SerialEvent('opened', {'config': cfg, 'byAgent': byAgent}));
    if (configWarning != null) events.add(SerialEvent('error', configWarning));
    return {'ok': true, if (configWarning != null) 'warning': configWarning};
  }

  /// Opens a TCP or UDP endpoint. TCP connects to host:port; UDP binds an
  /// ephemeral local socket and sends/receives with host:port as the peer.
  Future<Map<String, dynamic>> openNet(NetConfig cfg,
      {bool byAgent = false}) async {
    if (_openPaths.contains(cfg.label) && activeConfig?.label != cfg.label) {
      return {'ok': false, 'error': '${cfg.label} is already open in another tab'};
    }
    await close(silent: true);

    try {
      if (cfg.protocol == 'tcp') {
        final s = await Socket.connect(cfg.host, cfg.port,
            timeout: const Duration(seconds: 5));
        _tcp = s;
        _netSub = s.listen(
          (d) => _ingest(d),
          onError: (Object e) {
            events.add(SerialEvent('error', e.toString()));
            close();
          },
          onDone: () => close(),
          cancelOnError: true,
        );
      } else {
        final list = await InternetAddress.lookup(cfg.host);
        if (list.isEmpty) {
          return {'ok': false, 'error': 'Cannot resolve host ${cfg.host}'};
        }
        final addr = list.firstWhere(
            (a) => a.type == InternetAddressType.IPv4,
            orElse: () => list.first);
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _udp = s;
        _udpRemote = addr;
        _udpPort = cfg.port;
        _netSub = s.listen((event) {
          if (event == RawSocketEvent.read) {
            final dg = s.receive();
            if (dg != null) _ingest(dg.data);
          }
        });
      }
    } catch (e) {
      await close(silent: true);
      return {'ok': false, 'error': e.toString()};
    }

    activeConfig = cfg;
    _openPaths.add(cfg.label);
    rxTotal = 0;
    txTotal = 0;
    _rxAssembly = [];

    events.add(SerialEvent('opened', {'config': cfg, 'byAgent': byAgent}));
    return {'ok': true};
  }

  /// Feeds incoming bytes from any transport into the capture pipeline + UI.
  void _ingest(Uint8List data) {
    rxTotal += data.length;
    _captureRx(data);
    rxChunks.add(data);
  }

  Future<Map<String, dynamic>> close({bool silent = false}) async {
    _flushRxAssembly();
    final wasOpen = connected;

    _readTimer?.cancel();
    _readTimer = null;
    await _netSub?.cancel();
    _netSub = null;
    if (_port != null) {
      try {
        _port!.close();
      } catch (_) {}
      _port!.dispose();
      _port = null;
    }
    try {
      _tcp?.destroy();
    } catch (_) {}
    _tcp = null;
    _udp?.close();
    _udp = null;
    _udpRemote = null;

    if (activeConfig != null) _openPaths.remove(activeConfig!.label);
    activeConfig = null;

    if (wasOpen && !silent) events.add(SerialEvent('closed'));
    return {'ok': true, 'was_open': wasOpen};
  }

  Future<Map<String, dynamic>> write({
    required String data,
    bool hex = false,
    String lineEnding = '',
    bool byAgent = false,
  }) async {
    if (!connected) return {'ok': false, 'error': 'Port is not open'};

    Uint8List buf;
    if (hex) {
      final cleaned = data.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
      if (cleaned.isEmpty || cleaned.length.isOdd) {
        return {
          'ok': false,
          'error': 'Invalid hex string (need an even number of hex digits)'
        };
      }
      buf = Uint8List.fromList([
        for (var i = 0; i < cleaned.length; i += 2)
          int.parse(cleaned.substring(i, i + 2), radix: 16)
      ]);
    } else {
      buf = Uint8List.fromList(utf8.encode(data + lineEnding));
    }

    int written;
    try {
      if (_tcp != null) {
        _tcp!.add(buf);
        await _tcp!.flush();
        written = buf.length;
      } else if (_udp != null) {
        written = _udp!.send(buf, _udpRemote!, _udpPort);
      } else {
        written = _port!.write(buf);
      }
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    if (written != buf.length) {
      return {'ok': false, 'error': 'Short write ($written of ${buf.length} bytes)'};
    }

    txTotal += written;
    _recordEntry('tx', buf);
    if (byAgent) {
      events.add(
          SerialEvent('agentTx', {'data': data, 'hex': hex, 'bytes': written}));
    }
    return {'ok': true, 'bytes': written};
  }

  // ---------- capture buffer ----------

  void _recordEntry(String dir, Uint8List buffer) {
    captureSeq += 1;
    final hexPart = buffer.length > hexMaxBytes
        ? buffer.sublist(0, hexMaxBytes)
        : buffer;
    final hexStr = hexPart
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ') +
        (buffer.length > hexMaxBytes
            ? ' … (+${buffer.length - hexMaxBytes} bytes)'
            : '');
    captureBuffer.add(CaptureEntry(
      captureSeq,
      dir,
      DateTime.now().toUtc().toIso8601String(),
      utf8
          .decode(buffer, allowMalformed: true)
          .replaceFirst(RegExp(r'\r\n$|[\r\n]$'), ''),
      hexStr,
    ));
    if (captureBuffer.length > captureMaxEntries) {
      captureBuffer.removeRange(0, captureBuffer.length - captureMaxEntries);
    }
  }

  // RX line assembly: serial data arrives in arbitrary USB-sized fragments, so
  // chunks are glued together and recorded one complete line per entry. A
  // flush timer catches non-line-based protocols and trailing partial lines.

  void _flushRxAssembly() {
    _rxFlushTimer?.cancel();
    _rxFlushTimer = null;
    if (_rxAssembly.isNotEmpty) {
      _recordEntry('rx', Uint8List.fromList(_rxAssembly));
      _rxAssembly = [];
    }
  }

  int _indexOfCrlf(List<int> bytes) {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x0d && bytes[i + 1] == 0x0a) return i;
    }
    return -1;
  }

  void _captureRx(Uint8List data) {
    _rxAssembly.addAll(data);

    final mode = settings.rxLineEnding;
    while (true) {
      int idx;
      var len = 1;
      if (mode == 'cr') {
        idx = _rxAssembly.indexOf(0x0d);
      } else if (mode == 'crlf') {
        idx = _indexOfCrlf(_rxAssembly);
        len = 2;
      } else {
        // auto and lf: \n terminates a line (covers both LF and CRLF devices)
        idx = _rxAssembly.indexOf(0x0a);
      }
      if (idx == -1) break;
      _recordEntry('rx', Uint8List.fromList(_rxAssembly.sublist(0, idx + len)));
      _rxAssembly = _rxAssembly.sublist(idx + len);
    }

    if (_rxAssembly.length >= rxAssemblyMax) _flushRxAssembly();

    _rxFlushTimer?.cancel();
    _rxFlushTimer = _rxAssembly.isNotEmpty
        ? Timer(const Duration(milliseconds: rxFlushMs), _flushRxAssembly)
        : null;
  }

  /// Clears captured data and byte counters. Sequence numbers keep counting
  /// up so MCP clients polling with since_seq never see duplicates.
  void clearCapture() {
    captureBuffer.clear();
    rxTotal = 0;
    txTotal = 0;
  }

  // ---------- MCP-facing views ----------

  Map<String, dynamic> mcpStatus() => {
        'connected': connected,
        'kind': activeConfig?.kind,
        'port': activeConfig?.label,
        'settings': activeConfig?.toJson(),
        'rxBytes': rxTotal,
        'txBytes': txTotal,
        'buffer': {
          'entries': captureBuffer.length,
          'oldest_seq': captureBuffer.isEmpty ? null : captureBuffer.first.seq,
          'latest_seq': captureBuffer.isEmpty ? null : captureBuffer.last.seq,
        },
      };

  Map<String, dynamic> readData({
    int sinceSeq = 0,
    int maxEntries = 200,
    String direction = 'both',
    String? query,
    bool isRegex = false,
  }) {
    var entries = captureBuffer.where((e) => e.seq > sinceSeq);
    if (direction != 'both') {
      entries = entries.where((e) => e.dir == direction);
    }
    if (query != null && query.isNotEmpty) {
      if (isRegex) {
        final RegExp re;
        try {
          re = RegExp(query, caseSensitive: false);
        } on FormatException catch (e) {
          return {'error': 'Invalid regex: ${e.message}'};
        }
        entries = entries.where((e) => re.hasMatch(e.text));
      } else {
        final q = query.toLowerCase();
        entries = entries.where((e) => e.text.toLowerCase().contains(q));
      }
    }
    var list = entries.toList();
    final truncated = list.length > maxEntries;
    if (truncated) {
      // since_seq set: page forward (oldest first) so a client can walk the
      // entire buffer without gaps. No cursor: tail of the live stream.
      list = sinceSeq > 0
          ? list.sublist(0, maxEntries)
          : list.sublist(list.length - maxEntries);
    }

    return {
      'latest_seq': captureSeq,
      'truncated': truncated,
      if (captureBuffer.isNotEmpty &&
          sinceSeq > 0 &&
          sinceSeq < captureBuffer.first.seq - 1)
        'note': 'Some entries older than the buffer window were dropped',
      'entries': list.map((e) => e.toJson()).toList(),
    };
  }
}
