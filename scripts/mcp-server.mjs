import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import WebSocket from 'ws';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { ensureBridge } from './mcp-bridge.mjs';

const extensionRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const maxBytes = 16 * 1024 * 1024;
const errorResult = text => ({ isError: true, content: [{ type: 'text', text }] });

function toolResult(result) {
  try {
    if (typeof result?.success !== 'boolean' || !Array.isArray(result.contentItems)) throw Error('Malformed native result');
    const content = result.contentItems.map(item => {
      if (item.type === 'inputText' && typeof item.text === 'string') return { type: 'text', text: item.text };
      if (item.type !== 'inputImage' || typeof item.imageUrl !== 'string') throw Error('Malformed native content item');
      const match = /^data:image\/png;base64,([A-Za-z0-9+/]+={0,2})$/.exec(item.imageUrl);
      if (!match || match[1].length % 4 !== 0) throw Error('Invalid native PNG data URL');
      const bytes = Buffer.from(match[1], 'base64');
      if (bytes.length < 8 || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
        || bytes.toString('base64') !== match[1]) throw Error('Invalid native PNG image');
      return { type: 'image', data: match[1], mimeType: 'image/png' };
    });
    return { isError: !result.success, content };
  } catch (error) { return errorResult(error.message); }
}

/**
 * Create a dormant SDK server. Catalog requests never create a hub or touch home.
 * The first valid tool call shares one startup; later calls may reconnect after
 * hub retirement. Dispatched operations are never replayed. close() invalidates
 * pending startup and retires only this client's native scope, not the daemon.
 * @param {{home:string, extensionRoot?:string}} options Absolute native paths.
 * @param {{ensureBridge?:Function}} dependencies Test seam for hub startup.
 * @returns {Promise<{server:Server, close:Function}>}
 */
export async function createMcpServer({ home, extensionRoot: root = extensionRoot }, dependencies = {}) {
  if (!path.isAbsolute(home) || !path.isAbsolute(root)) throw Error('home and extensionRoot must be absolute paths');
  const definitions = JSON.parse(await readFile(path.join(root, 'tools.json'), 'utf8'));
  const tools = definitions.map(({ name, description, inputSchema }) => ({ name, description, inputSchema,
    annotations: { readOnlyHint: ['list_sprites', 'view_sprite', 'inspect_sprite', 'read_pixels'].includes(name),
      destructiveHint: name === 'execute_lua', openWorldHint: false } }));
  const names = new Set(tools.map(tool => tool.name));
  const pending = new Map();
  let socket = null;
  let starting = null;
  let closed = false;
  const server = new Server({ name: 'aseprite_chat', version: '1.0.0' }, {
    capabilities: { tools: {} },
    instructions: 'Control the live Aseprite editor from any MCP client. Enable MCP once in Aseprite; it connects automatically when tools are used. '
      + 'Use list_sprites for discovery, view_sprite for rendered images, and inspect_sprite for requested structural sections. '
      + 'No open sprite is a normal state: listing returns empty; document operations report NO_OPEN_SPRITE. '
      + 'Inspect the live target before editing; execute_lua requires its expectedRevision and native user approval. '
      + 'Each client has its own editing target and observations. A busy operation is never queued or replayed. '
      + 'The hub sleeps after inactivity. A new call reconnects with a fresh scope; inspect again before editing. '
      + 'Export paths refer to temporary native files; copy them with your own authorized file tools.',
  });
  function settle(id, result) {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    entry.signal.removeEventListener('abort', entry.abort);
    entry.resolve(result);
  }
  function connect() {
    if (closed) return Promise.resolve(null);
    if (socket?.readyState === WebSocket.OPEN) return Promise.resolve(socket);
    if (starting) return starting;
    starting = (async () => {
      const descriptor = await (dependencies.ensureBridge ?? ensureBridge)({ home, extensionRoot: root });
      // Startup can outlive cancellation or stdio shutdown. Never attach a late
      // client once every interested request has retired.
      if (closed || pending.size === 0) return null;
      const current = new WebSocket(descriptor.clientEndpoint, { maxPayload: maxBytes, handshakeTimeout: 3000,
        perMessageDeflate: false });
      socket = current;
      current.on('error', () => {});
      current.on('message', data => {
        try {
          const message = JSON.parse(data.toString());
          if (message.type === 'result' && typeof message.id === 'string'
            && pending.get(message.id)?.socket === current) settle(message.id, toolResult(message.result));
        } catch { current.terminate(); }
      });
      current.on('close', () => {
        if (socket === current) socket = null;
        for (const [id, entry] of pending) if (entry.socket === current) {
          settle(id, errorResult('MCP bridge disconnected; operation was not replayed. Inspect again on the next call.'));
        }
      });
      try {
        await new Promise((resolve, reject) => {
          const opened = () => { cleanup(); resolve(); };
          const failed = error => { cleanup(); reject(error); };
          const ended = () => failed(Error('MCP bridge closed during connection'));
          const cleanup = () => {
            current.off('open', opened); current.off('error', failed); current.off('close', ended);
          };
          current.once('open', opened); current.once('error', failed); current.once('close', ended);
        });
      } catch (error) { current.terminate(); throw error; }
      if (closed || pending.size === 0) { current.terminate(); return null; }
      return current;
    })().finally(() => { starting = null; });
    return starting;
  }
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools }));
  server.setRequestHandler(CallToolRequestSchema, (request, { signal }) => {
    if (!names.has(request.params.name)) return errorResult('Unknown Aseprite tool');
    if (closed) return errorResult('MCP client closed');
    if (signal.aborted) return errorResult('Operation cancelled');
    const id = randomUUID();
    const encoded = JSON.stringify({ type: 'call', id, tool: request.params.name, arguments: request.params.arguments ?? {} });
    if (Buffer.byteLength(encoded) > maxBytes) return errorResult('Tool call exceeds the 16 MiB message limit');
    return new Promise(resolve => {
      const entry = { resolve, signal, socket: null, abort: () => {
        if (entry.socket?.readyState === WebSocket.OPEN) entry.socket.send(JSON.stringify({ type: 'cancel', id }));
        settle(id, errorResult('Operation cancelled'));
      } };
      pending.set(id, entry);
      signal.addEventListener('abort', entry.abort, { once: true });
      connect().then(current => {
        if (!pending.has(id)) return;
        if (closed || !current || current.readyState !== WebSocket.OPEN) {
          settle(id, errorResult('MCP bridge unavailable; retry the operation.')); return;
        }
        entry.socket = current;
        current.send(encoded, error => { if (error) settle(id, errorResult(error.message)); });
      }).catch(error => settle(id, errorResult(error.message)));
    });
  });
  const close = async () => {
    if (closed) return;
    closed = true;
    socket?.terminate();
    socket = null;
    for (const id of pending.keys()) settle(id, errorResult('MCP client closed'));
    await server.close();
  };
  server.onclose = () => { void close(); };
  return { server, close };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--home' || !path.isAbsolute(args[1])) {
    console.error('Usage: node mcp-server.mjs --home ABS_HOME');
    process.exitCode = 1;
  } else {
    try {
      const owned = await createMcpServer({ home: args[1] });
      const close = () => { owned.close().catch(error => { console.error(error.message); process.exitCode = 1; }); };
      process.stdin.once('end', close);
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, close);
      owned.server.onerror = error => console.error(error.message);
      await owned.server.connect(new StdioServerTransport(process.stdin, process.stdout, { maxBufferSize: maxBytes }));
    } catch (error) { console.error(error.message); process.exitCode = 1; }
  }
}
