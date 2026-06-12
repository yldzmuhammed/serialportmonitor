import 'dart:convert';
import 'dart:io';

import 'serial_service.dart';

/// Embedded MCP server (Streamable HTTP, stateless JSON responses).
/// Binds to 127.0.0.1 only. The serial port stays owned by the app — agents
/// observe through the capture buffer and act through the same write path
/// the UI uses, so nothing they do can disrupt the data stream.
class McpServer {
  final SerialService serial;
  McpServer(this.serial);

  HttpServer? _http;
  String? url;
  String? error;

  bool get running => _http != null;

  Future<bool> start(int port) async {
    await stop();
    try {
      _http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      error = e.toString();
      url = null;
      return false;
    }
    error = null;
    url = 'http://127.0.0.1:$port/mcp';
    _http!.listen(_handle);
    return true;
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    url = null;
  }

  Map<String, dynamic> _rpcError(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  Future<void> _respond(
      HttpRequest req, int status, Map<String, dynamic> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path != '/mcp') {
        await _respond(req, 404, {'error': 'Not found. MCP endpoint is /mcp'});
        return;
      }
      if (req.method != 'POST') {
        req.response.headers.set('Allow', 'POST');
        await _respond(req, 405, _rpcError(null, -32000, 'Method not allowed'));
        return;
      }

      final body = await utf8.decoder.bind(req).join();
      dynamic msg;
      try {
        msg = jsonDecode(body);
      } catch (_) {
        await _respond(req, 400, _rpcError(null, -32700, 'Parse error'));
        return;
      }
      if (msg is! Map<String, dynamic>) {
        await _respond(req, 400, _rpcError(null, -32600, 'Invalid request'));
        return;
      }

      final method = msg['method'] as String?;
      final id = msg['id'];

      // Notifications (no id) get acknowledged without a body.
      if (id == null) {
        req.response.statusCode = 202;
        await req.response.close();
        return;
      }

      Map<String, dynamic> result;
      switch (method) {
        case 'initialize':
          final params = msg['params'] as Map<String, dynamic>? ?? {};
          result = {
            'protocolVersion':
                params['protocolVersion'] as String? ?? '2025-03-26',
            'capabilities': {'tools': <String, dynamic>{}},
            'serverInfo': {
              'name': 'serial-port-monitor',
              'version': '1.0.0',
            },
          };
        case 'ping':
          result = {};
        case 'tools/list':
          result = {'tools': _toolDefs};
        case 'tools/call':
          result =
              await _callTool(msg['params'] as Map<String, dynamic>? ?? {});
        default:
          await _respond(
              req, 200, _rpcError(id, -32601, 'Method not found: $method'));
          return;
      }
      await _respond(req, 200, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } catch (e) {
      try {
        await _respond(req, 500, _rpcError(null, -32603, 'Internal error: $e'));
      } catch (_) {
        // response already closed
      }
    }
  }

  static const _lineEndings = {
    'none': '',
    'lf': '\n',
    'cr': '\r',
    'crlf': '\r\n'
  };

  Future<Map<String, dynamic>> _callTool(Map<String, dynamic> params) async {
    final name = params['name'] as String?;
    final args = params['arguments'] as Map<String, dynamic>? ?? {};

    dynamic out;
    switch (name) {
      case 'list_ports':
        out = serial.listPorts().map((p) => p.toJson()).toList();
      case 'get_status':
        out = serial.mcpStatus();
      case 'read_data':
        out = serial.readData(
          sinceSeq: (args['since_seq'] as num?)?.toInt() ?? 0,
          maxEntries: ((args['max_entries'] as num?)?.toInt() ?? 200)
              .clamp(1, 1000),
          direction: args['direction'] as String? ?? 'both',
        );
      case 'open_port':
        final path = args['path'] as String?;
        if (path == null || path.isEmpty) {
          return _toolError('open_port requires a "path" argument');
        }
        final cfg = SerialConfig(
          path: path,
          baudRate: (args['baud_rate'] as num?)?.toInt() ?? 115200,
          dataBits: (args['data_bits'] as num?)?.toInt() ?? 8,
          parity: args['parity'] as String? ?? 'none',
          stopBits: (args['stop_bits'] as num?)?.toInt() ?? 1,
          flowControl: args['flow_control'] as String? ?? 'none',
        );
        final res = await serial.open(cfg, byAgent: true);
        out = res['ok'] == true ? {'ok': true, 'opened': cfg.toJson()} : res;
      case 'close_port':
        out = await serial.close();
      case 'send_data':
        out = await serial.write(
          data: args['data'] as String? ?? '',
          hex: args['hex'] == true,
          lineEnding:
              _lineEndings[args['line_ending'] as String? ?? 'none'] ?? '',
          byAgent: true,
        );
      default:
        return _toolError('Unknown tool: $name');
    }

    return {
      'content': [
        {
          'type': 'text',
          'text': const JsonEncoder.withIndent('  ').convert(out),
        }
      ],
    };
  }

  Map<String, dynamic> _toolError(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isError': true,
      };

  static final _toolDefs = [
    {
      'name': 'list_ports',
      'description': 'List serial ports available on this machine.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'get_status',
      'description':
          'Get the monitor state: whether a port is open, its settings, byte totals, and the capture buffer sequence range.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'read_data',
      'description':
          "Read captured serial traffic (RX and TX) from the monitor's buffer. This is a passive read of already-captured data — it never touches the port or interferes with the stream. Incoming bytes are assembled into one entry per line. Poll incrementally by passing the latest_seq from the previous call as since_seq.",
      'inputSchema': {
        'type': 'object',
        'properties': {
          'since_seq': {
            'type': 'integer',
            'description': 'Only return entries with seq greater than this',
          },
          'max_entries': {
            'type': 'integer',
            'description': 'Cap on returned entries, newest kept (default 200)',
          },
          'direction': {
            'type': 'string',
            'enum': ['rx', 'tx', 'both'],
            'description': 'Filter by direction (default both)',
          },
        },
      },
    },
    {
      'name': 'open_port',
      'description':
          'Open a serial port in the monitor app. The app UI updates to show the connection. Any previously open port is closed first.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Port path, e.g. /dev/tty.usbmodem1234 or COM3',
          },
          'baud_rate': {
            'type': 'integer',
            'description': 'Baud rate (default 115200)',
          },
          'data_bits': {
            'type': 'integer',
            'description': 'Data bits 5-8 (default 8)',
          },
          'parity': {
            'type': 'string',
            'enum': ['none', 'even', 'odd', 'mark', 'space'],
            'description': 'Parity (default none)',
          },
          'stop_bits': {
            'type': 'integer',
            'enum': [1, 2],
            'description': 'Stop bits (default 1)',
          },
          'flow_control': {
            'type': 'string',
            'enum': ['none', 'rtscts', 'xonxoff'],
            'description': 'Flow control (default none)',
          },
        },
        'required': ['path'],
      },
    },
    {
      'name': 'close_port',
      'description':
          'Close the currently open serial port. The app UI updates to show the disconnection.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'send_data',
      'description':
          'Send data out the currently open serial port. The transmission is echoed in the app UI marked as agent traffic, and recorded in the capture buffer.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'string',
            'description':
                'Text to send, or hex byte string when hex=true (e.g. "DE AD BE EF")',
          },
          'hex': {
            'type': 'boolean',
            'description': 'Treat data as hex bytes (default false)',
          },
          'line_ending': {
            'type': 'string',
            'enum': ['none', 'lf', 'cr', 'crlf'],
            'description':
                'Line ending appended to text sends (default none; ignored for hex)',
          },
        },
        'required': ['data'],
      },
    },
  ];
}
