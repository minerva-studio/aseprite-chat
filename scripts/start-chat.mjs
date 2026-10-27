import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { open, lstat, stat, mkdir, writeFile, link, unlink } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { nativeCodex } from './register-mcp.mjs';

const maxBytes = 16 * 1024;
const startupLimitMs = 15000;
const startupError = '本地聊天服务启动失败。请检查 Node.js、扩展目录和进程访问权限后重试。';
const resultError = '无法写入启动结果。结果文件必须是尚未占用的绝对路径，且父目录存在并允许写入。';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const validPath = value => typeof value === 'string' && !value.includes('\0')
  && path.isAbsolute(value) && path.resolve(value) === path.normalize(value);
const validPort = value => Number.isSafeInteger(value) && value > 0 && value <= 65535;

// Read only regular, bounded JSON files; neither oversized hints nor readiness
// messages may turn a local discovery probe into an unbounded allocation.
async function readJson(file) {
  let handle;
  try {
    handle = await open(file, 'r');
    const info = await handle.stat();
    if (!info.isFile() || info.size > maxBytes) throw Error();
    const bytes = Buffer.alloc(maxBytes + 1);
    let size = 0;
    while (size < bytes.length) {
      const { bytesRead } = await handle.read(bytes, size, bytes.length - size, size);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > maxBytes) throw Error();
    return JSON.parse(bytes.subarray(0, size).toString('utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  } finally {
    await handle?.close();
  }
}

async function idleBridge(port, expectedPid, timeoutMs = 1000) {
  if (!validPort(port) || timeoutMs <= 0) return null;
  return new Promise(resolve => {
    let request;
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request?.destroy();
      resolve(value);
    };
    // This is a wall-clock deadline, including headers and a trickling body.
    const timer = setTimeout(() => finish(null), Math.min(1000, timeoutMs));
    request = http.get({ hostname: '127.0.0.1', port, path: '/readyz', agent: false,
      maxHeaderSize: maxBytes }, response => {
      if (response.statusCode !== 200) { finish(null); return; }
      let size = 0;
      const chunks = [];
      response.on('data', chunk => {
        size += chunk.length;
        if (size > maxBytes) finish(null);
        else chunks.push(chunk);
      });
      response.on('error', () => finish(null));
      response.on('aborted', () => finish(null));
      response.on('end', () => {
        try {
          const health = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          const valid = health?.service === 'aseprite-chat' && health.protocolVersion === 4
            && Number.isSafeInteger(health.pid) && health.pid > 0 && health.port === port
            && health.busy === false && (expectedPid === undefined || health.pid === expectedPid);
          finish(valid ? { endpoint: `ws://127.0.0.1:${port}`, pid: health.pid } : null);
        } catch { finish(null); }
      });
    });
    request.on('error', () => finish(null));
  });
}

async function publish(resultPath, result) {
  const temporary = `${resultPath}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(result), { flag: 'wx', mode: 0o600 });
    // Exclusive atomic publication also preserves a concurrent writer's result.
    await link(temporary, resultPath);
  } catch { throw Error(resultError); }
  finally { await unlink(temporary).catch(() => {}); }
}

/**
 * Reuse an exact protocol-4 idle Chat bridge, or asynchronously start a native
 * Node bridge and await its owned readiness plus PID-matched HTTP health.
 * Discovery is probed first, then port 4500 (each <= 1s, <= 16 KiB). New startup
 * has a 15s deadline; spawn acceptance alone never publishes an endpoint.
 * Resolves only after atomic publication of {endpoint, pid} or a safe Chinese {error}.
 * The PID comes from validated HTTP health, including for an owned new child;
 * it is internal bootstrap/cache data and does not change the Lua callback API.
 * Invalid/unwritable/occupied result paths reject with a safe Chinese Error.
 * The caller owns a unique, absent absolute resultPath in an existing directory,
 * and may remove its temporary import entry after awaiting this function.
 *
 * Child environment overrides are process-local; no shell, CLI command, account
 * read, model, or MCP registration runs here. Only a child created by this call
 * may be terminated on failed startup. The server retains ownership of shared
 * discovery publication and PID-checked cleanup. This helper never writes,
 * restores, or deletes shared discovery, including after startup failures.
 *
 * accountFile is the editor's authoritative account path. A nondefault path
 * starts its own bridge instead of reusing a service with unknown account
 * identity; the same Lua Launcher can still reuse its verified PID on reopen.
 * @param {{extensionRoot:string, resultPath:string, accountFile?:string}} options Installed extension and owned result file.
 * @param {{discoveryPath?:string, conventionalPort?:number, nativeCodex?:Function,
 *   spawn?:Function, startupTimeoutMs?:number, nodeVersion?:string}} deps Test-only boundaries:
 *   discoveryPath selects a disposable absolute hint; conventionalPort=0 disables
 *   fallback; nativeCodex resolves an existing native executable; spawn has the
 *   node:child_process.spawn contract and must return the child it creates.
 *   startupTimeoutMs can shorten (never extend) 15s; nodeVersion simulates runtime
 *   compatibility. Production always spawns process.execPath and server.mjs.
 * @returns {Promise<{endpoint:string, pid:number}|{error:string}>}
 */
export async function startChat({ extensionRoot, resultPath, accountFile }, deps = {}) {
  // Do this before any reuse/spawn; failure has no safe publication destination.
  try {
    if (!validPath(resultPath) || /[\\/]$/.test(resultPath)
      || !(await stat(path.dirname(resultPath))).isDirectory()) throw Error();
    try { await lstat(resultPath); throw Error(); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  } catch { throw Error(resultError); }

  let result;
  let stage = '无法确认扩展目录。请选择已安装的 Aseprite Chat 扩展。';
  let child;
  let readyPath;
  try {
    if (!validPath(extensionRoot) || (await readJson(path.join(extensionRoot, 'package.json')))?.name !== 'aseprite-chat'
      || !(await stat(path.join(extensionRoot, 'scripts/server.mjs'))).isFile()) throw Error();
    stage = '无法确定本机用户数据目录。请检查用户主目录后重试。';
    const dataDirectory = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'AsepriteChat');
    const defaultAccount = path.join(dataDirectory, 'providers.json');
    const selectedAccount = accountFile ?? (process.env.ASEPRITE_CHAT_ACCOUNT_FILE || defaultAccount);
    if (!validPath(selectedAccount)) throw Error();
    const privateAccount = path.resolve(selectedAccount) !== path.resolve(defaultAccount);
    const discoveryPath = deps.discoveryPath ?? path.join(path.dirname(selectedAccount), 'bridge.json');
    if (!validPath(discoveryPath)) throw Error();
    let hint;
    if (!privateAccount) {
      try { hint = await readJson(discoveryPath); } catch { /* Untrusted hints are optional. */ }
    }
    let bridge;
    if (Number.isSafeInteger(hint?.pid) && hint.pid > 0) bridge = await idleBridge(hint.port, hint.pid);
    if (!privateAccount && !bridge) bridge = await idleBridge(deps.conventionalPort ?? 4500);
    if (bridge) result = bridge;
    else {
      stage = 'Node.js 版本不受支持。请安装 Node.js 24 或更新版本，重新打开 Aseprite 后重试。';
      const major = Number((deps.nodeVersion ?? process.versions.node).split('.')[0]);
      if (!Number.isSafeInteger(major) || major < 24) throw Error();
      stage = '未找到可用的原生 Codex 程序。请安装或修复 Codex CLI 后重试。';
      const executable = await (deps.nativeCodex ?? nativeCodex)();
      if (!validPath(executable) || (process.platform === 'win32' && path.extname(executable).toLowerCase() !== '.exe')
        || !(await stat(executable)).isFile()) throw Error();
      stage = startupError;
      await mkdir(path.dirname(discoveryPath), { recursive: true });
      const identity = randomUUID();
      readyPath = `${resultPath}.${identity}.ready`;
      const timeout = deps.startupTimeoutMs ?? startupLimitMs;
      if (!Number.isFinite(timeout) || timeout <= 0 || timeout > startupLimitMs) throw Error();
      const deadline = performance.now() + timeout;
      let failed = false;
      let exited = false;
      child = (deps.spawn ?? spawn)(process.execPath, [path.join(extensionRoot, 'scripts/server.mjs')], {
        cwd: extensionRoot, shell: false, windowsHide: true, detached: true, stdio: 'ignore',
        env: { ...process.env, CODEX_CLI: executable, ASEPRITE_CHAT_PORT: '0',
          ASEPRITE_CHAT_ACCOUNT_FILE: selectedAccount,
          ASEPRITE_CHAT_READY_FILE: readyPath, ASEPRITE_CHAT_DISCOVERY_FILE: discoveryPath,
          ASEPRITE_CHAT_IDLE_TIMEOUT_MS: '120000' }
      });
      child.on('error', () => { failed = true; });
      child.on('exit', () => { exited = true; });
      child.unref();
      while (performance.now() < deadline) {
        if (failed || exited) throw Error();
        const ready = await readJson(readyPath);
        if (ready !== null) {
          const match = typeof ready?.endpoint === 'string' && /^ws:\/\/127\.0\.0\.1:([1-9]\d{0,4})$/.exec(ready.endpoint);
          if (!match || !validPort(Number(match[1])) || !Number.isSafeInteger(child.pid) || child.pid <= 0) throw Error();
          bridge = await idleBridge(Number(match[1]), child.pid, deadline - performance.now());
          if (!bridge || failed || exited || performance.now() >= deadline) throw Error();
          result = bridge;
          break;
        }
        await delay(Math.min(25, Math.max(0, deadline - performance.now())));
      }
      if (!result) {
        stage = '本地聊天服务启动超时。请检查 Node.js 与进程访问权限后重试。';
        throw Error();
      }
    }
  } catch {
    result = { error: stage };
  }
  let published = false;
  try {
    await publish(resultPath, result);
    published = true;
    return result;
  } finally {
    if ((result.error || !published) && child?.pid && child.exitCode === null && child.signalCode === null) {
      try { child.kill(); } catch { /* Only this call's owned child may be stopped. */ }
    }
    if (readyPath) await unlink(readyPath).catch(() => {});
  }
}
