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
 * Create an SDK MCP server and its authenticated hub client, without owning the daemon.
 * Returns {server, descriptor, close()}; close retires this client's native scope only.
 */
export async function createMcpServer({ home, extensionRoot: root = extensionRoot }) {
  const descriptor = await ensureBridge({ home, extensionRoot: root });
  const definitions = JSON.parse(await readFile(path.join(root, 'tools.json'), 'utf8'));
  const tools = definitions.map(({ name, description, inputSchema }) => ({ name, description, inputSchema,
    annotations: { readOnlyHint: name === 'read_sprite' || name === 'read_pixels',
      destructiveHint: name === 'execute_lua', openWorldHint: false } }));
  const names = new Set(tools.map(tool => tool.name));
  const pending = new Map();
  const socket = new WebSocket(descriptor.clientEndpoint, { maxPayload: maxBytes, handshakeTimeout: 3000,
    perMessageDeflate: false });
  socket.on('error', () => {});
  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  let closed = false;
  const server = new Server({ name: 'aseprite_chat', version: '1.0.0' }, {
    capabilities: { tools: {} },
    instructions: 'Control the live Aseprite editor. Open Aseprite MCP and connect before calling tools. '
      + 'Inspect the live sprite before editing; execute_lua requires its expectedRevision and native user approval. '
      + 'Each client has its own editing target and observations. A busy operation is never queued or replayed. '
      + 'Export paths refer to temporary native files; copy them with your own authorized file tools.',
  });
  function settle(id, result) {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    entry.signal.removeEventListener('abort', entry.abort);
    entry.resolve(result);
  }
  socket.on('message', data => {
    try {
      const message = JSON.parse(data.toString());
      if (message.type === 'result' && typeof message.id === 'string') settle(message.id, toolResult(message.result));
    } catch { socket.terminate(); }
  });
  socket.on('close', () => {
    for (const id of pending.keys()) settle(id, errorResult('MCP bridge disconnected; restart this MCP client'));
  });
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools }));
  server.setRequestHandler(CallToolRequestSchema, (request, { signal }) => {
    if (!names.has(request.params.name)) return errorResult('Unknown Aseprite tool');
    if (closed || socket.readyState !== WebSocket.OPEN) return errorResult('MCP bridge disconnected; restart this MCP client');
    if (signal.aborted) return errorResult('Operation cancelled');
    const id = randomUUID();
    const encoded = JSON.stringify({ type: 'call', id, tool: request.params.name, arguments: request.params.arguments ?? {} });
    if (Buffer.byteLength(encoded) > maxBytes) return errorResult('Tool call exceeds the 16 MiB message limit');
    return new Promise(resolve => {
      const abort = () => {
        if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'cancel', id }));
        settle(id, errorResult('Operation cancelled'));
      };
      pending.set(id, { resolve, signal, abort });
      signal.addEventListener('abort', abort, { once: true });
      socket.send(encoded, error => { if (error) settle(id, errorResult(error.message)); });
    });
  });
  const close = async () => {
    if (closed) return;
    closed = true;
    socket.terminate();
    for (const id of pending.keys()) settle(id, errorResult('MCP client closed'));
    await server.close();
  };
  server.onclose = () => { void close(); };
  return { server, descriptor, close };
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
