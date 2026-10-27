import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, stat, cp } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const implementation = await import('../scripts/register-mcp.mjs').catch(() => ({}));
const endpoint = 'ws://127.0.0.1:45678/editor/secret';
const seed = '# keep this comment\nmodel_provider = "fixture"\n\n[model_providers.fixture]\nname = "Fixture"\nbase_url = "https://example.invalid/v1"\n\n[mcp_servers.unrelated]\ncommand = "unrelated-command"\nargs = ["keep-me"]\n';

async function fixture() {
  await mkdir(path.join(root, 'work'), { recursive: true });
  const directory = await mkdtemp(path.join(root, 'work/mcp-register-test-'));
  const home = path.join(directory, "账户 space ' % & $()", 'home');
  const extensionRoot = path.join(directory, "插件 space ' % & $()");
  await mkdir(home, { recursive: true });
  await mkdir(path.join(extensionRoot, 'scripts'), { recursive: true });
  await writeFile(path.join(extensionRoot, 'package.json'), '{"name":"aseprite-chat"}');
  const resultPath = path.join(directory, 'result.json');
  return { directory, home, extensionRoot, resultPath, codexPath: process.execPath };
}

function owned(options, overrides = {}) {
  return { name: 'aseprite_chat', enabled: true, disabled_reason: null,
    transport: { type: 'stdio', command: process.execPath,
      args: [path.join(options.extensionRoot, 'scripts/mcp-server.mjs'), '--home', options.home],
      env: null, env_vars: [], cwd: null }, enabled_tools: null, disabled_tools: null,
    startup_timeout_sec: null, tool_timeout_sec: null, ...overrides };
}

function boundary(options, initial = [], behavior = {}) {
  const calls = [];
  let entries = initial;
  return { calls, ensureBridge: async parameters => {
    assert.deepEqual(parameters, { home: options.home, extensionRoot: options.extensionRoot });
    if (behavior.ensureError) throw Error('private-key-content');
    return { endpoint, clientEndpoint: 'ws://127.0.0.1:45678/client/private' };
  }, runCodex: async (executable, args, childOptions) => {
    calls.push(args);
    assert.equal(executable, options.codexPath);
    assert.equal(childOptions.env.CODEX_HOME, options.home);
    assert.equal(childOptions.env.PATH, process.env.PATH);
    if (args[1] === 'list') {
      assert.deepEqual(args, ['mcp', 'list', '--json']);
      if (behavior.afterList) await behavior.afterList();
      return JSON.stringify(entries);
    }
    if (args[1] === 'add') {
      assert.deepEqual(args, ['mcp', 'add', 'aseprite_chat', '--', process.execPath,
        path.join(options.extensionRoot, 'scripts/mcp-server.mjs'), '--home', options.home]);
      if (behavior.addError) {
        await writeFile(path.join(options.home, 'config.toml'), 'concurrent change\n');
        throw Error('private-key-content');
      }
      await writeFile(path.join(options.home, 'config.toml'), `${seed}\n# CLI registration\n`);
      entries = [owned(options)];
      return 'Added';
    }
    assert.deepEqual(args, ['mcp', 'get', 'aseprite_chat', '--json']);
    return JSON.stringify(behavior.getValue ?? entries.find(entry => entry.name === 'aseprite_chat'));
  } };
}

test('exports registerMcp', () => assert.equal(typeof implementation.registerMcp, 'function'));

test('backs up bytes, uses native argv and publishes only editor endpoint', async () => {
  const options = await fixture();
  await writeFile(path.join(options.home, 'config.toml'), seed);
  const previousHome = process.env.CODEX_HOME;
  const deps = boundary(options);
  const result = await implementation.registerMcp(options, deps);
  assert.equal(result.endpoint, endpoint);
  assert.equal(result.registered, true);
  assert.match(result.backup, /config-backup-[\da-f-]+\.toml$/);
  assert.equal(await readFile(result.backup, 'utf8'), seed);
  assert.equal((await readFile(path.join(options.home, 'config.toml'), 'utf8')).startsWith(seed), true);
  assert.deepEqual(JSON.parse(await readFile(options.resultPath, 'utf8')), result);
  assert.equal('clientEndpoint' in result, false);
  assert.deepEqual(deps.calls.map(args => args[1]), ['list', 'add', 'get']);
  assert.equal(process.env.CODEX_HOME, previousHome);
  assert.deepEqual((await readdir(options.directory)).filter(name => name.includes('.tmp')), []);
});

