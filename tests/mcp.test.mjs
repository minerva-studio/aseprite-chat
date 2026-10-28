import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, writeFile, rm, access, mkdir, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import http from 'node:http';
import WebSocket from 'ws';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createMcpServer } from '../scripts/mcp-server.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
const success = text => ({ success: true, contentItems: [{ type: 'inputText', text }] });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, ms = 5000) {
  const end = Date.now() + ms;
  do { if (await predicate()) return; await pause(20); } while (Date.now() < end);
  throw Error('Timed out waiting for condition');
}
async function library() { return import('../scripts/mcp-bridge.mjs'); }
async function home(t) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'aseprite-mcp-node-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}
async function hub(t, options = {}) {
  const { createMcpBridge } = await library();
  const bridge = await createMcpBridge({ home: await home(t), extensionRoot: root, ...options });
  t.after(() => bridge.close());
  return bridge;
}
async function socket(t, url, options = {}) {
  const ws = new WebSocket(url, options);
  const messages = [];
  ws.on('message', data => messages.push(JSON.parse(data.toString())));
  await once(ws, 'open');
  t.after(() => ws.terminate());
  return {
    ws, messages,
    send: value => ws.send(JSON.stringify(value)),
    async next(type) {
      await until(() => messages.some(m => !type || m.type === type));
      return messages.splice(messages.findIndex(m => !type || m.type === type), 1)[0];
    },
  };
}
async function rejected(url, options = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { handshakeTimeout: 1500, ...options });
    ws.on('open', () => { ws.terminate(); reject(Error('Unauthorized websocket opened')); });
    ws.on('error', () => resolve());
  });
}
async function sdk(t, dir) {
  const transport = new StdioClientTransport({ command: process.execPath,
    args: [path.join(root, 'scripts/mcp-server.mjs'), '--home', dir], stderr: 'pipe' });
  let stderr = '';
  transport.stderr.on('data', data => { stderr += data; });
  const client = new Client({ name: 'node-mcp-test', version: '1' });
  const protocolErrors = [];
  client.onerror = error => protocolErrors.push(error.message);
  let pid;
  t.after(async () => {
    await client.close();
    if (pid) await until(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
    assert.deepEqual(protocolErrors, [], 'stdout must contain only valid MCP messages');
  });
  try { await client.connect(transport); } catch (error) { throw Error(`${error.message}\n${stderr}`); }
  pid = transport.pid;
  return { client, transport };
}

test('hub authenticates endpoints, isolates IDs and returns native results', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint, { origin: b.descriptor.endpoint });
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'request-1', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  assert.equal(call.tool, 'view_sprite');
  assert.match(call.clientId, /^[\da-f-]{36}$/);
  assert.notEqual(call.id, 'request-1');
  editor.send({ type: 'result', id: call.id, result: success('live sprite') });
  assert.deepEqual(await client.next(), { type: 'result', id: 'request-1', result: success('live sprite') });
  await rejected(b.descriptor.clientEndpoint, { origin: 'http://127.0.0.1' });
  await rejected(b.descriptor.clientEndpoint, { headers: { 'Sec-Fetch-Site': 'same-origin' } });
  await rejected(b.descriptor.clientEndpoint, { headers: { Host: 'foreign.example' } });
  await rejected(b.descriptor.clientEndpoint.replace(b.descriptor.token, 'wrong'));
  await rejected(b.descriptor.endpoint);
  editor.ws.terminate();
  await until(() => editor.ws.readyState === WebSocket.CLOSED);
  const baseOrigin = new URL(b.descriptor.endpoint).origin;
  await socket(t, b.descriptor.endpoint, { origin: baseOrigin });
});

