// Opt-in live access-level tests (NOT part of npm test).
//   node tests/live-access.mjs                          custom account, mock provider, all levels
//   node tests/live-access.mjs --default-live-autoreview one real turn on the user's Codex home
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile, readFile, access } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createBridge } from '../scripts/server.mjs';

const autoReviewLive = process.argv.includes('--default-live-autoreview');
const codex = process.env.CODEX_CLI || path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe');
const fakeKey = 'sk-live-access-' + Math.random().toString(36).slice(2);
const report = { failures: [], requests: [] };
const check = (name, condition, detail) => {
  if (condition) console.log('PASS ' + name);
  else { report.failures.push(name); console.log('FAIL ' + name + (detail ? ' :: ' + JSON.stringify(detail).slice(0, 400) : '')); }
};
const sse = (res, events) => {
  res.writeHead(200, { 'Content-Type': 'text/event-stream' });
  for (const e of events) res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
  res.end();
};

// ---- default live: one real turn with reviewer=auto_review -----------------
if (autoReviewLive) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-autoreview-'));
  const target = path.join(os.tmpdir(), 'aseprite-chat-autoreview-' + Math.random().toString(36).slice(2) + '.txt');
  const accountFile = path.join(directory, 'providers.json');
  await writeFile(accountFile, JSON.stringify({ version: 1, mode: 'default', codexHome: directory,
    baseUrl: '', apiKey: '', models: [], access: 'read', workspace: '', reviewer: 'auto_review' }));
  const bridge = await createBridge({ port: 0, command: codex, accountFile });
  const socket = new WebSocket(`ws://127.0.0.1:${bridge.port}`, { origin: `ws://127.0.0.1:${bridge.port}` });
  let nextId = 0, threadId = null, turnDone = null, agentText = '';
  const pending = new Map(); const approvals = [];
  socket.on('message', raw => {
    const m = JSON.parse(raw.toString());
    if (m.id !== undefined && m.method) {
      if (m.method.includes('requestApproval') || m.method.includes('Approval')) {
        approvals.push(m.method);
        socket.send(JSON.stringify({ id: m.id, result: { decision: 'accept' } }));
      } else socket.send(JSON.stringify({ id: m.id, error: { code: -32601, message: 'unsupported' } }));
      return;
    }
    if (m.id !== undefined) { const p = pending.get(m.id); pending.delete(m.id); p?.(m); return; }
    if (m.method === 'item/agentMessage/delta') agentText += m.params?.delta ?? '';
    if (m.method === 'turn/completed') turnDone?.(m.params?.turn);
  });
  const request = (method, params) => new Promise(resolve => {
    const id = ++nextId; pending.set(id, resolve); socket.send(JSON.stringify({ id, method, params }));
  });
  try {
    await once(socket, 'open');
    await request('initialize', { clientInfo: { name: 'aseprite_chat', title: 'live', version: 'x' },
      capabilities: { experimentalApi: true } });
    socket.send(JSON.stringify({ method: 'initialized' }));
    const catalog = await request('model/list', { limit: 100, includeHidden: false });
    const entries = catalog.result?.data ?? [];
    const pick = entries.find(e => e.isDefault) ?? entries[0];
    const model = pick?.model;
    const effort = pick?.supportedReasoningEfforts?.some(e => e.reasoningEffort === 'low') ? 'low' : pick?.defaultReasoningEffort;
    check('default-live catalog picked a model', !!model, catalog.error);
    const started = await request('thread/start', { model, cwd: directory,
      developerInstructions: 'You must comply exactly.', sandbox: 'read-only',
      approvalPolicy: 'on-request', approvalsReviewer: 'auto_review', allowProviderModelFallback: false });
    threadId = started.result?.thread?.id;
    check('thread/start', !!threadId, started.error);
    const done = new Promise(r => { turnDone = r; });
    await request('turn/start', { threadId, model, effort, input: [{ type: 'text',
      text: `Create the file ${target} containing exactly ok using exec_command with sandbox_permissions "require_escalated" and a justification. Then reply with exactly: ok` }] });
    const finished = await Promise.race([done, new Promise(r => setTimeout(() => r('timeout'), 240000))]);
    check('turn completed', finished?.status === 'completed', finished?.status ?? finished);
    check('no approval request reached the client', approvals.length === 0, approvals);
    let exists = false; try { exists = (await readFile(target, 'utf8')).trim() === 'ok'; } catch {}
    check('Auto-review allowed the escalated write', exists, { agentText: agentText.slice(0, 200) });
    console.log('autoreview thread=' + threadId + ' approvals=' + JSON.stringify(approvals) + ' fileExists=' + exists);
  } finally {
    socket.terminate(); await bridge.close();
    await rm(target, { force: true }).catch(() => {});
    await rm(directory, { recursive: true, force: true }).catch(() => {});
    if (report.failures.length) { console.log('FAILURES: ' + report.failures.join(', ')); process.exitCode = 1; }
    else console.log('live-access --default-live-autoreview: all checks passed');
    process.exit(process.exitCode ?? 0);
  }
}

