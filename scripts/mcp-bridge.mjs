import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, unlink, realpath, link, open } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import WebSocket, { WebSocketServer } from 'ws';

const protocol = 'aseprite-chat-mcp/2';
const maxBytes = 16 * 1024 * 1024;
const offline = 'Enable Aseprite MCP for this home and keep the editor running';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const failure = text => ({ success: false, contentItems: [{ type: 'inputText', text }] });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const validId = id => typeof id === 'string' && id.length > 0 && id.length <= 256;

async function locations(home, extensionRoot) {
  if (!path.isAbsolute(home) || !path.isAbsolute(extensionRoot)) throw Error('home and extensionRoot must be absolute paths');
  await mkdir(home, { recursive: true });
  const [canonicalHome, root] = await Promise.all([realpath(home), realpath(extensionRoot)]);
  const directory = path.join(canonicalHome, '.aseprite-chat');
  await mkdir(directory, { recursive: true });
  return { home: canonicalHome, extensionRoot: root, directory,
    descriptorPath: path.join(directory, 'mcp-bridge.json'), lockPath: path.join(directory, 'mcp-bridge.lock') };
}

async function readJson(file) {
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function ownerDead(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return false; }
  catch (error) { return error.code === 'ESRCH'; }
}

async function removeOwned(file, identity) {
  const current = await readJson(file);
  if (current?.identity === identity) await unlink(file).catch(error => { if (error.code !== 'ENOENT') throw error; });
}

function endpointValid(d) {
  if (!object(d) || d.protocol !== protocol || !validId(d.identity)
    || !/^[a-f0-9]{64}$/.test(d.token) || !Number.isSafeInteger(d.pid) || d.pid <= 0) return false;
  try {
    const editor = new URL(d.endpoint);
    const client = new URL(d.clientEndpoint);
    return editor.protocol === 'ws:' && editor.hostname === '127.0.0.1' && editor.port !== ''
      && editor.username === '' && editor.password === '' && editor.search === '' && editor.hash === ''
      && editor.pathname === `/editor/${d.token}` && client.origin === editor.origin
      && client.username === '' && client.password === '' && client.search === '' && client.hash === ''
      && client.pathname === `/client/${d.token}`;
  } catch { return false; }
}

async function healthy(d) {
  if (!endpointValid(d)) return false;
  const url = new URL(d.endpoint);
  return new Promise(resolve => {
    const timer = setTimeout(() => { req.destroy(); finish(false); }, 600);
    const finish = value => { clearTimeout(timer); resolve(value); };
    const req = http.get({ hostname: '127.0.0.1', port: url.port, path: `/health/${d.token}`,
      agent: false }, res => {
      let body = '';
      res.on('data', data => { body += data; if (body.length > 16384) req.destroy(); });
      res.on('error', () => finish(false));
      res.on('end', () => {
        try {
          const actual = JSON.parse(body);
          finish(res.statusCode === 200 && ['protocol', 'identity', 'pid', 'home', 'extensionRoot', 'token', 'endpoint', 'clientEndpoint']
            .every(key => actual[key] === d[key]));
        } catch { finish(false); }
      });
    });
    req.on('error', () => finish(false));
  });
}

/**
 * Ensure one authenticated daemon for an absolute home and installed extension root.
 * The persisted capability descriptor includes editor endpoint and clientEndpoint.
 * A live daemon from another root/protocol is never replaced or terminated.
 */
export async function ensureBridge({ home, extensionRoot }) {
  const loc = await locations(home, extensionRoot);
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const existing = await readJson(loc.descriptorPath);
    if (existing) {
      if (await healthy(existing)) {
        if (existing.extensionRoot !== loc.extensionRoot || existing.home !== loc.home) throw Error('MCP bridge root/home identity mismatch');
        return existing;
      }
      if (!ownerDead(existing.pid)) throw Error('MCP bridge root/protocol identity is stale or unavailable; its owner is still alive');
    }
    const identity = randomUUID();
    let lock;
    try { lock = await open(loc.lockPath, 'wx', 0o600); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let held;
      try { held = await readJson(loc.lockPath); } catch (error) { if (!(error instanceof SyntaxError)) throw error; }
      if (held && ownerDead(held.pid)) await removeOwned(loc.lockPath, held.identity);
      await delay(40);
      continue;
    }
    let child;
    try {
      await lock.writeFile(JSON.stringify({ pid: process.pid, identity }));
      await lock.close();
      // Recheck after winning the lock: another starter may just have published.
      const current = await readJson(loc.descriptorPath);
      if (current && await healthy(current)) {
        if (current.extensionRoot !== loc.extensionRoot || current.home !== loc.home) throw Error('MCP bridge root/home identity mismatch');
        return current;
      }
      if (current) {
        if (!ownerDead(current.pid)) throw Error('MCP bridge owner is alive but failed identity/authentication checks');
        await removeOwned(loc.descriptorPath, current.identity);
      }
      let spawnError;
      child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--daemon', '--home', loc.home,
        '--root', loc.extensionRoot], { detached: true, windowsHide: true, stdio: 'ignore' });
      child.on('error', error => { spawnError = error; });
      child.unref();
      while (Date.now() < deadline) {
        if (spawnError) throw spawnError;
        const descriptor = await readJson(loc.descriptorPath);
        if (descriptor && await healthy(descriptor)) {
          if (descriptor.home !== loc.home || descriptor.extensionRoot !== loc.extensionRoot) throw Error('MCP bridge root/home identity mismatch');
          return descriptor;
        }
        if (child.exitCode !== null) throw Error('MCP bridge daemon exited before readiness');
        await delay(40);
      }
      throw Error('MCP bridge daemon readiness timed out');
    } finally {
      await lock.close().catch(() => {});
      await removeOwned(loc.lockPath, identity);
    }
  }
  throw Error('MCP bridge startup lock timed out; no live owner was removed');
}

