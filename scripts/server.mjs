import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import WebSocket, { WebSocketServer } from 'ws';

const maxBytes = 16 * 1024 * 1024;
const invalidAccount = '账户配置无效，请在 Settings 中重新保存。';
const protocolVersion = 3;
const provider = 'aseprite_custom';
const providerEnvKey = 'ASEPRITE_CHAT_API_KEY';
// The canvas workflow uses only the extension's dynamic tools plus Codex's
// request_user_input; every other bundled tool surface is disabled per child.
const leanOverrides = [
  ...['shell_tool', 'unified_exec', 'multi_agent', 'goals', 'view_image', 'memories',
    'apps', 'plugins', 'image_generation', 'skill_search', 'browser_use', 'computer_use']
    .flatMap(feature => ['-c', `features.${feature}=false`]),
  '-c', 'web_search="disabled"'];

/** Read the account file synchronously; a missing file means the default account. */
export function readAccount(file) {
  let text;
  try { text = readFileSync(file, 'utf8'); }
  catch (error) {
    if (error && error.code === 'ENOENT') return { mode: 'default' };
    throw Error(invalidAccount);
  }
  let parsed;
  try { parsed = JSON.parse(text); } catch { throw Error(invalidAccount); }
  const valid = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
    && parsed.version === 1
    && (parsed.mode === 'default' || parsed.mode === 'custom')
    && typeof parsed.codexHome === 'string' && path.isAbsolute(parsed.codexHome)
    && typeof parsed.baseUrl === 'string'
    && (parsed.baseUrl === '' || /^https?:\/\//.test(parsed.baseUrl))
    && typeof parsed.apiKey === 'string'
    && Array.isArray(parsed.models) && parsed.models.every(model => typeof model === 'string');
  if (!valid) throw Error(invalidAccount);
  return { mode: parsed.mode, codexHome: parsed.codexHome, baseUrl: parsed.baseUrl,
    apiKey: parsed.apiKey, models: parsed.models };
}

/** Build the Codex app-server argv and child environment for one account. */
export function launchFor(account, baseEnv) {
  const env = { ...baseEnv, CODEX_INTERNAL_ORIGINATOR_OVERRIDE: 'aseprite_chat' };
  delete env[providerEnvKey];
  const args = ['app-server', '--stdio', ...leanOverrides];
  if (!account || account.mode !== 'custom') return { args, env };
  env.CODEX_HOME = account.codexHome;
  const baseUrl = (account.baseUrl || '').replace(/\/+$/, '');
  const apiKey = account.apiKey || '';
  if (baseUrl === '' && apiKey === '') return { args, env };
  args.push(
    '-c', `model_provider=${JSON.stringify(provider)}`,
    '-c', `model_providers.${provider}.name=${JSON.stringify('Aseprite Chat Custom')}`,
    '-c', `model_providers.${provider}.base_url=${JSON.stringify(baseUrl === '' ? 'https://api.openai.com/v1' : baseUrl)}`,
    '-c', `model_providers.${provider}.wire_api=${JSON.stringify('responses')}`);
  if (apiKey !== '') {
    args.push('-c', `model_providers.${provider}.env_key=${JSON.stringify(providerEnvKey)}`);
    env[providerEnvKey] = apiKey;
  }
  return { args, env };
}

/** WebSocket close reasons are limited to 123 UTF-8 bytes. */
function closeReason(error) {
  let message = '';
  for (const character of String(error && error.message || error)) {
    if (Buffer.byteLength(message + character) > 123) break;
    message += character;
  }
  return message;
}

/**
 * Start a loopback-only WebSocket-to-stdio bridge. Each connection owns its Codex process.
 * When idleTimeoutMs is positive, onClose runs once after either idle or explicit shutdown.
 * launch() synchronously returns {args, env} per connection; its errors close that client.
 */
export async function createBridge({ port = 4500, command = process.env.CODEX_CLI || 'codex',
  accountFile = process.env.ASEPRITE_CHAT_ACCOUNT_FILE || path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'AsepriteChat', 'providers.json'),
  launch = () => {
    const account = readAccount(accountFile);
    if (account.mode === 'custom') mkdirSync(account.codexHome, { recursive: true });
    return launchFor(account, process.env);
  }, idleTimeoutMs = 0, onClose = async () => {} } = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw Error('Invalid local port');
  if (!Number.isFinite(idleTimeoutMs) || idleTimeoutMs < 0) throw Error('Invalid idle timeout');
  const server = http.createServer((request, response) => {
    const allowed = validRequest(request);
    const isReady = allowed && request.url === '/readyz';
    response.writeHead(!allowed ? 403 : isReady ? 200 : 404, isReady ? { 'Content-Type': 'application/json; charset=utf-8' } : {});
    response.end(isReady ? JSON.stringify({
      service: 'aseprite-chat', protocolVersion, pid: process.pid,
      port: server.address()?.port, busy: !!active
    }) : '');
  });
  const sockets = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: maxBytes });
  let active = null;
  let idleTimer = null;
  let closePromise = null;
  const clearIdleTimer = () => { if (idleTimer) clearTimeout(idleTimer); idleTimer = null; };
  async function closeBridge() {
    if (closePromise) return closePromise;
    closePromise = (async () => {
      clearIdleTimer();
      for (const client of sockets.clients) client.terminate();
      await Promise.all([
        new Promise(resolve => sockets.close(resolve)),
        new Promise(resolve => {
          if (!server.listening) { resolve(); return; }
          server.close(resolve); server.closeAllConnections();
        })
      ]);
      await onClose();
    })();
    return closePromise;
  }
  const scheduleIdleClose = () => {
    clearIdleTimer();
    if (idleTimeoutMs > 0 && !active) idleTimer = setTimeout(() => { void closeBridge(); }, idleTimeoutMs);
  };
  function validRequest(request) {
    const authority = `127.0.0.1:${request.socket.localPort}`;
    const origin = request.headers.origin;
    return request.socket.remoteAddress === '127.0.0.1' && request.headers.host === authority
      && (origin === undefined || origin === `ws://${authority}`)
      && !Object.keys(request.headers).some(key => key.startsWith('sec-fetch-'));
  }
  server.on('upgrade', (request, socket, head) => {
    const status = !validRequest(request) ? 403 : request.url !== '/' ? 404 : active ? 409 : null;
    if (status) { socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); return; }
    // With no asynchronous verifyClient hook, handleUpgrade validates and
    // invokes this callback synchronously. Failed handshakes own no session.
    sockets.handleUpgrade(request, socket, head, client => {
      sockets.emit('connection', client);
    });
  });
  sockets.on('connection', client => {
    clearIdleTimer();
    const session = { client, child: null };
    active = session;
    client.on('close', () => {
      if (active === session) active = null;
      session.child?.stdin.destroy();
      session.child?.kill();
      scheduleIdleClose();
    });
    // Resolve the per-connection launch plan synchronously: Lua sends
    // initialize immediately on open, so no buffering race can be introduced.
    let plan;
    try { plan = launch(); }
    catch (error) {
      client.close(1011, closeReason(error));
      return;
    }
    let child;
    // Keep durable thread ownership independent of the editor/launcher host's
    // Codex originator override. This affects only this bridge-owned child.
    try { child = spawn(command, plan.args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
      env: plan.env }); }
    catch {
      client.close(1011, 'Cannot start Codex; check CODEX_CLI and your PATH.');
      return;
    }
    session.child = child;
    let pendingOutput = Buffer.alloc(0);
    const fail = reason => { if (client.readyState === WebSocket.OPEN) client.close(1011, reason); };
    child.on('error', () => fail('Cannot start Codex; check CODEX_CLI and your PATH.'));
    child.on('exit', () => fail('Codex app-server exited. Reconnect to start it again.'));
    child.stdin.on('error', () => fail('Codex input closed.'));
    child.stderr.on('data', bytes => process.stderr.write(bytes));
    child.stdout.on('data', bytes => {
      pendingOutput = Buffer.concat([pendingOutput, bytes]);
      if (pendingOutput.length > maxBytes) { fail('Codex response exceeds message limit.'); return; }
      let newline;
      while ((newline = pendingOutput.indexOf(10)) !== -1) {
        const line = pendingOutput.subarray(0, newline);
        pendingOutput = pendingOutput.subarray(newline + 1);
        if (!line.length) continue;
        if (client.readyState !== WebSocket.OPEN) return;
        if (client.bufferedAmount > maxBytes) { fail('Client cannot receive Codex output.'); return; }
        client.send(line, { binary: false });
      }
    });
    client.on('message', (bytes, binary) => {
      if (binary) { client.close(1003, 'Text JSON frames required.'); return; }
      try { JSON.parse(bytes.toString('utf8')); }
      catch { client.close(1007, 'One JSON message per frame required.'); return; }
      if (child.stdin.destroyed || child.stdin.writableLength > maxBytes) { fail('Codex cannot receive requests.'); return; }
      // JSON has already been validated: literal CR/LF can only be formatting whitespace.
      // Preserve the original number spelling and escaped string newlines when forming JSONL.
      child.stdin.write(bytes.toString('utf8').replace(/[\r\n]/g, ''));
      child.stdin.write('\n');
    });
    client.on('error', () => client.terminate());
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  scheduleIdleClose();
  return { port: server.address().port, close: closeBridge };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const readyFile = process.env.ASEPRITE_CHAT_READY_FILE;
  const discoveryFile = process.env.ASEPRITE_CHAT_DISCOVERY_FILE || path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'AsepriteChat', 'bridge.json');
  const atomicWriteJson = async (file, value) => {
    await mkdir(path.dirname(file), { recursive: true });
    const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify(value)}\n`, 'utf8');
      await rename(temporary, file);
    } catch (error) {
      await unlink(temporary).catch(() => {});
      throw error;
    }
  };
  let bridge;
  let metadataWritten = false;
  const removeOwnedMetadata = async () => {
    if (!metadataWritten) return;
    try {
      const current = JSON.parse(await readFile(discoveryFile, 'utf8'));
      if (current.pid === process.pid) await unlink(discoveryFile);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    metadataWritten = false;
  };
  try {
    const portText = process.env.ASEPRITE_CHAT_PORT;
    const idleText = process.env.ASEPRITE_CHAT_IDLE_TIMEOUT_MS;
    const idleTimeoutMs = idleText === undefined ? 0 : Number(idleText);
    if (!Number.isFinite(idleTimeoutMs) || idleTimeoutMs < 0) throw Error('空闲超时必须是非负有限数字。');
    bridge = await createBridge({
      port: portText === undefined || portText === '' ? 4500 : Number(portText),
      command: process.env.CODEX_CLI || 'codex', idleTimeoutMs,
      onClose: () => removeOwnedMetadata().catch(() => {})
    });
    const endpoint = `ws://127.0.0.1:${bridge.port}`;
    const metadata = { service: 'aseprite-chat', protocolVersion, pid: process.pid, port: bridge.port, endpoint };
    await atomicWriteJson(discoveryFile, metadata);
    metadataWritten = true;
    if (readyFile) await atomicWriteJson(readyFile, { endpoint });
    console.log(`Aseprite Chat ready at ws://127.0.0.1:${bridge.port}`);
    console.log('Uses your existing Codex login. Browser origins are rejected. Press Ctrl+C to stop.');
    let closing = false;
    const stop = async () => {
      if (closing) return;
      closing = true;
      await bridge.close();
    };
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
  } catch (error) {
    if (bridge) await bridge.close().catch(() => {});
    await removeOwnedMetadata().catch(() => {});
    const message = `Aseprite Chat 本地服务启动失败：${error.message}`;
    if (readyFile) await atomicWriteJson(readyFile, { error: message }).catch(writeError => console.error(writeError.message));
    console.error(message);
    process.exitCode = 1;
  }
}
