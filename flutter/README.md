# Port Monitor (Flutter)

Flutter app for macOS, Windows, and Linux: a serial port monitor plus a local-network IP scanner. Native binaries, no bundled browser — a fraction of the Electron version's size and memory.

## IP Scanner

The **Network** tab discovers devices on your local /24 subnet. It ping-sweeps the subnet to populate the ARP cache, reads the ARP table for IP↔MAC pairs, resolves manufacturer from the bundled IEEE OUI database (`assets/oui.csv`), and names hosts via reverse mDNS/Bonjour with a reverse-DNS fallback. The local machine is listed with its own MAC and hostname. Live table shows online/offline dot, name, IP, MAC, manufacturer, and last-seen time, with a filter box and periodic rescan. Passive — only ordinary ICMP/ARP/mDNS traffic.

Cross-platform: ping/ARP use the right tool per OS — macOS `ping`/`arp`, Linux `ping`/`ip neigh` (falls back to `arp`), Windows `ping`/`arp`; self MAC via `ifconfig`/`ip link`/`getmac`.

## Serial Monitor

Feature parity with the Electron app:

- Port discovery with descriptions, full serial config (baud incl. custom, data bits, parity, stop bits, flow control)
- ASCII / HEX / Both views, timestamps, autoscroll, TX echo, RX/TX counters
- Selectable RX line ending (Auto / LF / CR / CRLF) applied to display and capture
- Send text with line ending or raw hex; Up/Down send history
- Save session log
- **History viewer** — browse the full capture buffer (independent of the display) with text filter, RX/TX filter, export, and buffer reset; Clear only wipes the screen
- Embedded MCP server (Streamable HTTP on `127.0.0.1:8765/mcp`, configurable via the MCP ⚙ panel, persisted settings) with the same six tools: `list_ports`, `get_status`, `read_data`, `open_port`, `close_port`, `send_data`
- Capture buffer assembles RX bytes into lines (300 ms flush) so agents read whole lines

Differences from the Electron version: stop bits 1.5 is not offered, and pseudo-terminals (virtual ports created by `socat`/`pty`) cannot be opened — libserialport requires real serial device semantics. Real USB serial devices are unaffected.

## Build & run

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install) with desktop support, plus per-platform toolchains:

- **macOS**: full Xcode (not just Command Line Tools) and CocoaPods (`brew install cocoapods`)
- **Windows**: Visual Studio with "Desktop development with C++"
- **Linux**: `clang cmake ninja-build pkg-config libgtk-3-dev`

```bash
cd flutter
flutter run -d macos      # or windows / linux
flutter build macos       # release app bundle
flutter build windows
flutter build linux
```

Serial access is via [flutter_libserialport](https://pub.dev/packages/flutter_libserialport) (FFI bindings to libserialport, bundled — nothing to install). The macOS App Sandbox is disabled in the entitlements; re-enable it in `macos/Runner/*.entitlements` if you ever need to distribute through the App Store (USB serial still works sandboxed via the `device.serial` entitlement).

## Architecture

- `lib/serial_service.dart` — owns the port, capture ring buffer, RX line assembly
- `lib/mcp_server.dart` — MCP Streamable HTTP server (pure Dart, `dart:io`)
- `lib/home_page.dart` — the UI
- `lib/settings_store.dart` — persisted settings (MCP enable/port, RX line ending)
