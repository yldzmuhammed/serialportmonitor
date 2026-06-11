# Serial Port Monitor

A cross-platform serial port monitor for **macOS, Windows, and Linux**, built with Electron and [node-serialport](https://serialport.io/).

## Features

- Auto-discovery of serial ports with manufacturer names (refreshes every 3 s while disconnected)
- Full connection settings: baud rate (presets + custom), data bits, parity, stop bits, flow control (RTS/CTS, XON/XOFF)
- **ASCII / HEX / Both** view modes with millisecond timestamps
- Send text with selectable line ending (None / LF / CR / CRLF) or raw HEX bytes
- TX echo, send history (Up/Down arrows), RX/TX byte counters
- Autoscroll toggle, clear, and save session log to file
- Output capped at 5000 lines so long sessions stay responsive

## Run from source

```bash
npm install
npm start
```

## Build installers

```bash
npm run dist:mac     # .dmg + .zip
npm run dist:win     # NSIS installer + portable .exe
npm run dist:linux   # AppImage + .deb
```

Output goes to `dist/`. Each platform's installer is best built on that platform (macOS can build all three with wine for Windows targets).

## Platform notes

- **macOS**: USB serial adapters appear as `/dev/tty.usbserial-*` or `/dev/tty.usbmodem*`. Most CP210x/CH340/FTDI adapters work without drivers on recent macOS.
- **Linux**: add yourself to the serial group to access ports without sudo: `sudo usermod -a -G dialout $USER` (log out/in afterwards).
- **Windows**: ports appear as `COM3`, `COM4`, etc.

## Architecture

- `src/main.js` — Electron main process; owns the serial port, exposes it over IPC
- `src/preload.js` — context-isolated bridge (`window.serialAPI`)
- `src/renderer/` — UI (plain HTML/CSS/JS, no framework)

serialport ≥ 10 uses N-API prebuilds, so no native compilation or electron-rebuild step is needed on any of the three platforms.
