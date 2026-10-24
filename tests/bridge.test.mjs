import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { createBridge, launchFor, readAccount } from '../scripts/server.mjs';

const fixture = fileURLToPath(new URL('./stdio-fixture.mjs', import.meta.url));
const serverScript = fileURLToPath(new URL('../scripts/server.mjs', import.meta.url));
const cliChildren = [];
const cliTempDirs = [];
async function setup(t, overrides = {}) {
  const bridge = await createBridge({ port: 0, command: process.execPath,
    launch: () => {
      const plan = launchFor({ mode: 'default' }, process.env);
      return { args: [fixture, ...plan.args], env: plan.env };
    }, ...overrides });
  t.after(() => bridge.close());
  return { bridge, url: `ws://127.0.0.1:${bridge.port}` };
}
async function until(assertion, timeoutMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try { return await assertion(); } catch (error) { lastError = error; await wait(10); }
  }
  throw lastError;
}
async function connect(t, url, options) {
  const socket = new WebSocket(url, options);
  t.after(() => socket.terminate());
  await once(socket, 'open');
  return socket;
}
function rejected(url, options) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.on('unexpected-response', (req, response) => {
      response.resume(); socket.terminate(); resolve(response.statusCode);
    });
    socket.on('error', () => {});
    socket.on('open', () => { socket.terminate(); reject(Error('unexpectedly accepted handshake')); });
  });
}
test('native Aseprite Origin reaches stdio with Unicode and exact request IDs', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url, { origin: url });
  const reply = once(socket, 'message');
  socket.send(JSON.stringify({ id: 'native-id', method: 'initialize', params: { text: '你好' } }));
  const response = JSON.parse((await reply)[0].toString());
  assert.equal(response.id, 'native-id');
  assert.equal(response.result.received.params.text, '你好');
  assert.equal(response.result.originator, 'aseprite_chat');
});
test('browser, null, foreign origins, fetch headers and foreign Host are rejected', async t => {
  const { url } = await setup(t);
  for (const origin of ['https://example.com', 'http://127.0.0.1:4500', 'null', 'ws://example.com']) {
    assert.equal(await rejected(url, { origin }), 403);
  }
  assert.equal(await rejected(url, { headers: { 'Sec-Fetch-Site': 'cross-site' } }), 403);
  assert.equal(await rejected(url, { headers: { Host: 'evil.example' } }), 403);
});
test('a second client cannot share the first client Codex process', async t => {
  const { url } = await setup(t);
  await connect(t, url);
  assert.equal(await rejected(url), 409);
});
test('a rejected WebSocket handshake does not reserve the bridge', async t => {
  const { bridge, url } = await setup(t);
  const status = await new Promise((resolve, reject) => {
    const request = http.get(`http://127.0.0.1:${bridge.port}/`, {
      headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13' }
    }, response => { response.resume(); resolve(response.statusCode); });
    request.on('error', reject);
  });
  assert.equal(status, 400);
  await connect(t, url);
});
test('reconnection gets a new stdio process and no prior message replay', async t => {
  const { url } = await setup(t);
  const first = await connect(t, url);
  let response = once(first, 'message'); first.send('{"id":1,"method":"first"}');
  const firstPid = JSON.parse((await response)[0]).result.pid;
  const closed = once(first, 'close'); first.close(); await closed;
  // The local close event can precede the server's session-release callback.
  await until(async () => assert.equal((await getJson(`${url}/readyz`)).value.busy, false));
  const second = await connect(t, url);
  response = once(second, 'message'); second.send('{"id":2,"method":"second"}');
  const value = JSON.parse((await response)[0]);
  assert.equal(value.id, 2); assert.notEqual(value.result.pid, firstPid);
});

