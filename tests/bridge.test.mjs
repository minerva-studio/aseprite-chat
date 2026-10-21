import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { createBridge } from '../scripts/server.mjs';

const fixture = fileURLToPath(new URL('./stdio-fixture.mjs', import.meta.url));
async function setup(t, overrides = {}) {
  const bridge = await createBridge({ port: 0, command: process.execPath, args: [fixture], ...overrides });
  t.after(() => bridge.close());
  return { bridge, url: `ws://127.0.0.1:${bridge.port}` };
}
async function connect(t, url, options) {
  const socket = new WebSocket(url, options);
  t.after(() => socket.terminate());
  await once(socket, 'open');
  return socket;
}
function rejected(url, options) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.on('unexpected-response', (req, response) => {
      response.resume(); socket.terminate(); resolve(response.statusCode);
    });
    socket.on('error', () => {});
    socket.on('open', () => { socket.terminate(); reject(Error('unexpectedly accepted handshake')); });
  });
}
test('native Aseprite Origin reaches stdio with Unicode and exact request IDs', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url, { origin: url });
  const reply = once(socket, 'message');
  socket.send(JSON.stringify({ id: 'native-id', method: 'initialize', params: { text: '你好' } }));
  const response = JSON.parse((await reply)[0].toString());
  assert.equal(response.id, 'native-id');
  assert.equal(response.result.received.params.text, '你好');
});
test('browser, null, foreign origins, fetch headers and foreign Host are rejected', async t => {
  const { url } = await setup(t);
  for (const origin of ['https://example.com', 'http://127.0.0.1:4500', 'null', 'ws://example.com']) {
    assert.equal(await rejected(url, { origin }), 403);
  }
  assert.equal(await rejected(url, { headers: { 'Sec-Fetch-Site': 'cross-site' } }), 403);
  assert.equal(await rejected(url, { headers: { Host: 'evil.example' } }), 403);
});
test('a second client cannot share the first client Codex process', async t => {
  const { url } = await setup(t);
  await connect(t, url);
  assert.equal(await rejected(url), 409);
});
test('reconnection gets a new stdio process and no prior message replay', async t => {
  const { url } = await setup(t);
  const first = await connect(t, url);
  let response = once(first, 'message'); first.send('{"id":1,"method":"first"}');
  const firstPid = JSON.parse((await response)[0]).result.pid;
  const closed = once(first, 'close'); first.close(); await closed;
  const second = await connect(t, url);
  response = once(second, 'message'); second.send('{"id":2,"method":"second"}');
  const value = JSON.parse((await response)[0]);
  assert.equal(value.id, 2); assert.notEqual(value.result.pid, firstPid);
});
test('binary and multiple-JSON frames never reach the backend', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url);
  const closed = once(socket, 'close'); socket.send('{"id":1}\n{"id":2}');
  assert.equal((await closed)[0], 1007);
  const next = await connect(t, url);
  const binaryClosed = once(next, 'close'); next.send(Buffer.from('binary'));
  assert.equal((await binaryClosed)[0], 1003);
});
test('process startup failure closes the client instead of hanging', async t => {
  const { url } = await setup(t, { command: 'aseprite-chat-nonexistent-executable' });
  const socket = new WebSocket(url); t.after(() => socket.terminate());
  const closed = once(socket, 'close'); await once(socket, 'open');
  assert.equal((await closed)[0], 1011);
});
test('one formatted JSON frame becomes one stdio line without changing large integer IDs', async t => {
  const { url } = await setup(t);
  const socket = await connect(t, url);
  const outcome = Promise.race([
    once(socket, 'message').then(([bytes]) => ({ text: bytes.toString() })),
    once(socket, 'close').then(([code]) => ({ code }))
  ]);
  socket.send('{\n  "id": 9007199254740993,\n  "method": "formatted",\n  "params": {"code": "a\\nb"}\n}');
  const value = await outcome;
  assert.equal(value.code, undefined, 'valid formatted JSON closed the backend');
  assert.equal(JSON.parse(value.text).result.received.params.code, 'a\nb');
  assert.match(JSON.parse(value.text).result.raw, /"id": 9007199254740993/);
});
test('synchronous spawn failure closes one client and leaves the bridge healthy', { timeout: 1500 }, async t => {
  const { bridge, url } = await setup(t, { command: '\0invalid-executable' });
  const socket = new WebSocket(url); t.after(() => socket.terminate());
  const closed = once(socket, 'close'); await once(socket, 'open');
  assert.equal((await closed)[0], 1011);
  const status = await new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${bridge.port}/readyz`, response => {
      response.resume(); resolve(response.statusCode);
    }).on('error', reject);
  });
  assert.equal(status, 200);
});
