import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const implementation = await import('../scripts/start-chat.mjs').catch(() => ({}));
const registrar = await import('../scripts/register-mcp.mjs');
const realServer = fileURLToPath(new URL('../scripts/server.mjs', import.meta.url));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function fixture(t, source) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-start-'));
  const special = process.platform === 'win32' ? "插件 空格 ' “引号” %PATH% & $() !" : '插件 空格 \' " %PATH% & $() !';
  const extensionRoot = path.join(directory, special);
  await mkdir(path.join(extensionRoot, 'scripts'), { recursive: true });
  await writeFile(path.join(extensionRoot, 'package.json'), '{"name":"aseprite-chat"}');
  await writeFile(path.join(extensionRoot, 'scripts/server.mjs'), source ?? `
    process.argv[1] = ${JSON.stringify(realServer)};
    await import(${JSON.stringify(pathToFileURL(realServer).href)});
  `);
  const options = { extensionRoot, resultPath: path.join(directory, `${special}.json`) };
  const discoveryPath = path.join(directory, 'discovery', 'bridge.json');
  const children = [];
  const ownedPids = [];
  const calls = [];
  const deps = { discoveryPath, conventionalPort: 0, nativeCodex: async () => process.execPath,
    spawn: (command, args, settings) => {
      calls.push({ command, args, settings });
      const child = spawn(command, args, settings);
      children.push(child);
      return child;
    } };
  t.after(async () => {
    for (const child of children) {
      if (child.pid && child.exitCode === null && child.signalCode === null) {
        const exited = once(child, 'exit').catch(() => {});
        child.kill();
        await Promise.race([exited, delay(2000)]);
      }
    }
    for (const pid of ownedPids) {
      try { process.kill(pid); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    // Windows may retain an owned child's working directory briefly after kill.
    await rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 25 });
  });
  return { directory, options, deps, calls, children, ownedPids, discoveryPath };
}

