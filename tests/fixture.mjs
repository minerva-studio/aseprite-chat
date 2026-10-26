// A real WebSocket peer for the Lua plugin, with deterministic agent/tool events.
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const port = Number(process.env.ASEPRITE_CHAT_FIXTURE_PORT || 4517);
fs.mkdirSync('work', { recursive: true });
const log = fs.createWriteStream('work/fixture.jsonl');
let active = null;
let turnNumber = 0;
const pending = new Map();
function frame(socket, opcode, bytes) {
  const body = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
  let header;
  if (body.length < 126) header = Buffer.from([0x80 | opcode, body.length]);
  else if (body.length < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(body.length, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(body.length), 2); }
  if (!socket.destroyed) socket.write(Buffer.concat([header, body]));
}
const server = http.createServer((req, res) => { res.writeHead(200); res.end('ready'); });
server.on('upgrade', (req, socket, head) => {
  log.write(JSON.stringify({ event: 'handshake', origin: req.headers.origin, host: req.headers.host }) + '\n');
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  let buffer = head, fragments = [];
  const send = message => frame(socket, 1, JSON.stringify(message));
  const notify = (method, params) => send({ method, params });
  const result = (id, value) => send({ id, result: value });
  const complete = () => {
    if (!active) return;
    const id = active.id;
    notify('item/completed', { threadId: 'fixture-thread', turnId: id, item: { id: id + '-msg', type: 'agentMessage', text: 'Fixture completed.' } });
    notify('turn/completed', { threadId: 'fixture-thread', turn: { id, status: 'completed', items: [], error: null } });
    active = null;
  };
  const call = (tool, args, callback) => {
    const id = active.id + '-' + tool;
    pending.set(id, callback);
    send({ id, method: 'item/tool/call', params: { threadId: 'fixture-thread', turnId: active.id, callId: id, tool, arguments: args } });
  };
  const readThenEdit = label => call('view_sprite', {}, response => {
    if (!response.success) throw Error('read failed: ' + JSON.stringify(response));
    const metadata = JSON.parse(response.contentItems.find(x => x.type === 'inputText').text);
    const preview = response.contentItems.find(x => x.type === 'inputImage');
    if (!preview?.imageUrl.startsWith('data:image/png;base64,')) throw Error('missing PNG preview');
    fs.writeFileSync('work/fixture-preview.png', Buffer.from(preview.imageUrl.split(',')[1], 'base64'));
    call('execute_lua', { summary: label, expectedRevision: metadata.revision,
      code: 'local cel = sprite.cels[1]\nlocal image = cel.image:clone()\nimage:drawPixel(1, 1, app.pixelColor.rgba(0,255,0,255))\ncel.image = image\nreturn "edited"' }, edit => {
      log.write(JSON.stringify({ event: 'edit', label, success: edit.success }) + '\n');
      complete();
    });
  });
  const receive = msg => {
    log.write(JSON.stringify({ method: msg.method, id: msg.id, success: msg.result?.success }) + '\n');
    if (!msg.method) { const cb = pending.get(msg.id); pending.delete(msg.id); if (cb) cb(msg.result); return; }
    if (msg.method === 'initialize') result(msg.id, { userAgent: 'aseprite-chat-fixture' });
    else if (msg.method === 'initialized') {}
    else if (msg.method === 'model/list') result(msg.id, {data:[
      {id:'fixture-a',model:'fixture-model-a',displayName:'Fixture A',isDefault:true,defaultReasoningEffort:'high',
        supportedReasoningEfforts:[{reasoningEffort:'low',description:'Quick'},{reasoningEffort:'high',description:'Deep'}]},
      {id:'fixture-b',model:'fixture-model-b',displayName:'Fixture B',isDefault:false,defaultReasoningEffort:'medium',
        supportedReasoningEfforts:[{reasoningEffort:'medium',description:'Balanced'}]}
    ],nextCursor:null});
    else if (msg.method === 'thread/start') result(msg.id, { thread: { id: 'fixture-thread', status: { type: 'idle' }, turns: [] } });
    else if (msg.method === 'thread/resume') result(msg.id, { thread: { id: 'fixture-thread', status: { type: active ? 'active' : 'idle', activeFlags: [] }, turns: [] } });
    else if (msg.method === 'thread/turns/list') result(msg.id, { data: active ? [{ id: active.id, status: 'inProgress', items: [] }] : [], nextCursor: null });
    else if (msg.method === 'turn/start') {
      const label = msg.params.input.filter(x => x.type === 'text').map(x => x.text).join('\n');
      active = { id: 'fixture-turn-' + (++turnNumber), label };
      result(msg.id, { turn: { id: active.id, status: 'inProgress', items: [], error: null } });
      notify('turn/started', { threadId: 'fixture-thread', turn: { id: active.id, status: 'inProgress', items: [] } });
      notify('item/agentMessage/delta', { threadId: 'fixture-thread', turnId: active.id, itemId: active.id + '-msg', delta: 'Hello 你好 — streaming.' });
      if (label.includes('fixture-break')) setTimeout(() => socket.destroy(), 100);
      else if (label.includes('fixture-stream-stop')) {}
      else readThenEdit(label);
    } else if (msg.method === 'turn/interrupt') {
      result(msg.id, {});
      if (active) {
        const old = active;
        notify('turn/completed', { threadId: 'fixture-thread', turn: { id: old.id, status: 'interrupted', items: [], error: null } });
        active = null;
        send({ id: old.id + '-late', method: 'item/tool/call', params: { threadId: 'fixture-thread', turnId: old.id, callId: 'late', tool: 'execute_lua', arguments: { summary: 'Late edit', expectedRevision: 1, code: 'error("must not execute")' } } });
      }
    } else result(msg.id, {});
  };
  function drain() {
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 15, fin = (buffer[0] & 128) !== 0, masked = (buffer[1] & 128) !== 0;
      let length = buffer[1] & 127, offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      if (length > 32 * 1024 * 1024) { socket.destroy(); return; }
      const mask = masked ? buffer.subarray(offset, offset + 4) : null;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      const body = Buffer.from(buffer.subarray(offset, offset + length));
      buffer = buffer.subarray(offset + length);
      if (masked) for (let n = 0; n < body.length; n++) body[n] ^= mask[n % 4];
      if (opcode === 8) { frame(socket, 8, body); socket.end(); return; }
      if (opcode === 9) { frame(socket, 10, body); continue; }
      if (opcode !== 0 && opcode !== 1) continue;
      fragments.push(body);
      if (fin) {
        const text = Buffer.concat(fragments).toString(); fragments = [];
        try { receive(JSON.parse(text)); }
        catch (error) { console.error(error); log.write(JSON.stringify({ error: error.message }) + '\n'); socket.destroy(); }
      }
    }
  }
  socket.on('data', bytes => { buffer = Buffer.concat([buffer, bytes]); drain(); });
  socket.on('error', error => log.write(JSON.stringify({ socketError: error.message }) + '\n'));
  drain();
});
server.listen(port, '127.0.0.1', () => console.log('fixture ready ' + port));