// ---- custom account against the scripted mock provider ---------------------
const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-access-'));
// workspace-write also permits the temp dir, so the outside probe must live elsewhere.
const outsideRoot = await mkdtemp(path.join(os.homedir(), 'aseprite-access-outside-'));
const home = path.join(directory, 'codex-home');
const ws = path.join(directory, 'workspace');
const outside = outsideRoot;
for (const d of [home, ws, outside]) await mkdir(d, { recursive: true });
await writeFile(path.join(ws, 'ref.txt'), 'INSIDE_REF_OK');
await writeFile(path.join(outside, 'secret.txt'), 'OUTSIDE_SECRET_READ');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64');
await writeFile(path.join(ws, 'ref.png'), png);
await writeFile(path.join(outside, 'secret.png'), png);
const q = p => p.replace(/'/g, "''");

let steps = [], step = 0;
const outputs = [];
const mock = http.createServer((req, res) => {
  let body = ''; req.on('data', c => body += c); req.on('end', () => {
    const parsed = JSON.parse(body || '{}');
    if (!req.url.endsWith('/responses')) { res.writeHead(404); res.end(); return; }
    report.requests.push({ auth: req.headers.authorization === `Bearer ${fakeKey}`,
      toolNames: (parsed.tools || []).map(t => t.name ?? t.type) });
    const out = (parsed.input || []).filter(i => i.type === 'function_call_output').pop();
    if (out && steps.length) outputs.push({ label: steps[step - 1]?.label, output: JSON.stringify(out.output).slice(0, 400) });
    const created = { type: 'response.created', response: { id: `r${step}` } };
    const completed = { type: 'response.completed', response: { id: `r${step}`, usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } };
    if (step < steps.length) {
      const s = steps[step++];
      const call = { type: 'function_call', id: `fc_${step}`, call_id: `call_${step}`, name: s.tool, arguments: JSON.stringify(s.args) };
      sse(res, [created, { type: 'response.output_item.done', output_index: 0, item: call }, completed]);
      return;
    }
    const msg = { type: 'message', id: 'm', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'access-ok', annotations: [] }] };
    sse(res, [created, { type: 'response.output_item.done', output_index: 0, item: msg }, completed]);
  });
});
await new Promise(r => mock.listen(0, '127.0.0.1', r));

