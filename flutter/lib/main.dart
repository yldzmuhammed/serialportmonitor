import 'package:flutter/material.dart';

import 'home_page.dart';
import 'mcp_server.dart';
import 'serial_service.dart';
import 'settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();
  final serial = SerialService(settings);
  final mcp = McpServer(serial);
  if (settings.mcpEnabled) {
    await mcp.start(settings.mcpPort);
  }

  runApp(SerialMonitorApp(settings: settings, serial: serial, mcp: mcp));
}

class SerialMonitorApp extends StatelessWidget {
  final AppSettings settings;
  final SerialService serial;
  final McpServer mcp;

  const SerialMonitorApp({
    super.key,
    required this.settings,
    required this.serial,
    required this.mcp,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Serial Port Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
      ),
      home: HomePage(serial: serial, mcp: mcp, settings: settings),
    );
  }
}
