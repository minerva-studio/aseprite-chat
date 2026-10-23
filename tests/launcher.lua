local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
assert(app.fs.isFile(app.fs.joinPath(root, "launcher.lua")), "automatic launcher is not implemented")
local Launcher = dofile(app.fs.joinPath(root, "launcher.lua"))
local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = {name, fn} end
local function eq(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local paths = {}
local function write(path, text)
  paths[path] = true
  local file = assert(io.open(path, "wb")); file:write(text); file:close()
end
local function harness(execute, timer_factory, module)
  local h = {timers={}, calls={}, commands={}}
  h.launcher = (module or Launcher).new {
    path=root,
    timer_factory=timer_factory or function(spec)
      local timer = {spec=spec, running=false}
      function timer:start() self.running=true end
      function timer:stop() self.running=false end
      function timer:fire() self.spec.ontick() end
      h.timers[#h.timers+1] = timer
      return timer
    end,
    execute=function(command)
      h.commands[#h.commands+1] = command
      h.result_path = assert(h.launcher.pending.result_path)
      paths[h.result_path] = true
      if execute then return execute(h, command) end
      return true, "exit", 0
    end,
  }
  function h:ensure(callback)
    return self.launcher:ensure(callback or function(endpoint, err)
      self.calls[#self.calls+1] = {endpoint=endpoint, error=err}
    end)
  end
  function h:tick(count)
    for _=1,count or 1 do self.timers[#self.timers]:fire() end
  end
  return h
end

test("MCP bootstrap accepts only its authenticated editor endpoint",function()
  local h=harness()
  h.launcher._options.script="mcp-launch.ps1"
  h.launcher._options.parameters={CodexHome="C:\\Codex 中文 ' & $()",ConnectOnly=true}
  h:ensure()
  write(h.result_path,'{"endpoint":"ws://127.0.0.1:45123/editor/test_nonce-123"}')
  h:tick(); eq(h.calls[1].endpoint,"ws://127.0.0.1:45123/editor/test_nonce-123")
  local bad=harness(); bad.launcher._options.script="mcp-launch.ps1"; bad:ensure()
  write(bad.result_path,'{"endpoint":"ws://127.0.0.1:45123/client/secret"}')
  bad:tick(); assert(bad.calls[1].error)
end)

test("one pending attempt completes once and clears its polling timer", function()
  local h = harness()
  h:ensure(); local pending = assert(h.launcher.pending)
  h:ensure(); eq(h.launcher.pending, pending); eq(#h.commands, 1)
  eq(h.timers[1].spec.interval, 0.1)
  write(h.result_path, '{"endpoint":"ws://127.0.0.1:45123"}')
  h:tick(3)
  eq(#h.calls, 1); eq(h.calls[1].endpoint, "ws://127.0.0.1:45123")
  eq(h.calls[1].error, nil); eq(h.launcher.pending, nil)
  eq(h.timers[1].running, false); eq(app.fs.isFile(h.result_path), false)
end)

test("partial JSON is retried rather than mistaken for startup failure", function()
  local h = harness(); h:ensure()
  write(h.result_path, '{"end'); h:tick(); eq(#h.calls, 0)
  write(h.result_path, '\239\187\191{"endpoint":"ws://127.0.0.1:4501"}')
  h:tick(); eq(h.calls[1].endpoint, "ws://127.0.0.1:4501")
end)

test("startup error is actionable and delivered once", function()
  local h = harness(); h:ensure()
  write(h.result_path, '{"error":"未找到 Codex，请安装 Codex 桌面版。"}')
  h:tick(2); eq(#h.calls, 1); eq(h.calls[1].endpoint, nil)
  assert(h.calls[1].error:find("Codex", 1, true)); eq(h.launcher.pending, nil)
end)

test("invalid or nonlocal endpoints cannot be returned as success", function()
  for _, raw in ipairs({'{}', '[]', 'null', '42', '{"endpoint":"ws://example.com:4500"}',
    '{"endpoint":"ws://127.0.0.1:0"}', '{"endpoint":"ws://127.0.0.1:65536"}',
    '{"error":""}'}) do
    local h = harness(); h:ensure(); write(h.result_path, raw); h:tick()
    eq(#h.calls, 1); eq(h.calls[1].endpoint, nil); assert(h.calls[1].error)
  end
end)

test("missing or permanently partial output times out after 200 polling ticks", function()
  for _, partial in ipairs({false, true}) do
    local h = harness(); h:ensure()
    if partial then write(h.result_path, '{') end
    h:tick(199); eq(#h.calls, 0)
    h:tick(2); eq(#h.calls, 1); eq(h.launcher.pending, nil)
    assert(h.calls[1].error:find("20", 1, true))
    assert(h.calls[1].error:find("重试", 1, true)); eq(h.timers[1].running, false)
  end
end)

test("cancel suppresses a queued tick and a late result without affecting retry", function()
  local h = harness(); h:ensure()
  local old_timer, old_path = h.timers[1], h.result_path
  h.launcher:cancel(); eq(h.launcher.pending, nil); eq(old_timer.running, false)
  h:ensure(); assert(h.result_path ~= old_path)
  write(old_path, '{"endpoint":"ws://127.0.0.1:4501"}')
  old_timer:fire(); eq(#h.calls, 0); assert(h.launcher.pending)
  write(h.result_path, '{"endpoint":"ws://127.0.0.1:4502"}')
  h:tick(); eq(#h.calls, 1); eq(h.calls[1].endpoint, "ws://127.0.0.1:4502")
end)

test("completion callback may immediately start the next independent attempt", function()
  local h = harness(); local calls = 0
  h:ensure(function()
    calls=calls+1; eq(h.launcher.pending, nil); h:ensure()
  end)
  write(h.result_path, '{"endpoint":"ws://127.0.0.1:4501"}')
  h:tick(); eq(calls, 1); assert(h.launcher.pending); eq(#h.commands, 2)
  h.timers[1]:fire(); eq(calls, 1); h.launcher:cancel()
end)

test("permission denial or failing shell exit completes with a remedy", function()
  for _, execute in ipairs({function() error("permission denied") end,
    function() return nil, "exit", 1 end, function() return false, "exit", 1 end}) do
    local h = harness(execute); h:ensure(); eq(#h.calls, 1)
    eq(h.launcher.pending, nil); eq(h.calls[1].endpoint, nil)
    assert(h.calls[1].error:find("允许", 1, true)); eq(h.timers[1].running, false)
  end
end)

test("timer construction and start failures cannot leave a stuck pending attempt", function()
  for _, factory in ipairs({function() error("timer unavailable") end,
    function() return {start=function() error("cannot start") end, stop=function() end} end}) do
    local h = harness(nil, factory); h:ensure()
    eq(h.launcher.pending, nil); eq(#h.calls, 1); assert(h.calls[1].error)
  end
end)

test("cancel during process launch cannot restart the canceled polling timer", function()
  local h = harness(function(self) self.launcher:cancel(); return true end)
  h:ensure(); eq(h.launcher.pending, nil); eq(h.timers[1].running, false)
  h:tick(); eq(#h.calls, 0)
end)

test("callback failure still retires the attempt and prevents duplicate notification", function()
  local h = harness(); local calls=0
  h:ensure(function() calls=calls+1; error("consumer failed") end)
  write(h.result_path, '{"endpoint":"ws://127.0.0.1:4501"}')
  pcall(function() h:tick() end); h:tick(); eq(calls, 1)
  eq(h.launcher.pending, nil); eq(h.timers[1].running, false)
end)

test("missing result does not request file-open permission while startup is pending", function()
  local opens=0
  local env=setmetatable({io={open=function(path,mode)
    if mode=="wb" then return io.open(path,mode) end
    opens=opens+1; error("unexpected permission request")
  end}}, {__index=_G})
  local module=assert(loadfile(app.fs.joinPath(root,"launcher.lua"),"t",env))()
  local h=harness(nil,nil,module); h:ensure()
  h:tick(3); eq(opens,0); eq(#h.calls,0); assert(h.launcher.pending)
  h.launcher:cancel()
end)

test("file permission and read failures report once and retire polling", function()
  for _, failure in ipairs({"stat", "open throw", "open nil", "read throw", "read nil", "close throw", "close nil"}) do
    local closed=false
    local env=setmetatable({app={fs={tempPath=app.fs.tempPath,joinPath=app.fs.joinPath,
      isFile=function(path)
        if failure=="stat" then error("permission denied") end
        return app.fs.isFile(path)
      end}}, io={open=function(path,mode)
        if mode=="wb" then return io.open(path,mode) end
        if failure=="open throw" then error("permission denied") end
        if failure=="open nil" then return nil,"permission denied" end
        return {
          read=function()
            if failure=="read throw" then error("read failed") end
            if failure=="read nil" then return nil,"read failed" end
            return '{"endpoint":"ws://127.0.0.1:45123"}'
          end,
          close=function()
            closed=true
            if failure=="close throw" then error("close failed") end
            if failure=="close nil" then return nil,"close failed" end
            return true
          end,
        }
      end}}, {__index=_G})
    local module=assert(loadfile(app.fs.joinPath(root,"launcher.lua"),"t",env))()
    local h=harness(nil,nil,module); h:ensure(); write(h.result_path,'{}')
    h:tick(2); eq(#h.calls,1); eq(h.calls[1].endpoint,nil)
    assert(h.calls[1].error:find("重试",1,true)); eq(h.launcher.pending,nil)
    eq(h.timers[1].running,false)
    if failure:match("^read") or failure:match("^close") then eq(closed,true) end
  end
end)

-- Run the actual encoded command against a disposable bootstrap, including the
-- native Aseprite os.execute boundary; the fixture owns no bridge or editor.
test("native background command preserves special paths under Restricted PowerShell policy", function()
  local directory = app.fs.joinPath(app.fs.tempPath, "launcher 中文 ' 100% & $() " .. tostring(Uuid()))
  local scripts = app.fs.joinPath(directory, "scripts")
  assert(app.fs.makeDirectory(directory)); assert(app.fs.makeDirectory(scripts))
  local bootstrap = app.fs.joinPath(scripts, "launch.ps1")
  write(bootstrap, 'param([string]$ResultPath)\n[IO.File]::WriteAllText($ResultPath,\'{"endpoint":"ws://127.0.0.1:45123"}\')\n')
  local h = harness(); h.launcher = Launcher.new {
    path=directory, timer_factory=function(spec)
      local timer={spec=spec}; function timer:start() end; function timer:stop() end
      function timer:fire() self.spec.ontick() end
      h.timers[1]=timer; return timer
    end,
    execute=function(command)
      -- Process-local policy applies to both hidden PowerShell children; no
      -- machine/user policy or parent environment is changed by this fixture.
      return os.execute('set "PSExecutionPolicyPreference=Restricted" && ' .. command)
    end,
  }
  h:ensure(); assert(h.launcher.pending, h.calls[1] and h.calls[1].error)
  paths[h.launcher.pending.result_path] = true
  local deadline = os.time()+8
  while h.launcher.pending and os.time()<deadline do
    local until_clock=os.clock()+0.05
    while os.clock()<until_clock do end
    h:tick()
  end
  local result = h.calls[1]
  h.launcher:cancel()
  os.remove(bootstrap); paths[bootstrap]=nil
  app.fs.removeDirectory(scripts); app.fs.removeDirectory(directory)
  assert(result, "background PowerShell did not publish its result")
  eq(result.endpoint, "ws://127.0.0.1:45123")
end)

test("permission dialogs cannot reenter an in-progress result read", function()
  local h, opens
  opens=0
  local env=setmetatable({io={open=function(path,mode)
    if mode~="rb" then return io.open(path,mode) end
    opens=opens+1
    assert(opens==1, "result read reentered while a native permission dialog was open")
    h:tick()
    return io.open(path,mode)
  end}}, {__index=_G})
  local module=assert(loadfile(app.fs.joinPath(root,"launcher.lua"),"t",env))()
  h=harness(nil,nil,module); h:ensure()
  write(h.result_path,'{"endpoint":"ws://127.0.0.1:4501"}')
  h:tick(); eq(opens,1); eq(h.calls[1].endpoint,"ws://127.0.0.1:4501")
end)

test("native permission prompt receives a short readable startup command", function()
  local h=harness(); h:ensure()
  assert(#h.commands[1]<240, "native permission command is too long")
  assert(h.commands[1]:find("aseprite-chat-",1,true) and h.commands[1]:find(".cmd",1,true), "permission prompt should name the startup script")
  assert(not h.commands[1]:find("EncodedCommand",1,true), "encoded command is unreadable in native permission UI")
  h.launcher:cancel()
end)

test("initial native permission decisions do not consume the background startup deadline", function()
  local now=0
  local env=setmetatable({os=setmetatable({time=function() return now end}, {__index=os})}, {__index=_G})
  local module=assert(loadfile(app.fs.joinPath(root,"launcher.lua"),"t",env))()
  local h=harness(function() now=60; return true end,nil,module)
  h:ensure(); h:tick()
  assert(h.launcher.pending and #h.calls==0, "native permission wait consumed startup timeout")
  now=81; h:tick(); eq(#h.calls,1); assert(h.calls[1].error:find("20",1,true))
end)

test("long extension paths cannot exceed the cmd command-line limit", function()
  local line
  local h=harness(function(self)
    local file=assert(io.open(self.launcher.pending.command_path,"rb"))
    line=file:read("*a"); file:close()
    return true
  end)
  h.launcher._options.path="C:\\" .. string.rep("folder name\\",80)
  h:ensure(); h.launcher:cancel()
  assert(line and #line<1000, "cmd command grows with the installed extension path")
end)

for _, item in ipairs(tests) do
  local ok, err = xpcall(item[2], debug.traceback)
  if ok then passed=passed+1 else print("FAIL " .. item[1] .. "\n" .. tostring(err)) end
end
for path in pairs(paths) do os.remove(path) end
print("launcher: " .. passed .. "/" .. #tests .. " tests passed")
assert(passed == #tests, "launcher suite failed")
