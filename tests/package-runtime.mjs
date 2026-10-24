// Run the installed MCP entry from an extracted package outside the repository.
// This detects dependencies accidentally resolved from the development checkout.
import assert from 'node:assert/strict';
import { readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const [runtime,home]=process.argv.slice(2);
const client=new Client({name:'packaged-runtime-check',version:'1.0.0'});
const transport=new StdioClientTransport({command:process.execPath,
  args:[path.join(runtime,'scripts/mcp-server.mjs'),'--home',home],stderr:'pipe'});
let descriptor;
try {
  await client.connect(transport);
  descriptor=JSON.parse(await readFile(path.join(home,'.aseprite-chat/mcp-bridge.json'),'utf8'));
  assert.equal(descriptor.home,await realpath(home));
  assert.equal(descriptor.extensionRoot,await realpath(runtime));
  const listed=await client.listTools();
  assert.deepEqual(listed.tools.map(tool=>tool.name),['read_sprite','read_pixels','switch_sprite','execute_lua','export_sprite']);
  const offline=await client.callTool({name:'read_sprite',arguments:{}});
  assert.equal(offline.isError,true);
  assert.match(offline.content[0].text,/Open Aseprite MCP/);
  console.log('PASS isolated packaged MCP runtime initializes and lists all five tools');
  const startup=await import(pathToFileURL(path.join(runtime,'scripts/start-chat.mjs')).href);
  assert.equal(typeof startup.startChat,'function');
  console.log('PASS isolated packaged Chat bootstrap imports its native resolver');
} finally {
  await client.close();
  if(descriptor?.home===await realpath(home) && descriptor.extensionRoot===await realpath(runtime) && descriptor.pid!==process.pid) {
    try {process.kill(descriptor.pid);} catch(error) {if(error.code!=='ESRCH') throw error;}
    for(let i=0;i<100;i++) {
      try {process.kill(descriptor.pid,0);} catch(error) {if(error.code==='ESRCH') break; throw error;}
      await new Promise(resolve=>setTimeout(resolve,20));
      if(i===99) throw Error('Owned package test daemon did not exit');
    }
  }
}
