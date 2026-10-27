-- Linux Connect-only regressions. No real hub, Codex config or login is used.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local passed,total=0,0
local function test(name,body)
  total=total+1
  local ok,err=xpcall(body,debug.traceback)
  if ok then passed=passed+1; print("PASS "..name) else print("FAIL "..name.."\n"..tostring(err)) end
end
local function read(path) local f=assert(io.open(path,"rb")); local text=f:read("*a"); f:close(); return text end
local function write(path,text) local f=assert(io.open(path,"wb")); assert(f:write(text)); assert(f:close()) end
local function module(name,env)
  return assert(loadfile(app.fs.joinPath(root,name),"t",setmetatable(env or {},{__index=_G})))()
end
local posix={config="/\n;\n?\n!\n-\n"}

test("POSIX account defaults are absolute and match the Node bridge fallback",function()
  local vars={HOME="/home/artist"}
  local account=module("account.lua",{os=setmetatable({getenv=function(name) return vars[name] end},{__index=os})})
  assert(account.path()=="/home/artist/AppData/Local/AsepriteChat/providers.json",account.path())
  assert(account.default_home()=="/home/artist/AppData/Local/AsepriteChat/codex-home")
  vars.LOCALAPPDATA="/chosen/data"
  assert(account.path()=="/chosen/data/AsepriteChat/providers.json")
  vars.ASEPRITE_CHAT_ACCOUNT_FILE="/chosen/providers.json"
  assert(account.path()=="/chosen/providers.json")
end)