test('native Codex accepts internal MCP isolation with and without a saved registration', { skip: process.platform !== 'win32', timeout: 10000 }, async t => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-internal-mcp-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const executable = path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe');
  const run = promisify(execFile);
  const plan = launchFor({ mode: 'custom', codexHome: home }, process.env);
  for (const config of ['', '[mcp_servers.aseprite_chat]\ncommand = "existing-node"\nargs = ["existing-script"]\n\n[mcp_servers.unrelated]\ncommand = "keep-command"\n']) {
    await writeFile(path.join(home, 'config.toml'), config);
    const { stdout } = await run(executable, [...plan.args.slice(2), 'mcp', 'list', '--json'], { env: plan.env, windowsHide: true, timeout: 5000 });
    const entries = JSON.parse(stdout);
    assert.equal(entries.find(entry => entry.name === 'aseprite_chat').enabled, false);
    if (config) assert.equal(entries.find(entry => entry.name === 'unrelated').enabled, true);
    assert.equal(await readFile(path.join(home, 'config.toml'), 'utf8'), config);
  }
});
test('binary and multiple-JSON frames never reach the backend', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url);
  const closed = once(socket, 'close'); socket.send('{"id":1}\n{"id":2}');
  assert.equal((await closed)[0], 1007);
  const next = await connect(t, url);
  const binaryClosed = once(next, 'close'); next.send(Buffer.from('binary'));
  assert.equal((await binaryClosed)[0], 1003);
});
test('process startup failure closes the client instead of hanging', async t => {
  const { url } = await setup(t, { command: 'aseprite-chat-nonexistent-executable' });
  const socket = new WebSocket(url); t.after(() => socket.terminate());
  const closed = once(socket, 'close'); await once(socket, 'open');
  assert.equal((await closed)[0], 1011);
});
test('one formatted JSON frame becomes one stdio line without changing large integer IDs', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url);
  const outcome = Promise.race([
    once(socket, 'message').then(([bytes]) => ({ text: bytes.toString() })),
    once(socket, 'close').then(([code]) => ({ code }))
  ]);
  socket.send('{\n  "id": 9007199254740993,\n  "method": "formatted",\n  "params": {"code": "a\\nb"}\n}');
  const value = await outcome;
  assert.equal(value.code, undefined, 'valid formatted JSON closed the backend');
  assert.equal(JSON.parse(value.text).result.received.params.code, 'a\nb');
  assert.match(JSON.parse(value.text).result.raw, /"id": 9007199254740993/);
});
test('synchronous spawn failure closes one client and leaves the bridge healthy', { timeout: 1500 }, async t => {
  const { bridge, url } = await setup(t, { command: '\0invalid-executable' });
  const socket = new WebSocket(url); t.after(() => socket.terminate());
  const closed = once(socket, 'close'); await once(socket, 'open');
  assert.equal((await closed)[0], 1011);
  const status = await new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${bridge.port}/readyz`, response => {
      response.resume(); resolve(response.statusCode);
    }).on('error', reject);
  });
  assert.equal(status, 200);
});

function getJson(url) {
  const httpUrl = url.replace(/^ws:/, 'http:');
  return new Promise((resolve, reject) => http.get(httpUrl, response => {
    let body = '';
    response.setEncoding('utf8');
    response.on('data', chunk => body += chunk);
    response.on('end', () => resolve({ status: response.statusCode, value: JSON.parse(body) }));
  }).on('error', reject));
}
function wait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function probe(t, url, options) {
  const socket = new WebSocket(url, options);
  t.after(() => socket.terminate());
  const messages = [];
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.terminate(); reject(Error('health socket did not close')); }, 1000);
    socket.on('message', (data, binary) => messages.push({ data, binary }));
    socket.on('error', error => { clearTimeout(timer); reject(error); });
    socket.on('close', code => { clearTimeout(timer); resolve(code); });
  });
  assert.equal(code, 1000);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].binary, false);
  return JSON.parse(messages[0].data.toString('utf8'));
}

test('WS readyz reports idle protocol-4 health without starting or reserving a session', async t => {
  let launches = 0;
  const { bridge, url } = await setup(t, { launch: () => {
    launches++;
    return { args: [fixture], env: process.env };
  } });
  const health = { service: 'aseprite-chat', protocolVersion: 4, pid: process.pid, port: bridge.port, busy: false };
  assert.deepEqual(await probe(t, `${url}/readyz`), health);
  assert.deepEqual((await getJson(`${url}/readyz`)).value, health);
  assert.equal(launches, 0);
  const client = await connect(t, url);
  assert.equal(launches, 1, 'health must leave the chat session available');
  const reply = once(client, 'message');
  client.send('{"id":1,"method":"after-health"}');
  assert.equal(JSON.parse((await reply)[0]).id, 1);
});

test('WS readyz remains available while busy and leaves the active backend and session unchanged', async t => {
  let launches = 0;
  const { bridge, url } = await setup(t, { launch: () => {
    launches++;
    return { args: [fixture], env: process.env };
  } });
  const client = await connect(t, url);
  let reply = once(client, 'message');
  client.send('{"id":1,"method":"before-health"}');
  const backendPid = JSON.parse((await reply)[0]).result.pid;
  const health = { service: 'aseprite-chat', protocolVersion: 4, pid: process.pid, port: bridge.port, busy: true };
  assert.deepEqual(await probe(t, `${url}/readyz`, { origin: `${url}/readyz` }), health);
  assert.deepEqual((await getJson(`${url}/readyz`)).value, health);
  assert.equal(await rejected(url), 409, 'active chat must stay reserved by its original client');
  reply = once(client, 'message');
  client.send('{"id":2,"method":"after-health"}');
  const response = JSON.parse((await reply)[0]);
  assert.equal(response.id, 2);
  assert.equal(response.result.pid, backendPid);
  assert.equal(launches, 1, 'health must not create a backend');
  const closed = once(client, 'close'); client.close(); await closed;
  await until(async () => assert.equal((await getJson(`${url}/readyz`)).value.busy, false));
  assert.equal((await probe(t, `${url}/readyz`)).busy, false);
  assert.equal(launches, 1);
  await connect(t, url);
  assert.equal(launches, 2, 'health must not reserve a released session');
});

test('WS readyz accepts only native absent/bare/exact health origins and retains Host/Fetch/path rejection', async t => {
  const { url } = await setup(t, { launch: () => assert.fail('health must not resolve a launch plan') });
  for (const origin of [undefined, url, `${url}/readyz`]) {
    assert.equal((await probe(t, `${url}/readyz`, origin === undefined ? {} : { origin })).busy, false);
  }
  for (const origin of ['https://example.com', 'http://127.0.0.1:4500', 'null', 'ws://example.com',
    `${url}/`, `${url}/other`, `${url}/readyz/`, `${url}/readyz?query=1`]) {
    assert.equal(await rejected(`${url}/readyz`, { origin }), 403, origin);
  }
  for (const headers of [{ 'Sec-Fetch-Site': 'same-origin' }, { 'Sec-Fetch-Mode': 'websocket' }, { Host: 'evil.example' }]) {
    assert.equal(await rejected(`${url}/readyz`, { origin: `${url}/readyz`, headers }), 403);
  }
  for (const pathname of ['/other', '/readyz/', '/readyz?query=1']) {
    assert.equal(await rejected(`${url}${pathname}`, { origin: url }), 404, pathname);
  }
  assert.equal(await rejected(url, { origin: `${url}/readyz` }), 403, 'full health origin must not authorize a chat socket');
  assert.equal((await getJson(`${url}/readyz`)).value.busy, false);
});

test('WS readyz probes do not renew the idle lifetime or count as chat clients', { timeout: 1500 }, async t => {
  let resolveClosed;
  const closed = new Promise(resolve => { resolveClosed = resolve; });
  const { url } = await setup(t, { idleTimeoutMs: 250, onClose: resolveClosed,
    launch: () => assert.fail('health must not launch a backend') });
  const started = performance.now();
  await wait(80);
  assert.equal((await probe(t, `${url}/readyz`)).busy, false);
  await wait(80);
  assert.equal((await probe(t, `${url}/readyz`)).busy, false);
  await closed;
  assert.ok(performance.now() - started < 390, 'health must retain the original idle deadline');
  await assert.rejects(getJson(`${url}/readyz`));
});

test('readyz reports bridge identity, bound port, process and live busy state', async t => {
  const { bridge, url } = await setup(t);
  const idle = await getJson(`${url}/readyz`);
  assert.deepEqual(idle.value, { service: 'aseprite-chat', protocolVersion: 4, pid: process.pid, port: bridge.port, busy: false });
  const socket = await connect(t, url);
  const busy = await getJson(`${url}/readyz`);
  assert.equal(busy.value.busy, true, JSON.stringify(busy));
  const closed = once(socket, 'close'); socket.close(); await closed;
  await until(async () => assert.equal((await getJson(`${url}/readyz`)).value.busy, false));
});

test('idle timeout closes bridge, but never while a client is connected', { timeout: 3000 }, async t => {
  let closeCount = 0;
  const { bridge, url } = await setup(t, { idleTimeoutMs: 100, onClose: () => { closeCount++; } });
  const socket = await connect(t, url);
  await wait(160);
  assert.equal((await getJson(`${url}/readyz`)).value.busy, true);
  const closed = once(socket, 'close'); socket.close(); await closed;
  await wait(160);
  await assert.rejects(getJson(`${url}/readyz`));
  await bridge.close(); // cleanup may close an already auto-closed bridge
  assert.equal(closeCount, 1);
});

test('manual close is idempotent and idle timer can be disabled', async t => {
  const bridge = await createBridge({ port: 0, command: process.execPath,
    launch: () => {
      const plan = launchFor({ mode: 'default' }, process.env);
      return { args: [fixture, ...plan.args], env: plan.env };
    } });
  t.after(() => bridge.close());
  await wait(30);
  assert.equal((await getJson(`http://127.0.0.1:${bridge.port}/readyz`)).value.busy, false);
  await bridge.close();
  await bridge.close();
});

