import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, chmod, symlink, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { nativeCodex } from '../scripts/register-mcp.mjs';
import { launchFor } from '../scripts/server.mjs';

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'aseprite-linux-node-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  await mkdir(bin);
  return { root, bin, env: { PATH: bin } };
}

async function elf(file, arch = 'x64', mode = 0o700) {
  const bytes = Buffer.alloc(64);
  bytes.set([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  bytes.writeUInt16LE(arch === 'arm64' ? 183 : 62, 18);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, bytes, { mode });
  await chmod(file, mode);
  return file;
}

for (const arch of ['x64', 'arm64']) {
  test(`Linux native resolver selects executable ${arch} ELF on PATH without running it`, async t => {
    const f = await fixture(t);
    const executable = await elf(path.join(f.bin, 'codex'), arch);
    assert.equal(await nativeCodex({ env: f.env, platform: 'linux', arch }), executable);
  });

  for (const layout of ['nested', 'hoisted', 'vendor', 'global-prefix']) {
    test(`Linux ${arch} npm ${layout} wrapper is only a location hint`, async t => {
      const f = await fixture(t);
      await writeFile(path.join(f.bin, 'codex'), '#!/bin/sh\nexit 88\n');
      const packageRoot = path.join(f.root, layout === 'global-prefix' ? 'lib/node_modules/@openai/codex' : 'bin/node_modules/@openai/codex');
      const triple = arch === 'arm64' ? 'aarch64-unknown-linux-musl' : 'x86_64-unknown-linux-musl';
      const vendor = layout === 'nested' ? path.join(packageRoot, `node_modules/@openai/codex-linux-${arch}/vendor`)
        : layout === 'hoisted' ? path.join(packageRoot, `../codex-linux-${arch}/vendor`) : path.join(packageRoot, 'vendor');
      const executable = await elf(path.join(vendor, triple, 'bin/codex'), arch);
      assert.equal(await nativeCodex({ env: f.env, platform: 'linux', arch }), executable);
    });
  }
}

test('Linux npm symlink resolves its package before finding the native platform dependency', async t => {
  const f = await fixture(t);
  const packageRoot = path.join(f.root, 'separate-prefix/lib/node_modules/@openai/codex');
  await mkdir(path.join(packageRoot, 'bin'), { recursive: true });
  const entry = path.join(packageRoot, 'bin/codex.js');
  await writeFile(entry, '#!/usr/bin/env node\nprocess.exit(88);');
  try { await symlink(entry, path.join(f.bin, 'codex'), 'file'); }
  catch (error) { if (process.platform === 'win32' && error.code === 'EPERM') return t.skip('Windows symlink privilege unavailable'); throw error; }
  const executable = await elf(path.join(packageRoot, '../codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex'));
  assert.equal(await nativeCodex({ env: f.env, platform: 'linux', arch: 'x64' }), executable);
});

for (const content of ['#!/bin/sh\nexit 88', '#!/usr/bin/env node\nprocess.exit(88)', '\u007fELF', 'MZ executable']) {
  test(`Linux rejects a non-native PATH wrapper (${JSON.stringify(content)})`, async t => {
    const f = await fixture(t);
    await writeFile(path.join(f.bin, 'codex'), content, { mode: 0o700 });
    await assert.rejects(nativeCodex({ env: f.env, platform: 'linux', arch: 'x64' }), /未找到原生 Codex/);
  });
}

test('Linux rejects another architecture instead of selecting an incompatible native binary', async t => {
  const f = await fixture(t);
  await elf(path.join(f.bin, 'codex'), 'arm64');
  await assert.rejects(nativeCodex({ env: f.env, platform: 'linux', arch: 'x64' }), /未找到原生 Codex/);
});

test('Linux rejects a nonexecutable ELF file', { skip: process.platform === 'win32' }, async t => {
  const f = await fixture(t);
  await elf(path.join(f.bin, 'codex'), 'x64', 0o600);
  await assert.rejects(nativeCodex({ env: f.env, platform: 'linux', arch: 'x64' }), /未找到原生 Codex/);
});

test('Linux ignores relative PATH entries even if they contain a native binary', async t => {
  const f = await fixture(t);
  await elf(path.join(f.bin, 'codex'));
  await assert.rejects(nativeCodex({ env: { PATH: path.relative(process.cwd(), f.bin) }, platform: 'linux', arch: 'x64' }), /未找到原生 Codex/);
});

for (const access of ['read', 'workspace', 'full']) {
  test(`Linux ${access} access preserves native sandbox settings without Windows overrides`, () => {
    const home = path.resolve('owned-test-home');
    const account = { mode: 'custom', codexHome: home, workspace: home, access };
    const plan = launchFor(account, {}, 'linux');
    assert.equal(plan.args.some(arg => arg.startsWith('windows.sandbox=')), false);
    assert.equal(plan.env.CODEX_HOME, home);
    assert.equal(plan.args.includes('features.shell_tool=false'), false);
    assert.equal(launchFor(account, {}, 'win32').args.includes('windows.sandbox="unelevated"'), true);
  });
}
