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

local function valid_settings(models, model, effort)
  for _, entry in ipairs(models or {}) do
    if entry.model == model then
      if #entry.supportedReasoningEfforts == 0 and effort == nil then return true end
      for _, option in ipairs(entry.supportedReasoningEfforts) do
        if option.reasoningEffort == effort then return true end
      end
      return false, "Choose a reasoning level supported by this model."
    end
  end
  return false, "Choose an available model after connecting."
end

function Controller:_load_models()
  self.client:list_models(function(models, err)
    self.models = models or {}
    if not models then self:_message("Error", err or "Cannot load model list. Reconnect to retry.") end
    if not self.preferences.model or self.preferences.model == "" then
      local selected = self.models[1]
      for _, entry in ipairs(self.models) do if entry.isDefault then selected = entry; break end end
      if selected then
        self.preferences.model = selected.model
        self.preferences.effort = #selected.supportedReasoningEfforts > 0 and selected.defaultReasoningEffort or nil
      end
    end
    for _, entry in ipairs(self.models) do
      if entry.model == self.preferences.model and self.preferences.effort == nil
          and #entry.supportedReasoningEfforts > 0 then
        self.preferences.effort = entry.defaultReasoningEffort
      end
    end
    self.view:set_models(self.models, self.preferences.model, self.preferences.effort)
    local valid, why = valid_settings(self.models, self.preferences.model, self.preferences.effort)
    if not valid and models then self:_message("Aseprite", why) end
  end)
end

function Controller:_create_client()
  return self.Codex.new {
    tools = self.Executor.tools, instructions = instructions,
    on_state = function(state)
      if state == "initializing" then self.models = nil; self.view:set_models(nil) end
      if state == "ready" then
        self:_cancel_pending("Turn ended before execution.")
        if self.models == nil then self:_load_models() end
      end
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
    on_connect = function(endpoint) self:connect(endpoint) end,
    on_settings = function(model, effort) return self:select_settings(model, effort) end,
    on_disconnect = function() self:disconnect() end,
    on_send = function(text) return self:send(text) end,
    on_stop = function() self:stop() end,
    on_new_chat = function() self:new_chat() end,
    on_close = function() self:close() end
  }, self.preferences)
  self.client = self:_create_client()
  return self
end

--- Show the chat window and track site changes for native control availability.
function Controller:open()
  if self.closed then
    self.client = self:_create_client()
    self.view:clear()
    self.closed = false
  end
  self.view:show()
  if not self.site_listener then
    self.site_listener = app.events:on("sitechange", function() self.view:set_state(self.client.state) end)
  end
end

--- Connect to a local bridge. Changing endpoint starts a new conversation.
function Controller:connect(endpoint)
  endpoint = endpoint:match("^%s*(.-)%s*$")
  if self.preferences.endpoint and self.preferences.endpoint ~= endpoint then
    self:disconnect()
    self.client = self:_create_client()
    self.view:clear()
  end
  local ok, connected, err = pcall(self.client.connect, self.client, endpoint)
  if not ok then self:_message("Error", connected)
  elseif not connected then self:_message("Error", err or "Connection was not started.")
  else self.preferences.endpoint = endpoint end
  self.view:set_state(self.client.state)
end

--- Select catalog-supported settings for the next turn without replacing its thread.
function Controller:select_settings(model, effort)
  if self.client.state ~= "ready" then return false, "Wait for the current turn to finish." end
  local valid, why = valid_settings(self.models, model, effort)
  if not valid then return false, why end
  self.preferences.model, self.preferences.effort = model, effort
  self.view:set_models(self.models, model, effort)
  return true
end

--- Submit a prompt against the currently open sprite without saving it.
function Controller:send(text)
  if not text or text:match("^%s*$") then return false end
  if self.client.state ~= "ready" then self:_message("Aseprite", "Connect and wait for the current turn to finish."); return false end
  local valid, why = valid_settings(self.models, self.preferences.model, self.preferences.effort)
  if not valid then self:_message("Aseprite", why); return false end
  if not app.sprite then self:_message("Aseprite", "Open a sprite before sending a message."); return false end
  local ok, context = pcall(function()
    self.executor:bind(app.sprite, app.frame, app.layer)
    return json.encode(self.executor:metadata())
  end)
  if not ok then self:_message("Error", context); return false end
  local sent, err = self.client:send(text, context, {model=self.preferences.model, effort=self.preferences.effort})
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
