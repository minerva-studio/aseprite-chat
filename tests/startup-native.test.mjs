import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, stat, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import WebSocket from 'ws';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test('native Chat launch reaches a real isolated app-server without PowerShell', {skip:process.platform!=='win32',timeout:30000},async t=>{
  const directory=await mkdtemp(path.join(os.tmpdir(),'aseprite-chat-native-start-'));
  const runtime=path.join(directory,"插件 ' % & $() !");
  const output=path.join(directory,'output');
  const home=path.join(directory,'home');
  const local=path.join(directory,'local');
  const discovery=path.join(directory,'discovery.json');
  const owned=path.join(directory,'owned.json');
  const job=path.join(directory,'job.json');
  for(const folder of [path.join(runtime,'scripts'),output,home,local]) await mkdir(folder,{recursive:true});
  const codex=path.join(process.env.LOCALAPPDATA,'Programs/OpenAI/Codex/bin/codex.exe');
  const aseprite=process.env.ASEPRITE_EXE??'D:/SteamLibrary/steamapps/common/Aseprite/aseprite.exe';
  let child,socket,bridgePid,endpoint,probeTask;
  const probes=new Set();
  t.after(async()=>{
    if(socket){const closed=once(socket,'close').catch(()=>{});socket.close();await Promise.race([closed,wait(2000)]);}
    for(const probe of probes)probe.terminate();
    if(endpoint){
      const deadline=Date.now()+2000;
      while(Date.now()<deadline){
        try{const health=await (await fetch(endpoint.replace('ws:','http:')+'/readyz',{signal:AbortSignal.timeout(500)})).json();if(!health.busy)break;}catch{break;}
        await wait(20);
      }
    }
    if(child?.exitCode===null){const exited=once(child,'exit').catch(()=>{});child.kill();await Promise.race([exited,wait(2000)]);}
    // The fixture records this PID at its own spawn boundary, never by scanning.
    const recorded=JSON.parse(await readFile(owned,'utf8').catch(()=>'null'));
    bridgePid=recorded?.pid;
    if(Number.isSafeInteger(bridgePid)&&bridgePid>0){
      try{process.kill(bridgePid);}catch(error){if(error.code!=='ESRCH')throw error;}
      const deadline=Date.now()+3000;
      while(Date.now()<deadline){try{process.kill(bridgePid,0);}catch(error){if(error.code==='ESRCH')break;throw error;}await wait(20);}
      assert.throws(()=>process.kill(bridgePid,0),{code:'ESRCH'});
    }
    assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));
    assert.match(path.basename(directory),/^aseprite-chat-native-start-/);
    await rm(directory,{recursive:true,force:true,maxRetries:20,retryDelay:100});
  });
  await writeFile(path.join(runtime,'package.json'),'{"name":"aseprite-chat"}');
  await writeFile(job,JSON.stringify({runtime}));
  const realServer=path.join(root,'scripts/server.mjs');
  await writeFile(path.join(runtime,'scripts/server.mjs'),`process.argv[1]=${JSON.stringify(realServer)};await import(${JSON.stringify(pathToFileURL(realServer).href)});`);
  const diagnostic=path.join(output,'fixture-error.txt');
  await writeFile(path.join(runtime,'scripts/start-chat.mjs'),`import {spawn} from 'node:child_process';import {writeFileSync} from 'node:fs';
    export const startChat=async options=>{try{const {startChat:start}=await import(${JSON.stringify(pathToFileURL(path.join(root,'scripts/start-chat.mjs')).href)});
      return await start(options,{discoveryPath:${JSON.stringify(discovery)},conventionalPort:0,nativeCodex:async()=>${JSON.stringify(codex)},
      spawn:(command,args,settings)=>{const child=spawn(command,args,settings);writeFileSync(${JSON.stringify(owned)},JSON.stringify({pid:child.pid}));return child;}});
    }catch(error){writeFileSync(${JSON.stringify(diagnostic)},String(error.stack));throw error;}};`);
  child=spawn(aseprite,['--batch','--script',path.join(root,'tests/startup-native.lua')],{windowsHide:true,
    env:{...process.env,CODEX_HOME:home,LOCALAPPDATA:local,ASEPRITE_CHAT_ACCOUNT_FILE:path.join(local,'providers.json'),
      ASEPRITE_CHAT_STARTUP_SOURCE:root,ASEPRITE_CHAT_STARTUP_JOB:job,ASEPRITE_CHAT_STARTUP_OUTPUT:output},stdio:['pipe','pipe','pipe']});
  let log='',buffer='',adapterError;
  child.stdout.on('data',bytes=>{
    log+=bytes;buffer+=bytes;
    let newline;
    while((newline=buffer.indexOf('\n'))!==-1){
      const line=buffer.slice(0,newline).trim();buffer=buffer.slice(newline+1);
      if(!line.startsWith('startup-probe: '))continue;
      probeTask=(async()=>{
        const {url}=JSON.parse(line.slice('startup-probe: '.length));
        const probe=new WebSocket(url,{origin:url});probes.add(probe);
        const message=once(probe,'message');await once(probe,'open');
        const wire=(await message)[0].toString();child.stdin.write(wire+'\n');
        probe.close();probes.delete(probe);
      })().catch(error=>{adapterError=error;child.kill();});
    }
  });child.stderr.on('data',bytes=>log+=bytes);
  const [code]=await once(child,'exit');log+=await readFile(diagnostic,'utf8').catch(()=>'');
  await probeTask;if(adapterError)throw adapterError;
  assert.equal(code,0,log);assert.match(log,/startup-native: passed/,log);
  const native=JSON.parse(await readFile(path.join(output,'result.json'),'utf8'));endpoint=native.endpoint;
  assert.equal(native.executions,1,'cold plus warm opening must launch one bootstrap total');
  const before=await stat(path.join(output,'before')),after=await stat(path.join(output,'after'));
  t.diagnostic(`Aseprite os.execute shell-return interval: ${Math.round(after.mtimeMs-before.mtimeMs)} ms; GUI responsiveness not measured`);
  socket=new WebSocket(endpoint);await once(socket,'open');
  const reply=once(socket,'message');
  socket.send(JSON.stringify({id:'native-start',method:'initialize',params:{clientInfo:{name:'aseprite_startup_test',version:'1.0.0'},capabilities:{experimentalApi:true}}}));
  const message=JSON.parse((await reply)[0].toString());
  assert.equal(message.id,'native-start');assert.equal(message.error,undefined,JSON.stringify(message));assert.ok(message.result);
});
