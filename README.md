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
- **Built-in MCP server** so AI agents can observe and use the port without disrupting it

## Run from source

```bash
npm install
npm start
```

For development, `npm run dev` runs the app with hot reload (via electronmon): UI file changes reload the window in place — the serial connection survives and the UI re-syncs to it — and main-process changes restart the app.

## Build installers

```bash
npm run dist:mac     # .dmg + .zip
npm run dist:win     # NSIS installer + portable .exe
npm run dist:linux   # AppImage + .deb
```

Output goes to `dist/`. Each platform's installer is best built on that platform (macOS can build all three with wine for Windows targets).

## MCP server (AI agent access)

While the app is running it serves MCP (Streamable HTTP) on `http://127.0.0.1:8765/mcp`. The app keeps exclusive ownership of the serial port — agents read from a capture buffer in the main process, so observing traffic can never disturb the connection or drop data.

Click **MCP ⚙** in the app to open the server config: enable/disable the server, change its port (persisted across restarts), and copy the Claude Code connect command. The current address is always shown in the status bar.

Connect Claude Code to it:

```bash
claude mcp add --transport http serial-monitor http://127.0.0.1:8765/mcp
```

Tools exposed:

| Tool | What it does |
|---|---|
| `list_ports` | Enumerate serial ports on the machine |
| `get_status` | Connection state, settings, RX/TX totals, buffer seq range |
| `read_data` | Passive read of captured RX/TX entries; poll incrementally with `since_seq` |
| `open_port` | Open a port (baud, framing, flow control); the UI syncs to show the connection |
| `close_port` | Close the current port |
| `send_data` | Transmit text or hex through the open port (echoed in the UI as purple `AI>` lines) |

Incoming bytes are assembled into complete lines before being recorded (a 300 ms flush timer catches partial lines and non-line-based protocols), so each `read_data` entry is one line of device output with timestamp, text, and hex forms. The buffer holds the most recent 5000 entries. The server binds to localhost only.

## Platform notes

- **macOS**: USB serial adapters appear as `/dev/tty.usbserial-*` or `/dev/tty.usbmodem*`. Most CP210x/CH340/FTDI adapters work without drivers on recent macOS.
- **Linux**: add yourself to the serial group to access ports without sudo: `sudo usermod -a -G dialout $USER` (log out/in afterwards).
- **Windows**: ports appear as `COM3`, `COM4`, etc.

## Architecture

- `src/main.js` — Electron main process; owns the serial port, exposes it over IPC
- `src/preload.js` — context-isolated bridge (`window.serialAPI`)
- `src/renderer/` — UI (plain HTML/CSS/JS, no framework)

serialport ≥ 10 uses N-API prebuilds, so no native compilation or electron-rebuild step is needed on any of the three platforms.
