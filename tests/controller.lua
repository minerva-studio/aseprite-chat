local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
assert(app.fs.isFile(app.fs.joinPath(root, "main.lua")), "controller is not implemented")
local passed = 0
local function scenario(name, body, configuration)
  configuration=configuration or {}
  local protocol, executor, view, launcher
  local executed, replies = 0, {}
  local modules = {
    ["codex.lua"] = { new = function(opts)
      protocol = { options = opts, state = configuration.state or "ready", allowed = true }
      function protocol:connect(endpoint)
        self.connected_endpoint=endpoint; self.connect_count=(self.connect_count or 0)+1
        self.state="connecting"; opts.on_state("connecting"); return true
      end
      function protocol:disconnect() self.state="disconnected"; self.allowed = false; opts.on_cancel("disconnect") end
      function protocol:can_execute() return self.allowed end
      function protocol:send(_,_,settings) self.sent_settings=settings; self.state = "working"; return true end
      function protocol:can_steer() return self.state=="working" and self.turn_id~=nil end
      function protocol:steer(text,context) self.steered_text,self.steered_context=text,context; self.state="steering"; return true end
      function protocol:list_models(callback)
        self.catalog_calls=(self.catalog_calls or 0)+1
        callback({
          {model="wire-a",displayName="A",isDefault=true,defaultReasoningEffort="high",serviceTiers={{id="priority",name="Fast"}},supportedReasoningEfforts={{reasoningEffort="low"},{reasoningEffort="high"}}},
          {model="wire-b",displayName="B",defaultReasoningEffort="medium",supportedReasoningEfforts={{reasoningEffort="medium"}}}
        })
        return true
      end
      function protocol:list_threads(options,callback) self.history_options=options; self.list_history_callback=callback; return true end
      function protocol:open_thread(id,callback)
        self.selected_history=id; self.open_history_callback=callback
        self.state="loading"; opts.on_state("loading"); return true
      end
      function protocol:stop() self.allowed = false; opts.on_cancel("stopped") end
      function protocol:new_chat() return true end
      function protocol:rename_thread(name,callback) self.rename_name=name; self.rename_callback=callback; return true end
      return protocol
    end },
    ["launcher.lua"] = {new=function()
      launcher={attempts=0}
      function launcher:ensure(callback)
        assert(not self.pending); self.attempts=self.attempts+1; self.pending={callback=callback}; return true
      end
      function launcher:cancel() self.pending=nil end
      function launcher:complete(endpoint,err)
        local pending=self.pending; self.pending=nil; pending.callback(endpoint,err)
      end
      return launcher
    end},
    ["executor.lua"] = { tools = {}, new = function()
      executor = { revision = 1 }
      function executor:bind() end
      function executor:metadata() return { revision = self.revision } end
      function executor:check(rev) return rev == self.revision, "stale revision" end
      function executor:execute() executed = executed + 1; return { success = true, contentItems = {} } end
      function executor:read() return { success = true, contentItems = {} } end
      function executor:dispose() end
      return executor
    end },
    ["timeline.lua"] = dofile(app.fs.joinPath(root,"timeline.lua")),
    ["chat.lua"] = { new = function(callbacks)
      view = { messages = {},callbacks=callbacks }
      function view:show() end
      function view:set_state(state) self.state=state end
      function view:add_message(...) self.messages[#self.messages + 1] = {...} end
      function view:request_approval(args, callback) self.decision = callback end
      function view:dismiss_approval() end
      function view:close() end
      function view:clear() self.messages = {} end
      function view:set_models(models,model,effort) self.catalog,self.model,self.effort=models,model,effort end
      function view:set_approval_mode(enabled) self.auto_approve=enabled end
      function view:set_thread(id,name) self.thread_id,self.thread_name=id,name end
      return view
    end }
  }
  local env = setmetatable({ dofile = function(path)
    local module = modules[app.fs.fileName(path)]
    assert(module, "unexpected dependency " .. path)
    return module
  end }, { __index = _G })
  local Main = assert(loadfile(app.fs.joinPath(root, "main.lua"), "t", env))()
  local controller = Main.create { path = root, preferences = {} }
  controller:open()
  if protocol.state=="ready" then protocol.options.on_state("ready") end
  local sprite = Sprite(4, 4)
  if not configuration.skip_send then assert(controller:send("edit")) end
  local params = { threadId = "thread", turnId = "turn", callId="call-1", tool = "execute_lua",
    arguments = { code = "return 1", summary = "test", expectedRevision = 1 } }
  local function request()
    protocol.options.on_tool(params, function(result) replies[#replies + 1] = result end)
  end
  body(controller, protocol, executor, view, request, function() return executed, replies end, launcher)
  controller:close()
  if sprite.isValid then sprite:close() end
  passed = passed + 1
  print("PASS " .. name)
end
scenario("approval executes exactly once", function(c, p, e, v, request, result)
  request(); local decide = v.decision; decide(true); decide(true)
  local count, replies = result()
  assert(count == 1 and #replies == 1 and replies[1].success)
end)
scenario("stale approval does not execute", function(c, p, e, v, request, result)
  request(); e.revision = 2; v.decision(true)
  local count, replies = result()
  assert(count == 0 and #replies == 1 and not replies[1].success)
end)
scenario("reject does not execute", function(c, p, e, v, request, result)
  request(); v.decision(false)
  local count, replies = result()
  assert(count == 0 and #replies == 1 and not replies[1].success)
end)
scenario("steering cancels old approval, refreshes the captured target and echoes once",function(c,p,e,v,request,result)
  p.turn_id="turn"; request(); local old=v.decision
  function e:bind() self.revision=self.revision+1 end
  assert(c:send("Use blue instead")); assert(p.steered_text=="Use blue instead" and p.steered_context)
  old(true); local count,replies=result()
  assert(count==0 and #replies==1 and not replies[1].success)
  assert(v.messages[#v.messages][2]=="You" and v.messages[#v.messages][3]=="Use blue instead")
  assert(not c:send("duplicate"))
  p.state="working"; request(); count,replies=result()
  assert(count==0 and #replies==2 and not replies[2].success, "old revision was executed after steering")
end)
scenario("steering waits for a known turn ID without consuming the input",function(c,p)
  assert(not c:send("too early")); assert(not p.steered_text)
end)
scenario("steering remains available after closing the canvas and disposes the captured target",function(c,p,e)
  p.turn_id="turn"; app.sprite:close(); assert(not app.sprite)
  local disposed=false; function e:dispose() disposed=true end
  assert(c:send("Do not edit; explain the result"))
  assert(disposed and p.steered_context=="No open sprite. Canvas tools are unavailable.")
end)
scenario("stop invalidates pending and late approval", function(c, p, e, v, request, result)
  request(); local decide = v.decision; c:stop(); decide(true)
  local count, replies = result()
  assert(count == 0 and #replies == 1 and not replies[1].success)
end)
scenario("disconnect invalidates pending approval", function(c, p, e, v, request, result)
  request(); local decide = v.decision; c:disconnect(); decide(true)
  local count, replies = result()
  assert(count == 0 and #replies == 1 and not replies[1].success)
end)
scenario("closing and reopening starts a fresh client session", function(c, p, e, v)
  c:close(); c:open()
  assert(c.client ~= p and #v.messages == 0)
end)
scenario("approval-time observation failure is returned once and displayed", function(c, p, e, v, request, result)
  request()
  function e:check() error("observation failed") end
  v.decision(true)
  local count, replies = result()
  assert(count == 0 and #replies == 1 and not replies[1].success)
  local visible = false
  for _, message in ipairs(v.messages) do if tostring(message[3]):find("observation failed", 1, true) then visible = true end end
  assert(visible)
end)
scenario("normal connect rejection is visible and not persisted", function(c, p, e, v)
  c.preferences.manual_server=true
  function p:connect() return false, "invalid endpoint" end
  c:connect("ws://localhost:4500", "")
  assert(c.preferences.endpoint == nil)
  local visible = false
  for _, message in ipairs(v.messages) do if message[3] == "invalid endpoint" then visible = true end end
  assert(visible)
end)
do
  local env = setmetatable({}, { __index = _G })
  assert(loadfile(app.fs.joinPath(root, "main.lua"), "t", env))()
  local registered
  env.init { newCommand = function(_, command) registered = command end }
  local file = assert(io.open(app.fs.joinPath(app.fs.filePath(app.fs.appPath), "data", "gui.xml"), "r"))
  local xml = file:read("*a"); file:close()
  local groups = {}
  for group in xml:gmatch('group="([^"]+)"') do groups[group] = true end
  assert(registered and registered.id == "AsepriteChat" and groups[registered.group], "chat command must use an existing native menu group")
  passed = passed + 1
  print("PASS extension command targets an existing native menu group")
end
scenario("dropdown selections validate capabilities and change the next turn without clearing history",function(c,p,e,v)
  assert(p.sent_settings.model=="wire-a" and p.sent_settings.effort=="high")
  assert(not c:select_settings("wire-b","medium"), "selection changed during generation")
  p.state="ready"; p.options.on_state("ready")
  local count=#v.messages
  assert(not c:select_settings("wire-b","high"), "unsupported reasoning accepted")
  assert(not c:select_settings("invented","low"), "unknown model accepted")
  assert(c:select_settings("wire-b","medium"))
  assert(c.preferences.model=="wire-b" and c.preferences.effort=="medium")
  assert(c:send("next")); assert(p.sent_settings.model=="wire-b" and p.sent_settings.effort=="medium")
  assert(#v.messages>count and p.catalog_calls==1, "history or catalog lifecycle changed")
end)
scenario("Fast follows advertised tiers and standard overrides a resumed thread's speed",function(c,p,e,v)
  assert(p.sent_settings.serviceTier=="default")
  p.state="ready"
  assert(c:select_settings("wire-a","low","priority"))
  assert(c:send("fast")); assert(p.sent_settings.serviceTier=="priority")
  p.state="ready"
  assert(not c:select_settings("wire-b","medium","priority"))
  assert(c:select_settings("wire-b","medium","default"))
  assert(c:send("standard")); assert(p.sent_settings.serviceTier=="default")
end)
scenario("reconnection reloads catalog and does not silently replace an unavailable saved model",function(c,p,e,v)
  c.preferences.model="removed-model"; p.options.on_state("initializing")
  p.state="ready"; p.options.on_state("ready")
  assert(p.catalog_calls==2 and v.model=="removed-model")
  assert(not c:send("must choose again"))
  assert(c:select_settings("wire-a","low")); assert(c:send("chosen explicitly"))
end)
scenario("opening starts one automatic attempt and uses the resolved endpoint without manual preferences",function(c,p,e,v,request,result,l)
  assert(l.attempts==1 and l.pending and v.state=="starting")
  c:open(); assert(l.attempts==1, "opening twice launched duplicate services")
  l:complete("ws://127.0.0.1:45991")
  assert(p.connected_endpoint=="ws://127.0.0.1:45991" and p.connect_count==1)
  assert(not c.preferences.manual_server and c.preferences.endpoint==nil)
  p.state="ready"; p.options.on_state("ready"); assert(c:send("automatic chat"))
end,{state="disconnected",skip_send=true})
scenario("closing while starting cancels bootstrap and never starts a protocol connection",function(c,p,e,v,request,result,l)
  assert(l.pending); c:close()
  assert(not l.pending and not p.connected_endpoint and c.closed)
end,{state="disconnected",skip_send=true})
scenario("automatic startup failure explains next action and Retry starts a new attempt",function(c,p,e,v,request,result,l)
  l:complete(nil,"没有找到 Codex，请先安装或登录 Codex，然后重试。")
  assert(v.state=="error" and v.messages[#v.messages][3]:find("Codex",1,true))
  c:connect(); assert(l.attempts==2 and l.pending and v.state=="starting")
end,{state="disconnected",skip_send=true})
scenario("a new automatic port preserves the current thread and transcript",function(c,p,e,v,request,result,l)
  p.thread_id="remembered-thread"; local count=#v.messages
  c:disconnect(); c:connect(); l:complete("ws://127.0.0.1:45992")
  assert(c.client==p and p.thread_id=="remembered-thread" and #v.messages==count)
end)
scenario("automatic edit approval is opt-in and still revalidates and executes once",function(c,p,e,v,request,result)
  assert(c.auto_approve==false)
  assert(not c:set_approval_mode(true), "approval mode changed during generation")
  p.state="ready"; assert(c:set_approval_mode(true)); assert(v.auto_approve)
  p.state="working"; request()
  local count,replies=result()
  assert(count==1 and #replies==1 and replies[1].success and not v.decision)
  local logged=false
  for _,row in ipairs(v.messages) do if row[2]=="Tool" and row[3]:find("Succeeded",1,true) and row[3]:find("return 1",1,true) then logged=true end end
  assert(logged, "approved edit has no actual execution record")
end)
scenario("automatic approval rejects stale documents without execution",function(c,p,e,v,request,result)
  p.state="ready"; assert(c:set_approval_mode(true)); p.state="working"
  local checks=0
  function e:check() checks=checks+1; return checks==1,"stale after initial check" end
  request(); local count,replies=result()
  assert(count==0 and #replies==1 and not replies[1].success)
end)
scenario("new chat and close reset temporary automatic approval",function(c,p,e,v)
  p.state="ready"; assert(c:set_approval_mode(true)); c:new_chat()
  assert(c.auto_approve==false and v.auto_approve==false)
  assert(c:set_approval_mode(true)); c:close()
  assert(c.auto_approve==false and v.auto_approve==false)
end)
scenario("opening history replaces display only on success and never replays edits",function(c,p,e,v,request,result)
  p.state="ready"; assert(c:set_approval_mode(true))
  local count=#v.messages
  assert(c:open_thread("stored")); assert(#v.messages==count and v.state=="loading")
  p.thread_id="stored"; p.state="ready"; p.options.on_state("ready")
  p.open_history_callback({thread={id="stored",preview='Old prompt\n\nCurrent Aseprite target:\n{"revision":123}'},turns={{items={
    {id="old-user",type="userMessage",content={{type="text",text="Old prompt"}}},
    {id="old-tool",type="dynamicToolCall",tool="execute_lua",arguments={code="return 123"},status="completed",success=true},
    {id="old-agent",type="agentMessage",text="Old answer"}
  }}}})
  local executed,replies=result()
  assert(executed==0 and #replies==0 and not c.auto_approve)
  assert(v.messages[1][3]=="Old prompt" and v.messages[3][3]=="Old answer")
  assert(v.messages[#v.messages][3]=="Opened conversation: stored", "open notice exposed raw metadata preview")
end)
scenario("failed history open preserves conversation and reports a visible error",function(c,p,e,v)
  p.state="ready"; local first=v.messages[1]
  assert(c:open_thread("missing")); p.state="ready"
  p.open_history_callback(nil,"Conversation unavailable")
  assert(v.messages[1]==first and v.messages[#v.messages][3]:find("Conversation unavailable",1,true))
end)
scenario("reasoning item updates are displayed separately from agent answers",function(c,p,e,v)
  p.options.on_item({id="summary",type="reasoning",summary={"Inspect layers"},content={"raw hidden"}},true)
  local row=v.messages[#v.messages]
  assert(row[1]=="activity:summary" and row[2]=="Summary" and row[3]=="Inspect layers")
  assert(p.sent_settings.summary=="auto", "reasoning summary was not requested")
end)
scenario("empty completed reasoning clears the streamed summary",function(c,p,e,v)
  p.options.on_item({id="summary",type="reasoning",summary={"Temporary summary"}},false)
  p.options.on_item({id="summary",type="reasoning",summary={}},true)
  local row=v.messages[#v.messages]
  assert(row[1]=="activity:summary" and row[2]=="Summary" and row[3]=="", "final empty summary did not replace streaming content")
end)
scenario("live user notifications do not duplicate the local send echo",function(c,p,e,v)
  local count=#v.messages
  p.options.on_item({id="sent-user",type="userMessage",content={{type="text",text="edit"}}},false)
  p.options.on_item({id="sent-user",type="userMessage",content={{type="text",text="edit"}}},true)
  assert(#v.messages==count, "provider user item duplicated the local send echo")
end)
print("controller: " .. passed .. " passed")