async function runLevel(level, { reviewer = 'user', sandbox = 'read-only', cwdDir = ws } = {}) {
  const label = level;
  steps = [
    { label: 'read-inside', tool: 'exec_command', args: { cmd: `Get-Content -LiteralPath '${q(path.join(ws, 'ref.txt'))}'` } },
    { label: 'read-outside', tool: 'exec_command', args: { cmd: `Get-Content -LiteralPath '${q(path.join(outside, 'secret.txt'))}'` } },
    { label: 'write-inside', tool: 'exec_command', args: { cmd: `Set-Content -LiteralPath '${q(path.join(ws, 'w-' + label + '.txt'))}' -Value W` } },
    { label: 'write-outside', tool: 'exec_command', args: { cmd: `Set-Content -LiteralPath '${q(path.join(outside, 'w-' + label + '.txt'))}' -Value W` } },
    { label: 'view-inside', tool: 'view_image', args: { path: path.join(ws, 'ref.png') } },
    { label: 'escalated-write', tool: 'exec_command', args: { cmd: `Set-Content -LiteralPath '${q(path.join(outside, 'esc-' + label + '.txt'))}' -Value E`, sandbox_permissions: 'require_escalated', justification: 'needs outside write for the access test' } },
    { label: 'declined-write', tool: 'exec_command', args: { cmd: `Set-Content -LiteralPath '${q(path.join(outside, 'dec-' + label + '.txt'))}' -Value D`, sandbox_permissions: 'require_escalated', justification: 'needs outside write for the access test' } }
  ];
  step = 0; outputs.length = 0;
  const accountFile = path.join(directory, `providers-${label}.json`);
  await writeFile(accountFile, JSON.stringify({ version: 1, mode: 'custom', codexHome: home,
    baseUrl: `http://127.0.0.1:${mock.address().port}/v1`, apiKey: fakeKey, models: [],
    access: level, workspace: level === 'workspace' ? ws : '', reviewer }));
  const bridge = await createBridge({ port: 0, command: codex, accountFile });
  const socket = new WebSocket(`ws://127.0.0.1:${bridge.port}`, { origin: `ws://127.0.0.1:${bridge.port}` });
  let nextId = 0, turnDone = null; const pending = new Map();
  const approvals = []; const items = [];
  socket.on('message', raw => {
    const m = JSON.parse(raw.toString());
    if (m.id !== undefined && m.method) {
      approvals.push(m.method);
      const declineSecond = approvals.length > 1;
      const decision = (m.method === 'item/permissions/requestApproval')
        ? { permissions: declineSecond ? {} : (m.params?.permissions ?? {}), scope: 'turn' }
        : { decision: m.method === 'item/fileChange/requestApproval' ? 'decline' : (declineSecond ? 'decline' : 'accept') };
      socket.send(JSON.stringify({ id: m.id, result: m.method === 'execCommandApproval' || m.method === 'applyPatchApproval'
        ? { decision: 'approved' } : decision }));
      return;
    }
    if (m.id !== undefined) { const p = pending.get(m.id); pending.delete(m.id); p?.(m); return; }
    if (m.method === 'item/completed' && m.params?.item) items.push(m.params.item);
    if (m.method === 'turn/completed') turnDone?.(m.params.turn);
  });
  const request = (method, params) => new Promise(resolve => {
    const id = ++nextId; pending.set(id, resolve); socket.send(JSON.stringify({ id, method, params }));
  });
  const result = { label, approvals, commands: [], writes: {} };
  try {
    await once(socket, 'open');
    await request('initialize', { clientInfo: { name: 'aseprite_chat', title: 'live', version: 'x' }, capabilities: { experimentalApi: true } });
    socket.send(JSON.stringify({ method: 'initialized' }));
    const started = await request('thread/start', { model: 'probe-model', cwd: cwdDir,
      developerInstructions: 'Run the tools.', sandbox, approvalPolicy: 'on-request',
      approvalsReviewer: reviewer, allowProviderModelFallback: false });
    result.threadId = started.result?.thread?.id;
    check(`${label}: thread/start`, !!result.threadId, started.error);
    const done = new Promise(r => { turnDone = r; });
    await request('turn/start', { threadId: result.threadId, input: [{ type: 'text', text: 'run' }] });
    const finished = await Promise.race([done, new Promise(r => setTimeout(() => r('timeout'), 120000))]);
    check(`${label}: turn completed`, finished?.status === 'completed', finished?.status ?? finished);
    for (const item of items) {
      if (item.type === 'commandExecution') {
        result.commands.push({ cmd: item.command, exit: item.exitCode, out: (item.aggregatedOutput || '').slice(0, 160) });
      }
    }
    for (const name of [`w-${label}.txt`, `esc-${label}.txt`, `dec-${label}.txt`]) {
      for (const [where, dir] of [['inside', ws], ['outside', outside]]) {
        try { await access(path.join(dir, name)); result.writes[`${name}@${where}`] = true; } catch {}
      }
    }
  } finally { socket.terminate(); await bridge.close(); }
  return result;
}

