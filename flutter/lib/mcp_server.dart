import 'dart:convert';
import 'dart:io';

import 'serial_service.dart';

/// Embedded MCP server (Streamable HTTP, stateless JSON responses).
/// Binds to 127.0.0.1 only. The serial port stays owned by the app — agents
/// observe through the capture buffer and act through the same write path
/// the UI uses, so nothing they do can disrupt the data stream.
class McpServer {
  /// All open serial sessions (one per tab) and which is active. The UI keeps
  /// these in sync. Tools act on the session named by the `port` argument, or
  /// the active tab when `port` is omitted.
  List<SerialService> sessions = [];
  SerialService? active;
  McpServer([SerialService? initial]) {
    if (initial != null) {
      sessions = [initial];
      active = initial;
    }
  }

  /// Resolves the target session: by open-port path if `port` given, else the
  /// active tab. Returns null with an error map when it can't.
  ({SerialService? s, Map<String, dynamic>? err}) _target(
      Map<String, dynamic> args) {
    final port = args['port'] as String?;
    if (port != null && port.isNotEmpty) {
      for (final s in sessions) {
        if (s.activeConfig?.label == port) return (s: s, err: null);
      }
      return (
        s: null,
        err: _toolError(
            'No open port "$port". Call get_status to list open ports.')
      );
    }
    if (active == null) return (s: null, err: _toolError('No serial session.'));
    return (s: active, err: null);
  }

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

    // tools that target a specific session
    SerialService? target;
    if (name == 'get_status' ||
        name == 'read_data' ||
        name == 'close_port' ||
        name == 'send_data') {
      final r = _target(args);
      if (r.s == null) return r.err!;
      target = r.s;
    }