test('exact existing registration is idempotent without touching config or making backup', async () => {
  const options = await fixture();
  const config = path.join(options.home, 'config.toml');
  await writeFile(config, seed);
  const before = await stat(config);
  const deps = boundary(options, [owned(options)]);
  const result = await implementation.registerMcp(options, deps);
  assert.deepEqual(result, { endpoint, registered: true });
  assert.deepEqual(deps.calls.map(args => args[1]), ['list', 'get']);
  assert.equal((await stat(config)).mtimeMs, before.mtimeMs);
  assert.equal(await readFile(config, 'utf8'), seed);
  assert.equal((await readdir(options.home)).includes('.aseprite-chat'), false);
});

for (const change of [
  entry => ({ ...entry, transport: { ...entry.transport, command: 'foreign' } }),
  entry => ({ ...entry, transport: { ...entry.transport, args: ['wrong'] } }),
  entry => ({ ...entry, transport: { ...entry.transport, env: { API_KEY: 'private-key-content' } } }),
  entry => ({ ...entry, transport: { ...entry.transport, env_vars: ['API_KEY'] } }),
  entry => ({ ...entry, transport: { ...entry.transport, cwd: 'foreign' } }),
  entry => ({ ...entry, enabled: false }),
]) test('refuses foreign or altered same-name registration without writes', async () => {
  const options = await fixture();
  await writeFile(path.join(options.home, 'config.toml'), seed);
  const deps = boundary(options, [change(owned(options))]);
  const result = await implementation.registerMcp(options, deps);
  assert.match(result.error, /同名|冲突/);
  assert.equal(await readFile(path.join(options.home, 'config.toml'), 'utf8'), seed);
  assert.deepEqual(await readdir(options.home), ['config.toml']);
  assert.deepEqual(deps.calls.map(args => args[1]), ['list']);
  assert.equal(JSON.stringify(result).includes('private-key-content'), false);
});

test('connect-only does not find or invoke Codex or create config', async () => {
  const options = { ...await fixture(), connectOnly: true, codexPath: 'not-an-executable' };
  const deps = boundary(options);
  const result = await implementation.registerMcp(options, deps);
  assert.deepEqual(result, { endpoint, registered: false });
  assert.deepEqual(deps.calls, []);
  assert.deepEqual(await readdir(options.home), []);
});

test('failed add keeps backup and concurrent config changes without blind rollback', async () => {
  const options = await fixture();
  await writeFile(path.join(options.home, 'config.toml'), seed);
  const result = await implementation.registerMcp(options, boundary(options, [], { addError: true }));
  assert.match(result.error, /注册/);
  assert.equal(JSON.stringify(result).includes('private-key-content'), false);
  assert.equal(await readFile(path.join(options.home, 'config.toml'), 'utf8'), 'concurrent change\n');
  const backups = await readdir(path.join(options.home, '.aseprite-chat'));
  assert.equal(backups.length, 1);
  assert.equal(await readFile(path.join(options.home, '.aseprite-chat', backups[0]), 'utf8'), seed);
});

test('refuses stale list when config changed before mutation', async () => {
  const options = await fixture();
  const config = path.join(options.home, 'config.toml');
  await writeFile(config, seed);
  const deps = boundary(options, [], { afterList: () => writeFile(config, 'concurrent change\n') });
  const result = await implementation.registerMcp(options, deps);
  assert.match(result.error, /更改|变化/);
  assert.deepEqual(deps.calls.map(args => args[1]), ['list']);
  assert.equal(await readFile(config, 'utf8'), 'concurrent change\n');
});

test('verifies get command and args before starting bridge', async () => {
  const options = await fixture();
  const deps = boundary(options, [], { getValue: owned(options, { transport: { type: 'stdio', command: 'wrong', args: [] } }) });
  deps.ensureBridge = () => assert.fail('must not start bridge after failed verification');
  const result = await implementation.registerMcp(options, deps);
  assert.match(result.error, /验证/);
  assert.equal('endpoint' in result, false);
});

for (const home of ['', '   ', 'relative/home']) test(`rejects invalid home ${JSON.stringify(home)}`, async () => {
  const options = { ...await fixture(), home };
  const deps = boundary(options);
  const result = await implementation.registerMcp(options, deps);
  assert.match(result.error, /绝对路径/);
  assert.deepEqual(deps.calls, []);
});

test('trims selected home and rejects wrong root identity with safe error', async () => {
  const options = await fixture();
  const result = await implementation.registerMcp({ ...options, home: `  ${options.home}  `, connectOnly: true }, boundary(options));
  assert.equal(result.endpoint, endpoint);
  await writeFile(path.join(options.extensionRoot, 'package.json'), '{"name":"wrong"}');
  const failed = await implementation.registerMcp(options, boundary(options));
  assert.match(failed.error, /扩展/);
});

test('bridge errors publish Chinese safe diagnostics atomically', async () => {
  const options = { ...await fixture(), connectOnly: true };
  await writeFile(options.resultPath, '{"old":true}');
  const result = await implementation.registerMcp(options, boundary(options, [], { ensureError: true }));
  assert.match(result.error, /连接/);
  assert.equal(result.error.includes('private-key-content'), false);
  assert.deepEqual(JSON.parse(await readFile(options.resultPath, 'utf8')), result);
});

