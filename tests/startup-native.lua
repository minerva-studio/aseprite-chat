-- A Node test driver supplies disposable runtime/output paths and owns cleanup.
local Launcher=dofile(app.fs.joinPath(os.getenv("ASEPRITE_CHAT_STARTUP_SOURCE"),"launcher.lua"))
local output=assert(os.getenv("ASEPRITE_CHAT_STARTUP_OUTPUT"))
local function write(name,text)
  local file=assert(io.open(app.fs.joinPath(output,name),"wb")); file:write(text); file:close()
end
local timer,reply,problem,probe,executions
executions=0
-- Lua's native getenv uses the Windows ANSI encoding. Installed plugin paths
-- are UTF-8, so pass this fixture's equivalent through a UTF-8 JSON file too.
local configuration=assert(io.open(os.getenv("ASEPRITE_CHAT_STARTUP_JOB"),"rb"))
local runtime=json.decode(configuration:read("*a")).runtime; configuration:close()
local launcher=Launcher.new{path=runtime,
  -- Batch has no native GUI event loop; the driver supplies actual bridge
  -- health messages over stdin while the production Launcher owns the state.
  socket_factory=function(spec)
    probe={spec=spec}
    function probe:connect() print("startup-probe: "..json.encode{url=spec.url}) end
    function probe:close() self.closed=true end
    return probe
  end,
  timer_factory=function(spec)
    timer={}; function timer:start() end; function timer:stop() end
    function timer:tick() spec.ontick() end
    return timer
  end,
  execute=function(command)
    executions=executions+1
    write("before","before")
    local status=table.pack(os.execute(command))
    write("after","after")
    return table.unpack(status,1,status.n)
  end}
launcher:ensure(function(endpoint,err) reply,problem=endpoint,err end)
local deadline=os.time()+20
while launcher.pending and os.time()<deadline do
  local clock=os.clock()+0.02
  while os.clock()<clock do end
  timer:tick()
end
launcher:cancel()
assert(reply,problem or "Native launcher did not become ready")
local first=reply;reply=nil
launcher:ensure(function(endpoint,err) reply,problem=endpoint,err end)
assert(probe and executions==1,"Warm open tried to start another process")
local health=assert(io.read("*l"),"Health adapter closed")
probe.spec.onreceive(WebSocketMessageType.TEXT,health)
assert(reply==first,problem or "Warm health did not reuse the bridge")
assert(probe.closed and not launcher.pending,"Warm probe was not retired")
write("result.json",json.encode{endpoint=reply,executions=executions})
print("startup-native: passed")