test('CLI writes readiness and atomically replaces an existing discovery hint', { timeout: 5000 }, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-cli-'));
  cliTempDirs.push(directory);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const readyFile = path.join(directory, 'ready.json');
  const discoveryFile = path.join(directory, 'bridge.json');
  await writeFile(discoveryFile, JSON.stringify({ service: 'other-service', protocolVersion: 1, pid: 123, port: 9, endpoint: 'ws://127.0.0.1:9' }));
  const child = spawn(process.execPath, [serverScript], { env: {
    ...process.env, ASEPRITE_CHAT_PORT: '0', CODEX_CLI: process.execPath,
    ASEPRITE_CHAT_READY_FILE: readyFile, ASEPRITE_CHAT_DISCOVERY_FILE: discoveryFile,
    ASEPRITE_CHAT_IDLE_TIMEOUT_MS: '0'
  }, stdio: 'ignore', windowsHide: true });
  cliChildren.push(child);
  const exited = once(child, 'exit');
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const waitForFile = async file => {
    for (let i = 0; i < 100; i++) {
      try { return JSON.parse(await readFile(file, 'utf8')); } catch { await wait(20); }
    }
    throw Error(`CLI did not write ${path.basename(file)}`);
  };
  const ready = await waitForFile(readyFile);
  const metadata = await waitForFile(discoveryFile);
  assert.equal(ready.endpoint, metadata.endpoint);
  assert.match(ready.endpoint, /^ws:\/\/127\.0\.0\.1:\d+$/);
  assert.deepEqual(metadata, {
    service: 'aseprite-chat', protocolVersion: 4, pid: child.pid,
    port: Number(new URL(ready.endpoint).port), endpoint: ready.endpoint
  });
  assert.notEqual(metadata.pid, 123, 'atomic metadata replacement must replace a prior discovery hint');
  child.kill('SIGINT');
  await exited;
});

