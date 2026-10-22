// Opt-in live account tests (NOT part of npm test).
//   node tests/live-account.mjs                custom account -> local mock Responses provider
//   node tests/live-account.mjs --default-live one real turn against the user's default Codex home
import http from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createBridge } from '../scripts/server.mjs';

const defaultLive = process.argv.includes('--default-live');
const codex = process.env.CODEX_CLI || path.join(process.env.LOCALAPPDATA, 'Programs/OpenAI/Codex/bin/codex.exe');
const fakeKey = 'sk-live-account-' + Math.random().toString(36).slice(2);
const report = { mode: defaultLive ? 'default' : 'custom', requests: [], rpc: [], failures: [] };
const check = (name, condition, detail) => {
  if (condition) console.log('PASS ' + name);
  else { report.failures.push(name); console.log('FAIL ' + name + (detail ? ' :: ' + JSON.stringify(detail) : '')); }
};

const sse = (res, events) => {
  res.writeHead(200, { 'Content-Type': 'text/event-stream' });
  for (const event of events) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  res.end();
};
let responseCount = 0;
const mock = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let parsed = null; try { parsed = JSON.parse(body); } catch {}
    report.requests.push({ method: req.method, url: req.url,
      authIsBearerFakeKey: req.headers.authorization === `Bearer ${fakeKey}`,
      model: parsed?.model,
      toolNames: parsed?.tools?.map(t => t.name ?? t.namespace ?? t.type) });
    if (!req.url.endsWith('/responses')) { res.writeHead(404); res.end(); return; }
    responseCount++;
    const id = `resp_${responseCount}`;
    const hasToolOutput = parsed?.input?.some(i => i.type === 'function_call_output');
    const readTool = parsed?.tools?.find(t => JSON.stringify(t).includes('read_sprite'));
    const created = { type: 'response.created', response: { id } };
    const completed = { type: 'response.completed', response: { id, usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } };
    if (!hasToolOutput && readTool) {
      const call = { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: readTool.name, arguments: '{}' };
      sse(res, [created, { type: 'response.output_item.added', output_index: 0, item: call },
        { type: 'response.output_item.done', output_index: 0, item: call }, completed]);
      return;
    }
    const msg = { type: 'message', id: 'msg_1', role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text: 'account-ok', annotations: [] }] };
    sse(res, [created, { type: 'response.output_item.added', output_index: 0, item: { ...msg, content: [] } },
      { type: 'response.output_text.delta', item_id: 'msg_1', output_index: 0, content_index: 0, delta: 'account-ok' },
      { type: 'response.output_item.done', output_index: 0, item: msg }, completed]);
  });
});

const directory = await mkdtemp(path.join(os.tmpdir(), 'aseprite-chat-live-'));
const accountFile = path.join(directory, 'providers.json');
let account;
if (defaultLive) {
  account = { version: 1, mode: 'default', codexHome: directory, baseUrl: '', apiKey: '', models: [] };
} else {
  await new Promise(r => mock.listen(0, '127.0.0.1', r));
  account = { version: 1, mode: 'custom', codexHome: path.join(directory, 'codex-home'),
    baseUrl: `http://127.0.0.1:${mock.address().port}/v1`, apiKey: fakeKey, models: [] };
}
await writeFile(accountFile, JSON.stringify(account));

const bridge = await createBridge({ port: 0, command: codex, accountFile });
const socket = new WebSocket(`ws://127.0.0.1:${bridge.port}`, { origin: `ws://127.0.0.1:${bridge.port}` });
let nextId = 0, agentText = '', turnDone = null, threadId = null;
const pending = new Map();
const notifications = [];
socket.on('message', raw => {
  const m = JSON.parse(raw.toString());
  if (m.id !== undefined && m.method) {
    if (m.method === 'item/tool/call') {
      socket.send(JSON.stringify({ id: m.id, result: { success: true, contentItems: [{ type: 'inputText', text: '{"live":true}' }] } }));
    } else {
      socket.send(JSON.stringify({ id: m.id, error: { code: -32601, message: 'unsupported' } }));
    }
    return;
  }
  if (m.id !== undefined) {
    const p = pending.get(m.id); pending.delete(m.id);
    report.rpc.push({ method: p?.method, result: m.result, error: m.error });
    p?.resolve(m);
    return;
  }
  notifications.push(m.method);
  if (m.method === 'item/agentMessage/delta') agentText += m.params?.delta ?? '';
  if (m.method === 'turn/completed') turnDone?.(m.params?.turn);
});
const request = (method, params) => new Promise(resolve => {
  const id = ++nextId; pending.set(id, { method, resolve });
  socket.send(JSON.stringify({ id, method, params }));
});