test('busy never queues operations, cancellation waits for acknowledgement and clients cannot spoof results', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const a = await socket(t, b.descriptor.clientEndpoint);
  const c = await socket(t, b.descriptor.clientEndpoint);
  a.send({ type: 'call', id: 'same', tool: 'view_sprite', arguments: {} });
  const first = await editor.next('call');
  c.send({ type: 'result', id: first.id, result: success('spoof') });
  c.send({ type: 'cancel', id: 'same' });
  c.send({ type: 'cancel', id: first.id });
  c.send({ type: 'call', id: 'same', tool: 'execute_lua', arguments: {} });
  assert.match((await c.next('result')).result.contentItems[0].text, /busy/i);
  a.send({ type: 'cancel', id: 'same' });
  assert.equal((await editor.next('cancel')).id, first.id);
  assert.equal((await a.next('result')).result.success, false);
  assert.equal(editor.messages.filter(m => m.type === 'cancel').length, 0);
  c.send({ type: 'call', id: 'second', tool: 'view_sprite', arguments: {} });
  assert.match((await c.next('result')).result.contentItems[0].text, /busy/i);
  editor.send({ type: 'result', id: first.id, result: success('late') });
  await pause(30);
  c.send({ type: 'call', id: 'third', tool: 'view_sprite', arguments: {} });
  const third = await editor.next('call');
  assert.notEqual(third.clientId, first.clientId);
  editor.send({ type: 'result', id: first.id, result: success('foreign late') });
  editor.send({ type: 'result', id: third.id, result: success('correct') });
  assert.equal((await c.next('result')).result.contentItems[0].text, 'correct');
  assert.equal(a.messages.length, 0);
  assert.equal(editor.messages.filter(m => m.type === 'call').length, 0);
});

test('client disconnect cancels and closes its native scope; editor disconnect permits reconnect without replay', { timeout: 10000 }, async t => {
  const b = await hub(t, { editorTimeoutMs: 100 });
  const editor = await socket(t, b.descriptor.endpoint);
  const a = await socket(t, b.descriptor.clientEndpoint);
  const c = await socket(t, b.descriptor.clientEndpoint);
  a.send({ type: 'call', id: 'a', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  a.ws.terminate();
  assert.equal((await editor.next('cancel')).id, call.id);
  assert.equal((await editor.next('client_closed')).clientId, call.clientId);
  editor.ws.terminate();
  await pause(30);
  c.send({ type: 'call', id: 'offline', tool: 'view_sprite', arguments: {} });
  assert.match((await c.next('result')).result.contentItems[0].text, /Enable Aseprite MCP/);
  const reconnected = await socket(t, b.descriptor.endpoint);
  assert.equal(reconnected.messages.length, 0);
  c.send({ type: 'call', id: 'online', tool: 'view_sprite', arguments: {} });
  await reconnected.next('call');
  reconnected.ws.terminate();
  assert.equal((await c.next('result')).result.success, false);
  assert.equal(c.ws.readyState, WebSocket.OPEN);
});

test('timeout revokes editor and idle shutdown retires connected peers', { timeout: 10000 }, async t => {
  const b = await hub(t, { activeTimeoutMs: 100, idleTimeoutMs: 100 });
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'hung', tool: 'view_sprite', arguments: {} });
  await editor.next('call');
  assert.match((await client.next('result')).result.contentItems[0].text, /timed out/i);
  await until(() => editor.ws.readyState === WebSocket.CLOSED);
  await until(async () => { try { await access(b.descriptorPath); return false; } catch { return true; } });
  await until(() => client.ws.readyState === WebSocket.CLOSED);
});

test('malformed requests and native results fail safely without unblocking a foreign ID', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 7, tool: 'view_sprite', arguments: {} });
  assert.equal((await client.next('result')).result.success, false);
  client.send({ type: 'call', id: 'spoof', clientId: 'chosen', tool: 'view_sprite', arguments: {} });
  assert.equal((await client.next('result')).result.success, false);
  client.send({ type: 'call', id: 'good', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  editor.send({ type: 'result', id: 'foreign', result: success('no') });
  client.send({ type: 'call', id: 'busy', tool: 'view_sprite', arguments: {} });
  assert.match((await client.next('result')).result.contentItems[0].text, /busy/i);
  editor.send({ type: 'result', id: call.id, result: { success: true, contentItems: 'bad' } });
  assert.match((await client.next('result')).result.contentItems[0].text, /malformed/i);
  client.ws.send('{bad JSON');
  await until(() => client.ws.readyState === WebSocket.CLOSED);
});