test('automatic idle CLI exit removes only its own discovery metadata', { timeout: 5000 }, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-idle-cli-'));
  cliTempDirs.push(directory);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const readyFile = path.join(directory, 'ready.json');
  const discoveryFile = path.join(directory, 'bridge.json');
  const child = spawn(process.execPath, [serverScript], { env: {
    ...process.env, ASEPRITE_CHAT_PORT: '0', CODEX_CLI: process.execPath,
    ASEPRITE_CHAT_READY_FILE: readyFile, ASEPRITE_CHAT_DISCOVERY_FILE: discoveryFile,
    ASEPRITE_CHAT_IDLE_TIMEOUT_MS: '100'
  }, stdio: 'ignore', windowsHide: true });
  cliChildren.push(child);
  const exited = once(child, 'exit');
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const metadata = await (async () => {
    for (let i = 0; i < 100; i++) {
      try { return JSON.parse(await readFile(discoveryFile, 'utf8')); } catch { await wait(20); }
    }
    throw Error('CLI did not write discovery metadata');
  })();
  assert.equal(metadata.pid, child.pid);
  await exited;
  await assert.rejects(readFile(discoveryFile));

  const foreignFile = path.join(directory, 'foreign-bridge.json');
  const foreignReadyFile = path.join(directory, 'foreign-ready.json');
  const foreign = spawn(process.execPath, [serverScript], { env: {
    ...process.env, ASEPRITE_CHAT_PORT: '0', CODEX_CLI: process.execPath,
    ASEPRITE_CHAT_READY_FILE: foreignReadyFile, ASEPRITE_CHAT_DISCOVERY_FILE: foreignFile,
    ASEPRITE_CHAT_IDLE_TIMEOUT_MS: '1000'
  }, stdio: 'ignore', windowsHide: true });
  cliChildren.push(foreign);
  const foreignExited = once(foreign, 'exit');
  t.after(() => { if (foreign.exitCode === null) foreign.kill(); });
  for (let i = 0; i < 100; i++) {
    try { await readFile(foreignFile, 'utf8'); break; } catch { await wait(20); }
  }
  await writeFile(foreignFile, JSON.stringify({ service: 'replacement', protocolVersion: 1, pid: 98765 }));
  await foreignExited;
  assert.deepEqual(JSON.parse(await readFile(foreignFile, 'utf8')), {
    service: 'replacement', protocolVersion: 1, pid: 98765
  });
});

