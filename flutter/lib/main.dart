import 'package:flutter/material.dart';

import 'home_page.dart' show kBg;
import 'mcp_server.dart';
import 'network_scanner.dart';
import 'root_page.dart';
import 'serial_service.dart';
import 'settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();
  final serial = SerialService(settings);
  final mcp = McpServer(serial);
  final scanner = NetworkScanner();
  if (settings.mcpEnabled) {
    await mcp.start(settings.mcpPort);
  }

  runApp(PortMonitorApp(
      settings: settings, serial: serial, mcp: mcp, scanner: scanner));
}

class PortMonitorApp extends StatelessWidget {
  final AppSettings settings;
  final SerialService serial;
  final McpServer mcp;
  final NetworkScanner scanner;

  const PortMonitorApp({
    super.key,
    required this.settings,
    required this.serial,
    required this.mcp,
    required this.scanner,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Port Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
      ),
      home: RootPage(
          settings: settings, serial: serial, mcp: mcp, scanner: scanner),
    );
  }
}
