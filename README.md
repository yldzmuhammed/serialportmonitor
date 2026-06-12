# Serial Port Monitor

A cross-platform serial port monitor for **macOS, Windows, and Linux**, built with Flutter — with an embedded MCP server so AI agents can observe and use the serial port without disrupting it.

The app lives in [flutter/](flutter/) — see its [README](flutter/README.md) for features, build instructions, and architecture.

## Quick start

```bash
cd flutter
flutter run -d macos      # or windows / linux
flutter build macos       # release app bundle
```

## History

The original implementation was Electron + node-serialport, feature-equivalent to the Flutter app. It is preserved on the [`electron` branch](../../tree/electron) and tag `v1.0.0-electron`.