test('CLI startup failure writes a human-readable Chinese readiness error', { timeout: 3000 }, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-fail-'));
  cliTempDirs.push(directory);
  t.after(() => rm(directory, { recursive: true, force: true }));
  const readyFile = path.join(directory, 'ready.json');
  // Occupy a loopback port so the CLI fails during listen without touching an existing service.
  const blocker = http.createServer();
  await new Promise(resolve => blocker.listen(0, '127.0.0.1', resolve));
  const port = blocker.address().port;
  const failed = spawn(process.execPath, [serverScript], { env: {
    ...process.env, ASEPRITE_CHAT_PORT: String(port), CODEX_CLI: process.execPath,
    ASEPRITE_CHAT_READY_FILE: readyFile, ASEPRITE_CHAT_DISCOVERY_FILE: path.join(directory, 'bridge.json')
  }, stdio: 'ignore', windowsHide: true });
  cliChildren.push(failed);
  const exited = once(failed, 'exit');
  t.after(() => { if (failed.exitCode === null) failed.kill(); });
  const error = await (async () => {
    for (let i = 0; i < 100; i++) {
      try { return JSON.parse(await readFile(readyFile, 'utf8')); } catch { await wait(20); }
    }
    throw Error('CLI did not report startup failure');
  })();
  assert.match(error.error, /无法|失败|端口/);
  await exited;
  await new Promise(resolve => blocker.close(resolve));
});

test('readAccount treats a missing file as the default account', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-account-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  assert.deepEqual(readAccount(path.join(directory, 'providers.json')), { mode: 'default' });
});

test('readAccount rejects unreadable, malformed and out-of-schema files', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-account-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'providers.json');
  const base = { version: 1, mode: 'custom', codexHome: directory, baseUrl: '', apiKey: '', models: [] };
  for (const content of [
    'not json', '[]', JSON.stringify({ ...base, version: 2 }),
    JSON.stringify({ ...base, mode: 'invented' }),
    JSON.stringify({ ...base, codexHome: 'relative/home' }),
    JSON.stringify({ ...base, baseUrl: 'ftp://example.com' }),
    JSON.stringify({ ...base, apiKey: 7 }),
    JSON.stringify({ ...base, models: 'gpt' })]) {
    await writeFile(file, content);
    assert.throws(() => readAccount(file), /账户配置无效/);
  }
  await writeFile(file, JSON.stringify(base));
  assert.deepEqual(readAccount(file), { mode: 'custom', codexHome: directory,
    baseUrl: '', apiKey: '', models: [], access: 'canvas', workspace: '', reviewer: 'user' });
});