for (const source of ['PATH', 'LOCALAPPDATA', 'npm-wrapper']) test(`finds native Windows Codex through ${source} without executing wrappers`, { skip: process.platform !== 'win32' }, async () => {
  const options = await fixture();
  const bin = path.join(options.directory, 'bin');
  const local = path.join(options.directory, 'local');
  const candidate = source === 'PATH' ? path.join(bin, 'codex.exe')
    : source === 'LOCALAPPDATA' ? path.join(local, 'Programs/OpenAI/Codex/bin/codex.exe')
      : path.join(bin, 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe');
  await mkdir(bin, { recursive: true });
  await mkdir(path.dirname(candidate), { recursive: true });
  await writeFile(candidate, 'native executable boundary fixture');
  await writeFile(path.join(bin, 'codex.cmd'), '@echo forbidden-wrapper');
  const previous = { PATH: process.env.PATH, LOCALAPPDATA: process.env.LOCALAPPDATA, APPDATA: process.env.APPDATA };
  try {
    process.env.PATH = bin;
    process.env.LOCALAPPDATA = local;
    process.env.APPDATA = path.join(options.directory, 'appdata');
    const deps = boundary({ ...options, codexPath: candidate });
    const result = await implementation.registerMcp({ ...options, codexPath: undefined }, deps);
    assert.equal(result.error, undefined, result.error);
    assert.equal(result.endpoint, endpoint);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

function run(executable, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, ...options });
    let stdout = '', stderr = '';
    child.stdout?.on('data', chunk => { stdout += chunk; });
    child.stderr?.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
}

test('real native Codex preserves unrelated settings and registers special-character paths idempotently', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const options = await fixture();
  // Explicit native executable injection remains isolated to the selected home.
  options.codexPath = path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe');
  await writeFile(path.join(options.home, 'config.toml'), seed);
  await writeFile(path.join(options.home, 'providers.json'), '{"sentinel":"unchanged"}');
  const deps = { ensureBridge: boundary(options).ensureBridge };
  const result = await implementation.registerMcp(options, deps);
  assert.equal(result.error, undefined, result.error);
  assert.equal(await readFile(result.backup, 'utf8'), seed);
  const config = await readFile(path.join(options.home, 'config.toml'), 'utf8');
  assert.ok(config.startsWith(seed));
  assert.equal(await readFile(path.join(options.home, 'providers.json'), 'utf8'), '{"sentinel":"unchanged"}');
  assert.deepEqual(await implementation.registerMcp(options, deps), { endpoint, registered: true });
  assert.equal(await readFile(path.join(options.home, 'config.toml'), 'utf8'), config);
  assert.equal((await readdir(path.join(options.home, '.aseprite-chat'))).length, 1);
});

test('real native Codex registers a new home directory without an existing config', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const options = await fixture();
  options.home = path.join(options.directory, 'new home', 'not created yet');
  options.codexPath = path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe');
  const deps = { ensureBridge: boundary(options).ensureBridge };
  const result = await implementation.registerMcp(options, deps);
  assert.equal(result.error, undefined, result.error);
  assert.equal(result.registered, true);
  assert.equal(result.backup, undefined);
  assert.match(await readFile(path.join(options.home, 'config.toml'), 'utf8'), /\[mcp_servers\.aseprite_chat\]/);
  assert.deepEqual(await implementation.registerMcp(options, deps), { endpoint, registered: true });
});

test('real native Codex refuses foreign collision without changing config or creating backup', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const options = await fixture();
  delete options.codexPath;
  const config = `${seed}\n[mcp_servers.aseprite_chat]\ncommand = "foreign-command"\nargs = ["private-key-content"]\n`;
  await writeFile(path.join(options.home, 'config.toml'), config);
  const deps = { ensureBridge: () => assert.fail('collision must not start a hub') };
  const result = await implementation.registerMcp(options, deps);
  assert.match(result.error, /同名|冲突/);
  assert.equal(result.error.includes('private-key-content'), false);
  assert.equal(await readFile(path.join(options.home, 'config.toml'), 'utf8'), config);
  assert.equal((await readdir(options.home)).includes('.aseprite-chat'), false);
});