test('stdio SDK initializes offline and lists canonical tools with truthful annotations', { timeout: 15000 }, async t => {
  const b = await hub(t, { editorTimeoutMs: 100 });
  const { client } = await sdk(t, b.descriptor.home);
  assert.match(client.getInstructions(), /Aseprite/);
  const { tools } = await client.listTools();
  const canonical = JSON.parse(await readFile(path.join(root, 'tools.json'), 'utf8'));
  assert.deepEqual(tools.map(({ annotations, ...tool }) => tool), canonical.map(({ type, ...tool }) => tool));
  assert.deepEqual(tools.map(tool => tool.name), ['list_sprites','view_sprite','inspect_sprite','read_pixels','switch_sprite','execute_lua','export_sprite']);
  for (const name of ['list_sprites', 'inspect_sprite']) assert.equal(tools.find(x => x.name === name).annotations.readOnlyHint, true);
  assert.equal(tools.find(x => x.name === 'view_sprite').annotations.readOnlyHint, true);
  assert.equal(tools.find(x => x.name === 'read_pixels').annotations.readOnlyHint, true);
  assert.deepEqual(tools.find(x => x.name === 'switch_sprite').annotations,
    { readOnlyHint: false, destructiveHint: false, openWorldHint: false });
  assert.equal(tools.find(x => x.name === 'export_sprite').annotations.readOnlyHint, false);
  assert.equal(tools.find(x => x.name === 'export_sprite').annotations.destructiveHint, false);
  assert.equal(tools.find(x => x.name === 'execute_lua').annotations.destructiveHint, true);
  const result = await client.callTool({ name: 'view_sprite', arguments: {} });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /Enable Aseprite MCP/);
});

test('real stdio SDK maps text, PNG and failures and rejects unsafe image data URLs', { timeout: 15000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const { client } = await sdk(t, b.descriptor.home);
  const pending = client.callTool({ name: 'view_sprite', arguments: {} });
  let call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: { success: true, contentItems: [
    { type: 'inputText', text: '{"revision":2}' }, { type: 'inputImage', imageUrl: `data:image/png;base64,${png}` },
  ] } });
  assert.deepEqual(await pending, { isError: false, content: [
    { type: 'text', text: '{"revision":2}' }, { type: 'image', data: png, mimeType: 'image/png' },
  ] });
  for (const imageUrl of ['https://foreign/image.png', 'data:image/png;base64,AAAA', 'data:image/svg+xml;base64,PHN2Zz4=', 'data:image/png;base64,%%%']) {
    const p = client.callTool({ name: 'view_sprite', arguments: {} });
    call = await editor.next('call');
    editor.send({ type: 'result', id: call.id, result: { success: true,
      contentItems: [{ type: 'inputImage', imageUrl }] } });
    assert.equal((await p).isError, true);
  }
  const failed = client.callTool({ name: 'execute_lua', arguments: { code: 'error()', summary: 'fail', expectedRevision: 0 } });
  call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: { ...success('Approval rejected'), success: false } });
  assert.deepEqual(await failed, { isError: true, content: [{ type: 'text', text: 'Approval rejected' }] });
  assert.equal((await client.callTool({ name: 'foreign', arguments: {} })).isError, true);
});

test('SDK abort forwards native cancellation and stdio exit closes only its own scope', { timeout: 15000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const { client } = await sdk(t, b.descriptor.home);
  const controller = new AbortController();
  const pending = client.callTool({ name: 'view_sprite', arguments: {} }, undefined, { signal: controller.signal });
  const rejection = assert.rejects(pending, /abort|cancel/i);
  const call = await editor.next('call');
  controller.abort();
  await rejection;
  assert.equal((await editor.next('cancel')).id, call.id);
  editor.send({ type: 'result', id: call.id, result: success('cancel acknowledged') });
  await client.close();
  assert.equal((await editor.next('client_closed')).clientId, call.clientId);
  assert.equal(editor.ws.readyState, WebSocket.OPEN);
  await access(b.descriptorPath);
});

