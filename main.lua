local Main = {}
local Controller = {}
Controller.__index = Controller

local instructions = [[You are an artist working inside the user's running Aseprite editor.
Reply concisely in plain text, in the user's language. Do not use Markdown or code fences.
Use read_sprite to inspect the live unsaved document before every edit; it returns the current revision and a rendered preview.
Use execute_lua for edits. Its Lua environment provides sprite, app, Aseprite constructors/constants, and basic Lua libraries.
Use only short, terminating scripts. Edits must target the captured sprite and be undoable.
For pixel edits, clone a cel image, modify the clone, then assign cel.image = clone; direct drawPixel on an attached image does not create Undo.
The plugin owns the app.transaction boundary. Do not save/open/close documents, access external files, run shell commands, or call other apps.
If the document or context became stale, inspect again. Never claim an edit succeeded until execute_lua returns success.
The user must approve each execute_lua call. Treat rejection as a decision, not an invitation to retry the same edit.
Each prompt includes the current target sprite/frame/layer context. Conversation history may concern a different target.
]]

local function failure(text)
  return { success = false, contentItems = { { type = "inputText", text = tostring(text) } } }
end

function Controller:_message(role, text)
  self.message_id = self.message_id + 1
  self.view:add_message("local-" .. self.message_id, role, tostring(text), false)
end

function Controller:_cancel_pending(reason)
  local pending = self.pending
  self.pending = nil
  self.view:dismiss_approval()
  if pending then pending.reply(failure(reason)) end
end

function Controller:_tool(params, reply)
  if not self.client:can_execute(params) then reply(failure("Turn is no longer active.")); return end
  local args = params.arguments
  if params.tool == "read_sprite" then
    local ok, result = pcall(self.executor.read, self.executor, args)
    reply(ok and result or failure(result))
    return
  end
  if params.tool ~= "execute_lua" then reply(failure("Unknown Aseprite tool.")); return end
  if not args or type(args.code) ~= "string" or type(args.summary) ~= "string"
      or type(args.expectedRevision) ~= "number" or args.expectedRevision % 1 ~= 0 then
    reply(failure("execute_lua requires code, summary, and an integer expectedRevision.")); return
  end
  if self.pending then reply(failure("Another Lua request is awaiting approval.")); return end
  local valid, reason = self.executor:check(args.expectedRevision)
  if not valid then reply(failure(reason)); return end
  local pending = { params = params, args = args, reply = reply }
  self.pending = pending
  self.view:request_approval(args, function(accepted)
    if self.pending ~= pending then return end
    self.pending = nil
    if not accepted then reply(failure("User rejected the proposed edit.")); return end
    local ok, result = pcall(function()
      if not self.client:can_execute(params) then return failure("Turn is no longer active.") end
      local current, why = self.executor:check(args.expectedRevision)
      if not current then return failure(why) end
      return self.executor:execute(args)
    end)
    if not ok then result = failure(result) end
    reply(result)
    self:_message("Aseprite", result.success and ("Applied: " .. args.summary .. " · Undo is available.")
      or ("Edit failed: " .. tostring(result.contentItems[1].text)))
  end)
end

function Controller:_create_client(model)
  return self.Codex.new {
    tools = self.Executor.tools, instructions = instructions, model = model ~= "" and model or nil,
    on_state = function(state)
      if state == "ready" then self:_cancel_pending("Turn ended before execution.") end
      self.view:set_state(state)
    end,
    on_message = function(id, text, delta) self.view:add_message(id, "Codex", text, delta) end,
    on_tool = function(params, reply) self:_tool(params, reply) end,
    on_cancel = function(reason)
      self:_cancel_pending(reason or "Turn cancelled.")
      self.executor:dispose()
    end,
    on_error = function(text) self:_message("Error", text) end
  }
end

