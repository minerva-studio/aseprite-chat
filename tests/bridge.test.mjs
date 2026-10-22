import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
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
  const second = await connect(t, url);
  response = once(second, 'message'); second.send('{"id":2,"method":"second"}');
  const value = JSON.parse((await response)[0]);
  assert.equal(value.id, 2); assert.notEqual(value.result.pid, firstPid);
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

test('readyz reports bridge identity, bound port, process and live busy state', async t => {
  const { bridge, url } = await setup(t);
  const idle = await getJson(`${url}/readyz`);
  assert.deepEqual(idle.value, { service: 'aseprite-chat', protocolVersion: 3, pid: process.pid, port: bridge.port, busy: false });
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
    service: 'aseprite-chat', protocolVersion: 3, pid: child.pid,
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
    baseUrl: '', apiKey: '', models: [] });
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