test('ensureBridge reuses one detached daemon under simultaneous startup, rejects wrong roots, and removes only owned descriptor', { timeout: 20000 }, async t => {
  const { ensureBridge } = await library();
  const dir = await home(t);
  const descriptors = await Promise.all(Array.from({ length: 5 }, () => ensureBridge({ home: dir, extensionRoot: root })));
  const d = descriptors[0];
  t.after(async () => {
    // This PID belongs to the daemon created exclusively for this temporary home.
    try { process.kill(d.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await until(() => { try { process.kill(d.pid, 0); return false; } catch { return true; } });
  });
  assert.equal(new Set(descriptors.map(x => x.identity)).size, 1);
  assert.equal((await ensureBridge({ home: dir, extensionRoot: root })).endpoint, d.endpoint);
  await assert.rejects(ensureBridge({ home: dir, extensionRoot: path.join(root, 'scripts') }), /root/i);
  const file = path.join(dir, '.aseprite-chat', 'mcp-bridge.json');
  await writeFile(file, JSON.stringify({ ...d, identity: 'replacement' }));
  process.kill(d.pid, 'SIGTERM');
  await until(() => { try { process.kill(d.pid, 0); return false; } catch { return true; } });
  assert.equal(JSON.parse(await readFile(file, 'utf8')).identity, 'replacement');
});

test('health requires native authentication and exact identity; shutdown cleans owned descriptor', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const endpoint = new URL(b.descriptor.endpoint);
  async function get(pathname, headers = {}) {
    return new Promise((resolve, reject) => {
      const req = http.get({ hostname: '127.0.0.1', port: endpoint.port, path: pathname, headers }, res => {
        let body = ''; res.on('data', data => { body += data; });
        res.on('end', () => resolve({ status: res.statusCode, body }));
      });
      req.on('error', reject);
    });
  }
  assert.equal((await get('/health/wrong')).status, 403);
  assert.equal((await get(`/health/${b.descriptor.token}`, { Origin: endpoint.origin })).status, 403);
  const healthy = await get(`/health/${b.descriptor.token}`);
  assert.equal(healthy.status, 200);
  assert.equal(JSON.parse(healthy.body).identity, b.descriptor.identity);
  await b.close();
  await assert.rejects(access(b.descriptorPath), { code: 'ENOENT' });
});

test('health has a total deadline even when a stale service keeps streaming bytes', { timeout: 10000 }, async t => {
  const dir = await home(t);
  const server = http.createServer((req, res) => {
    res.writeHead(200);
    const ticker = setInterval(() => res.write(' '), 30);
    const end = setTimeout(() => { clearInterval(ticker); res.end('{}'); }, 1800);
    res.once('close', () => { clearInterval(ticker); clearTimeout(end); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const token = 'a'.repeat(64);
  const base = `ws://127.0.0.1:${server.address().port}`;
  await mkdir(path.join(dir, '.aseprite-chat'));
  await writeFile(path.join(dir, '.aseprite-chat', 'mcp-bridge.json'), JSON.stringify({
    protocol: 'aseprite-chat-mcp/2', identity: 'stale', pid: process.pid, token,
    home: await realpath(dir), extensionRoot: await realpath(root),
    endpoint: `${base}/editor/${token}`, clientEndpoint: `${base}/client/${token}`,
  }));
  const { ensureBridge } = await library();
  const started = Date.now();
  await assert.rejects(ensureBridge({ home: dir, extensionRoot: root }), /identity|owner|stale/i);
  assert.ok(Date.now() - started < 1300, 'A streaming foreign service must not prolong health readiness');
});

test('16 MiB websocket limit revokes an oversized native editor and fails its active call', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'large', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: success('x'.repeat(16 * 1024 * 1024)) });
  assert.equal((await client.next('result')).result.success, false);
  await until(() => editor.ws.readyState === WebSocket.CLOSED);
  assert.equal(client.ws.readyState, WebSocket.OPEN);
});

test('duplicate active ID retires only that client', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const a = await socket(t, b.descriptor.clientEndpoint);
  a.send({ type: 'call', id: 'duplicate', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  a.send({ type: 'call', id: 'duplicate', tool: 'foreign', arguments: null, clientId: 'spoof' });
  assert.equal((await editor.next('cancel')).id, call.id);
  assert.equal((await editor.next('client_closed')).clientId, call.clientId);
  editor.send({ type: 'result', id: call.id, result: success('cancel acknowledged') });
  assert.equal(editor.ws.readyState, WebSocket.OPEN);
});

test('live startup lock is preserved; proven-dead owner and descriptor recover without killing any foreign process', { timeout: 15000 }, async t => {
  const dir = await home(t);
  const directory = path.join(dir, '.aseprite-chat');
  await mkdir(directory);
  const lockFile = path.join(directory, 'mcp-bridge.lock');
  const owner = { pid: process.pid, identity: 'live-lock-owner' };
  await writeFile(lockFile, JSON.stringify(owner));
  const { ensureBridge } = await library();
  const pending = ensureBridge({ home: dir, extensionRoot: root });
  const settled = pending.then(() => true);
  assert.equal(await Promise.race([settled, pause(160).then(() => false)]), false);
  assert.deepEqual(JSON.parse(await readFile(lockFile, 'utf8')), owner);
  const child = spawn(process.execPath, ['-e', ''], { windowsHide: true, stdio: 'ignore' });
  await once(child, 'exit');
  await writeFile(path.join(directory, 'mcp-bridge.json'), JSON.stringify({ pid: child.pid, identity: 'dead-descriptor' }));
  await writeFile(lockFile, JSON.stringify({ pid: child.pid, identity: 'dead-lock' }));
  const descriptor = await pending;
  t.after(async () => {
    try { process.kill(descriptor.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await until(() => { try { process.kill(descriptor.pid, 0); return false; } catch { return true; } });
  });
  assert.notEqual(descriptor.pid, child.pid);
  await assert.rejects(access(lockFile), { code: 'ENOENT' });
  await socket(t, descriptor.clientEndpoint);
});

test('stdio initialization and listing stay dormant; first call bootstraps once for independent SDK clients', { timeout: 15000 }, async t => {
  const dir = await home(t);
  const first = await sdk(t, dir);
  const descriptorPath = path.join(dir, '.aseprite-chat', 'mcp-bridge.json');
  assert.equal((await first.client.listTools()).tools.length, 7);
  await assert.rejects(access(path.join(dir, '.aseprite-chat')), { code: 'ENOENT' });
  const one = first.client.callTool({ name: 'view_sprite', arguments: {} });
  await until(async () => { try { await access(descriptorPath); return true; } catch { return false; } });
  const descriptor = JSON.parse(await readFile(descriptorPath, 'utf8'));
  t.after(async () => {
    try { process.kill(descriptor.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await until(() => { try { process.kill(descriptor.pid, 0); return false; } catch { return true; } });
  });
  assert.equal((await first.client.listTools()).tools.length, 7);
  const editor = await socket(t, descriptor.endpoint);
  const second = await sdk(t, dir);
  const a = await editor.next('call');
  editor.send({ type: 'result', id: a.id, result: success('first') });
  assert.equal((await one).content[0].text, 'first');
  const two = second.client.callTool({ name: 'view_sprite', arguments: {} });
  const b = await editor.next('call');
  assert.notEqual(a.clientId, b.clientId);
  editor.send({ type: 'result', id: b.id, result: success('second') });
  assert.equal((await two).content[0].text, 'second');
  await first.client.close();
  assert.equal((await editor.next('client_closed')).clientId, a.clientId);
  assert.equal(second.transport.pid > 0, true);
});

test('hub cleanup preserves a descriptor whose identity was replaced', { timeout: 10000 }, async t => {
  const b = await hub(t);
  await writeFile(b.descriptorPath, JSON.stringify({ ...b.descriptor, identity: 'another-owner' }));
  await b.close();
  assert.equal(JSON.parse(await readFile(b.descriptorPath, 'utf8')).identity, 'another-owner');
});


test('first call waits for editor attachment and cancelled waiting work never dispatches', { timeout: 10000 }, async t => {
  const b = await hub(t, { editorTimeoutMs: 500 });
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'cancel-before-editor', tool: 'execute_lua', arguments: {} });
  await pause(30);
  assert.equal(client.messages.length, 0);
  client.send({ type: 'cancel', id: 'cancel-before-editor' });
  assert.match((await client.next('result')).result.contentItems[0].text, /cancel/i);
  const editor = await socket(t, b.descriptor.endpoint);
  await pause(40);
  assert.equal(editor.messages.length, 0);
  client.send({ type: 'call', id: 'actual', tool: 'view_sprite', arguments: {} });
  const call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: success('after enable') });
  assert.equal((await client.next('result')).result.contentItems[0].text, 'after enable');
});

test('idle peers do not keep hub alive; active approval suspends idle shutdown', { timeout: 10000 }, async t => {
  const b = await hub(t, { idleTimeoutMs: 150 });
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'approval', tool: 'execute_lua', arguments: {} });
  const call = await editor.next('call');
  await pause(210);
  await access(b.descriptorPath);
  editor.send({ type: 'result', id: call.id, result: success('approved') });
  await client.next('result');
  await until(async () => { try { await access(b.descriptorPath); return false; } catch { return true; } });
  await until(() => editor.ws.readyState === WebSocket.CLOSED && client.ws.readyState === WebSocket.CLOSED);
});


async function embedded(t, home, dependencies) {
  const owned = await createMcpServer({ home, extensionRoot: root }, dependencies);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'lazy-lifecycle', version: '1' });
  await owned.server.connect(serverTransport);
  await client.connect(clientTransport);
  t.after(async () => { await client.close(); await owned.close(); });
  return { ...owned, client };
}