function validResult(result) {
  return object(result) && typeof result.success === 'boolean' && Array.isArray(result.contentItems)
    && result.contentItems.every(item => object(item)
      && ((item.type === 'inputText' && typeof item.text === 'string')
        || (item.type === 'inputImage' && typeof item.imageUrl === 'string')));
}

/**
 * Start an owned loopback hub. Returns {descriptor, descriptorPath, close()}.
 * Timeouts default to 5s for editor attachment, 90s per active operation, and
 * 120s without operations. Connected peers do not prevent idle retirement.
 * A matching result acknowledges cancellation; no new native work starts earlier.
 */
export async function createMcpBridge({ home, extensionRoot, activeTimeoutMs = 90000, idleTimeoutMs = 120000, editorTimeoutMs = 5000 }) {
  if (!(activeTimeoutMs > 0) || !(idleTimeoutMs > 0) || !(editorTimeoutMs > 0)) throw Error('Timeouts must be positive');
  const loc = await locations(home, extensionRoot);
  const tools = new Set(JSON.parse(await readFile(path.join(loc.extensionRoot, 'tools.json'), 'utf8')).map(tool => tool.name));
  const descriptor = { protocol, identity: randomUUID(), pid: process.pid, home: loc.home,
    extensionRoot: loc.extensionRoot, token: randomBytes(32).toString('hex') };
  let editor = null;
  let active = null;
  let idleTimer;
  let closed = false;
  let closing;
  const peers = new WebSocketServer({ noServer: true, maxPayload: maxBytes, perMessageDeflate: false });
  const send = (ws, value) => {
    if (ws?.readyState !== WebSocket.OPEN) return;
    const encoded = JSON.stringify(value);
    if (Buffer.byteLength(encoded) > maxBytes) { ws.terminate(); return; }
    ws.send(encoded, error => { if (error) ws.terminate(); });
  };
  const reply = (ws, id, result) => send(ws, { type: 'result', id: validId(id) ? id : null, result });
  const finish = result => {
    if (!active) return;
    clearTimeout(active.timer);
    if (!active.cancelled) reply(active.client, active.requestId, result);
    active = null;
    idle();
  };
  const cancel = () => {
    if (!active || active.cancelled) return;
    active.cancelled = true;
    reply(active.client, active.requestId, failure('Operation cancelled'));
    if (active.dispatched) send(editor, { type: 'cancel', id: active.id });
    else finish(failure('Operation cancelled'));
  };
  const idle = () => {
    clearTimeout(idleTimer);
    if (!closed && !active) idleTimer = setTimeout(() => {
      close().catch(error => console.error(error.message));
    }, idleTimeoutMs);
  };
  const dispatch = () => {
    if (!active || active.dispatched || !editor) return;
    clearTimeout(active.timer);
    active.dispatched = true;
    active.timer = setTimeout(() => {
      const staleEditor = editor;
      editor = null;
      finish(failure('Aseprite operation timed out; reconnect the editor'));
      staleEditor?.terminate();
    }, activeTimeoutMs);
    send(editor, { type: 'call', id: active.id, clientId: active.clientId, tool: active.tool, arguments: active.arguments });
  };
  function nativeRequest(req, role) {
    if (req.headers.host !== `127.0.0.1:${server.address()?.port}`) return false;
    if (Object.keys(req.headers).some(name => name.startsWith('sec-fetch-'))) return false;
    if (req.headers.origin !== undefined) {
      if (role !== 'editor') return false;
      if (![descriptor.endpoint, new URL(descriptor.endpoint).origin].includes(req.headers.origin)) return false;
    }
    return req.socket.remoteAddress === '127.0.0.1';
  }
  const server = http.createServer((req, res) => {
    if (!nativeRequest(req, 'health') || req.method !== 'GET' || req.url !== `/health/${descriptor.token}`) {
      res.writeHead(403).end(); return;
    }
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(descriptor));
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.on('upgrade', (req, socket, head) => {
    const role = req.url === `/editor/${descriptor.token}` ? 'editor'
      : req.url === `/client/${descriptor.token}` ? 'client' : null;
    if (closed || !role || !nativeRequest(req, role) || (role === 'editor' && editor)) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
    }
    peers.handleUpgrade(req, socket, head, ws => {
      const clientId = role === 'client' ? randomUUID() : null;
      if (role === 'editor') { editor = ws; dispatch(); }
      ws.on('error', () => {});
      ws.on('message', (data, binary) => {
        let message;
        try { if (binary) throw Error('Binary messages unsupported'); message = JSON.parse(data.toString()); }
        catch { ws.close(1008, 'Invalid JSON message'); return; }
        if (!object(message)) { ws.close(1008, 'Invalid message'); return; }
        if (role === 'editor') {
          if (editor !== ws || !active?.dispatched || message.type !== 'result' || message.id !== active?.id) return;
          finish(validResult(message.result) ? message.result : failure('Malformed native tool result'));
          return;
        }
        if (message.type === 'cancel') {
          if (active?.client === ws && active.requestId === message.id) cancel();
          return;
        }
        if (message.type !== 'call') return;
        if (active?.client === ws && active.requestId === message.id) {
          ws.close(1008, 'Duplicate active request ID'); return;
        }
        if (!validId(message.id) || Object.keys(message).some(key => !['type', 'id', 'tool', 'arguments'].includes(key))
          || !tools.has(message.tool) || !object(message.arguments)) {
          reply(ws, message.id, failure('Malformed or unknown tool call')); return;
        }
        if (active) { reply(ws, message.id, failure('Aseprite is busy; retry after the current operation completes')); return; }
        clearTimeout(idleTimer);
        const id = randomUUID();
        active = { id, client: ws, clientId, requestId: message.id, cancelled: false, dispatched: false,
          tool: message.tool, arguments: message.arguments,
          timer: setTimeout(() => finish(failure(offline)), editorTimeoutMs) };
        dispatch();
      });
      ws.on('close', () => {
        if (role === 'editor') {
          if (editor === ws) { editor = null; finish(failure(`${offline}: editor disconnected`)); }
        } else {
          if (active?.client === ws) cancel();
          send(editor, { type: 'client_closed', clientId });
        }
      });
    });
  });
  async function close() {
    if (closing) return closing;
    closed = true;
    closing = (async () => {
      clearTimeout(idleTimer);
      finish(failure('MCP bridge closed'));
      // Publish retirement before notifying peers, so their next call can start
      // a replacement instead of rediscovering this closing owner's descriptor.
      await removeOwned(loc.descriptorPath, descriptor.identity);
      for (const ws of peers.clients) ws.terminate();
      await new Promise(resolve => peers.close(resolve));
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    })();
    return closing;
  }
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve(); });
  });
  const base = `ws://127.0.0.1:${server.address().port}`;
  descriptor.endpoint = `${base}/editor/${descriptor.token}`;
  descriptor.clientEndpoint = `${base}/client/${descriptor.token}`;
  const temporary = path.join(loc.directory, `mcp-bridge-${descriptor.identity}.tmp`);
  try {
    await writeFile(temporary, JSON.stringify(descriptor), { flag: 'wx', mode: 0o600 });
    // A hard-link publishes complete JSON without replacing any competing owner.
    await link(temporary, loc.descriptorPath);
  } catch (error) {
    await close(); throw error;
  } finally { await unlink(temporary).catch(() => {}); }
  idle();
  return { descriptor, descriptorPath: loc.descriptorPath, close };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const args = process.argv.slice(2);
  const value = name => args[args.indexOf(name) + 1];
  if (!args.includes('--daemon') || !args.includes('--home') || !args.includes('--root')) {
    console.error('Usage: node mcp-bridge.mjs --daemon --home ABS_HOME --root ABS_EXTENSION_ROOT');
    process.exitCode = 1;
  } else {
    try {
      const bridge = await createMcpBridge({ home: value('--home'), extensionRoot: value('--root') });
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
        bridge.close().catch(error => { console.error(error.message); process.exitCode = 1; });
      });
    } catch (error) { console.error(error.message); process.exitCode = 1; }
  }
}
