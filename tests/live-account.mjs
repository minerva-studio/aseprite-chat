// Opt-in live account tests (NOT part of npm test).
//   node tests/live-account.mjs                custom account -> local mock Responses provider
//   node tests/live-account.mjs --reasoning    also verify readable reasoning events/history (mock only)
//   node tests/live-account.mjs --questions    verify built-in questions/answers (mock only)
//   node tests/live-account.mjs --default-live one real turn against the user's default Codex home
import http from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import WebSocket from 'ws';
import { createBridge } from '../scripts/server.mjs';

const defaultLive = process.argv.includes('--default-live');
const reasoningProbe = process.argv.includes('--reasoning');
const questionProbe = process.argv.includes('--questions');
if (defaultLive && (reasoningProbe || questionProbe)) throw Error('Protocol probes use only the local mock provider');
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
      toolOutput: questionProbe ? parsed?.input?.filter(i => i.type === 'function_call_output') : undefined,
      toolNames: parsed?.tools?.map(t => t.name ?? t.namespace ?? t.type) });
    if (!req.url.endsWith('/responses')) { res.writeHead(404); res.end(); return; }
    responseCount++;
    const id = `resp_${responseCount}`;
    const hasToolOutput = parsed?.input?.some(i => i.type === 'function_call_output');
    const readTool = parsed?.tools?.find(t => JSON.stringify(t).includes('read_sprite'));
    const questionTool = parsed?.tools?.find(t => t.name === 'request_user_input');
    const created = { type: 'response.created', response: { id } };
    const completed = { type: 'response.completed', response: { id, usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } };
    if (!hasToolOutput && (questionProbe ? questionTool : readTool)) {
      const args = questionProbe ? { questions: [{ id: 'color', header: 'Color', question: 'Which highlight?',
        isOther: true, options: [{ label: 'Blue', description: 'Cool highlights' }, { label: 'Gold', description: 'Warm highlights' }] }], isBlocking: true } : {};
      const call = { type: 'function_call', id: 'fc_1', call_id: 'call_1',
        name: questionProbe ? questionTool.name : readTool.name, arguments: JSON.stringify(args) };
      sse(res, [created, { type: 'response.output_item.added', output_index: 0, item: call },
        { type: 'response.output_item.done', output_index: 0, item: call }, completed]);
      return;
    }
    const msg = { type: 'message', id: 'msg_1', role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text: 'account-ok', annotations: [] }] };
    const thoughts = { type: 'reasoning', id: 'thoughts_1', summary: [],
      content: [{ type: 'reasoning_text', text: 'Mock provider thoughts.' }] };
    const prefix = reasoningProbe ? [
      { type: 'response.output_item.added', output_index: 1, item: { ...thoughts, content: [] } },
      { type: 'response.reasoning_text.delta', item_id: thoughts.id, output_index: 1, content_index: 0, delta: 'Mock provider thoughts.' },
      { type: 'response.output_item.done', output_index: 1, item: thoughts }
    ] : [];
    sse(res, [created, ...prefix, { type: 'response.output_item.added', output_index: 0, item: { ...msg, content: [] } },
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
const questions = [];
const pending = new Map();
const notifications = [];
const reasoningDeltas = [], reasoningItems = [];
socket.on('message', raw => {
  const m = JSON.parse(raw.toString());
  if (m.id !== undefined && m.method) {
    if (m.method === 'item/tool/requestUserInput' && questionProbe) {
      questions.push(m.params);
      socket.send(JSON.stringify({ id: m.id, result: { answers: { color: { answers: ['Gold', 'Note: Keep the outline'] } } } }));
    } else if (m.method === 'item/tool/call') {
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
  if (m.method === 'item/reasoning/textDelta') reasoningDeltas.push(m.params);
  if (m.method === 'item/completed' && m.params?.item?.type === 'reasoning') reasoningItems.push(m.params.item);
  if (m.method === 'item/agentMessage/delta') agentText += m.params?.delta ?? '';
  if (m.method === 'turn/completed') turnDone?.(m.params?.turn);
});
const request = (method, params) => new Promise((resolve,reject) => {
  const id = ++nextId;
  const timeout = setTimeout(() => { pending.delete(id); reject(Error(method + ' timed out')); }, 15000);
  pending.set(id, { method, resolve: value => { clearTimeout(timeout); resolve(value); } });
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
    config: { 'features.default_mode_request_user_input': true },
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
  let turnTimeout;
  const finished = await Promise.race([done, new Promise(r => { turnTimeout = setTimeout(() => r('timeout'), defaultLive ? 120000 : 60000); })]);
  clearTimeout(turnTimeout);
  check('turn completed', finished?.status === 'completed', finished?.status ?? finished);
  check('agent message arrived', agentText.length > 0 || notifications.includes('item/completed'),
    agentText);
  if (questionProbe) {
    check('real Codex emitted a built-in question', questions.length === 1 && questions[0].questions[0].id === 'color', questions);
    check('answer reached the local mock provider', report.requests.some(r => (JSON.stringify(r.toolOutput) ?? '').includes('Gold')));
    check('supplementary note reached the local mock provider', report.requests.some(r => (JSON.stringify(r.toolOutput) ?? '').includes('Note: Keep the outline')));
    check('server resolved the question', notifications.includes('serverRequest/resolved'));
    // Codex does not persist a resumable rollout until a thread has a turn.
    const resumed = await request('thread/resume', { threadId, excludeTurns: true,
      config: { 'features.default_mode_request_user_input': true },
      sandbox: 'read-only', approvalPolicy: 'on-request', approvalsReviewer: 'user' });
    check('question config accepted on thread/resume', !resumed.error && resumed.result?.thread?.id === threadId, resumed.error);
  }
  if (reasoningProbe) {
    check('raw reasoning delta forwarded by real Codex', reasoningDeltas.some(p => p.contentIndex === 0 && p.delta === 'Mock provider thoughts.'), reasoningDeltas);
    check('completed reasoning content forwarded by real Codex', reasoningItems.some(i => i.content?.includes('Mock provider thoughts.')), reasoningItems);
    const restored = await request('thread/read', { threadId, includeTurns: true });
    const items = restored.result?.thread?.turns?.flatMap(t => t.items) ?? [];
    check('persisted reasoning content restored', items.some(i => i.type === 'reasoning' && i.content?.includes('Mock provider thoughts.')), restored.error ?? items.map(i => i.type));
  }

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
    if (questionProbe) check('request tools include request_user_input', names.has('request_user_input'), [...names]);
    for (const banned of ['exec_command', 'write_stdin', 'view_image', 'web_search', 'namespace',
      'multi_agent', 'get_goal', 'create_goal', 'update_goal']) {
      check(`request tools exclude ${banned}`, !names.has(banned) && ![...names].some(n => String(n).includes(banned)), [...names]);
    }
    check('tool round trip reached the model', calls.length >= 2, calls.length);
  }
} catch (error) {
  report.failures.push(error.message);
  console.error(error);
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