async function healthServer(t, change = {}, handler) {
  const server = http.createServer((req, res) => {
    assert.equal(req.url, '/readyz');
    if (handler) return handler(req, res);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ service: 'aseprite-chat', protocolVersion: 4,
      pid: process.pid, port: server.address().port, busy: false, ...change }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  return server.address().port;
}

async function hint(f, value) {
  await mkdir(path.dirname(f.discoveryPath), { recursive: true });
  await writeFile(f.discoveryPath, JSON.stringify(value));
}

async function result(f) {
  return JSON.parse(await readFile(f.options.resultPath, 'utf8'));
}

test('exports startChat and the existing shared nativeCodex resolver', () => {
  assert.equal(typeof implementation.startChat, 'function');
  assert.equal(typeof registrar.nativeCodex, 'function');
});
test('an explicit nondefault account file reaches the child without reusing another account bridge', async t => {
  const f = await fixture(t);
  f.options.accountFile = path.join(f.directory, 'native-user-config', 'providers.json');
  delete f.deps.discoveryPath;
  f.deps.conventionalPort = await healthServer(t);
  assert.equal((await implementation.startChat(f.options, f.deps)).error, undefined);
  assert.equal(f.calls.length, 1, 'a healthy bridge with unknown account identity was reused');
  assert.equal(f.calls[0].settings.env.ASEPRITE_CHAT_ACCOUNT_FILE, f.options.accountFile);
  assert.equal(f.calls[0].settings.env.ASEPRITE_CHAT_DISCOVERY_FILE,
    path.join(path.dirname(f.options.accountFile), 'bridge.json'));
});

test('Chat discovery uses the server user-data fallback without LOCALAPPDATA', async t => {
  const f = await fixture(t);
  const previous = { LOCALAPPDATA: process.env.LOCALAPPDATA, HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
  delete process.env.LOCALAPPDATA;
  process.env.HOME = f.directory;
  process.env.USERPROFILE = f.directory;
  try {
    const port = await healthServer(t);
    const actual = await implementation.startChat(f.options, { conventionalPort: port,
      nativeCodex: () => assert.fail('idle fallback must be reused without native lookup') });
    assert.deepEqual(actual, { endpoint: `ws://127.0.0.1:${port}`, pid: process.pid });
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test('Chat startup publishes and reuses owned discovery without LOCALAPPDATA', async t => {
  const f = await fixture(t);
  const previous = { LOCALAPPDATA: process.env.LOCALAPPDATA, HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
  delete process.env.LOCALAPPDATA;
  process.env.HOME = f.directory;
  process.env.USERPROFILE = f.directory;
  try {
    const deps = { ...f.deps };
    delete deps.discoveryPath;
    const actual = await implementation.startChat(f.options, deps);
    assert.equal(actual.error, undefined, actual.error);
    const discovery = path.join(f.directory, 'AppData/Local/AsepriteChat/bridge.json');
    assert.equal(f.calls[0].settings.env.ASEPRITE_CHAT_DISCOVERY_FILE, discovery);
    const descriptor = JSON.parse(await readFile(discovery, 'utf8'));
    assert.equal(descriptor.pid, actual.pid);
    assert.deepEqual(await implementation.startChat({ ...f.options, resultPath: path.join(f.directory, 'again.json') }, {
      conventionalPort: 0, nativeCodex: () => assert.fail('fallback discovery must reuse the owned bridge')
    }), actual);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test('reuses exact idle discovery with matching PID, before conventional port or executable lookup', async t => {
  const f = await fixture(t);
  const port = await healthServer(t);
  const conventional = await healthServer(t);
  await hint(f, { port, pid: process.pid });
  f.deps.conventionalPort = conventional;
  f.deps.nativeCodex = () => assert.fail('reuse must not resolve or execute Codex');
  const actual = await implementation.startChat(f.options, f.deps);
  assert.deepEqual(actual, { endpoint: `ws://127.0.0.1:${port}`, pid: process.pid });
  assert.deepEqual(await result(f), actual);
  assert.equal(f.calls.length, 0);
});

for (const change of [
  { service: 'Aseprite-chat' }, { protocolVersion: 2 }, { protocolVersion: 3 }, { protocolVersion: '4' },
  { busy: true }, { busy: 0 }, { pid: 0 }, { pid: '42' }, { port: 1 },
  { pid: process.pid + 100000 }
]) {
  test(`rejects discovery identity ${JSON.stringify(change)} and falls back to conventional idle`, async t => {
    const f = await fixture(t);
    const port = await healthServer(t, change);
    const fallback = await healthServer(t);
    await hint(f, { port, pid: process.pid });
    f.deps.conventionalPort = fallback;
    assert.deepEqual(await implementation.startChat(f.options, f.deps), { endpoint: `ws://127.0.0.1:${fallback}`, pid: process.pid });
    assert.equal(f.calls.length, 0);
  });
}

test('busy discovery and conventional port are never reused; real owned server starts on port zero', async t => {
  const f = await fixture(t);
  const busy = await healthServer(t, { busy: true });
  await hint(f, { port: busy, pid: process.pid });
  f.deps.conventionalPort = busy;
  const envBefore = { ...process.env };
  const actual = await implementation.startChat(f.options, f.deps);
  assert.match(actual.endpoint, /^ws:\/\/127\.0\.0\.1:\d+$/);
  assert.notEqual(actual.endpoint, `ws://127.0.0.1:${busy}`);
  assert.deepEqual(await result(f), actual);
  const descriptor = JSON.parse(await readFile(f.discoveryPath, 'utf8'));
  assert.equal(descriptor.endpoint, actual.endpoint);
  assert.equal(descriptor.pid, f.children[0].pid);
  assert.equal(actual.pid, f.children[0].pid);
  const again = { ...f.options, resultPath: path.join(f.directory, 'again.json') };
  assert.deepEqual(await implementation.startChat(again, f.deps), actual);
  assert.equal(f.calls.length, 1, 'new idle service must replace busy discovery and be reused');
  const response = await fetch(`http://127.0.0.1:${busy}/readyz`);
  assert.equal((await response.json()).busy, true, 'original busy service remains alive');
  const [{ command, args, settings }] = f.calls;
  assert.equal(command, process.execPath);
  assert.deepEqual(args, [path.join(f.options.extensionRoot, 'scripts/server.mjs')]);
  assert.equal(settings.cwd, f.options.extensionRoot);
  assert.equal(settings.shell, false);
  assert.equal(settings.windowsHide, true);
  assert.equal(settings.detached, true);
  assert.equal(settings.stdio, 'ignore');
  assert.equal(settings.env.CODEX_CLI, process.execPath);
  assert.equal(settings.env.ASEPRITE_CHAT_PORT, '0');
  assert.equal(settings.env.ASEPRITE_CHAT_IDLE_TIMEOUT_MS, '120000');
  assert.notEqual(settings.env.ASEPRITE_CHAT_READY_FILE, f.options.resultPath);
  assert.equal(settings.env.ASEPRITE_CHAT_DISCOVERY_FILE, f.discoveryPath);
  assert.ok(Object.keys(process.env).length === Object.keys(envBefore).length
    && Object.entries(envBefore).every(([name, value]) => process.env[name] === value), 'parent environment must stay unchanged');
});

test('slow real startup stays asynchronous and publishes only after health', async t => {
  const f = await fixture(t, `
    await new Promise(resolve => setTimeout(resolve, 500));
    process.argv[1] = ${JSON.stringify(realServer)};
    await import(${JSON.stringify(pathToFileURL(realServer).href)});
  `);
  let settled = false;
  const started = performance.now();
  const pending = implementation.startChat(f.options, f.deps).then(value => { settled = true; return value; });
  await delay(80);
  assert.equal(settled, false);
  await assert.rejects(stat(f.options.resultPath), { code: 'ENOENT' });
  const actual = await pending;
  assert.ok(actual.endpoint);
  assert.equal(actual.pid, f.children[0].pid);
  assert.ok(performance.now() - started >= 450);
  t.diagnostic(`slow ready ${Math.round(performance.now() - started)}ms; event loop yielded before 80ms probe`);
});

test('stale discovery is replaced by an owned real service and the next call reuses it', async t => {
  const f = await fixture(t);
  await hint(f, { pid: 123, port: 0, endpoint: 'ws://127.0.0.1:1' });
  const first = await implementation.startChat(f.options, f.deps);
  assert.ok(first.endpoint);
  const descriptor = JSON.parse(await readFile(f.discoveryPath, 'utf8'));
  assert.equal(descriptor.pid, f.children[0].pid);
  assert.equal(descriptor.endpoint, first.endpoint);
  assert.equal(first.pid, f.children[0].pid);
  assert.deepEqual(await implementation.startChat({ ...f.options, resultPath: path.join(f.directory, 'again.json') }, f.deps), first);
  assert.equal(f.calls.length, 1);
});

test('failed owned startup never deletes or rolls back newer unrelated discovery', async t => {
  const f = await fixture(t, 'setTimeout(() => process.exit(9), 350);');
  const pending = implementation.startChat(f.options, f.deps);
  await delay(80);
  await hint(f, { pid: 123, port: 23456, concurrent: 'keep unchanged' });
  const concurrent = await readFile(f.discoveryPath, 'utf8');
  assert.ok((await pending).error);
  assert.equal(await readFile(f.discoveryPath, 'utf8'), concurrent);
});

test('new real service publishes a reusable discovery hint without launching a model', async t => {
  const f = await fixture(t);
  const first = await implementation.startChat(f.options, f.deps);
  const descriptor = JSON.parse(await readFile(f.discoveryPath, 'utf8'));
  assert.equal(descriptor.pid, f.children[0].pid);
  assert.equal(descriptor.endpoint, first.endpoint);
  assert.equal(first.pid, f.children[0].pid);
  const again = { ...f.options, resultPath: path.join(f.directory, 'again.json') };
  assert.deepEqual(await implementation.startChat(again, f.deps), first);
  assert.equal(f.calls.length, 1);
  assert.equal((await readdir(f.directory)).some(name => name.endsWith('.tmp')), false);
});

for (const mode of ['hang', 'trickle', 'oversize', 'redirect', 'malformed', 'abort']) {
  test(`HTTP ${mode} is bounded and does not become readiness`, async t => {
    const f = await fixture(t);
    const port = await healthServer(t, {}, (req, res) => {
      if (mode === 'hang') return;
      if (mode === 'trickle') {
        res.writeHead(200);
        const timer = setInterval(() => res.write(' '), 40);
        res.on('close', () => clearInterval(timer));
      } else if (mode === 'oversize') res.end(' '.repeat(16385));
      else if (mode === 'redirect') res.writeHead(302, { location: 'http://example.invalid/private' }).end();
      else if (mode === 'abort') res.destroy();
      else res.end('{');
    });
    await hint(f, { port, pid: process.pid });
    f.deps.nativeCodex = async () => { throw Error('secret config/key contents'); };
    const started = performance.now();
    const actual = await implementation.startChat(f.options, f.deps);
    const elapsed = performance.now() - started;
    assert.match(actual.error, /Codex/);
    assert.doesNotMatch(actual.error, /secret|config\/key/);
    assert.ok(elapsed < 1600, `HTTP took ${elapsed}ms`);
    if (mode === 'hang' || mode === 'trickle') assert.ok(elapsed >= 850);
    t.diagnostic(`${mode} ${Math.round(elapsed)}ms`);
  });
}

for (const source of [
  'process.exit(7);',
  `throw Error('secret-key-config');`,
  `await import('node:fs/promises').then(fs => fs.writeFile(process.env.ASEPRITE_CHAT_READY_FILE, '{'));`,
  `await import('node:fs/promises').then(fs => fs.writeFile(process.env.ASEPRITE_CHAT_READY_FILE, JSON.stringify({error:'secret-key-config'})));`,
  `await import('node:fs/promises').then(fs => fs.writeFile(process.env.ASEPRITE_CHAT_READY_FILE, JSON.stringify({endpoint:'ws://example.invalid:4500'})));`
]) {
  test(`owned child failure is safe: ${source.slice(0, 45)}`, async t => {
    const f = await fixture(t, source);
    const actual = await implementation.startChat(f.options, f.deps);
    assert.equal(typeof actual.error, 'string');
    assert.match(actual.error, /启动/);
    assert.doesNotMatch(actual.error, /secret|example|config/);
    assert.deepEqual(await result(f), actual);
  });
}

test('valid-looking owned readiness must match the child PID, not a foreign idle service', async t => {
  const foreign = await healthServer(t);
  const f = await fixture(t, `
    await import('node:fs/promises').then(fs => fs.writeFile(process.env.ASEPRITE_CHAT_READY_FILE,
      JSON.stringify({endpoint:${JSON.stringify(`ws://127.0.0.1:${foreign}`)}})));
    setTimeout(() => {}, 10000);
  `);
  f.deps.startupTimeoutMs = 250;
  const actual = await implementation.startChat(f.options, f.deps);
  assert.ok(actual.error);
  assert.equal(foreign > 0, true);
});

test('accepted but never-ready owned child times out without publishing success', async t => {
  const f = await fixture(t, 'setTimeout(() => {}, 10000);');
  f.deps.startupTimeoutMs = 250;
  const started = performance.now();
  const actual = await implementation.startChat(f.options, f.deps);
  assert.match(actual.error, /超时/);
  assert.ok(performance.now() - started < 1000);
  assert.deepEqual(await result(f), actual);
});

test('asynchronous spawn errors publish safe failure without unhandled errors', async t => {
  const f = await fixture(t);
  f.deps.spawn = (command, args, settings) => spawn(path.join(f.directory, 'missing.exe'), args, settings);
  const actual = await implementation.startChat(f.options, f.deps);
  assert.match(actual.error, /启动/);
  assert.doesNotMatch(actual.error, /missing|ENOENT/);
  assert.deepEqual(await result(f), actual);
});

test('rejects old Node and non-native executable seams safely', async t => {
  for (const override of [ { nodeVersion: '22.0.0' },
    { nativeCodex: async () => 'relative.exe' },
    { nativeCodex: async () => path.join(os.tmpdir(), 'not-installed.exe') },
    { nativeCodex: async () => path.join(os.tmpdir(), 'codex.cmd') } ]) {
    const f = await fixture(t);
    const actual = await implementation.startChat(f.options, { ...f.deps, ...override });
    assert.ok(actual.error);
    assert.equal(f.calls.length, 0);
  }
});

test('invalid extension roots publish safe errors before reuse or spawn', async t => {
  for (const invalid of ['relative', '\0', path.join(os.tmpdir(), 'missing-extension')]) {
    const f = await fixture(t);
    const actual = await implementation.startChat({ ...f.options, extensionRoot: invalid }, f.deps);
    assert.match(actual.error, /扩展/);
    assert.equal(f.calls.length, 0);
  }
  const f = await fixture(t);
  await writeFile(path.join(f.options.extensionRoot, 'package.json'), '{"name":"foreign"}');
  assert.match((await implementation.startChat(f.options, f.deps)).error, /扩展/);
});

test('invalid or occupied result paths reject safely without overwriting any file', async t => {
  const f = await fixture(t);
  const occupied = path.join(f.directory, 'occupied.json');
  await writeFile(occupied, 'keep original');
  for (const resultPath of ['relative.json', '\0', f.directory, occupied,
    path.join(f.directory, 'missing-parent', 'result.json')]) {
    await assert.rejects(implementation.startChat({ ...f.options, resultPath }, f.deps), /结果/);
  }
  assert.equal(await readFile(occupied, 'utf8'), 'keep original');
  assert.equal(f.calls.length, 0);
});

test('temporary import entry survives slow startup, awaits result, unlinks itself, then exits while bridge stays reusable', async t => {
  const f = await fixture(t, `
    await import('node:fs/promises').then(fs => fs.writeFile(${JSON.stringify('ENV_REPORT')}, process.env.CODEX_CLI));
    await new Promise(resolve => setTimeout(resolve, 500));
    process.argv[1] = ${JSON.stringify(realServer)};
    await import(${JSON.stringify(pathToFileURL(realServer).href)});
  `);
  const envReport = path.join(f.directory, 'native-path.txt');
  const serverPath = path.join(f.options.extensionRoot, 'scripts/server.mjs');
  await writeFile(serverPath, (await readFile(serverPath, 'utf8')).replace('ENV_REPORT', envReport.replaceAll('\\', '\\\\')));
  const local = path.join(f.directory, 'local');
  const bin = path.join(f.directory, "原生 ' %PATH% bin");
  await mkdir(bin);
  const native = path.join(bin, process.platform === 'win32' ? 'codex.exe' : 'codex');
  if (process.platform === 'win32') await writeFile(native, 'This is a lookup fixture and must never execute.');
  else {
    const { copyFile, chmod } = await import('node:fs/promises');
    await copyFile(process.execPath, native);
    await chmod(native, 0o700);
  }
  const entry = `${f.options.resultPath}.mjs`;
  await writeFile(entry, `
    import { startChat } from ${JSON.stringify(new URL('../scripts/start-chat.mjs', import.meta.url).href)};
    import { unlink } from 'node:fs/promises';
    import { fileURLToPath } from 'node:url';
    try { await startChat(${JSON.stringify(f.options)}, {conventionalPort:0}); }
    finally { await unlink(fileURLToPath(import.meta.url)); }
  `);
  const started = performance.now();
  const child = spawn(process.execPath, [entry], { shell: false, windowsHide: true, stdio: 'ignore',
    env: { ...process.env, PATH: bin, LOCALAPPDATA: local,
      APPDATA: path.join(f.directory, 'roaming'), CODEX_HOME: path.join(f.directory, 'home') } });
  f.children.push(child);
  const exited = once(child, 'exit');
  await once(child, 'spawn');
  const acceptance = performance.now() - started;
  await delay(80);
  assert.equal((await stat(entry)).isFile(), true);
  await assert.rejects(stat(f.options.resultPath), { code: 'ENOENT' });
  let timer;
  try {
    assert.deepEqual(await Promise.race([exited, new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(Error('owned bootstrap did not exit')), 5000);
    })]), [0, null]);
  } finally { clearTimeout(timer); }
  const descriptor = JSON.parse(await readFile(path.join(local, 'AsepriteChat', 'bridge.json'), 'utf8'));
  f.ownedPids.push(descriptor.pid);
  await assert.rejects(stat(entry), { code: 'ENOENT' });
  assert.equal(await readFile(envReport, 'utf8'), native);
  const actual = await result(f);
  assert.deepEqual(actual, { endpoint: descriptor.endpoint, pid: descriptor.pid });
  const again = await implementation.startChat({ ...f.options, resultPath: path.join(f.directory, 'again.json') }, {
    ...f.deps, discoveryPath: path.join(local, 'AsepriteChat', 'bridge.json'),
    nativeCodex: () => assert.fail('bridge must outlive temporary entry and be reusable')
  });
  assert.deepEqual(again, actual);
  t.diagnostic(`entry spawn accepted ${Math.round(acceptance)}ms; ready and entry exit ${Math.round(performance.now() - started)}ms`);
});

for (const layout of ['path', 'desktop', 'npm-wrapper', 'npm-appdata', 'missing']) {
  test(`shared native resolver uses disposable Windows ${layout} layout without executing wrappers or native CLI`, { skip: process.platform !== 'win32' }, async t => {
    const f = await fixture(t);
    const bin = path.join(f.directory, 'bin');
    const local = path.join(f.directory, 'local');
    const roaming = path.join(f.directory, 'roaming');
    await mkdir(bin);
    const architecture = process.arch === 'arm64' ? 'arm64' : 'x64';
    const triple = architecture === 'arm64' ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc';
    let native;
    if (layout === 'path') native = path.join(bin, 'codex.exe');
    if (layout === 'desktop') native = path.join(local, 'Programs/OpenAI/Codex/bin/codex.exe');
    if (layout.startsWith('npm-')) {
      const npm = layout === 'npm-wrapper' ? bin : path.join(roaming, 'npm');
      await mkdir(npm, { recursive: true });
      await writeFile(path.join(npm, 'codex.cmd'), '@echo must never execute');
      native = path.join(npm, `node_modules/@openai/codex/node_modules/@openai/codex-win32-${architecture}/vendor/${triple}/bin/codex.exe`);
    }
    if (native) {
      await mkdir(path.dirname(native), { recursive: true });
      await writeFile(native, 'must never execute');
    }
    const script = `
      const {nativeCodex} = await import(${JSON.stringify(new URL('../scripts/register-mcp.mjs', import.meta.url).href)});
      try { console.log(JSON.stringify({path:await nativeCodex()})); }
      catch (error) { console.log(JSON.stringify({error:error.message})); }
    `;
    const child = spawn(process.execPath, ['--input-type=module', '-e', script], { shell: false, windowsHide: true,
      env: { ...process.env, PATH: bin, LOCALAPPDATA: local, APPDATA: roaming }, stdio: ['ignore', 'pipe', 'pipe'] });
    f.children.push(child);
    let output = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { output += chunk; });
    assert.deepEqual(await once(child, 'exit'), [0, null]);
    const actual = JSON.parse(output);
    if (native) assert.deepEqual(actual, { path: native });
    else assert.match(actual.error, /未找到原生 Codex/);
  });
}

for (const content of ['{', 'null', JSON.stringify({ pid: '123', port: 4500 }), ' '.repeat(16385)]) {
  test(`malformed or oversized discovery cannot block conventional idle reuse (${content.length} bytes)`, async t => {
    const f = await fixture(t);
    await mkdir(path.dirname(f.discoveryPath), { recursive: true });
    await writeFile(f.discoveryPath, content);
    f.deps.conventionalPort = await healthServer(t);
    f.deps.nativeCodex = () => assert.fail('fallback must reuse');
    assert.deepEqual(await implementation.startChat(f.options, f.deps), { endpoint: `ws://127.0.0.1:${f.deps.conventionalPort}`, pid: process.pid });
  });
}

test('concurrent result publication is preserved and rejected safely', async t => {
  const f = await fixture(t, 'setTimeout(() => process.exit(7), 250);');
  const pending = implementation.startChat(f.options, f.deps);
  const rejected = assert.rejects(pending, /结果/);
  await delay(80);
  await writeFile(f.options.resultPath, 'concurrent owner');
  await rejected;
  assert.equal(await readFile(f.options.resultPath, 'utf8'), 'concurrent owner');
  assert.equal((await readdir(f.directory)).some(name => name.endsWith('.tmp') || name.endsWith('.ready')), false);
});
