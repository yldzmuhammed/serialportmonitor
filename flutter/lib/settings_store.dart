import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  bool mcpEnabled;
  int mcpPort;
  String rxLineEnding; // auto | lf | cr | crlf

  AppSettings({
    required this.mcpEnabled,
    required this.mcpPort,
    required this.rxLineEnding,
  });

  static int get defaultMcpPort =>
      int.tryParse(Platform.environment['SERIAL_MCP_PORT'] ?? '') ?? 8765;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/settings.json');
  }

  static Future<AppSettings> load() async {
    try {
      final raw = await (await _file()).readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return AppSettings(
        mcpEnabled: data['mcpEnabled'] as bool? ?? true,
        mcpPort: data['mcpPort'] as int? ?? defaultMcpPort,
        rxLineEnding: data['rxLineEnding'] as String? ?? 'auto',
      );
    } catch (_) {
      return AppSettings(
        mcpEnabled: true,
        mcpPort: defaultMcpPort,
        rxLineEnding: 'auto',
      );
    }
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'mcpEnabled': mcpEnabled,
        'mcpPort': mcpPort,
        'rxLineEnding': rxLineEnding,
      }));
    } catch (_) {
      // non-fatal: settings just won't persist
    }
  }
}