    dynamic out;
    switch (name) {
      case 'list_ports':
        out = (active ?? sessions.firstOrNull)?.listPorts().map((p) => p.toJson()).toList() ?? [];
      case 'get_status':
        out = {
          'active_port': active?.activeConfig?.label,
          'open_ports': [
            for (final s in sessions)
              if (s.connected) s.activeConfig!.label
          ],
          'sessions': [
            for (var i = 0; i < sessions.length; i++)
              {'tab': i + 1, ...sessions[i].mcpStatus()}
          ],
          ...target!.mcpStatus(),
        };
      case 'read_data':
        out = target!.readData(
          sinceSeq: (args['since_seq'] as num?)?.toInt() ?? 0,
          maxEntries: ((args['max_entries'] as num?)?.toInt() ?? 200)
              .clamp(1, 1000),
          direction: args['direction'] as String? ?? 'both',
          query: args['query'] as String?,
          isRegex: args['regex'] == true,
        );
      case 'open_port':
        final path = args['path'] as String?;
        if (path == null || path.isEmpty) {
          return _toolError('open_port requires a "path" argument');
        }
        if (sessions.any((s) => s.activeConfig?.label == path)) {
          return _toolError(
              'Port "$path" is already open in another tab. A port can only be opened once.');
        }
        if (active == null) return _toolError('No serial session.');
        final cfg = SerialConfig(
          path: path,
          baudRate: (args['baud_rate'] as num?)?.toInt() ?? 115200,
          dataBits: (args['data_bits'] as num?)?.toInt() ?? 8,
          parity: args['parity'] as String? ?? 'none',
          stopBits: (args['stop_bits'] as num?)?.toInt() ?? 1,
          flowControl: args['flow_control'] as String? ?? 'none',
        );
        final res = await active!.open(cfg, byAgent: true);
        out = res['ok'] == true
            ? {'ok': true, 'opened': cfg.toJson(), 'tab': sessions.indexOf(active!) + 1}
            : res;
      case 'open_socket':
        final proto = (args['protocol'] as String? ?? 'tcp').toLowerCase();
        if (proto != 'tcp' && proto != 'udp') {
          return _toolError('protocol must be "tcp" or "udp"');
        }
        final server = args['server'] == true;
        final host = args['host'] as String?;
        final sport = (args['port'] as num?)?.toInt();
        if (sport == null || (!server && (host == null || host.isEmpty))) {
          return _toolError(server
              ? 'open_socket server requires "port"'
              : 'open_socket requires "host" and "port"');
        }
        final ncfg = NetConfig(
            protocol: proto, host: host ?? '', port: sport, server: server);
        if (sessions.any((s) => s.activeConfig?.label == ncfg.label)) {
          return _toolError('${ncfg.label} is already open in another tab.');
        }
        if (active == null) return _toolError('No serial session.');
        final nres = await active!.openNet(ncfg, byAgent: true);
        out = nres['ok'] == true
            ? {
                'ok': true,
                'opened': ncfg.toJson(),
                'tab': sessions.indexOf(active!) + 1
              }
            : nres;
      case 'open_mqtt':
        final host = args['host'] as String?;
        if (host == null || host.isEmpty) {
          return _toolError('open_mqtt requires "host"');
        }
        final mcfg = MqttConfig(
          host: host,
          port: (args['port'] as num?)?.toInt() ?? 1883,
          subTopic: args['sub_topic'] as String? ?? '',
          pubTopic: args['pub_topic'] as String? ?? '',
          username: args['username'] as String? ?? '',
          password: args['password'] as String? ?? '',
        );
        if (sessions.any((s) => s.activeConfig?.label == mcfg.label)) {
          return _toolError('${mcfg.label} is already open in another tab.');
        }
        if (active == null) return _toolError('No serial session.');
        final mres = await active!.openMqtt(mcfg, byAgent: true);
        out = mres['ok'] == true
            ? {
                'ok': true,
                'opened': mcfg.toJson(),
                'tab': sessions.indexOf(active!) + 1
              }
            : mres;
      case 'close_port':
        out = await target!.close();
      case 'send_data':
        out = await target!.write(
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
          'Get the monitor state. The app can hold several ports open at once, one per tab. Returns the active tab\'s status plus "open_ports" (list of open port paths), "active_port", and a "sessions" array (one per tab with its port, settings, byte totals, and buffer range). Use the port paths here as the "port" argument to other tools.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'port': {
            'type': 'string',
            'description':
                'Report this open port\'s status as the top-level fields (default: active tab). Does not affect the sessions array.',
          },
        },
      },
    },
    {
      'name': 'read_data',
      'description':
          "Read captured serial traffic (RX and TX) from the monitor's buffer (holds the most recent 5000 entries, one per line). This is a passive read of already-captured data — it never touches the port or interferes with the stream. Without since_seq you get the newest entries. With since_seq you get the OLDEST entries after that cursor, so you can page through the entire buffer: start with since_seq = oldest_seq - 1 (from get_status) and repeat with the last seq received until entries is empty. For live tailing, poll with the latest_seq from the previous call.",
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
          'query': {
            'type': 'string',
            'description':
                'Search the buffer: only return entries whose text matches (case-insensitive substring, or regex when regex=true). Combines with direction and since_seq.',
          },
          'regex': {
            'type': 'boolean',
            'description': 'Treat query as a regular expression (default false)',
          },
          'port': {
            'type': 'string',
            'description':
                'Read from this open port (default: active tab). Use a path from get_status open_ports.',
          },
        },
      },
    },
    {
      'name': 'open_port',
      'description':
          'Open a serial port in the active tab. The app UI updates to show the connection. If that tab already has a port open it is closed first. Fails if the requested port is already open in another tab (a port can only be opened once).',
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
      'name': 'open_socket',
      'description':
          'Open a TCP or UDP network connection in the active tab. As a client (default) it connects to host:port. As a server (server=true) it listens on port: TCP accepts clients and broadcasts sends to all of them; UDP binds the port and replies to whoever last sent. Received bytes flow into the same capture buffer as serial data. Labels: client "<proto> <host>:<port>", server "<proto>-server :<port>" — use as the "port" argument to other tools.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'protocol': {
            'type': 'string',
            'enum': ['tcp', 'udp'],
            'description': 'Transport (default tcp)',
          },
          'server': {
            'type': 'boolean',
            'description':
                'Listen/accept instead of connect (default false = client)',
          },
          'host': {
            'type': 'string',
            'description':
                'Client: host/IP to connect to (required). Server: bind address (optional, default 0.0.0.0).',
          },
          'port': {
            'type': 'integer',
            'description': 'TCP/UDP port number',
          },
        },
        'required': ['port'],
      },
    },
    {
      'name': 'open_mqtt',
      'description':
          'Connect to an MQTT broker in the active tab. Subscribes to sub_topic (wildcards allowed); each received message is captured as a "topic  payload" line. send_data on this tab publishes its payload to pub_topic. Labelled "mqtt <host>:<port>" for the "port" targeting argument.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': 'Broker host or IP'},
          'port': {'type': 'integer', 'description': 'Broker port (default 1883)'},
          'sub_topic': {
            'type': 'string',
            'description': 'Topic/wildcard to subscribe to (optional)',
          },
          'pub_topic': {
            'type': 'string',
            'description': 'Topic that send_data publishes to (optional)',
          },
          'username': {'type': 'string', 'description': 'Broker username (optional)'},
          'password': {'type': 'string', 'description': 'Broker password (optional)'},
        },
        'required': ['host'],
      },
    },
    {
      'name': 'close_port',
      'description':
          'Close an open connection (serial, socket, or MQTT). The app UI updates to show the disconnection.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'port': {
            'type': 'string',
            'description':
                'Which open port to close (default: active tab). Use a path from get_status open_ports.',
          },
        },
      },
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
          'port': {
            'type': 'string',
            'description':
                'Send out this open port (default: active tab). Use a path from get_status open_ports.',
          },
        },
        'required': ['data'],
      },
    },
  ];
}
