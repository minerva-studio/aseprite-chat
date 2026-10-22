local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
assert(app.fs.isFile(app.fs.joinPath(root, "main.lua")), "controller is not implemented")
local passed = 0
local function scenario(name, body)
  local protocol, executor, view
  local executed, replies = 0, {}
  local modules = {
    ["codex.lua"] = { new = function(opts)
      protocol = { options = opts, state = "ready", allowed = true }
      function protocol:connect() end
      function protocol:disconnect() self.allowed = false; opts.on_cancel("disconnect") end
      function protocol:can_execute() return self.allowed end
      function protocol:send(_,_,settings) self.sent_settings=settings; self.state = "working"; return true end
      function protocol:list_models(callback)
        self.catalog_calls=(self.catalog_calls or 0)+1
        callback({
          {model="wire-a",displayName="A",isDefault=true,defaultReasoningEffort="high",supportedReasoningEfforts={{reasoningEffort="low"},{reasoningEffort="high"}}},
          {model="wire-b",displayName="B",defaultReasoningEffort="medium",supportedReasoningEfforts={{reasoningEffort="medium"}}}
        })
        return true
      end
      function protocol:stop() self.allowed = false; opts.on_cancel("stopped") end
      function protocol:new_chat() return true end
      return protocol
    end },
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
    ["chat.lua"] = { new = function()
      view = { messages = {} }
      function view:show() end
      function view:set_state() end
      function view:add_message(...) self.messages[#self.messages + 1] = {...} end
      function view:request_approval(args, callback) self.decision = callback end
      function view:dismiss_approval() end
      function view:close() end
      function view:clear() self.messages = {} end
      function view:set_models(models,model,effort) self.catalog,self.model,self.effort=models,model,effort end
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
  protocol.options.on_state("ready")
  local sprite = Sprite(4, 4)
  assert(controller:send("edit"))
  local params = { threadId = "thread", turnId = "turn", tool = "execute_lua",
    arguments = { code = "return 1", summary = "test", expectedRevision = 1 } }
  local function request()
    protocol.options.on_tool(params, function(result) replies[#replies + 1] = result end)
  end
  body(controller, protocol, executor, view, request, function() return executed, replies end)
  controller:close()
  sprite:close()
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
scenario("reconnection reloads catalog and does not silently replace an unavailable saved model",function(c,p,e,v)
  c.preferences.model="removed-model"; p.options.on_state("initializing")
  p.state="ready"; p.options.on_state("ready")
  assert(p.catalog_calls==2 and v.model=="removed-model")
  assert(not c:send("must choose again"))
  assert(c:select_settings("wire-a","low")); assert(c:send("chosen explicitly"))
end)
print("controller: " .. passed .. " passed")