local function controller(platform)
  local calls={}
  local m=module("mcp.lua",{package=platform or posix,dofile=function(path)
    local name=app.fs.fileName(path)
    if name=="launcher.lua" then return {new=function(options)
      calls[#calls+1]=options
      return {ensure=function() return true end,cancel=function() end}
    end} end
    if name=="chat.lua" then return {new=function() return {dismiss_approval=function() end} end} end
    return dofile(path)
  end}).new{path=root}
  return m,calls
end

test("MCP accepts an absolute POSIX home and connects without registration",function()
  local m,calls=controller()
  assert(m:start("  /home/artist/账户 ' $()  ",false))
  assert(calls[1].parameters.CodexHome=="/home/artist/账户 ' $()")
  assert(calls[1].parameters.ConnectOnly==true)
  m:close()
end)

test("MCP rejects relative homes and unsupported registration without side effects",function()
  local m,calls=controller()
  for _,home in ipairs({"", "relative/home", "~/home", "C:relative", "C:/windows", "\\\\server\\share"}) do assert(not m:start(home,false)) end
  local ok,why=m:start("/home/artist",true)
  assert(not ok and why:find("Connect",1,true),tostring(why))
  assert(#calls==0 and not m.startup and not m.preferences.mcp_home)
  m:close()
end)

test("Windows keeps rejecting POSIX homes before startup",function()
  local m,calls=controller{config="\\"}
  assert(not m:start("/wrong-platform/home",false))
  assert(#calls==0 and not m.preferences.mcp_home)
  assert(m:start("C:\\artist",false))
  m:close()
end)

local function launcher(options,env)
  local h={calls={},commands={},timers={}}
  options=options or {}
  options.path=options.path or root
  options.script="mcp-launch.ps1"
  options.parameters=options.parameters or {CodexHome="/home/artist/账户 ' $()",ConnectOnly=true}
  options.timer_factory=function(spec)
    local timer={spec=spec}; function timer:start() self.running=true end; function timer:stop() self.running=false end
    h.timers[#h.timers+1]=timer; return timer
  end
  options.execute=options.execute or function(command)
    h.commands[#h.commands+1]=command
    if command:sub(1,11)=="umask 077; " then return os.execute(command) end
    return true
  end
  env=env or {}; env.package=posix
  h.instance=module("launcher.lua",env).new(options)
  function h:start() return self.instance:ensure(function(endpoint,err) self.calls[#self.calls+1]={endpoint=endpoint,error=err} end) end
  function h:tick() self.timers[#self.timers].spec.ontick() end
  return h
end

test("POSIX launcher polls authenticated results and retires cancelled attempts",function()
  local h=launcher(); h:start()
  local attempt=assert(h.instance.pending,h.calls[1] and h.calls[1].error)
  assert(#h.commands==2 and not h.commands[2]:find("powershell",1,true))
  write(attempt.result_path,'{"endpoint":"ws://127.0.0.1:45123/editor/test_nonce-123"}')
  h:tick(); assert(h.calls[1].endpoint=="ws://127.0.0.1:45123/editor/test_nonce-123")
  assert(not app.fs.isFile(attempt.command_source_path))
  h:start(); local old=h.instance.pending; h.instance:cancel(); h:tick()
  assert(#h.calls==1 and not app.fs.isFile(old.command_source_path))
  h:start(); local current=h.instance.pending
  write(current.result_path,'{"endpoint":"ws://127.0.0.1:45123/client/not-editor"}')
  h:tick(); assert(h.calls[2].error)
end)

test("missing Node fails without executing a shell",function()
  local env={os=setmetatable({getenv=function() return nil end},{__index=os})}
  local h=launcher(nil,env); h:start()
  assert(#h.commands==0 and not h.instance.pending and h.calls[1].error:find("Node.js",1,true))
end)

test("POSIX launcher never executes unsupported registration",function()
  local h=launcher{parameters={CodexHome="/home/artist",ConnectOnly=false}}
  h:start(); assert(#h.commands==0 and not h.instance.pending and h.calls[1].error)
end)

test("native POSIX Node startup is asynchronous and preserves special path characters",function()
  local directory=app.fs.joinPath(app.fs.tempPath,"mcp 中文 ' % & $() ` ; "..tostring(Uuid()))
  local scripts=app.fs.joinPath(directory,"scripts")
  assert(app.fs.makeAllDirectories(scripts))
  local helper=app.fs.joinPath(scripts,"register-mcp.mjs")
  write(helper,[[import {existsSync,writeFileSync,statSync} from 'node:fs';
import path from 'node:path';
export async function registerMcp(job) {
  if(!job.connectOnly) throw Error('registration must not run');
  if((statSync(path.dirname(job.resultPath)).mode & 0o777)!==0o700) throw Error('startup directory is not private');
  const deadline=Date.now()+5000;
  while(!existsSync(job.resultPath+'.release')) {
    if(Date.now()>deadline) throw Error('release timeout');
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  writeFileSync(job.resultPath+'.job',JSON.stringify(job));
  writeFileSync(job.resultPath,JSON.stringify({endpoint:'ws://127.0.0.1:45123/editor/fixture-token'}));
}
]])
  local home=directory.."/home ' 账户 $()"
  local real_node
  for folder in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    local candidate=app.fs.joinPath(folder,"node")
    if candidate:sub(1,1)=="/" and app.fs.isFile(candidate) then real_node=candidate; break end
  end
  assert(real_node,"Node is required for this native process test")
  local function quoted(value) return "'"..value:gsub("'", "'\"'\"'").."'" end
  local node=app.fs.joinPath(directory,"node")
  assert(os.execute("ln -s "..quoted(real_node).." "..quoted(node)))
  -- Both actual shell operands now contain hostile characters, not only JSON data.
  local fs=setmetatable({tempPath=directory},{__index=app.fs})
  local h=launcher({path=directory,node=node,execute=os.execute,parameters={CodexHome=home,ConnectOnly=true}},
    {app={fs=fs}})
  h:start(); local attempt=assert(h.instance.pending,h.calls[1] and h.calls[1].error)
  assert(not app.fs.isFile(attempt.result_path),"launcher waited for readiness")
  write(attempt.result_path..".release","go")
  local deadline=os.time()+8
  while h.instance.pending and os.time()<deadline do
    local finish=os.clock()+0.02; while os.clock()<finish do end
    h:tick()
  end
  local result=h.calls[1]
  h.instance:cancel()
  assert(result and result.endpoint=="ws://127.0.0.1:45123/editor/fixture-token",result and result.error or "no result")
  local job=json.decode(read(attempt.result_path..".job"))
  assert(job.home==home and job.extensionRoot==directory and job.connectOnly==true)
  for _,file in ipairs({helper,node,attempt.result_path..".release",attempt.result_path..".job"}) do os.remove(file) end
  app.fs.removeDirectory(attempt.private_dir)
  app.fs.removeDirectory(scripts); app.fs.removeDirectory(directory)
end)

print("linux: "..passed.."/"..total.." tests passed")
assert(passed==total,"Linux suite failed")
