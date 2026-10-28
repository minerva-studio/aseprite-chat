import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, access, readFile, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import WebSocket from 'ws';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const aseprite=process.env.ASEPRITE_EXE ?? 'D:/SteamLibrary/steamapps/common/Aseprite/aseprite.exe';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(predicate) {
  for(let i=0;i<150;i++) {if(await predicate()) return; await pause(20);}
  throw Error('Timed out waiting for native fixture');
}

test('SDK stdio tools control a persistent native Aseprite document with PNG GIF sheet and Undo', {timeout:30000},async t=>{
  assert.equal((await readFile(path.join(root,'tests/mcp-native.lua'),'utf8')).length>0,true);
  const home=await mkdtemp(path.join(os.tmpdir(),'aseprite-mcp-native-'));
  const canonicalHome=await realpath(home);
  let descriptor;
  t.after(async()=>{
    if (descriptor?.home===canonicalHome && descriptor.pid!==process.pid) {
      try {process.kill(descriptor.pid);} catch(error) {if(error.code!=='ESRCH') throw error;}
      await until(()=>{try{process.kill(descriptor.pid,0);return false;}catch{return true;}});
    }
    await rm(home,{recursive:true,force:true});
  });
  const native=spawn(aseprite,['--batch','--script-param',`mcpHome=${home}`,'--script',path.join(root,'tests/mcp-native.lua')],
    {cwd:root,windowsHide:true,stdio:['pipe','pipe','pipe']});
  let output='',ready=false,attached=false;
  const lines=createInterface({input:native.stdout});
  native.stderr.on('data',bytes=>{output+=bytes;});
  let editor;
  lines.on('line',line=>{
    output+=line+'\n';
    if(line==='NATIVE_MCP_READY') ready=true;
    if(line==='NATIVE_MCP_ATTACHED') attached=true;
    if(line.startsWith('NATIVE_MCP_RESULT ')) editor.send(line.slice('NATIVE_MCP_RESULT '.length));
  });
  t.after(async()=>{
    if(native.exitCode===null) {
      native.stdin.end('{"type":"fixture_shutdown"}\n');
      await Promise.race([once(native,'exit'),pause(3000)]);
      if(native.exitCode===null) {native.kill(); await once(native,'exit');}
    }
    lines.close(); editor?.terminate();
  });
  await until(()=>ready || (native.exitCode!==null && assert.fail(output)));
  const transport=new StdioClientTransport({command:process.execPath,
    args:[path.join(root,'scripts/mcp-server.mjs'),'--home',home],stderr:'pipe'});
  const client=new Client({name:'native-acceptance',version:'1.0.0'});
  t.after(()=>client.close()); await client.connect(transport);
  const catalog=await client.listTools(); assert.equal(catalog.tools.length,7);
  const descriptorPath=path.join(home,'.aseprite-chat/mcp-bridge.json');
  await assert.rejects(access(descriptorPath),{code:'ENOENT'});
  const first=client.callTool({name:'list_sprites',arguments:{}});
  first.catch(()=>{});
  await until(async()=>{
    try {descriptor=JSON.parse(await readFile(descriptorPath,'utf8'));return true;}catch{return false;}
  });
  native.stdin.write('{"type":"fixture_discover"}\n');
  await until(()=>attached || (native.exitCode!==null && assert.fail(output)));
  editor=new WebSocket(descriptor.endpoint);
  await once(editor,'open');
  editor.on('message',data=>native.stdin.write(data.toString()+'\n'));
  const listed=await first;
  assert.equal(listed.isError,false);
  const sprites=JSON.parse(listed.content[0].text).sprites;
  assert.equal(sprites.items.length,1);
  const inspected=await client.callTool({name:'inspect_sprite',arguments:{sections:['layers']}});
  assert.equal(inspected.isError,false);
  const structure=JSON.parse(inspected.content[0].text);
  assert.equal(structure.layers.items.length,1);
  assert.equal(structure.palette,undefined);
  const read=await client.callTool({name:'view_sprite',arguments:{}});
  assert.equal(read.isError,false); assert.equal(read.content[1].type,'image');
  assert.equal(read.content[1].mimeType,'image/png');
  const metadata=JSON.parse(read.content[0].text);
  assert.equal(metadata.palette,undefined); assert.equal(metadata.layers,undefined);
  assert.equal(metadata.frames,undefined); assert.equal(metadata.openSprites,undefined);
  const edit=await client.callTool({name:'execute_lua',arguments:{summary:'Native fixture rename',
    code:"sprite.layers[1].name='MCP Native'; return sprite.layers[1].name",expectedRevision:metadata.revision}});
  assert.equal(edit.isError,false); assert.equal(JSON.parse(edit.content[0].text).result,'MCP Native');
  const paths=[];
  for(const args of [{frame:1},{frames:[1,2],format:'gif'},
    {frames:[2,1,2],output:'sheet',columns:2,padding:1,metadata:true}]) {
    const exported=await client.callTool({name:'export_sprite',arguments:args});
    assert.equal(exported.isError,false,JSON.stringify(exported));
    const data=JSON.parse(exported.content[0].text);
    for(const file of data.files) {await access(file.path); paths.push(file.path);}
  }
  await client.close();
  await until(async()=>{for(const file of paths) {try{await access(file); return false;}catch{}} return true;});
  const exited=once(native,'exit'); native.stdin.end('{"type":"fixture_shutdown"}\n');
  const [code]=await exited; assert.equal(code,0,output);
  assert.match(output,/native-mcp: passed; one Undo restored source/);
});
