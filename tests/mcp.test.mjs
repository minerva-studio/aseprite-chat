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
  client.send({ type: 'call', id: 'request-1', tool: 'read_sprite', arguments: {} });
  const call = await editor.next('call');
  assert.equal(call.tool, 'read_sprite');
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
  a.send({ type: 'call', id: 'same', tool: 'read_sprite', arguments: {} });
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
  c.send({ type: 'call', id: 'second', tool: 'read_sprite', arguments: {} });
  assert.match((await c.next('result')).result.contentItems[0].text, /busy/i);
  editor.send({ type: 'result', id: first.id, result: success('late') });
  await pause(30);
  c.send({ type: 'call', id: 'third', tool: 'read_sprite', arguments: {} });
  const third = await editor.next('call');
  assert.notEqual(third.clientId, first.clientId);
  editor.send({ type: 'result', id: first.id, result: success('foreign late') });
  editor.send({ type: 'result', id: third.id, result: success('correct') });
  assert.equal((await c.next('result')).result.contentItems[0].text, 'correct');
  assert.equal(a.messages.length, 0);
  assert.equal(editor.messages.filter(m => m.type === 'call').length, 0);
});

test('client disconnect cancels and closes its native scope; editor disconnect permits reconnect without replay', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const a = await socket(t, b.descriptor.clientEndpoint);
  const c = await socket(t, b.descriptor.clientEndpoint);
  a.send({ type: 'call', id: 'a', tool: 'read_sprite', arguments: {} });
  const call = await editor.next('call');
  a.ws.terminate();
  assert.equal((await editor.next('cancel')).id, call.id);
  assert.equal((await editor.next('client_closed')).clientId, call.clientId);
  editor.ws.terminate();
  await pause(30);
  c.send({ type: 'call', id: 'offline', tool: 'read_sprite', arguments: {} });
  assert.match((await c.next('result')).result.contentItems[0].text, /Open Aseprite MCP and connect/);
  const reconnected = await socket(t, b.descriptor.endpoint);
  assert.equal(reconnected.messages.length, 0);
  c.send({ type: 'call', id: 'online', tool: 'read_sprite', arguments: {} });
  await reconnected.next('call');
  reconnected.ws.terminate();
  assert.equal((await c.next('result')).result.success, false);
  assert.equal(c.ws.readyState, WebSocket.OPEN);
});

test('timeout revokes editor and idle shutdown waits until all peers leave', { timeout: 10000 }, async t => {
  const b = await hub(t, { activeTimeoutMs: 100, idleTimeoutMs: 100 });
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 'hung', tool: 'read_sprite', arguments: {} });
  await editor.next('call');
  assert.match((await client.next('result')).result.contentItems[0].text, /timed out/i);
  await until(() => editor.ws.readyState === WebSocket.CLOSED);
  await pause(160);
  await access(b.descriptorPath);
  client.ws.terminate();
  await until(async () => { try { await access(b.descriptorPath); return false; } catch { return true; } });
});

test('malformed requests and native results fail safely without unblocking a foreign ID', { timeout: 10000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const client = await socket(t, b.descriptor.clientEndpoint);
  client.send({ type: 'call', id: 7, tool: 'read_sprite', arguments: {} });
  assert.equal((await client.next('result')).result.success, false);
  client.send({ type: 'call', id: 'spoof', clientId: 'chosen', tool: 'read_sprite', arguments: {} });
  assert.equal((await client.next('result')).result.success, false);
  client.send({ type: 'call', id: 'good', tool: 'read_sprite', arguments: {} });
  const call = await editor.next('call');
  editor.send({ type: 'result', id: 'foreign', result: success('no') });
  client.send({ type: 'call', id: 'busy', tool: 'read_sprite', arguments: {} });
  assert.match((await client.next('result')).result.contentItems[0].text, /busy/i);
  editor.send({ type: 'result', id: call.id, result: { success: true, contentItems: 'bad' } });
  assert.match((await client.next('result')).result.contentItems[0].text, /malformed/i);
  client.ws.send('{bad JSON');
  await until(() => client.ws.readyState === WebSocket.CLOSED);
});

