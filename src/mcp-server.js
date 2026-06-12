const http = require('http');
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StreamableHTTPServerTransport } = require('@modelcontextprotocol/sdk/server/streamableHttp.js');
const { z } = require('zod');

function jsonResult(obj) {
  return { content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }] };
}

// api: { listPorts, getStatus, readData, sendData } provided by main.js
function buildServer(api) {
  const server = new McpServer({ name: 'serial-port-monitor', version: '1.0.0' });

  server.tool(
    'list_ports',
    'List serial ports available on this machine.',
    async () => jsonResult(await api.listPorts())
  );

  server.tool(
    'get_status',
    'Get the monitor state: whether a port is open, its settings, byte totals, and the capture buffer sequence range.',
    async () => jsonResult(api.getStatus())
  );

  server.tool(
    'read_data',
    'Read captured serial traffic (RX and TX) from the monitor\'s buffer. This is a passive read of already-captured data — it never touches the port or interferes with the stream. Poll incrementally by passing the latest_seq from the previous call as since_seq.',
    {
      since_seq: z.number().int().nonnegative().optional()
        .describe('Only return entries with seq greater than this value'),
      max_entries: z.number().int().min(1).max(1000).optional()
        .describe('Cap on returned entries, newest kept (default 200)'),
      direction: z.enum(['rx', 'tx', 'both']).optional()
        .describe('Filter by direction (default both)')
    },
    async (args) => jsonResult(api.readData(args || {}))
  );

  server.tool(
    'open_port',
    'Open a serial port in the monitor app. The app UI updates to show the connection. Any previously open port is closed first.',
    {
      path: z.string().describe('Port path, e.g. /dev/tty.usbmodem1234 or COM3'),
      baud_rate: z.number().int().positive().optional().describe('Baud rate (default 115200)'),
      data_bits: z.number().int().min(5).max(8).optional().describe('Data bits (default 8)'),
      parity: z.enum(['none', 'even', 'odd', 'mark', 'space']).optional().describe('Parity (default none)'),
      stop_bits: z.union([z.literal(1), z.literal(1.5), z.literal(2)]).optional().describe('Stop bits (default 1)'),
      flow_control: z.enum(['none', 'rtscts', 'xonxoff']).optional().describe('Flow control (default none)')
    },
    async (args) => jsonResult(await api.openPort(args))
  );

  server.tool(
    'close_port',
    'Close the currently open serial port. The app UI updates to show the disconnection.',
    async () => jsonResult(await api.closePort())
  );

  server.tool(
    'send_data',
    'Send data out the currently open serial port. The transmission is echoed in the app UI marked as agent traffic, and recorded in the capture buffer.',
    {
      data: z.string().describe('Text to send, or hex byte string when hex=true (e.g. "DE AD BE EF")'),
      hex: z.boolean().optional().describe('Treat data as hex bytes (default false)'),
      line_ending: z.enum(['none', 'lf', 'cr', 'crlf']).optional()
        .describe('Line ending appended to text sends (default none; ignored for hex)')
    },
    async (args) => jsonResult(await api.sendData(args))
  );

  return server;
}

// Stateless Streamable HTTP: a fresh server+transport pair per request, bound to 127.0.0.1 only.
function startMcpServer(api, port) {
  const httpServer = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname !== '/mcp') {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found. MCP endpoint is /mcp' }));
      return;
    }
    if (req.method !== 'POST') {
      res.writeHead(405, { 'Content-Type': 'application/json', Allow: 'POST' });
      res.end(JSON.stringify({
        jsonrpc: '2.0',
        error: { code: -32000, message: 'Method not allowed' },
        id: null
      }));
      return;
    }

    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', async () => {
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          jsonrpc: '2.0',
          error: { code: -32700, message: 'Parse error' },
          id: null
        }));
        return;
      }

      const server = buildServer(api);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on('close', () => {
        transport.close();
        server.close();
      });

      try {
        await server.connect(transport);
        await transport.handleRequest(req, res, parsed);
      } catch (err) {
        if (!res.headersSent) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            jsonrpc: '2.0',
            error: { code: -32603, message: `Internal error: ${err.message}` },
            id: null
          }));
        }
      }
    });
  });

  return new Promise((resolve) => {
    httpServer.once('error', (err) => resolve({ server: null, error: err.message }));
    httpServer.listen(port, '127.0.0.1', () => {
      resolve({ server: httpServer, url: `http://127.0.0.1:${port}/mcp` });
    });
  });
}

module.exports = { startMcpServer };