--- Assemble one editor session; path is the installed extension directory.
function Main.create(options)
  local self = setmetatable({ preferences = options.preferences, message_id = 0 }, Controller)
  self.Codex = dofile(app.fs.joinPath(options.path, "codex.lua"))
  self.Executor = dofile(app.fs.joinPath(options.path, "executor.lua"))
  local Chat = dofile(app.fs.joinPath(options.path, "chat.lua"))
  self.executor = self.Executor.new()
  self.view = Chat.new({
    on_connect = function(endpoint, model) self:connect(endpoint, model) end,
    on_disconnect = function() self:disconnect() end,
    on_send = function(text) return self:send(text) end,
    on_stop = function() self:stop() end,
    on_new_chat = function() self:new_chat() end,
    on_close = function() self:close() end
  }, self.preferences)
  self.client = self:_create_client(self.preferences.model or "")
  return self
end

--- Show the chat window and track site changes for native control availability.
function Controller:open()
  if self.closed then
    self.client = self:_create_client(self.preferences.model or "")
    self.view:clear()
    self.closed = false
  end
  self.view:show()
  if not self.site_listener then
    self.site_listener = app.events:on("sitechange", function() self.view:set_state(self.client.state) end)
  end
end

--- Connect to a local app-server. Changing endpoint/model starts a new conversation.
function Controller:connect(endpoint, model)
  model = (model or ""):match("^%s*(.-)%s*$")
  endpoint = endpoint:match("^%s*(.-)%s*$")
  if (self.preferences.model or "") ~= model or (self.preferences.endpoint and self.preferences.endpoint ~= endpoint) then
    self:disconnect()
    self.client = self:_create_client(model)
    self.view:clear()
  end
  local ok, connected, err = pcall(self.client.connect, self.client, endpoint)
  if not ok then self:_message("Error", connected)
  elseif not connected then self:_message("Error", err or "Connection was not started.")
  else self.preferences.endpoint, self.preferences.model = endpoint, model end
  self.view:set_state(self.client.state)
end

--- Submit a prompt against the currently open sprite without saving it.
function Controller:send(text)
  if not text or text:match("^%s*$") then return false end
  if self.client.state ~= "ready" then self:_message("Aseprite", "Connect and wait for the current turn to finish."); return false end
  if not app.sprite then self:_message("Aseprite", "Open a sprite before sending a message."); return false end
  local ok, context = pcall(function()
    self.executor:bind(app.sprite, app.frame, app.layer)
    return json.encode(self.executor:metadata())
  end)
  if not ok then self:_message("Error", context); return false end
  local sent, err = self.client:send(text, context)
  if sent then self:_message("You", text) else self:_message("Error", err or "Message was not sent.") end
  return sent
end

--- Invalidate execution permission before asking Codex to interrupt the turn.
function Controller:stop()
  self:_cancel_pending("User stopped the task.")
  self.client:stop()
end

--- Disconnect transport and invalidate pending document operations.
function Controller:disconnect()
  self:_cancel_pending("Disconnected before execution.")
  self.client:disconnect()
  self.executor:dispose()
end

--- Start a fresh conversation while retaining connection settings.
function Controller:new_chat()
  local ok, err = self.client:new_chat()
  if ok then
    self:_cancel_pending("New conversation.")
    self.executor:dispose()
    self.view:clear()
  else self:_message("Error", err or "Cannot start a new chat during a turn.") end
end

--- Release all native resources owned by this editor session.
function Controller:close()
  self:disconnect()
  if self.site_listener then app.events:off(self.site_listener); self.site_listener = nil end
  self.view:close()
  self.closed = true
end

local controller
function init(plugin)
  plugin:newCommand {
    id = "AsepriteChat", title = "Aseprite Chat", group = "view_controls",
    onclick = function()
      if not controller then controller = Main.create { path = plugin.path, preferences = plugin.preferences } end
      controller:open()
    end
  }
end

function exit(plugin)
  if controller then controller:close(); controller = nil end
end

return Main