test('stdio SDK initializes offline and lists canonical tools with truthful annotations', { timeout: 15000 }, async t => {
  const b = await hub(t);
  const { client } = await sdk(t, b.descriptor.home);
  assert.match(client.getInstructions(), /Aseprite/);
  const { tools } = await client.listTools();
  const canonical = JSON.parse(await readFile(path.join(root, 'tools.json'), 'utf8'));
  assert.deepEqual(tools.map(({ annotations, ...tool }) => tool), canonical.map(({ type, ...tool }) => tool));
  assert.equal(tools.find(x => x.name === 'read_sprite').annotations.readOnlyHint, true);
  assert.equal(tools.find(x => x.name === 'read_pixels').annotations.readOnlyHint, true);
  assert.deepEqual(tools.find(x => x.name === 'switch_sprite').annotations,
    { readOnlyHint: false, destructiveHint: false, openWorldHint: false });
  assert.equal(tools.find(x => x.name === 'export_sprite').annotations.readOnlyHint, false);
  assert.equal(tools.find(x => x.name === 'export_sprite').annotations.destructiveHint, false);
  assert.equal(tools.find(x => x.name === 'execute_lua').annotations.destructiveHint, true);
  const result = await client.callTool({ name: 'read_sprite', arguments: {} });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /Open Aseprite MCP and connect/);
});

test('real stdio SDK maps text, PNG and failures and rejects unsafe image data URLs', { timeout: 15000 }, async t => {
  const b = await hub(t);
  const editor = await socket(t, b.descriptor.endpoint);
  const { client } = await sdk(t, b.descriptor.home);
  const pending = client.callTool({ name: 'read_sprite', arguments: {} });
  let call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: { success: true, contentItems: [
    { type: 'inputText', text: '{"revision":2}' }, { type: 'inputImage', imageUrl: `data:image/png;base64,${png}` },
  ] } });
  assert.deepEqual(await pending, { isError: false, content: [
    { type: 'text', text: '{"revision":2}' }, { type: 'image', data: png, mimeType: 'image/png' },
  ] });
  for (const imageUrl of ['https://foreign/image.png', 'data:image/png;base64,AAAA', 'data:image/svg+xml;base64,PHN2Zz4=', 'data:image/png;base64,%%%']) {
    const p = client.callTool({ name: 'read_sprite', arguments: {} });
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
  const pending = client.callTool({ name: 'read_sprite', arguments: {} }, undefined, { signal: controller.signal });
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
    protocol: 'aseprite-chat-mcp/1', identity: 'stale', pid: process.pid, token,
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
  client.send({ type: 'call', id: 'large', tool: 'read_sprite', arguments: {} });
  const call = await editor.next('call');
  editor.send({ type: 'result', id: call.id, result: success('x'.repeat(16 * 1024 * 1024)) });
  assert.equal((await client.next('result')).result.success, false);
  await until(() => editor.ws.readyState === WebSocket.CLOSED);
  assert.equal(client.ws.readyState, WebSocket.OPEN);
});

test('idle editor keeps hub alive; duplicate active ID retires only that client', { timeout: 10000 }, async t => {
  const b = await hub(t, { idleTimeoutMs: 100 });
  const editor = await socket(t, b.descriptor.endpoint);
  await pause(150);
  await access(b.descriptorPath);
  const a = await socket(t, b.descriptor.clientEndpoint);
  a.send({ type: 'call', id: 'duplicate', tool: 'read_sprite', arguments: {} });
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

test('stdio first initialization bootstraps daemon; two SDK clients retain independent native scopes', { timeout: 15000 }, async t => {
  const dir = await home(t);
  const first = await sdk(t, dir);
  const descriptor = JSON.parse(await readFile(path.join(dir, '.aseprite-chat', 'mcp-bridge.json'), 'utf8'));
  t.after(async () => {
    try { process.kill(descriptor.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await until(() => { try { process.kill(descriptor.pid, 0); return false; } catch { return true; } });
  });
  assert.equal((await first.client.listTools()).tools.length, 5);
  const editor = await socket(t, descriptor.endpoint);
  const second = await sdk(t, dir);
  const one = first.client.callTool({ name: 'read_sprite', arguments: {} });
  const a = await editor.next('call');
  editor.send({ type: 'result', id: a.id, result: success('first') });
  assert.equal((await one).content[0].text, 'first');
  const two = second.client.callTool({ name: 'read_sprite', arguments: {} });
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