try {
  await once(socket, 'open');
  const init = await request('initialize', { clientInfo: { name: 'aseprite_chat', title: 'Aseprite Chat', version: 'live-account' },
    capabilities: { experimentalApi: true } });
  check('initialize', !init.error, init.error);
  socket.send(JSON.stringify({ method: 'initialized' }));

  let model = 'probe-model', effort;
  if (defaultLive) {
    const catalog = await request('model/list', { limit: 100, includeHidden: false });
    const entries = catalog.result?.data ?? [];
    const pick = entries.find(e => e.isDefault) ?? entries[0];
    model = pick?.model;
    effort = pick?.supportedReasoningEfforts?.some(e => e.reasoningEffort === 'low')
      ? 'low' : pick?.defaultReasoningEffort;
    check('default catalog picked a model', !!model, catalog.error ?? entries.length);
    console.log(`default-live model=${model} effort=${effort}`);
  }

  const tools = [{ type: 'function', name: 'read_sprite', description: 'Inspect the live sprite',
    inputSchema: { type: 'object', properties: {}, required: [], additionalProperties: false } }];
  const started = await request('thread/start', { dynamicTools: tools, model,
    developerInstructions: 'Reply concisely.', sandbox: 'read-only', approvalPolicy: 'on-request',
    approvalsReviewer: 'user', allowProviderModelFallback: false });
  check('thread/start', !started.error && started.result?.thread?.id, started.error);
  threadId = started.result?.thread?.id;
  if (!defaultLive) {
    check('custom provider is active', started.result?.thread?.modelProvider === 'aseprite_custom',
      started.result?.thread?.modelProvider);
  }

  const done = new Promise(resolve => { turnDone = resolve; });
  const turn = await request('turn/start', { threadId, model, effort,
    input: [{ type: 'text', text: defaultLive ? 'Reply with exactly: ok'
      : 'Call read_sprite, then reply with exactly account-ok.' }] });
  check('turn/start accepted', !turn.error, turn.error);
  const finished = await Promise.race([done, new Promise(r => setTimeout(() => r('timeout'), defaultLive ? 120000 : 60000))]);
  check('turn completed', finished?.status === 'completed', finished?.status ?? finished);
  check('agent message arrived', agentText.length > 0 || notifications.includes('item/completed'),
    agentText);

  const listed = await request('thread/list', { limit: 10, useStateDbOnly: true,
    sourceKinds: ['cli', 'vscode', 'appServer'] });
  const row = (listed.result?.data ?? []).find(t => t.id === threadId);
  check('thread/list shows the aseprite_chat thread', row?.originator === 'aseprite_chat', row ?? listed.error);
  if (defaultLive) console.log('default-live thread=' + threadId + ' reply=' + agentText);

  if (!defaultLive) {
    const calls = report.requests.filter(r => r.url.endsWith('/responses'));
    check('mock saw POST /responses', calls.length >= 1, report.requests);
    check('mock saw the Bearer key', calls.every(r => r.authIsBearerFakeKey));
    const names = new Set((calls[0]?.toolNames ?? []));
    check('request tools include read_sprite', names.has('read_sprite'), [...names]);
    for (const banned of ['exec_command', 'write_stdin', 'view_image', 'web_search', 'namespace']) {
      check(`request tools exclude ${banned}`, !names.has(banned) && ![...names].some(n => String(n).includes(banned)), [...names]);
    }
    check('tool round trip reached the model', calls.length >= 2, calls.length);
  }
} finally {
  socket.terminate();
  await bridge.close();
  mock.close();
  await rm(directory, { recursive: true, force: true }).catch(() => {});
  if (report.failures.length) {
    console.log('FAILURES: ' + report.failures.join(', '));
    process.exitCode = 1;
  } else console.log('live-account: all checks passed');
}