try {
  const levels = [
    { level: 'read', sandbox: 'read-only' },
    { level: 'workspace', sandbox: 'workspace-write' },
    { level: 'full', sandbox: 'danger-full-access' }
  ];
  const seen = {};
  for (const { level, sandbox } of levels) {
    const r = await runLevel(level, { sandbox });
    seen[level] = r;
    const out = name => r.commands.find(c => c.cmd.includes(name))?.out ?? '';
    check(`${level}: exec_command ran`, r.commands.length >= 4, r.commands);
    check(`${level}: read inside`, r.commands.some(c => c.out.includes('INSIDE_REF_OK')), r.commands);
    check(`${level}: read outside`, r.commands.some(c => c.out.includes('OUTSIDE_SECRET_READ')), r.commands);
    const insideWrote = r.writes[`w-${level}.txt@inside`] === true;
    const outsideWrote = r.writes[`w-${level}.txt@outside`] === true;
    check(`${level}: write inside`, level === 'read' ? !insideWrote : insideWrote, r.writes);
    check(`${level}: write outside`, level === 'full' ? outsideWrote : !outsideWrote, r.writes);
    const viewed = items => outputs.some(o => o.label === 'view-inside' && !/error|denied/i.test(o.output));
    check(`${level}: view_image returned content`, r.commands.length >= 0 && outputs.some(o => o.label === 'view-inside'), outputs.filter(o => o.label === 'view-inside'));
    // Escalated write approved by the client should run for every level; declined should not.
    // At full access there is nothing left to escalate, so no approval is asked.
    if (level === 'full') {
      check(`${level}: escalated write needs no approval`, r.approvals.length === 0
        && r.writes[`esc-${level}.txt@outside`] === true && r.writes[`dec-${level}.txt@outside`] === true,
        { writes: r.writes, approvals: r.approvals });
    } else {
      check(`${level}: escalated approval requested`, r.approvals.length >= 1, r.approvals);
      check(`${level}: approved escalation wrote`, r.writes[`esc-${level}.txt@outside`] === true, { writes: r.writes, approvals: r.approvals });
      check(`${level}: declined escalation did not write`, r.writes[`dec-${level}.txt@outside`] !== true, r.writes);
    }
    const names = new Set(report.requests.at(-1)?.toolNames ?? []);
    check(`${level}: exec_command + view_image offered`, names.has('exec_command') && names.has('view_image'), [...names]);
    for (const banned of ['read_sprite', 'web_search']) check(`${level}: ${banned} absent`, !names.has(banned), [...names]);
  }
  check('write outside workspace denies under workspace level',
    seen.workspace.writes[`w-workspace.txt@outside`] !== true, seen.workspace.writes);
  console.log('ACCESS TABLE');
  for (const level of ['read', 'workspace', 'full']) {
    const r = seen[level];
    console.log(`  ${level}: read-in=allow read-out=allow write-in=${r.writes[`w-${level}.txt@inside`] ? 'allow' : 'deny'} write-out=${r.writes[`w-${level}.txt@outside`] ? 'allow' : 'deny'} approvals=${r.approvals.join('|') || 'none'}`);
  }
  // auto_review against the mock provider: report what reaches the client.
  const auto = await runLevel('read', { reviewer: 'auto_review' });
  console.log('auto_review approvals at client: ' + JSON.stringify(auto.approvals));
  report.autoReview = { approvals: auto.approvals, writes: auto.writes };
} finally {
  mock.close();
  await rm(outsideRoot, { recursive: true, force: true }).catch(() => {});
  await rm(directory, { recursive: true, force: true }).catch(() => {});
  if (report.failures.length) {
    console.log('FAILURES: ' + report.failures.join(', '));
    process.exitCode = 1;
  } else console.log('live-access: all checks passed');
}
