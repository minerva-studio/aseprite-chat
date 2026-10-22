local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local Codex = dofile(app.fs.joinPath(root, "codex.lua"))
local tests, passed, failures = {}, 0, 0
local function eq(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, fn) tests[#tests + 1] = {name, fn} end
local function harness(overrides)
  local h = {sockets={}, timers={}, errors={}, messages={}, calls={}, cancels={}, states={}}
  local options = {
    tools={{type="function", name="read_sprite", description="Read live sprite",
      inputSchema={type="object", properties=json.decode("{}"), required=json.decode("[]")}}},
    instructions="Use Aseprite tools only.",
    on_state=function(s) h.states[#h.states+1]=s end,
    on_error=function(e) h.errors[#h.errors+1]=e end,
    on_cancel=function(e) h.cancels[#h.cancels+1]=e end,
    on_message=function(id,text,delta) h.messages[#h.messages+1]={id=id,text=text,delta=delta} end,
    on_tool=function(p,reply) h.calls[#h.calls+1]={params=p,reply=reply} end,
    socket_factory=function(spec)
      local ws={spec=spec,sent={},raw={},closed=0}
      function ws:connect() self.connected=true end
      function ws:close() self.closed=self.closed+1 end
      function ws:sendText(raw)
        if self.fail_send then error("native send failed") end
        self.raw[#self.raw+1]=raw
        self.sent[#self.sent+1]=json.decode(raw)
      end
      function ws:sendPing()
        if self.fail_ping then error("native ping failed") end
      end
      function ws:event(kind,data,err) self.spec.onreceive(kind,data,err) end
      function ws:receive(value) self:event(WebSocketMessageType.TEXT,json.encode(value)) end
      h.sockets[#h.sockets+1]=ws
      return ws
    end,
    timer_factory=function(spec)
      local timer={spec=spec,running=false}
      function timer:start() self.running=true end
      function timer:stop() self.running=false end
      function timer:fire() self.spec.ontick() end
      h.timers[#h.timers+1]=timer
      return timer
    end,
  }
  for k,v in pairs(overrides or {}) do options[k]=v end
  h.client=Codex.new(options)
  function h:last(method)
    for i=#self.ws.sent,1,-1 do
      local m=self.ws.sent[i]
      if not method or m.method==method then return m end
    end
    error("missing request " .. tostring(method))
  end
  function h:respond(request,result,err)
    self.ws:receive({id=request.id,result=result,error=err})
  end
  function h:notify(method,params) self.ws:receive({method=method,params=params}) end
  function h:open()
    assert(self.client:connect("ws://127.0.0.1:4500"))
    self.ws=self.sockets[#self.sockets]
    self.ws:event(WebSocketMessageType.OPEN)
    self:respond(self:last("initialize"),{})
  end
  function h:start(id)
    assert(self.client:send("hello","live context",{model="explicit-model",effort="high"}))
    if self:last().method=="thread/start" then
      self:respond(self:last(),{thread={id="thread",status={type="idle"}}})
    end
    local request=self:last("turn/start")
    self:respond(request,{turn={id=id or "turn",status="inProgress"}})
    return request
  end
  function h:complete(id)
    self:notify("turn/completed",{threadId="thread",turn={id=id or "turn",status="completed"}})
  end
  function h:tool(id,turn,call_id)
    self.ws:receive({id=id or "server-tool",method="item/tool/call",params={
      threadId="thread",turnId=turn or "turn",callId=call_id or tostring(id or "server-tool"),tool="read_sprite",arguments={}}})
  end
  function h:reopen(status)
    self.ws:event(WebSocketMessageType.OPEN)
    self:respond(self:last("initialize"),{})
    local resume=self:last("thread/resume")
    self:respond(resume,{thread={id="thread",status={type=status or "idle"}}})
    return resume
  end
  return h
end

test("initialize and two turns retain thread and exact tool specs",function()
  local h=harness(); h:open()
  eq(h.client.state,"ready")
  local init=h:last("initialize")
  eq(init.params.capabilities.experimentalApi,true)
  assert(init.params.clientInfo.name and init.params.clientInfo.version)
  eq(h:last().method,"initialized"); eq(h:last().jsonrpc,nil)
  h:start()
  local start=h:last("thread/start")
  eq(start.params.sandbox,"read-only"); eq(start.params.approvalPolicy,"on-request")
  eq(start.params.approvalsReviewer,"user")
  eq(start.params.model,"explicit-model"); eq(start.params.allowProviderModelFallback,false)
  eq(start.params.developerInstructions,"Use Aseprite tools only.")
  eq(start.params.dynamicTools[1].type,"function")
  assert(h.ws.raw[3]:match('"required"%s*:%s*%[%s*%]'))
  assert(h.ws.raw[3]:match('"properties"%s*:%s*{%s*}'))
  local turn=h:last("turn/start")
  eq(turn.params.threadId,"thread")
  eq(turn.params.model,"explicit-model"); eq(turn.params.effort,"high")
  assert(turn.params.input[1].text:find("hello",1,true))
  assert(turn.params.input[1].text:find("live context",1,true))
  eq(h.client.turn_id,"turn"); eq(h.client:send("overlap",""),false)
  h:complete(); eq(h.client.state,"ready"); eq(h.client.turn_id,nil)
  h:start("turn2"); eq(h:last("thread/start").id,start.id)
  assert(h:last("turn/start").id>turn.id)
  h:complete("turn2"); assert(h.client:new_chat()); eq(h.client.thread_id,nil)
  h:start("turn3"); assert(h:last("thread/start").id>start.id)
end)

test("stream completion replaces deltas and deduplicates within a turn only",function()
  local h=harness(); h:open(); h:start()
  h:notify("item/started",{threadId="thread",turnId="turn",item={type="agentMessage",id="item",text=""}})
  h:notify("item/agentMessage/delta",{threadId="thread",turnId="turn",itemId="item",delta="你好"})
  h:notify("item/completed",{threadId="thread",turnId="turn",item={type="agentMessage",id="item",text="你好！"}})
  local count=#h.messages
  h:notify("item/completed",{threadId="thread",turnId="turn",item={type="agentMessage",id="item",text="你好！"}})
  h:notify("item/agentMessage/delta",{threadId="thread",turnId="turn",itemId="item",delta="late"})
  eq(#h.messages,count); eq(h.messages[count].text,"你好！"); eq(h.messages[count].delta,false)
  h:complete(); h:start("turn2")
  h:notify("item/completed",{threadId="thread",turnId="turn2",item={type="agentMessage",id="item",text="new"}})
  eq(#h.messages,count+1)
  h:notify("item/agentMessage/delta",{threadId="other",turnId="turn2",itemId="bad",delta="bad"})
  eq(#h.messages,count+1)
end)

test("stop before thread ID prevents turn start",function()
  local h=harness(); h:open(); assert(h.client:send("hello",""))
  local start=h:last(); h.client:stop()
  h:respond(start,{thread={id="thread",status={type="idle"}}})
  eq(h:last().method,"thread/start"); eq(h.client.state,"ready"); eq(h.client.turn_id,nil)
end)

test("stop before turn ID interrupts once and disallows tools",function()
  local h=harness(); h:open(); assert(h.client:send("hello",""))
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  local start=h:last(); h.client:stop(); eq(h.client.state,"stopping")
  h:notify("turn/started",{threadId="thread",turn={id="turn",status="inProgress"}})
  local interrupt=h:last(); eq(interrupt.method,"turn/interrupt")
  h:respond(start,{turn={id="turn",status="inProgress"}})
  eq(h:last().id,interrupt.id)
  h:tool(); eq(#h.calls,0); eq(h:last().result.success,false)
  h:respond(interrupt,{}); eq(h.client.state,"stopping")
  h:complete(); eq(h.client.state,"ready")
end)

test("completed before turn start response cannot revive old turn",function()
  local h=harness(); h:open(); assert(h.client:send("hello",""))
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  local old=h:last(); h:complete(); eq(h.client.state,"ready")
  h:start("turn2")
  h:respond(old,{turn={id="turn",status="inProgress"}})
  h:notify("turn/started",{threadId="thread",turn={id="turn",status="inProgress"}})
  eq(h.client.turn_id,"turn2"); eq(h.client.state,"working")
end)

test("tool replies are typed single use and stop cancels pending request",function()
  local h=harness(); h:open(); h:start(); h:tool(42)
  eq(#h.calls,1); assert(h.client:can_execute(h.calls[1].params))
  assert(h.calls[1].reply({success=true,contentItems={{type="inputText",text="ok"},{type="inputImage",imageUrl="data:image/png;base64,AA=="}}}))
  eq(h:last().id,42); eq(type(h:last().id),"number"); eq(h:last().result.contentItems[2].type,"inputImage")
  local count=#h.ws.sent
  eq(h.calls[1].reply({success=true,contentItems={}}),false); eq(#h.ws.sent,count)
  h:tool("pending"); local reply=h.calls[2].reply
  h.client:stop(); eq(h.client:can_execute(h.calls[2].params),false)
  eq(h.ws.sent[#h.ws.sent-1].id,"pending"); eq(h.ws.sent[#h.ws.sent-1].result.success,false)
  eq(reply({success=true,contentItems={}}),false)
  h:tool("late"); eq(#h.calls,2); eq(h:last().result.success,false)
end)

test("empty contentItems encodes as array and unknown tool is rejected",function()
  local h=harness(); h:open(); h:start(); h:tool()
  h.calls[1].reply({success=true,contentItems={}})
  assert(h.ws.raw[#h.ws.raw]:match('"contentItems"%s*:%s*%[%s*%]'))
  h.ws:receive({id="bad-tool",method="item/tool/call",params={threadId="thread",turnId="turn",callId="bad",tool="invented",arguments={}}})
  eq(#h.calls,1); eq(h:last().result.success,false)
end)

test("unexpected close invalidates approvals and resumes without dynamicTools",function()
  local h=harness(); h:open(); h:start(); h:tool(); local reply=h.calls[1].reply
  local count=#h.ws.sent
  h.ws:event(WebSocketMessageType.CLOSE)
  eq(h.client.state,"disconnected"); eq(h.client.turn_id,nil)
  eq(reply({success=true,contentItems={}}),false); eq(#h.ws.sent,count)
  local resume=h:reopen()
  eq(resume.params.threadId,"thread"); eq(resume.params.excludeTurns,true); eq(resume.params.dynamicTools,nil)
  eq(h.client.state,"ready"); eq(#h.sockets,1)
  h:start("turn2"); h:tool("resumed","turn2"); eq(#h.calls,2)
  assert(h.client:can_execute(h.calls[2].params))
end)

test("resume active turn recovers ID and waits for terminal notification",function()
  local h=harness(); h:open(); h:start(); h.ws:event(WebSocketMessageType.CLOSE)
  h:reopen("active")
  local list=h:last(); eq(list.method,"thread/turns/list")
  eq(list.params.limit,1); eq(list.params.sortDirection,"desc"); eq(list.params.itemsView,"summary")
  eq(h.client:send("blocked",""),false)
  h:respond(list,{data={{id="remote",status="inProgress"}}})
  local interrupt=h:last(); eq(interrupt.method,"turn/interrupt"); eq(interrupt.params.turnId,"remote")
  h:tool("recovery","remote"); eq(#h.calls,0)
  h:respond(interrupt,{}); eq(h.client.state,"stopping")
  h:complete("remote"); eq(h.client.state,"ready"); h:start("next")
end)

test("unidentified active recovery and resume failures keep Send disabled",function()
  local h=harness(); h:open(); h:start(); h.ws:event(WebSocketMessageType.CLOSE); h:reopen("active")
  h:respond(h:last(),{data={}})
  eq(h.client.state,"error"); eq(h.client:send("blocked",""),false); assert(#h.errors>0)
  assert(h.client:new_chat()); eq(h.client.state,"ready")
  h:start("new"); h.ws:event(WebSocketMessageType.CLOSE)
  h.ws:event(WebSocketMessageType.OPEN); h:respond(h:last(),{})
  h:respond(h:last(),nil,{code=-1,message="resume failed"})
  eq(h.client.thread_id,"thread"); eq(h.client.state,"error"); eq(h.client:send("blocked",""),false)
end)

test("intentional disconnect retires late OPEN and replacement ignores old events",function()
  local h=harness(); h:open(); h:start(); local old=h.ws
  h.client:disconnect(); local count=#old.sent
  old:event(WebSocketMessageType.OPEN); eq(#old.sent,count); assert(old.closed>=2)
  h:open(); eq(#h.sockets,2)
  old:event(WebSocketMessageType.CLOSE); old:event(WebSocketMessageType.TEXT,"not JSON")
  eq(h.client.state,"initializing")
  h:respond(h:last("thread/resume"),{thread={id="thread",status={type="idle"}}})
  eq(h.client.state,"ready")
end)

test("new OPEN generation invalidates callbacks even without a CLOSE",function()
  local h=harness(); h:open(); h:start(); h:tool(); local reply=h.calls[1].reply
  h:reopen(); eq(reply({success=true,contentItems={}}),false)
  eq(h.client.state,"ready"); eq(h.client.turn_id,nil)
  for _,timer in ipairs(h.timers) do timer:fire() end
  eq(h.client.state,"ready")
end)

test("unsupported requests echo IDs and approvals use actual typed denials",function()
  local h=harness(); h:open()
  h.ws:receive({id="opaque",method="unknown/method",params={}})
  eq(h:last().id,"opaque"); eq(h:last().error.code,-32601)
  h:notify("unknown/notification",{}); eq(h.client.state,"ready")
  for _,method in ipairs({"item/commandExecution/requestApproval","item/fileChange/requestApproval"}) do
    h.ws:receive({id=8,method=method,params={}})
    eq(h:last().result.decision,"decline")
  end
  h.ws:receive({id="permissions",method="item/permissions/requestApproval",params={}})
  assert(h.ws.raw[#h.ws.raw]:match('"permissions"%s*:%s*{%s*}'))
  for _,method in ipairs({"execCommandApproval","applyPatchApproval"}) do
    h.ws:receive({id=9,method=method,params={}})
    assert(h:last().result.decision.denied.rejection)
  end
  assert(#h.errors>=5)
end)

test("request errors are visible without replay and explicit new chat recovers",function()
  local h=harness(); h:open(); assert(h.client:send("hello",""))
  h:respond(h:last(),nil,{code=-32001,message="overloaded"})
  eq(h.client.state,"error"); assert(h.errors[#h.errors]:find("overloaded",1,true))
  eq(h:last().method,"thread/start"); assert(h.client:new_chat()); eq(h.client.state,"ready")
  h:start(); h:notify("error",{threadId="thread",turnId="turn",error={message="generation failed"},willRetry=false})
  assert(h.errors[#h.errors]:find("generation failed",1,true)); eq(h.client:can_execute({threadId="thread",turnId="turn"}),false)
end)

test("request timeouts retire socket but health traffic does not time out generation",function()
  local h=harness(); assert(h.client:connect("ws://127.0.0.1:4500")); h.ws=h.sockets[1]
  h.ws:event(WebSocketMessageType.OPEN); eq(h.timers[1].spec.interval,30)
  h.timers[1]:fire(); eq(h.client.state,"error"); eq(h.ws.closed,1)
  local count=#h.ws.sent; h.ws:event(WebSocketMessageType.OPEN); eq(#h.ws.sent,count)
  local k=harness(); k:open(); k:start()
  for _,timer in ipairs(k.timers) do
    if timer.spec.interval == 30 then eq(timer.running,false) end
    timer:fire()
  end
  eq(k.client.state,"working")
  k.client:stop(); k.timers[#k.timers]:fire(); eq(k.client.state,"error")
end)

test("malformed protocol messages retire socket",function()
  for _,raw in ipairs({'not json','[]','{"method":42}','{"id":true,"result":{}}','{"id":1}'}) do
    local h=harness(); h:open(); h.ws:event(WebSocketMessageType.TEXT,raw)
    eq(h.client.state,"error"); eq(h.ws.closed,1); assert(#h.errors>0)
  end
end)

test("native send and callback exceptions become visible errors",function()
  local h=harness(); h:open(); h.ws.fail_send=true
  local ok,err=h.client:send("hello","")
  eq(ok,false); assert(err); eq(h.client.state,"error"); assert(h.errors[#h.errors]:find("native send failed",1,true))
  local k=harness({on_tool=function() error("controller exploded") end})
  k:open(); k:start(); k:tool()
  assert(k.errors[#k.errors]:find("controller exploded",1,true))
  eq(k.client.state,"error"); eq(k.ws.closed,1)
end)

test("socket error retires transport and invalid endpoints never connect",function()
  local h=harness(); eq(h.client:connect("ws://example.com:4500"),false); eq(#h.sockets,0)
  eq(h.client:connect("ws://127.0.0.1:99999"),false); eq(#h.sockets,0)
  h:open(); h.ws:event(WebSocketMessageType.ERROR,"","native socket failed")
  eq(h.client.state,"error"); assert(h.errors[#h.errors]:find("native socket failed",1,true))
end)

test("cancellation callback failure cannot prevent retirement",function()
  local fail=false
  local h=harness({on_cancel=function() if fail then error("cancel callback exploded") end end})
  h:open(); h:start(); h:tool(); local reply=h.calls[1].reply; fail=true
  h.client:disconnect()
  eq(h.client.state,"disconnected"); eq(h.ws.closed,1)
  eq(reply({success=true,contentItems={}}),false)
  assert(h.errors[#h.errors]:find("cancel callback exploded",1,true))
end)

test("late item started cannot erase streamed text",function()
  local h=harness(); h:open(); h:start()
  h:notify("item/agentMessage/delta",{threadId="thread",turnId="turn",itemId="item",delta="first"})
  local count=#h.messages
  h:notify("item/started",{threadId="thread",turnId="turn",item={type="agentMessage",id="item",text=""}})
  eq(#h.messages,count)
end)

test("repeated dynamic call ID never replays a completed tool",function()
  local h=harness(); h:open(); h:start(); h:tool()
  h.calls[1].reply({success=true,contentItems={}})
  h:tool("duplicate-id","turn","server-tool")
  eq(#h.calls,1); eq(h:last().result.success,false)
end)

test("invalid known notifications retire transport",function()
  local h=harness(); h:open(); h:start()
  h:notify("turn/completed",{threadId="thread",turn={id="turn",status="inProgress"}})
  eq(h.client.state,"error"); eq(h.ws.closed,1)
end)

test("completed before start reply remains safe when old events arrive in next ID gap",function()
  local h=harness(); h:open(); assert(h.client:send("first",""))
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  local old=h:last(); h:complete()
  assert(h.client:send("second","")); local next_request=h:last()
  h:notify("turn/started",{threadId="thread",turn={id="turn",status="inProgress"}})
  eq(h.client.turn_id,nil)
  h:respond(old,{turn={id="turn",status="inProgress"}}); eq(h.client.turn_id,nil)
  h:respond(next_request,{turn={id="next",status="inProgress"}}); eq(h.client.turn_id,"next")
end)

test("a new chat callback error returns failure and retires the socket",function()
  local fail=false
  local h=harness({on_cancel=function() if fail then error("new chat callback exploded") end end})
  h:open(); fail=true
  local ok,err=h.client:new_chat()
  eq(ok,false); assert(err:find("new chat callback exploded",1,true))
  eq(h.client.state,"error"); eq(h.ws.closed,1)
end)

test("cancelled pre-reconnect turn cannot be adopted while new ID is pending",function()
  local h=harness(); h:open(); h:start("old")
  h.ws:event(WebSocketMessageType.CLOSE)
  h:reopen("idle")
  assert(h.client:send("new prompt","new target")); local next_request=h:last("turn/start")
  h:notify("turn/started",{threadId="thread",turn={id="old",status="inProgress"}})
  h:tool("late-old-tool","old")
  eq(#h.calls,0); eq(h.client.turn_id,nil)
  h:complete("old"); eq(h.client.state,"working")
  h:respond(next_request,{turn={id="new",status="inProgress"}})
  eq(h.client.turn_id,"new"); eq(h.client.state,"working")
end)

test("failed health ping revokes tools and leaves native automatic reconnect in charge",function()
  local h=harness(); h:open(); h:start(); h:tool()
  local reply=h.calls[1].reply
  h.ws.fail_ping=true
  for _,timer in ipairs(h.timers) do if timer.running then timer:fire() end end
  eq(h.client.state,"disconnected")
  eq(h.client:can_execute({threadId="thread",turnId="turn"}),false)
  eq(reply({success=true,contentItems={}}),false)
  eq(h.ws.closed,0)
  h.ws.fail_ping=false; h:reopen("idle"); eq(h.client.state,"ready")
  h.client:disconnect()
  for _,timer in ipairs(h.timers) do eq(timer.running,false) end
end)

test("model discovery collects every page and preserves native catalog capabilities",function()
  local h=harness(); h:open()
  local models, failure
  assert(h.client:list_models(function(value,err) models,failure=value,err end))
  local first=h:last("model/list"); eq(first.params.includeHidden,false)
  h:respond(first,{data={{id="catalog-id",model="wire-model",displayName="Visible model",isDefault=true,
    defaultReasoningEffort="high",supportedReasoningEfforts={{reasoningEffort="high",description="Deep"}}}},nextCursor="page-2"})
  eq(models,nil); eq(h:last().params.cursor,"page-2")
  h:respond(h:last(),{data={{id="other",model="other-model",displayName="Other",isDefault=false,
    defaultReasoningEffort="low",supportedReasoningEfforts={{reasoningEffort="low",description="Quick"}}}}})
  eq(failure,nil); eq(#models,2); eq(models[1].model,"wire-model")
  eq(models[1].supportedReasoningEfforts[1].reasoningEffort,"high")
  eq(h.client.state,"ready")
end)

test("catalog errors are visible to caller and a retired request cannot change selection",function()
  local h=harness(); h:open(); local calls,err=0
  assert(h.client:list_models(function(_,why) calls=calls+1; err=why end))
  h:respond(h:last(),nil,{code=-1,message="catalog unavailable"})
  eq(calls,1); assert(err:find("catalog unavailable",1,true)); eq(h.client.state,"ready")
  assert(h.client:list_models(function() calls=calls+1 end)); local old=h:last()
  h.client:disconnect(); h:respond(old,{data={}}); eq(calls,1)
end)

test("per-turn model and reasoning changes retain the same thread",function()
  local h=harness(); h:open(); h:start(); h:complete()
  local original=h:last("thread/start")
  local selection={model="other-model",effort="low"}
  assert(h.client:send("continue","context",selection))
  selection.model="mutated-after-send"
  local turn=h:last("turn/start")
  eq(turn.params.threadId,"thread"); eq(turn.params.model,"other-model"); eq(turn.params.effort,"low")
  eq(h:last("thread/start").id,original.id)
end)

for _,case in ipairs(tests) do
  local ok,err=xpcall(case[2],debug.traceback)
  if ok then passed=passed+1; print("PASS " .. case[1])
  else failures=failures+1; print("FAIL " .. case[1] .. "\n" .. tostring(err)) end
end
print(string.format("protocol: %d/%d tests passed",passed,#tests))
assert(failures==0,"protocol suite failed")
