import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFile, writeFile, mkdir, rename, unlink, stat } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const serverName = 'aseprite_chat';

class RegistrationError extends Error {}

async function isFile(file) {
  try { return (await stat(file)).isFile(); }
  catch { return false; }
}

/**
 * Locate a native Codex executable using PATH and known Windows install layouts.
 * Shell wrappers are location hints only; lookup never executes a process or
 * reads account/configuration files. Rejects with a safe Chinese installation error.
 * @returns {Promise<string>} Absolute path to an existing native executable.
 */
export async function nativeCodex() {
  const directories = (process.env.PATH ?? '').split(path.delimiter).map(value => value.replace(/^"|"$/g, ''));
  const candidates = directories.filter(Boolean).map(directory => path.resolve(directory, 'codex.exe'));
  if (process.env.LOCALAPPDATA) candidates.push(path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe'));
  for (const candidate of candidates) if (await isFile(candidate)) return candidate;

  // A wrapper is only a location hint. Never execute .cmd/.ps1 or a shell.
  const packageRoots = [];
  for (const directory of directories.filter(Boolean)) {
    if (await isFile(path.join(directory, 'codex.cmd'))) packageRoots.push(path.join(directory, 'node_modules/@openai'));
  }
  if (process.env.APPDATA) packageRoots.push(path.join(process.env.APPDATA, 'npm/node_modules/@openai'));
  const architectures = process.arch === 'arm64' ? ['arm64', 'x64'] : ['x64', 'arm64'];
  for (const packageRoot of packageRoots) {
    for (const architecture of architectures) {
      const triple = architecture === 'arm64' ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc';
      for (const prefix of ['codex/node_modules/@openai/', '']) {
        const candidate = path.join(packageRoot, `${prefix}codex-win32-${architecture}/vendor/${triple}/bin/codex.exe`);
        if (await isFile(candidate)) return candidate;
      }
    }
  }
  throw new RegistrationError('未找到原生 Codex 程序。请安装或修复 Codex CLI 后重试。');
}

function runNative(executable, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { ...options, shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const stdout = [];
    let bytes = 0;
    const timer = setTimeout(() => { child.kill(); reject(new Error('CLI timeout')); }, 20000);
    const collect = (chunk, output) => {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) { child.kill(); reject(new Error('CLI output limit')); }
      else if (output) stdout.push(chunk);
    };
    child.stdout.on('data', chunk => collect(chunk, true));
    child.stderr.on('data', chunk => collect(chunk, false));
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code === 0) resolve(Buffer.concat(stdout).toString('utf8'));
      else reject(new Error('CLI failed'));
    });
  });
}