test('simultaneous calls share one deferred startup; rejected startup can retry', async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  let attempts = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const { client } = await embedded(t, b.descriptor.home, { ensureBridge: async () => {
    attempts++;
    if (attempts === 1) throw Error('startup unavailable');
    await gate;
    return b.descriptor;
  } });
  assert.equal(attempts, 0);
  assert.equal((await client.callTool({ name: 'foreign' })).isError, true);
  assert.equal(attempts, 0);
  assert.match((await client.callTool({ name: 'view_sprite' })).content[0].text, /startup unavailable/);
  const one = client.callTool({ name: 'view_sprite' });
  const two = client.callTool({ name: 'view_sprite' });
  await until(() => attempts === 2);
  await pause(30);
  assert.equal(attempts, 2);
  release();
  const call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: success('first') });
  const results = await Promise.all([one, two]);
  assert.equal(results.filter(result => !result.isError).length, 1);
  assert.match(results.find(result => result.isError).content[0].text, /busy/i);
  assert.equal(attempts, 2);
});

test('cancel or stdio close during startup never attaches or dispatches late work', async t => {
  for (const action of ['cancel', 'close']) {
    const b = await hub(t);
    const editor = await socket(t, b.descriptor.endpoint);
    let entered = false, release;
    const gate = new Promise(resolve => { release = resolve; });
    const owned = await embedded(t, b.descriptor.home, { ensureBridge: async () => {
      entered = true;
      await gate;
      return b.descriptor;
    } });
    const controller = new AbortController();
    const request = owned.client.callTool({ name: 'execute_lua', arguments: {} }, undefined, { signal: controller.signal });
    const rejected = assert.rejects(request, /abort|cancel|closed/i);
    await until(() => entered);
    if (action === 'cancel') controller.abort();
    else await owned.close();
    await rejected;
    release();
    await pause(80);
    assert.equal(editor.messages.length, 0);
    if (action === 'cancel') await owned.close();
  }
});