test('readAccount validates optional access fields and defaults them', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-access-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'providers.json');
  const base = { version: 1, mode: 'default', codexHome: dir, baseUrl: '', apiKey: '', models: [] };
  await writeFile(file, JSON.stringify(base));
  const legacy = readAccount(file);
  assert.equal(legacy.access, 'canvas'); assert.equal(legacy.workspace, ''); assert.equal(legacy.reviewer, 'user');
  await writeFile(file, JSON.stringify({ ...base, access: 'workspace', workspace: dir, reviewer: 'auto_review' }));
  const full = readAccount(file);
  assert.equal(full.access, 'workspace'); assert.equal(full.workspace, dir); assert.equal(full.reviewer, 'auto_review');
  for (const bad of [{ access: 'vault' }, { access: 'workspace' },
    { access: 'workspace', workspace: 'relative' }, { workspace: 'rel' }, { reviewer: 'robot' }]) {
    await writeFile(file, JSON.stringify({ ...base, ...bad }));
    assert.throws(() => readAccount(file), /账户配置无效/);
  }
});

test('launchFor re-enables file tools only beyond the canvas level', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-launch-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const disabled = args => args.filter((arg, i) => args[i - 1] === '-c' && /=false$/.test(arg));
  const canvas = launchFor({ mode: 'custom', codexHome: dir, access: 'canvas' }, {});
  const canvasText = canvas.args.join(' ');
  assert.match(canvasText, /features\.shell_tool=false/);
  assert.match(canvasText, /features\.unified_exec=false/);
  assert.match(canvasText, /features\.view_image=false/);
  for (const access of ['read', 'workspace', 'full']) {
    const home = path.join(dir, access);
    const plan = launchFor({ mode: 'custom', codexHome: home, access, workspace: home }, {});
    const text = plan.args.join(' ');
    assert.equal(text.includes('features.shell_tool'), false, access);
    assert.equal(text.includes('features.unified_exec'), false, access);
    assert.equal(text.includes('features.view_image'), false, access);
    assert.match(text, /features\.multi_agent=false/);
    assert.match(text, /windows\.sandbox="unelevated"/, `missing windows sandbox override for ${access}`);
  }
  const configured = path.join(dir, 'configured');
  await mkdir(configured, { recursive: true });
  await writeFile(path.join(configured, 'config.toml'), '[windows]\nsandbox = "elevated"\n');
  const kept = launchFor({ mode: 'custom', codexHome: configured, access: 'read', workspace: configured }, {});
  assert.equal(kept.args.join(' ').includes('windows.sandbox'), false);
  const plan = launchFor({ mode: 'default', access: 'read' }, {});
  assert.match(plan.args.join(' '), /features\.multi_agent=false/);
  assert.equal(plan.args.join(' ').includes('features.shell_tool'), false);
  assert.equal(plan.args.join(' ').includes('windows.sandbox'), false, 'default mode must not force a sandbox');
});

test('internal chat never imports its own external Aseprite MCP registration', () => {
  for (const account of [{mode:'default'}, {mode:'custom',codexHome:'C:/fixture'}]) {
    const plan=launchFor(account,process.env);
    const override=plan.args.find(arg=>arg.startsWith('mcp_servers.aseprite_chat='));
    assert.match(override,/enabled=false/);
    assert(override.includes(JSON.stringify(process.execPath)));
  }
});

test('launchFor default keeps the user home, strips the key and adds lean overrides', () => {
  const { args, env } = launchFor({ mode: 'default' },
    { ASEPRITE_CHAT_API_KEY: 'inherited', CODEX_HOME: 'inherited-home', KEEP: '1' });
  assert.equal(args[0], 'app-server');
  assert.equal(args[1], '--stdio');
  assert.ok(args.includes('features.shell_tool=false'));
  assert.ok(args.includes('features.computer_use=false'));
  assert.ok(args.includes('web_search="disabled"'));
  assert.equal(args.filter(a => a.startsWith('model_provider')).length, 0);
  assert.equal(env.ASEPRITE_CHAT_API_KEY, undefined);
  assert.equal(env.CODEX_HOME, 'inherited-home');
  assert.equal(env.KEEP, '1');
  assert.equal(env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE, 'aseprite_chat');
});