async function configBytes(file) {
  try { return await readFile(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function sameBytes(first, second) {
  return first === null ? second === null : second !== null && first.equals(second);
}

function exactRegistration(entry, command, args) {
  const transport = entry?.transport;
  return entry?.name === serverName && entry.enabled === true && !entry.disabled_reason
    && transport?.type === 'stdio' && transport.command === command
    && Array.isArray(transport.args) && transport.args.length === args.length
    && transport.args.every((argument, index) => argument === args[index])
    && (transport.env == null || (typeof transport.env === 'object' && Object.keys(transport.env).length === 0))
    && (transport.env_vars == null || (Array.isArray(transport.env_vars) && transport.env_vars.length === 0))
    && transport.cwd == null;
}

async function publish(resultPath, result) {
  if (typeof resultPath !== 'string' || !path.isAbsolute(resultPath)) throw new RegistrationError('结果文件必须使用绝对路径。');
  const temporary = `${resultPath}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(result), { flag: 'wx', mode: 0o600 });
    await rename(temporary, resultPath);
  } finally {
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
}

/**
 * Register the canonical native stdio server in one explicitly selected Codex home,
 * creating that directory before invoking the native CLI when it does not exist.
 * Publishes an atomic editor-only result, including safe Chinese errors. Existing
 * foreign entries are never replaced, and failed CLI changes are never rolled back
 * over concurrent writes. `registered` means registration was verified this run;
 * connect-only reports false because it deliberately does not inspect Codex config.
 *
 * @param {{home:string, extensionRoot:string, resultPath:string, connectOnly?:boolean, codexPath?:string}} options
 * @param {{ensureBridge?:Function, runCodex?:Function}} dependencies Test seams for the hub and native CLI boundary.
 * @returns {Promise<{endpoint:string, registered:boolean, backup?:string}|{error:string}>}
 */
export async function registerMcp(options, dependencies = {}) {
  let result;
  let stage = '无法读取所选 Codex 配置。请检查目录权限后重试。';
  try {
    const home = typeof options.home === 'string' ? options.home.trim() : '';
    if (!home || !path.isAbsolute(home)) throw new RegistrationError('Codex 目录必须是非空绝对路径。');
    const extensionRoot = options.extensionRoot;
    if (typeof extensionRoot !== 'string' || !path.isAbsolute(extensionRoot)) throw new RegistrationError('扩展目录必须使用绝对路径。');
    let identity;
    try { identity = JSON.parse(await readFile(path.join(extensionRoot, 'package.json'), 'utf8')); }
    catch { throw new RegistrationError('无法确认扩展目录。请选择已安装的 Aseprite Chat 扩展。'); }
    if (identity.name !== 'aseprite-chat') throw new RegistrationError('扩展目录不是 Aseprite Chat。');
    if (typeof options.resultPath !== 'string' || !path.isAbsolute(options.resultPath)) throw new RegistrationError('结果文件必须使用绝对路径。');

    let backup;
    if (!options.connectOnly) {
      const executable = options.codexPath ?? await nativeCodex();
      if (!path.isAbsolute(executable) || (process.platform === 'win32' && path.extname(executable).toLowerCase() !== '.exe') || !await isFile(executable)) {
        throw new RegistrationError('未找到可用的原生 Codex 程序。');
      }
      stage = '无法创建所选 Codex 目录。请检查路径与目录权限后重试。';
      await mkdir(home, { recursive: true });
      stage = '无法读取所选 Codex 配置。请检查目录权限后重试。';
      const configPath = path.join(home, 'config.toml');
      const original = await configBytes(configPath);
      const args = [path.join(extensionRoot, 'scripts/mcp-server.mjs'), '--home', home];
      const run = dependencies.runCodex ?? runNative;
      const childOptions = { env: { ...process.env, CODEX_HOME: home } };
      stage = '无法读取 Codex MCP 列表。请检查 Codex CLI 和所选目录后重试。';
      const entries = JSON.parse(await run(executable, ['mcp', 'list', '--json'], childOptions));
      if (!Array.isArray(entries)) throw Error('Unexpected MCP list');
      const existing = entries.filter(entry => entry.name === serverName);
      if (existing.length > 1 || (existing.length === 1 && !exactRegistration(existing[0], process.execPath, args))) {
        throw new RegistrationError('所选 Codex 目录已有同名 aseprite_chat 配置，存在冲突。请先手动检查，未覆盖现有配置。');
      }
      if (!existing.length) {
        stage = '无法备份 Codex 配置。注册尚未执行，请检查目录权限。';
        if (!sameBytes(original, await configBytes(configPath))) throw new RegistrationError('Codex 配置已被其他进程更改。请重试注册。');
        if (original !== null) {
          const backupDirectory = path.join(home, '.aseprite-chat');
          await mkdir(backupDirectory, { recursive: true });
          backup = path.join(backupDirectory, `config-backup-${randomUUID()}.toml`);
          await writeFile(backup, original, { flag: 'wx', mode: 0o600 });
        }
        if (!sameBytes(original, await configBytes(configPath))) throw new RegistrationError('Codex 配置已被其他进程更改。请重试注册。');
        stage = 'Codex MCP 注册失败。已有配置未回滚；若原配置存在，备份保存在所选目录的 .aseprite-chat 文件夹中。';
        await run(executable, ['mcp', 'add', serverName, '--', process.execPath, ...args], childOptions);
      }
      stage = 'Codex MCP 注册验证失败。请检查所选目录中的 aseprite_chat 配置后重试。';
      const verified = JSON.parse(await run(executable, ['mcp', 'get', serverName, '--json'], childOptions));
      if (!exactRegistration(verified, process.execPath, args)) throw Error('Registration mismatch');
    }
    stage = '无法连接 Aseprite MCP 服务。请检查 Node.js 与扩展目录后重试。';
    const ensure = dependencies.ensureBridge ?? (await import('./mcp-bridge.mjs')).ensureBridge;
    const bridge = await ensure({ home, extensionRoot });
    if (typeof bridge?.endpoint !== 'string' || !bridge.endpoint) throw Error('Missing editor endpoint');
    result = { endpoint: bridge.endpoint, registered: !options.connectOnly, ...(backup ? { backup } : {}) };
  } catch (error) {
    result = { error: error instanceof RegistrationError ? error.message : stage };
  }
  await publish(options.resultPath, result);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  let options = {};
  try {
    const names = { '--home': 'home', '--root': 'extensionRoot', '--result': 'resultPath' };
    const args = process.argv.slice(2);
    let invalid = false;
    for (let index = 0; index < args.length; index++) {
      const argument = args[index];
      if (argument === '--connect-only' && !options.connectOnly) options.connectOnly = true;
      else if (names[argument] && options[names[argument]] === undefined && args[index + 1] && !args[index + 1].startsWith('--')) options[names[argument]] = args[++index];
      else invalid = true;
    }
    if (invalid) {
      await publish(options.resultPath, { error: 'MCP 注册参数无效。请从 Aseprite 面板重新连接。' });
      process.exitCode = 1;
    } else {
      const result = await registerMcp(options);
      if (result.error) process.exitCode = 1;
    }
  } catch {
    // Never expose raw native CLI errors or config/key content on stderr.
    process.stderr.write('无法写入 MCP 连接结果。请检查结果文件路径与目录权限。\n');
    process.exitCode = 1;
  }
}