test('hub retirement reconnects on a new call without replaying old operations', async t => {
  const directory = await home(t);
  const { createMcpBridge } = await library();
  let current, editor, starts = 0;
  const owned = await embedded(t, directory, { ensureBridge: async () => {
    starts++;
    current = await createMcpBridge({ home: directory, extensionRoot: root, idleTimeoutMs: 100 });
    t.after(() => current.close());
    editor = await socket(t, current.descriptor.endpoint);
    return current.descriptor;
  } });
  const first = owned.client.callTool({ name: 'view_sprite' });
  await until(() => editor !== undefined);
  const a = await editor.next('call');
  editor.send({ type: 'result', id: a.id, result: success('first scope') });
  assert.equal((await first).content[0].text, 'first scope');
  const old = editor;
  await until(() => old.ws.readyState === WebSocket.CLOSED);
  await pause(20);
  assert.equal(starts, 1);
  assert.equal((await owned.client.listTools()).tools.length, 7);
  assert.equal(starts, 1);
  const second = owned.client.callTool({ name: 'view_sprite' });
  await until(() => starts === 2 && editor !== old);
  const b = await editor.next('call');
  assert.notEqual(b.clientId, a.clientId);
  assert.notEqual(b.id, a.id);
  assert.equal(editor.messages.length, 0);
  editor.send({ type: 'result', id: b.id, result: success('fresh scope') });
  assert.equal((await second).content[0].text, 'fresh scope');
});