test('launchFor custom home alone sets CODEX_HOME without provider overrides', () => {
  const { args, env } = launchFor(
    { mode: 'custom', codexHome: 'D:\\home', baseUrl: '', apiKey: '', models: [] }, {});
  assert.equal(env.CODEX_HOME, 'D:\\home');
  assert.equal(args.filter(a => a.startsWith('model_provider')).length, 0);
  assert.equal(env.ASEPRITE_CHAT_API_KEY, undefined);
});

test('launchFor custom key alone targets the official OpenAI Responses endpoint', () => {
  const { args, env } = launchFor(
    { mode: 'custom', codexHome: 'D:\\home', baseUrl: '', apiKey: 'sk-test', models: [] }, {});
  const joined = args.join(' ');
  assert.ok(joined.includes('model_provider="aseprite_custom"'));
  assert.ok(joined.includes('base_url="https://api.openai.com/v1"'));
  assert.ok(joined.includes('wire_api="responses"'));
  assert.ok(joined.includes('env_key="ASEPRITE_CHAT_API_KEY"'));
  assert.equal(env.ASEPRITE_CHAT_API_KEY, 'sk-test');
});

test('launchFor custom URL without a key drops the trailing slash and sets no env key', () => {
  const { args, env } = launchFor(
    { mode: 'custom', codexHome: 'D:\\home', baseUrl: 'http://127.0.0.1:8080/v1/', apiKey: '', models: [] }, {});
  const joined = args.join(' ');
  assert.ok(joined.includes('base_url="http://127.0.0.1:8080/v1"'));
  assert.ok(!joined.includes('env_key'));
  assert.equal(env.ASEPRITE_CHAT_API_KEY, undefined);
});

test('a custom account reaches the spawned process argv and environment', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-account-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const home = path.join(directory, 'codex home');
  const file = path.join(directory, 'providers.json');
  await writeFile(file, JSON.stringify({ version: 1, mode: 'custom', codexHome: home,
    baseUrl: 'http://127.0.0.1:9/v1/', apiKey: 'sk-live-test', models: [] }));
  const previous = process.env.ASEPRITE_CHAT_ACCOUNT_FILE;
  process.env.ASEPRITE_CHAT_ACCOUNT_FILE = file;
  t.after(() => {
    if (previous === undefined) delete process.env.ASEPRITE_CHAT_ACCOUNT_FILE;
    else process.env.ASEPRITE_CHAT_ACCOUNT_FILE = previous;
  });
  const { url } = await setup(t, { launch: () => {
    const plan = launchFor(readAccount(file), process.env);
    return { args: [fixture, ...plan.args], env: plan.env };
  } });
  const socket = await connect(t, url);
  const reply = once(socket, 'message');
  socket.send(JSON.stringify({ id: 'account', method: 'initialize', params: {} }));
  const response = JSON.parse((await reply)[0].toString());
  assert.deepEqual(response.result.argv.slice(0, 2), ['app-server', '--stdio']);
  assert.ok(response.result.argv.includes('features.shell_tool=false'));
  assert.ok(response.result.argv.join(' ').includes('base_url="http://127.0.0.1:9/v1"'));
  assert.equal(response.result.codexHome, home);
  assert.equal(response.result.apiKey, 'sk-live-test');
  assert.equal(response.result.originator, 'aseprite_chat');
});

test('an invalid account file closes only that client with a Chinese reason', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-account-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'providers.json');
  await writeFile(file, '{ broken');
  const { bridge, url } = await setup(t, { launch: undefined, accountFile: file });
  const socket = new WebSocket(url); t.after(() => socket.terminate());
  const closed = once(socket, 'close'); await once(socket, 'open');
  const [code, reason] = await closed;
  assert.equal(code, 1011);
  assert.match(reason.toString('utf8'), /账户配置无效/);
  const status = await getJson(`${url}/readyz`);
  assert.equal(status.status, 200);
  assert.equal(status.value.busy, false);
  assert.equal(bridge.port, status.value.port);
});

test('reports the isolated CLI process IDs and temporary directories used by this suite', () => {
  assert.ok(cliChildren.every(child => child.exitCode !== null || child.signalCode !== null), 'all test-owned CLI processes must have exited');
  console.log(`Test-owned CLI PIDs: ${cliChildren.map(child => child.pid).join(', ')}`);
  console.log(`Test temporary directories: ${cliTempDirs.join(', ')}`);
});
