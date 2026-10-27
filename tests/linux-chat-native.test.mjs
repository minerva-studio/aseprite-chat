// Opt-in native Linux CLI checks; every operation uses an owned temporary home.
// No turn/start or model inference is sent.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { registerMcp } from '../scripts/register-mcp.mjs';
import { startChat } from '../scripts/start-chat.mjs';
import { createMcpBridge } from '../scripts/mcp-bridge.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const executable = process.env.ASEPRITE_CHAT_TEST_CODEX;
const skip = process.platform !== 'linux' || !executable;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

test('native Linux registration backs up the selected home and remains idempotent', { skip, timeout: 30000 }, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-linux-registration-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const home = path.join(directory, "账户 ' $()", '.codex');
  await mkdir(home, { recursive: true });
  const seed = '# keep this configuration\n[mcp_servers.unrelated]\ncommand = "keep-command"\n';
  await writeFile(path.join(home, 'config.toml'), seed);
  const hub = await createMcpBridge({ home, extensionRoot: root });
  t.after(() => hub.close());
  const options = { home, extensionRoot: root, resultPath: path.join(directory, 'result.json'), codexPath: executable };
  const deps = { ensureBridge: async () => hub.descriptor };
  const first = await registerMcp(options, deps);
  assert.equal(first.error, undefined);
  assert.equal(first.registered, true);
  assert.equal(await readFile(first.backup, 'utf8'), seed);
  const config = await readFile(path.join(home, 'config.toml'), 'utf8');
  assert.match(config, /mcp_servers\.unrelated/);
  assert.match(config, /mcp_servers\.aseprite_chat/);
  const second = await registerMcp({ ...options, resultPath: path.join(directory, 'again.json') }, deps);
  assert.equal(second.error, undefined);
  assert.equal(second.backup, undefined);
  assert.equal(await readFile(path.join(home, 'config.toml'), 'utf8'), config);
});

test('native Linux Chat starts app-server and initializes using a disposable account', { skip, timeout: 30000 }, async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-linux-chat-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const variables = ['PATH', 'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'CODEX_HOME', 'ASEPRITE_CHAT_ACCOUNT_FILE'];
  const saved = Object.fromEntries(variables.map(name => [name, process.env[name]]));
  const children = [];
  let socket;
  t.after(async () => {
    socket?.terminate();
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) {
        const exited = once(child, 'exit');
        child.kill();
        await Promise.race([exited, pause(3000)]);
      }
    }
    for (const name of variables) {
      if (saved[name] === undefined) delete process.env[name]; else process.env[name] = saved[name];
    }
  });
  process.env.PATH = path.dirname(executable) + path.delimiter + (saved.PATH ?? '');
  process.env.HOME = path.join(directory, 'user');
  process.env.CODEX_HOME = path.join(directory, 'codex-home');
  process.env.ASEPRITE_CHAT_ACCOUNT_FILE = path.join(directory, 'missing-account.json');
  delete process.env.USERPROFILE;
  delete process.env.LOCALAPPDATA;
  await mkdir(process.env.CODEX_HOME, { recursive: true });
  const selectedHome = path.join(directory, 'selected-account-home');
  const accountFile = path.join(directory, 'native-config', 'providers.json');
  await mkdir(path.dirname(accountFile), { recursive: true });
  await writeFile(accountFile, JSON.stringify({ version: 1, mode: 'custom', codexHome: selectedHome,
    baseUrl: '', apiKey: '', models: [], access: 'canvas' }));
  const result = await startChat({ extensionRoot: root, resultPath: path.join(directory, 'result.json'), accountFile }, {
    conventionalPort: 0,
    spawn(command, args, settings) {
      const child = spawn(command, args, settings);
      children.push(child);
      return child;
    }
  });
  assert.equal(result.error, undefined);
  assert.equal(result.pid, children[0].pid);
  socket = new WebSocket(result.endpoint);
  await once(socket, 'open');
  const initialized = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('Native Linux initialize timed out')), 15000);
    socket.on('message', data => {
      const message = JSON.parse(data.toString());
      if (message.id !== 11) return;
      clearTimeout(timer);
      if (message.error) reject(Error(JSON.stringify(message.error))); else resolve(message.result);
    });
    socket.once('error', error => { clearTimeout(timer); reject(error); });
  });
  socket.send(JSON.stringify({ id: 11, method: 'initialize', params: {
    clientInfo: { name: 'aseprite_linux_native_test', version: '1' }, capabilities: { experimentalApi: true }
  } }));
  assert.ok(await initialized);
  assert.equal((await stat(selectedHome)).isDirectory(), true, 'the explicit native account file was ignored');
  socket.send(JSON.stringify({ method: 'initialized', params: {} }));
  const closed = once(socket, 'close');
  socket.close();
  await closed;
  for (let attempt = 0; attempt < 50; attempt++) {
    // Match the native health client: fetch adds browser-style Fetch Metadata,
    // which the bridge intentionally rejects at this local-only boundary.
    const health = await new Promise((resolve, reject) => {
      const request = http.get(result.endpoint.replace('ws:', 'http:') + '/readyz', response => {
        let body = '';
        response.on('data', chunk => { body += chunk; });
        response.on('end', () => { try { resolve(JSON.parse(body)); } catch (error) { reject(error); } });
        response.on('error', reject);
      });
      request.on('error', reject);
      request.setTimeout(1000, () => request.destroy(Error('Native health timed out')));
    });
    if (!health.busy) return;
    await pause(20);
  }
  assert.fail('Chat bridge did not release the native client');
});
