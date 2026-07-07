import 'package:flutter/material.dart';

import 'home_page.dart' show kBg, kPanel, kBorder, kText, kTextDim, kAccent;
import 'mcp_server.dart';
import 'network_page.dart';
import 'network_scanner.dart';
import 'serial_service.dart';
import 'serial_tabs_page.dart';
import 'settings_store.dart';

/// Top-level shell: switches between the Serial Monitor and the IP Scanner.
/// Both pages stay alive (IndexedStack) so the serial connection and the
/// scan loop keep running while you look at the other tab.
class RootPage extends StatefulWidget {
  final AppSettings settings;
  final SerialService serial;
  final McpServer mcp;
  final NetworkScanner scanner;

  const RootPage({
    super.key,
    required this.settings,
    required this.serial,
    required this.mcp,
    required this.scanner,
  });

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Row(children: [
        _nav(),
        Expanded(
          child: IndexedStack(
            index: index,
            children: [
              SerialTabsPage(
                  settings: widget.settings,
                  mcp: widget.mcp,
                  boot: widget.serial),
              NetworkPage(scanner: widget.scanner),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _nav() {
    return Container(
      width: 64,
      decoration: const BoxDecoration(
        color: kPanel,
        border: Border(right: BorderSide(color: kBorder)),
      ),
      child: Column(children: [
        const SizedBox(height: 12),
        _tab(0, Icons.cable, 'Connections'),
        _tab(1, Icons.lan, 'Network'),
      ]),
    );
  }

  Widget _tab(int i, IconData icon, String label) {
    final active = index == i;
    return InkWell(
      onTap: () => setState(() => index = i),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
                color: active ? kAccent : Colors.transparent, width: 3),
          ),
        ),
        child: Column(children: [
          Icon(icon, size: 22, color: active ? kAccent : kTextDim),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: active ? kText : kTextDim, fontSize: 10)),
        ]),
      ),
    );
  }
}