test('PowerShell hidden bootstrap survives Restricted policy and native argument quoting', { skip: process.platform !== 'win32', timeout: 20000 }, async () => {
  const options = await fixture();
  // This fixture executes the actual bootstrap but substitutes only the asynchronous Node helper.
  await cp(path.join(root, 'scripts/mcp-launch.ps1'), path.join(options.extensionRoot, 'scripts/mcp-launch.ps1'));
  await writeFile(path.join(options.extensionRoot, 'scripts/register-mcp.mjs'), `import {writeFileSync,existsSync} from 'node:fs';
const args = process.argv.slice(2); const result = args[args.indexOf('--result') + 1];
const deadline = setTimeout(() => process.exit(2), 10000);
const timer = setInterval(() => { if (existsSync(result + '.release')) {
  clearInterval(timer); clearTimeout(deadline);
  writeFileSync(result, JSON.stringify({args, home:process.env.CODEX_HOME}));
} }, 50);`);
  const before = Date.now();
  const bootstrap = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Restricted', '-Command',
    '$text = [IO.File]::ReadAllText($env:MCP_TEST_SCRIPT); $block = [ScriptBlock]::Create($text); & $block -ResultPath $env:MCP_TEST_RESULT -ExtensionRoot $env:MCP_TEST_ROOT -CodexHome $env:MCP_TEST_HOME -ConnectOnly'],
  { env: { ...process.env, CODEX_HOME: options.home, MCP_TEST_SCRIPT: path.join(options.extensionRoot, 'scripts/mcp-launch.ps1'),
    MCP_TEST_RESULT: options.resultPath, MCP_TEST_ROOT: options.extensionRoot, MCP_TEST_HOME: options.home }, timeout: 12000 });
  assert.equal(bootstrap.code, 0, bootstrap.stderr);
  assert.ok(Date.now() - before < 5000, 'bootstrap must return promptly');
  await writeFile(`${options.resultPath}.release`, 'release helper after bootstrap returned');
  let published;
  for (let i = 0; i < 60; i++) {
    try { published = JSON.parse(await readFile(options.resultPath, 'utf8')); break; }
    catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  assert.deepEqual(published, { args: ['--home', options.home, '--root', options.extensionRoot, '--result', options.resultPath, '--connect-only'], home: options.home });
});

test('real PowerShell to helper to native Codex to hub bootstrap uses selected home only', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const options = await fixture();
  for (const name of ['register-mcp.mjs', 'mcp-launch.ps1', 'mcp-bridge.mjs']) {
    await cp(path.join(root, 'scripts', name), path.join(options.extensionRoot, 'scripts', name));
  }
  await cp(path.join(root, 'tools.json'), path.join(options.extensionRoot, 'tools.json'));
  await writeFile(path.join(options.home, 'config.toml'), seed);
  const bootstrap = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Restricted', '-Command',
    '$block = [ScriptBlock]::Create([IO.File]::ReadAllText($env:MCP_TEST_SCRIPT)); & $block -ResultPath $env:MCP_TEST_RESULT -ExtensionRoot $env:MCP_TEST_ROOT -CodexHome $env:MCP_TEST_HOME'],
  { env: { ...process.env, CODEX_HOME: options.home, MCP_TEST_SCRIPT: path.join(options.extensionRoot, 'scripts/mcp-launch.ps1'),
    MCP_TEST_RESULT: options.resultPath, MCP_TEST_ROOT: options.extensionRoot, MCP_TEST_HOME: options.home }, timeout: 12000 });
  assert.equal(bootstrap.code, 0, bootstrap.stderr);
  let descriptor;
  try {
    let result;
    for (let i = 0; i < 150; i++) {
      try { result = JSON.parse(await readFile(options.resultPath, 'utf8')); break; }
      catch { await new Promise(resolve => setTimeout(resolve, 100)); }
    }
    assert.ok(result, 'helper must publish a result');
    assert.equal(result.error, undefined, result.error);
    assert.equal(result.registered, true);
    descriptor = JSON.parse(await readFile(path.join(options.home, '.aseprite-chat/mcp-bridge.json'), 'utf8'));
    assert.equal(result.endpoint, descriptor.endpoint);
    assert.equal(descriptor.home, options.home);
    assert.equal('clientEndpoint' in result, false);
    assert.equal(await readFile(result.backup, 'utf8'), seed);
    const config = await readFile(path.join(options.home, 'config.toml'), 'utf8');
    assert.ok(config.startsWith(seed));
    assert.ok(config.includes('aseprite_chat'));
    const { default: WebSocket } = await import('ws');
    const editor = new WebSocket(result.endpoint);
    await new Promise((resolve, reject) => { editor.once('open', resolve); editor.once('error', reject); });
    editor.close();
    const connected = await implementation.registerMcp({ ...options, connectOnly: true });
    assert.deepEqual(connected, { endpoint: descriptor.endpoint, registered: false });
    assert.equal(await readFile(path.join(options.home, 'config.toml'), 'utf8'), config);
  } finally {
    // Only the daemon identity from this unique test home is eligible for cleanup.
    if (descriptor?.home === options.home && descriptor.pid !== process.pid) {
      try { process.kill(descriptor.pid); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  }
});
