# Serial Port Monitor (Flutter)

Flutter rewrite of the serial port monitor for macOS, Windows, and Linux. Native binaries, no bundled browser — a fraction of the Electron version's size and memory.

Feature parity with the Electron app:

- Port discovery with descriptions, full serial config (baud incl. custom, data bits, parity, stop bits, flow control)
- ASCII / HEX / Both views, timestamps, autoscroll, TX echo, RX/TX counters
- Selectable RX line ending (Auto / LF / CR / CRLF) applied to display and capture
- Send text with line ending or raw hex; Up/Down send history
- Save session log
- Embedded MCP server (Streamable HTTP on `127.0.0.1:8765/mcp`, configurable via the MCP ⚙ panel, persisted settings) with the same six tools: `list_ports`, `get_status`, `read_data`, `open_port`, `close_port`, `send_data`
- Capture buffer assembles RX bytes into lines (300 ms flush) so agents read whole lines

Differences from the Electron version: stop bits 1.5 is not offered (libserialport supports 1 or 2 only).

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

Serial access is via [flutter_libserialport](https://pub.dev/packages/flutter_libserialport) (FFI bindings to libserialport, bundled — nothing to install). The macOS sandbox entitlements already include `com.apple.security.device.serial` and network server access for the MCP endpoint.

## Architecture

- `lib/serial_service.dart` — owns the port, capture ring buffer, RX line assembly
- `lib/mcp_server.dart` — MCP Streamable HTTP server (pure Dart, `dart:io`)
- `lib/home_page.dart` — the UI
- `lib/settings_store.dart` — persisted settings (MCP enable/port, RX line ending)
