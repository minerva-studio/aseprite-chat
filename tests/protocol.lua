local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local Codex = dofile(app.fs.joinPath(root, "codex.lua"))
local tests, passed, failures = {}, 0, 0
local function eq(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, fn) tests[#tests + 1] = {name, fn} end
local function harness(overrides)
  local h = {sockets={}, timers={}, errors={}, messages={}, items={}, calls={}, cancels={}, states={}}
  local options = {
    tools={{type="function", name="read_sprite", description="Read live sprite",
      inputSchema={type="object", properties=json.decode("{}"), required=json.decode("[]")}}},
    instructions="Use Aseprite tools only.",
    on_state=function(s) h.states[#h.states+1]=s end,
    on_error=function(e) h.errors[#h.errors+1]=e end,
    on_cancel=function(e) h.cancels[#h.cancels+1]=e end,
    on_message=function(id,text,delta) h.messages[#h.messages+1]={id=id,text=text,delta=delta} end,
    on_item=function(item,completed) h.items[#h.items+1]={item=item,completed=completed} end,
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
  function h:history_read(id,status)
    self:respond(self:last("thread/read"),{thread={id=id or "history",originator="aseprite_chat",
      preview="previous prompt",updatedAt=100,status={type=status or "notLoaded"}}})
  end
  function h:history_resume(id,status)
    self:respond(self:last("thread/resume"),{thread={id=id or "history",originator="aseprite_chat",
      preview="previous prompt",updatedAt=100,status={type=status or "idle"}}})
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
  eq(h.client.state,"error"); assert(h.errors[#h.errors]:find("Retry",1,true))
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
    defaultReasoningEffort="high",serviceTiers={{id="priority",name="Fast",description="More usage"}},
    supportedReasoningEfforts={{reasoningEffort="high",description="Deep"}}}},nextCursor="page-2"})
  eq(models,nil); eq(h:last().params.cursor,"page-2")
  h:respond(h:last(),{data={{id="other",model="other-model",displayName="Other",isDefault=false,
    defaultReasoningEffort="low",supportedReasoningEfforts={{reasoningEffort="low",description="Quick"}}}}})
  eq(failure,nil); eq(#models,2); eq(models[1].model,"wire-model")
  eq(models[1].supportedReasoningEfforts[1].reasoningEffort,"high")
  eq(models[1].serviceTiers[1].id,"priority")
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

test("thread listing sends one filtered page and returns plain Lua metadata",function()
  local h=harness(); h:open(); local page,why,calls
  calls=0
  assert(h.client:list_threads({search="sprite",cursor="older"},function(value,err) page,why=value,err; calls=calls+1 end))
  local request=h:last("thread/list")
  eq(request.params.limit,50); eq(request.params.sortKey,"updated_at"); eq(request.params.sortDirection,"desc")
  eq(request.params.searchTerm,"sprite"); eq(request.params.cursor,"older"); eq(request.params.originators,nil)
  eq(request.params.sourceKinds[1],"cli"); eq(request.params.sourceKinds[2],"vscode"); eq(request.params.sourceKinds[3],"appServer")
  eq(request.params.useStateDbOnly,true)
  h:respond(request,{data={
    {id="own",originator="aseprite_chat",name="Sprite",preview="hello",updatedAt=123,status={type="idle"}},
    {id="foreign",originator="vscode",preview="private",updatedAt=124,status={type="active"}},
    {id="unknown",preview="unknown",updatedAt=125,status={type="notLoaded"}}},nextCursor="more"})
  eq(why,nil); eq(calls,1); eq(type(page),"table"); eq(type(page.data),"table"); eq(#page.data,1)
  eq(type(page.data[1]),"table"); eq(page.data[1].status,"idle")
  eq(page.data[1].id,"own"); eq(page.data[1].name,"Sprite"); eq(page.data[1].updatedAt,123)
  eq(page.nextCursor,"more"); eq(h:last().id,request.id); eq(h.client.state,"ready")
end)

test("thread listing keeps empty pages with cursors and reports errors without retirement",function()
  local h=harness(); h:open(); local page,why
  local function done(value,err) page,why=value,err end
  assert(h.client:list_threads({},done))
  h:respond(h:last(),{data={{id="other",originator="other"}},nextCursor="next"})
  eq(#page.data,0); eq(page.nextCursor,"next")
  assert(h.client:list_threads({cursor="next"},done))
  h:respond(h:last(),nil,{code=-1,message="history unavailable"})
  eq(page,nil); assert(why:find("history unavailable",1,true)); eq(h.client.state,"ready")
  assert(h.client:list_threads({},done))
  h.ws:event(WebSocketMessageType.TEXT,'{"id":' .. h:last().id .. ',"result":{"data":[],"nextCursor":null}}')
  eq(type(page.data),"table"); eq(#page.data,0); eq(page.nextCursor,nil)
end)

test("thread listing rejects malformed pages and cursor loops and ignores retired results",function()
  local h=harness(); h:open(); local calls,why=0
  local function done(value,err) calls=calls+1; eq(value,nil); why=err end
  for _,page in ipairs({{data={},nextCursor=9},{data={},nextCursor="same"},{data={}},{data={{id=4,originator="aseprite_chat"}}}}) do
    if page.nextCursor==nil and #page.data==0 then page.data={bad=true} end
    assert(h.client:list_threads({cursor="same"},done)); h:respond(h:last(),page)
    assert(why); eq(h.client.state,"ready")
  end
  eq(calls,4)
  assert(h.client:list_threads({},done)); local old=h:last()
  h.client:disconnect(); h:respond(old,{data={}}); eq(calls,4); eq(h.client.state,"disconnected")
  eq(h.client:list_threads({},done),false)
end)

test("history list callbacks retained across a lost connection cannot update the picker",function()
  for _,retirement in ipairs({"close","disconnect","open"}) do
    local h=harness(); h:open(); local calls=0
    assert(h.client:list_threads({},function() calls=calls+1 end))
    local callback=h.client._pending[h:last().id].callback
    if retirement=="close" then h.ws:event(WebSocketMessageType.CLOSE)
    elseif retirement=="open" then h.ws:event(WebSocketMessageType.OPEN)
    else h.client:disconnect() end
    callback(json.decode('{"data":[]}'))
    eq(calls,0)
  end
end)

test("opening history loads every full ascending page before replacing binding without replay",function()
  local h=harness(); h:open(); h:start(); h:complete(); local result,why,calls= nil,nil,0
  assert(h.client:open_thread("history",function(value,err) result,why=value,err; calls=calls+1 end))
  eq(h.client.state,"loading"); eq(h.client.thread_id,"thread")
  local read=h:last("thread/read"); eq(read.params.threadId,"history"); eq(read.params.includeTurns,false)
  eq(h.client:send("blocked",""),false); eq(h.client:new_chat(),false)
  eq(h.client:open_thread("second",function() error("overlap") end),false)
  h:history_read()
  local resume=h:last("thread/resume")
  eq(resume.params.threadId,"history"); eq(resume.params.excludeTurns,true); eq(resume.params.dynamicTools,nil)
  eq(resume.params.developerInstructions,"Use Aseprite tools only.")
  eq(resume.params.sandbox,"read-only"); eq(resume.params.approvalPolicy,"on-request"); eq(resume.params.approvalsReviewer,"user")
  h:history_resume()
  h.ws:receive({id="historical-request",method="item/tool/call",params={threadId="history",turnId="past1",
    callId="past-call",tool="read_sprite",arguments={}}})
  eq(h:last().result.success,false); eq(#h.calls,0)
  local first=h:last("thread/turns/list")
  eq(first.params.threadId,"history"); eq(first.params.sortDirection,"asc"); eq(first.params.itemsView,"full"); eq(first.params.limit,50)
  h:respond(first,{data={{id="past1",status="completed",items={{id="tool",type="dynamicToolCall",tool="read_sprite",
    arguments={},status="completed",success=true,contentItems={{type="inputText",text="old result"}}}}}},nextCursor="page2"})
  eq(calls,0); eq(h.client.thread_id,"thread"); eq(h:last().params.cursor,"page2")
  h:respond(h:last(),{data={},nextCursor="page3"}); eq(h:last().params.cursor,"page3"); eq(calls,0)
  h:respond(h:last(),{data={{id="past2",status="interrupted",items={{id="answer",type="agentMessage",text="history"}}}}})
  eq(calls,1); eq(why,nil); eq(h.client.state,"ready"); eq(h.client.thread_id,"history")
  eq(type(result),"table"); eq(type(result.thread),"table"); eq(type(result.turns[1].items[1]),"table")
  eq(#result.turns,2); eq(result.turns[1].items[1].contentItems[1].text,"old result"); eq(result.turns[2].id,"past2")
  eq(#h.calls,0); eq(#h.messages,0)
  assert(h.client:send("continue","canvas")); eq(h:last("turn/start").params.threadId,"history")
  h:notify("turn/started",{threadId="history",turn={id="past1",status="inProgress"}})
  eq(h.client.turn_id,nil)
end)

test("history rejects foreign and active reads or resumes without interrupting other editors",function()
  for _,scenario in ipairs({"foreign","active-read","active-resume","foreign-resume"}) do
    local h=harness(); h:open(); h:start(); h:complete(); local result,why
    assert(h.client:open_thread("history",function(value,err) result,why=value,err end))
    if scenario=="foreign" then
      h:respond(h:last(),{thread={id="history",originator="vscode",status={type="idle"}}})
    elseif scenario=="active-read" then h:history_read(nil,"active")
    else
      h:history_read()
      if scenario=="foreign-resume" then
        h:respond(h:last(),{thread={id="history",originator="other",status={type="idle"}}})
      else h:history_resume(nil,"active") end
    end
    eq(result,nil); assert(why); eq(h.client.thread_id,"thread"); eq(h.client.state,"ready")
    for _,m in ipairs(h.ws.sent) do assert(m.method~="turn/interrupt" and m.method~="thread/turns/list") end
    if scenario=="foreign" or scenario=="active-read" then eq(h:last().method,"thread/read") end
  end
end)

test("history request errors at every stage preserve prior binding and recover ready",function()
  for _,stage in ipairs({"read","resume","turns"}) do
    local h=harness(); h:open(); h:start(); h:complete(); local calls,why=0
    assert(h.client:open_thread("history",function(value,err) eq(value,nil); calls=calls+1; why=err end))
    if stage~="read" then h:history_read() end
    if stage=="turns" then h:history_resume() end
    h:respond(h:last(),nil,{code=-1,message=stage .. " unavailable"})
    eq(calls,1); assert(why:find(stage,1,true)); eq(h.client.thread_id,"thread"); eq(h.client.state,"ready")
    assert(h.client:send("continue original","")); eq(h:last().params.threadId,"thread")
  end
end)

test("history validates pages and detects multi-page cursor cycles",function()
  for _,scenario in ipairs({"cycle","cursor","object-data","bad-turn","bad-items","bad-status","wrong-id"}) do
    local h=harness(); h:open(); local calls,why=0
    assert(h.client:open_thread("history",function(value,err) eq(value,nil); calls=calls+1; why=err end))
    h:history_read(scenario=="wrong-id" and "wrong" or nil)
    if scenario~="wrong-id" then
      h:history_resume()
      if scenario=="cycle" then
        h:respond(h:last(),{data={},nextCursor="a"}); h:respond(h:last(),{data={},nextCursor="b"})
        h:respond(h:last(),{data={},nextCursor="a"})
      elseif scenario=="cursor" then h:respond(h:last(),{data={},nextCursor=6})
      elseif scenario=="object-data" then h:respond(h:last(),{data={bad=true}})
      elseif scenario=="bad-turn" then h:respond(h:last(),{data={{id=4,status="completed",items={}}}})
      elseif scenario=="bad-status" then h:respond(h:last(),{data={{id="past",status="invented",items={}}}})
      else h:respond(h:last(),{data={{id="past",status="completed",items={bad=true}}}}) end
    end
    eq(calls,1); assert(why); eq(h.client.state,"ready"); eq(h.client.thread_id,nil)
  end
end)

test("idle resumed history retains recorded in-progress turns without treating them as live execution",function()
  local h=harness(); h:open(); local result,why
  assert(h.client:open_thread("history",function(value,err) result,why=value,err end))
  h:history_read(); h:history_resume()
  h:respond(h:last(),{data={{id="past",status="inProgress",items={{id="tool",type="dynamicToolCall",
    tool="read_sprite",arguments={},status="inProgress"}}}}})
  eq(why,nil); eq(result.turns[1].status,"inProgress"); eq(h.client.state,"ready"); eq(#h.calls,0)
  assert(h.client:send("continue","canvas"))
  h:notify("turn/started",{threadId="history",turn={id="past",status="inProgress"}})
  eq(h.client.turn_id,nil)
end)

test("retired history callbacks cannot restore ready binding or tools",function()
  for _,stage in ipairs({"read","resume","turns"}) do
    for _,retirement in ipairs({"disconnect","close","open","timeout"}) do
      local h=harness(); h:open(); local calls=0
      assert(h.client:open_thread("history",function() calls=calls+1 end))
      if stage~="read" then h:history_read() end
      if stage=="turns" then h:history_resume() end
      local request=h:last(); local callback=h.client._pending[request.id].callback
      if retirement=="disconnect" then h.client:disconnect()
      elseif retirement=="close" then h.ws:event(WebSocketMessageType.CLOSE)
      elseif retirement=="timeout" then h.timers[#h.timers]:fire()
      else h.ws:event(WebSocketMessageType.OPEN) end
      local state=h.client.state
      callback(stage=="turns" and json.decode('{"data":[]}') or json.decode('{"thread":{"id":"history","originator":"aseprite_chat","status":{"type":"idle"}}}'))
      h:respond(request,{data={}})
      eq(calls,0); eq(h.client.state,state); eq(h.client.thread_id,nil); eq(h.client.turn_id,nil); eq(#h.calls,0)
    end
  end
end)

test("history opening refuses disconnected busy and invalid IDs without requests",function()
  local h=harness(); eq(h.client:open_thread("history",function() end),false)
  h:open(); local count=#h.ws.sent
  for _,id in ipairs({"",4,false}) do eq(h.client:open_thread(id,function() end),false) end
  eq(#h.ws.sent,count); h:start(); count=#h.ws.sent
  eq(h.client:open_thread("history",function() end),false); eq(#h.ws.sent,count)
end)

test("synchronous state observers retiring a history operation cannot revive its completion",function()
  for _,stage in ipairs({"loading","ready"}) do
    local armed=false
    local h
    h=harness({on_state=function(state) if armed and state==stage then h.client:disconnect() end end})
    h:open(); armed=true; local calls=0; local count=#h.ws.sent
    assert(h.client:open_thread("history",function() calls=calls+1 end))
    if stage=="ready" then
      h:history_read(); h:history_resume(); h:respond(h:last(),{data={}})
    else eq(#h.ws.sent,count) end
    eq(h.client.state,"disconnected"); eq(calls,0); eq(h.client.turn_id,nil)
  end
end)

test("non-agent item lifecycle is plain Lua and completed items deduplicate without tool execution",function()
  local h=harness(); h:open(); h:start()
  local item={id="activity",type="dynamicToolCall",tool="read_sprite",arguments={code="return 1"},status="inProgress"}
  h:notify("item/started",{threadId="thread",turnId="turn",item=item})
  eq(#h.items,1); eq(h.items[1].completed,false); eq(type(h.items[1].item),"table")
  eq(type(h.items[1].item.arguments),"table"); eq(h.items[1].item.arguments.code,"return 1")
  h:notify("item/started",{threadId="thread",turnId="turn",item=item}); eq(#h.items,1)
  item.status="completed"; item.success=true; item.contentItems={{type="inputText",text="result"}}
  h:notify("item/completed",{threadId="thread",turnId="turn",item=item})
  eq(#h.items,2); eq(h.items[2].completed,true); eq(h.items[2].item.contentItems[1].text,"result")
  eq(h.items[1].item.status,"inProgress")
  h:notify("item/completed",{threadId="thread",turnId="turn",item=item}); eq(#h.items,2)
  h:notify("item/started",{threadId="thread",turnId="turn",item=item}); eq(#h.items,2)
  eq(#h.calls,0); eq(#h.messages,0)
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="answer",type="agentMessage",text="answer"}})
  eq(#h.items,2); eq(#h.messages,1)
end)

test("provider reasoning content streams by contentIndex and final snapshots are authoritative",function()
  local h=harness(); h:open(); h:start()
  local function delta(index,text,turn)
    h:notify("item/reasoning/textDelta",{threadId="thread",turnId=turn or "turn",itemId="raw",contentIndex=index,delta=text})
  end
  delta(0,"wrong","other"); eq(#h.items,0)
  delta(1,"Second"); delta(0,"First"); delta(0," block")
  local latest=h.items[#h.items].item
  eq(latest.content[1],"First block"); eq(latest.content[2],"Second"); eq(#latest.summary,0)
  eq(h.items[1].item.content[1],"Second")
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="raw",type="reasoning",summary={},content={"Final thought"},encryptedContent="opaque"}})
  latest=h.items[#h.items].item; eq(latest.content[1],"Final thought"); eq(latest.encryptedContent,nil)
  local count=#h.items; delta(0,"late"); eq(#h.items,count)
  h.client:stop(); delta(0,"stopped"); eq(#h.items,count)
end)

test("reasoning summaries and content remain separate with authoritative completion",function()
  local h=harness(); h:open(); h:start()
  local function summary(method,index,delta)
    h:notify("item/reasoning/" .. method,{threadId="thread",turnId="turn",itemId="r",summaryIndex=index,delta=delta})
  end
  summary("summaryTextDelta",1,"Second")
  eq(#h.items,1); eq(h.items[1].item.type,"reasoning"); eq(h.items[1].completed,false)
  summary("summaryPartAdded",0); summary("summaryTextDelta",0,"First")
  summary("summaryTextDelta",0," section")
  local latest=h.items[#h.items].item
  eq(latest.id,"r"); eq(latest.summary[1],"First section"); eq(latest.summary[2],"Second")
  eq(h.items[1].item.summary[1],"Second")
  local count=#h.items
  summary("summaryPartAdded",0); eq(#h.items,count)
  h:notify("item/started",{threadId="thread",turnId="turn",item={id="r",type="reasoning",summary={},content={"private start"}}})
  eq(#h.items,count)
  h:notify("item/reasoning/contentDelta",{threadId="thread",turnId="turn",itemId="r",delta="hidden content"})
  eq(#h.items,count)
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="r",type="reasoning",summary={"Final"},content={"private final"}}})
  eq(#h.items,count+1); eq(h.items[#h.items].completed,true)
  latest=h.items[#h.items].item; eq(type(latest.summary),"table"); eq(#latest.summary,1); eq(latest.summary[1],"Final")
  eq(latest.content[1],"private final"); eq(latest.text,nil); eq(#h.messages,0)
  summary("summaryTextDelta",0,"late"); summary("summaryPartAdded",2)
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="r",type="reasoning",summary={"duplicate"}}})
  eq(#h.items,count+1)
end)

test("reasoning starts seed summaries while empty authoritative completion clears streamed text",function()
  local h=harness(); h:open(); h:start()
  h:notify("item/started",{threadId="thread",turnId="turn",item={id="r",type="reasoning",summary={"seed"},content={"hidden"}}})
  eq(#h.items,1); eq(h.items[1].item.summary[1],"seed"); eq(h.items[1].item.content[1],"hidden")
  h:notify("item/reasoning/summaryTextDelta",{threadId="thread",turnId="turn",itemId="r",summaryIndex=0,delta=" text"})
  eq(h.items[2].item.summary[1],"seed text")
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="r",type="reasoning",summary={},content={}}})
  eq(#h.items[3].item.summary,0); eq(#h.items[3].item.content,0)
end)

test("activity and summaries ignore wrong turns stopped turns terminal turns and retired sockets",function()
  local h=harness(); h:open(); h:start()
  h:notify("item/started",{threadId="other",turnId="turn",item={id="p",type="plan",text="wrong"}})
  h:notify("item/reasoning/summaryTextDelta",{threadId="thread",turnId="other",itemId="r",summaryIndex=0,delta="wrong"})
  eq(#h.items,0)
  h:notify("item/started",{threadId="thread",turnId="turn",item={id="p",type="plan",text="plan"}})
  eq(#h.items,1); h.client:stop()
  h:notify("item/reasoning/summaryTextDelta",{threadId="thread",turnId="turn",itemId="r",summaryIndex=0,delta="stopped"})
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="p",type="plan",text="late"}})
  eq(#h.items,1); h:complete()
  h:notify("item/reasoning/summaryTextDelta",{threadId="thread",turnId="turn",itemId="r",summaryIndex=0,delta="ended"})
  eq(#h.items,1); h:start("next")
  h:notify("item/completed",{threadId="thread",turnId="next",item={id="p",type="plan",text="next"}})
  eq(#h.items,2)
  local old=h.ws; h.client:disconnect()
  old:receive({method="item/started",params={threadId="thread",turnId="next",item={id="late",type="plan",text="retired"}}})
  eq(#h.items,2)
end)

test("malformed reasoning summary notifications retire the transport",function()
  for _,index in ipairs({-1,0.5,"0"}) do
    local h=harness(); h:open(); h:start()
    h:notify("item/reasoning/summaryTextDelta",{threadId="thread",turnId="turn",itemId="r",summaryIndex=index,delta="bad"})
    eq(h.client.state,"error"); eq(h.ws.closed,1)
  end
end)

test("malformed provider reasoning content never enters the transcript",function()
  for _,index in ipairs({-1,0.5,"0"}) do
    local h=harness(); h:open(); h:start()
    h:notify("item/reasoning/textDelta",{threadId="thread",turnId="turn",itemId="raw",contentIndex=index,delta="bad"})
    eq(h.client.state,"error"); eq(#h.items,0)
  end
  local h=harness(); h:open(); h:start()
  h:notify("item/completed",{threadId="thread",turnId="turn",item={id="raw",type="reasoning",content={42}}})
  eq(h.client.state,"error"); eq(#h.items,0)
end)

test("optional turn summary mode is snapshotted across thread creation and never globally enabled",function()
  local h=harness(); h:open(); local settings={model="reasoning",effort="high",summary="auto"}
  assert(h.client:send("hello","",settings)); settings.summary="none"
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  eq(h:last("turn/start").params.summary,"auto")
  h:respond(h:last(),{turn={id="turn",status="inProgress"}}); h:complete()
  assert(h.client:send("plain model","",{model="nonreasoning"}))
  eq(h:last("turn/start").params.summary,nil)
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

test("speed overrides are snapshotted per turn and standard explicitly clears inherited Fast",function()
  local h=harness(); h:open()
  local selection={model="sol",effort="low",serviceTier="priority"}
  assert(h.client:send("fast","",selection)); selection.serviceTier="default"
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  eq(h:last("turn/start").params.serviceTierForTurn,"priority")
  eq(h:last("turn/start").params.serviceTier,nil)
  h:respond(h:last(),{turn={id="fast",status="inProgress"}}); h:complete("fast")
  assert(h.client:send("standard","",{serviceTier="default"}))
  eq(h:last("turn/start").params.serviceTierForTurn,"default")
end)

test("renaming persists the current thread name, reports errors and refuses unsafe states",function()
  local h=harness(); h:open()
  assert(not h.client:rename_thread("Title",function() end))
  h:start(); assert(not h.client:rename_thread("Title",function() end)); h:complete()
  assert(not h.client:rename_thread("   ",function() end))
  local called,ok,why=0
  local function done(value,err) called,ok,why=called+1,value,err end
  assert(h.client:rename_thread("  魔法书  ",done)); eq(h.client.state,"renaming")
  local request=h:last("thread/name/set"); eq(request.params.threadId,"thread"); eq(request.params.name,"魔法书")
  assert(not h.client:send("race",""))
  h:respond(request,{}); eq(called,1); eq(ok,true); eq(h.client.thread_name,"魔法书"); eq(h.client.state,"ready")
  assert(h.client:rename_thread("Replacement",done))
  h:respond(h:last(),nil,{code=-1,message="Cannot rename"})
  eq(called,2); eq(ok,false); eq(why,"Cannot rename"); eq(h.client.thread_name,"魔法书"); eq(h.client.state,"ready")
  h:notify("thread/name/updated",{threadId="other",threadName="Foreign"}); eq(h.client.thread_name,"魔法书")
  h:notify("thread/name/updated",{threadId="thread",threadName="Changed externally"}); eq(h.client.thread_name,"Changed externally")
  h.ws:event(WebSocketMessageType.OPEN); h:respond(h:last("initialize"),{})
  h:respond(h:last("thread/resume"),{thread={id="thread",name="Persisted title",status={type="idle"}}})
  eq(h.client.thread_name,"Persisted title")
  assert(h.client:rename_thread("Late",done)); local late=h:last()
  h.client:disconnect(); h:respond(late,{})
  eq(called,2); eq(h.client.thread_name,"Persisted title")
  h:open(); h:respond(h:last("thread/resume"),{thread={id="thread",name="Persisted title",status={type="idle"}}})
  assert(h.client:new_chat()); eq(h.client.thread_name,nil)
end)

test("steering appends to the exact active turn without settings overrides or another turn",function()
  local h=harness(); h:open()
  assert(not h.client:can_steer())
  assert(h.client:send("first","")); assert(not h.client:can_steer())
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  h:respond(h:last(),{turn={id="turn",status="inProgress"}})
  assert(h.client:can_steer()); assert(not h.client:steer(" ",""))
  local started=h:last("turn/start").id
  assert(h.client:steer("Use blue instead","current target")); eq(h.client.state,"steering")
  local request=h:last("turn/steer")
  eq(request.params.expectedTurnId,"turn"); eq(request.params.threadId,"thread")
  assert(request.params.input[1].text:find("Use blue instead",1,true))
  eq(request.params.model,nil); eq(request.params.effort,nil); eq(request.params.serviceTierForTurn,nil)
  assert(not h.client:can_steer() and not h.client:can_execute({threadId="thread",turnId="turn"}))
  assert(not h.client:steer("duplicate","")); h:respond(request,{turnId="turn"})
  eq(h.client.state,"working"); assert(h.client:can_steer()); eq(h:last("turn/start").id,started)
end)

test("steering failure stays in the current turn and terminal acknowledgement never revives work",function()
  local h=harness(); h:open(); h:start()
  assert(h.client:steer("Keep this instruction visible",""))
  h:respond(h:last(),nil,{code=-1,message="No active turn"})
  eq(h.client.state,"working"); assert(h.errors[#h.errors]:find("Keep this instruction visible",1,true))
  assert(h.client:steer("finish race","")); local request=h:last()
  h:complete(); eq(h.client.state,"steering")
  assert(not h.client:send("not yet","")); assert(not h.client:new_chat())
  h:respond(request,{turnId="turn"}); eq(h.client.state,"ready"); assert(not h.client:can_steer())
end)

test("stop and disconnect prevent steering responses from restoring execution",function()
  local h=harness(); h:open(); h:start()
  assert(h.client:steer("adjust","")); local request=h:last()
  h.client:stop(); h:respond(request,{turnId="turn"}); eq(h.client.state,"stopping")
  h:complete(); eq(h.client.state,"ready")
  h:start("next"); assert(h.client:steer("retired","")); local late=h:last()
  h.client:disconnect(); h:respond(late,{turnId="next"}); eq(h.client.state,"disconnected")
end)

test("late steering acknowledgement cannot clear an unrelated turn failure or alter a replacement turn",function()
  local h=harness(); h:open(); assert(h.client:send("start",""))
  h:respond(h:last(),{thread={id="thread",status={type="idle"}}})
  local start=h:last("turn/start")
  h:notify("turn/started",{threadId="thread",turn={id="turn",status="inProgress"}})
  assert(h.client:steer("old steer","")); local old=h:last()
  h:respond(start,nil,{code=-1,message="Start failed"}); eq(h.client.state,"error")
  h:respond(old,{turnId="turn"}); eq(h.client.state,"error")
  assert(h.client:new_chat()); h:start("replacement")
  eq(h.client.turn_id,"replacement"); eq(h.client.state,"working")
end)

test("a close reason string is surfaced as an error while plain close stays quiet",function()
  local h=harness(); h:open(); h:start()
  h.ws:event(WebSocketMessageType.CLOSE,"账户配置无效，请在 Settings 中重新保存。")
  eq(h.client.state,"disconnected"); eq(h.client.turn_id,nil)
  assert(h.errors[#h.errors]:find("账户配置无效",1,true))
  local count=#h.errors
  h.ws:event(WebSocketMessageType.CLOSE,"")
  h.ws:event(WebSocketMessageType.CLOSE)
  eq(#h.errors,count)
end)

test("thread settings reach thread start resume and history resume",function()
  local h=harness({thread_settings=function()
    return {sandbox="workspace-write",cwd="D:\\ws",approvalPolicy="on-request",approvalsReviewer="auto_review"}
  end}); h:open(); h:start()
  local start=h:last("thread/start")
  eq(start.params.sandbox,"workspace-write"); eq(start.params.cwd,"D:\\ws")
  eq(start.params.approvalsReviewer,"auto_review")
  h.ws:event(WebSocketMessageType.CLOSE)
  local resume=h:reopen()
  eq(resume.params.sandbox,"workspace-write"); eq(resume.params.cwd,"D:\\ws")
  eq(resume.params.approvalsReviewer,"auto_review")
  h.client:open_thread("history",function() end)
  h:history_read(); h:history_resume()
  local resumed=h:last("thread/resume")
  eq(resumed.params.sandbox,"workspace-write"); eq(resumed.params.cwd,"D:\\ws")
end)

test("default thread settings reproduce the canvas profile",function()
  local h=harness(); h:open(); h:start()
  local start=h:last("thread/start")
  eq(start.params.sandbox,"read-only"); eq(start.params.approvalsReviewer,"user")
  eq(start.params.cwd,nil)
  h.ws:event(WebSocketMessageType.CLOSE)
  local resume=h:reopen()
  eq(resume.params.sandbox,"read-only"); eq(resume.params.approvalsReviewer,"user")
end)

local function approval_request(h,method,params,id)
  params=params or {}
  -- exec/applyPatch approvals carry conversationId instead of threadId/turnId.
  if method~="execCommandApproval" and method~="applyPatchApproval" then
    params.threadId=params.threadId or "thread"; params.turnId=params.turnId or "turn"
  end
  h.ws:receive({id=id or "appr-1",method=method,params=params})
end
local function sent_to(h,id)
  for i=#h.ws.sent,1,-1 do if h.ws.sent[i].id==id then return h.ws.sent[i] end end
end

test("live approvals forward a description and reply with each method's shape",function()
  local approvals={}
  local h=harness({on_approval=function(request,reply) approvals[#approvals+1]={request=request,reply=reply} end})
  h:open(); h:start()
  approval_request(h,"item/commandExecution/requestApproval",{command="pwsh rm x",cwd="D:\\ws",reason="cleanup"},"a1")
  eq(#approvals,1); eq(approvals[1].request.kind,"command"); eq(approvals[1].request.command,"pwsh rm x")
  approvals[1].reply("accept"); local response=h:last(); eq(response.id,"a1"); eq(response.result.decision,"accept")
  approval_request(h,"item/fileChange/requestApproval",{reason="export"},"a2")
  eq(approvals[2].request.kind,"fileChange"); approvals[2].reply("decline")
  eq(h:last().result.decision,"decline")
  approval_request(h,"item/permissions/requestApproval",{cwd="D:\\ws",reason="w",
    permissions={fileSystem={write={"D:\\out"}}}},"a3")
  eq(approvals[3].request.kind,"permissions")
  assert(approvals[3].request.permissions:find("D:\\out",1,true))
  approvals[3].reply("accept")
  eq(h:last().result.scope,"turn"); eq(h:last().result.permissions.fileSystem.write[1],"D:\\out")
  approval_request(h,"item/permissions/requestApproval",{permissions={}},"a4")
  approvals[4].reply("decline"); eq(h:last().result.permissions[1],nil); eq(h:last().result.scope,"turn")
  approval_request(h,"execCommandApproval",{conversationId="thread",command="rm x",cwd="D:\\"}, "a5")
  eq(approvals[5].request.kind,"command"); approvals[5].reply("accept")
  eq(h:last().result.decision,"approved")
  approval_request(h,"applyPatchApproval",{conversationId="thread",
    fileChanges={["D:\\f.txt"]={type="update",unified_diff="@@ x"}}},"a6")
  eq(approvals[6].request.kind,"fileChange"); assert(approvals[6].request.changes:find("f%.txt"))
  approvals[6].reply("decline"); eq(h:last().result.decision.denied.rejection:len()>0,true)
end)

test("stale and reply-less approvals fall back to schema-shaped declines",function()
  local calls=0
  local h=harness({on_approval=function(_,__) calls=calls+1 end})
  h:open(); h:start()
  approval_request(h,"item/commandExecution/requestApproval",{threadId="other",turnId="turn"})
  eq(calls,0); eq(h:last().result.decision,"decline")
  approval_request(h,"execCommandApproval",{conversationId="other"},"stale")
  eq(calls,0); eq(h:last().result.decision.denied.rejection:find("declined",1,true)~=nil,true)
  approval_request(h,"item/permissions/requestApproval",{turnId="never"},"stale2")
  eq(calls,0); eq(h:last().result.scope,"turn")
end)

test("approval replies are single-use and die with stop and disconnect",function()
  local approvals={}
  local h=harness({on_approval=function(request,reply) approvals[#approvals+1]={request=request,reply=reply} end})
  h:open(); h:start()
  approval_request(h,"item/commandExecution/requestApproval",{command="a"},"a1")
  local reply=approvals[1].reply
  h.client:stop()
  local answered=sent_to(h,"a1"); eq(answered.result.decision,"cancel")
  eq(reply("accept"),false)
  approval_request(h,"execCommandApproval",{conversationId="thread"},"a2")
  eq(#approvals,1,"request arrived after stop")
  h:complete()
  h:start("turn2")
  approval_request(h,"item/fileChange/requestApproval",{turnId="turn2"},"a3")
  eq(#approvals,2)
  h.ws:event(WebSocketMessageType.CLOSE)
  eq(approvals[2].reply("accept"),false)
end)

for _,case in ipairs(tests) do
  local ok,err=xpcall(case[2],debug.traceback)
  if ok then passed=passed+1; print("PASS " .. case[1])
  else failures=failures+1; print("FAIL " .. case[1] .. "\n" .. tostring(err)) end
end
print(string.format("protocol: %d/%d tests passed",passed,#tests))
assert(failures==0,"protocol suite failed")
