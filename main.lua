local Main = {}
local Controller = {}
Controller.__index = Controller

local instructions = [[You are an artist working inside the user's running Aseprite editor.
Reply concisely in plain text, in the user's language. Do not use Markdown or code fences.
Use read_sprite to inspect the live unsaved document before every edit; it returns the current revision and rendered previews (frame/frames/tag/layers/region/grid options).
Use read_pixels for exact pixel values of a small region; do not spend an execute_lua approval on reads.
The metadata's openSprites lists every open document; other sprites are read-only references.
Use switch_sprite with a spriteId to move the editing target to another open sprite; edits apply only to the current target.
Depending on the user's access setting, shell commands and view_image may also be available.
Use them only to read references or to write exports the user asked for; never write to a file that is currently open in Aseprite.
Use execute_lua for canvas edits. Its Lua environment provides sprite, app, Aseprite constructors/constants, and basic Lua libraries.
Use only short, terminating scripts. Edits must target the captured sprite and be undoable.
For pixel edits, clone a cel image, modify the clone, then assign cel.image = clone; direct drawPixel on an attached image does not create Undo.
The plugin owns the app.transaction boundary. Inside execute_lua, do not save/open/close documents, access external files, run shell commands, or call other apps.
If the document or context became stale, inspect again. Never claim an edit succeeded until execute_lua returns success.
The client controls edit approval: each execute_lua call is either approved individually or covered by the user's explicit auto-approval for this chat.
Treat rejection as a decision, not an invitation to retry the same edit.
Each prompt includes the current target sprite/frame/layer context. Conversation history may concern a different target.
]]

local function failure(text)
  return { success = false, contentItems = { { type = "inputText", text = tostring(text) } } }
end

function Controller:_message(role, text)
  self.message_id = self.message_id + 1
  self.view:add_message("local-" .. self.message_id, role, tostring(text), false)
end

function Controller:_refresh_state()
  self.view:set_thread(self.client.thread_id,self.client.thread_name)
  self.view:set_state(self.startup_error and "error" or self.launcher.pending and "starting" or self.client.state,self.client:can_steer())
end

function Controller:_cancel_pending(reason)
  local pending = self.pending
  self.pending = nil
  local codex_approval = self.codex_approval
  self.codex_approval = nil
  self.view:dismiss_approval()
  if pending then pending.reply(failure(reason),"Cancelled") end
  if codex_approval then codex_approval.reply("decline") end
end

function Controller:_tool(params, reply)
  if not self.client:can_execute(params) then reply(failure("Turn is no longer active.")); return end
  local args = params.arguments
  local id="tool:" .. params.callId
  local function respond(result,status)
    local delivered=reply(result)
    status=status or (result.success and "Succeeded" or "Failed")
    if delivered==false then status=result.success and "Completed locally; reply not sent" or "Cancelled" end
    self.view:add_message(id,"Tool",self.Timeline.tool(params.tool,args,status,result),false)
    return delivered
  end
  self.view:add_message(id,"Tool",self.Timeline.tool(params.tool,args,"Running"),false)
  if params.tool == "read_sprite" then
    local ok, result = pcall(self.executor.read, self.executor, args)
    respond(ok and result or failure(result))
    return
  end
  if params.tool == "read_pixels" then
    local ok, result = pcall(self.executor.read_pixels, self.executor, args)
    respond(ok and result or failure(result))
    return
  end
  if params.tool == "switch_sprite" then
    if self.pending then respond(failure("Another Lua request is awaiting approval.")); return end
    local ok, result = pcall(self.executor.switch, self.executor, args)
    respond(ok and result or failure(result))
    return
  end
  if params.tool ~= "execute_lua" then respond(failure("Unknown Aseprite tool.")); return end
  if not args or type(args.code) ~= "string" or type(args.summary) ~= "string"
      or type(args.expectedRevision) ~= "number" or args.expectedRevision % 1 ~= 0 then
    respond(failure("execute_lua requires code, summary, and an integer expectedRevision.")); return
  end
  if self.pending then respond(failure("Another Lua request is awaiting approval.")); return end
  local valid, reason = self.executor:check(args.expectedRevision)
  if not valid then respond(failure(reason)); return end
  local pending = { params = params, args = args, reply = respond }
  self.pending = pending
  local function decide(accepted)
    if self.pending ~= pending then return end
    self.pending = nil
    if not accepted then respond(failure("User rejected the proposed edit."),"Rejected"); return end
    local ok, result = pcall(function()
      if not self.client:can_execute(params) then return failure("Turn is no longer active.") end
      local current, why = self.executor:check(args.expectedRevision)
      if not current then return failure(why) end
      return self.executor:execute(args)
    end)
    if not ok then result = failure(result) end
    respond(result)
  end
  if self.auto_approve then decide(true)
  else
    self.view:add_message(id,"Tool",self.Timeline.tool(params.tool,args,"Awaiting approval"),false)
    self.view:request_approval(args,decide)
  end
end

local function valid_settings(models, model, effort, tier)
  for _, entry in ipairs(models or {}) do
    if entry.model == model then
      if tier and tier~="default" then
        local supported=false
        for _,option in ipairs(entry.serviceTiers or {}) do
          if option.id==tier and (tier=="priority" or tier=="fast") then supported=true end
        end
        if not supported then return false,"Choose a speed supported by this model." end
      end
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
  local function present(models, err)
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
      if entry.model==self.preferences.model then
        local fast=false
        for _,tier in ipairs(entry.serviceTiers or {}) do
          if tier.id=="priority" or tier.id=="fast" then fast=true end
        end
        -- Unsupported models have no speed control, so retire an old Fast choice.
        if not fast then self.preferences.service_tier="default" end
      end
      if entry.model == self.preferences.model and self.preferences.effort == nil
          and #entry.supportedReasoningEfforts > 0 then
        self.preferences.effort = entry.defaultReasoningEffort
      end
    end
    self.view:set_models(self.models, self.preferences.model, self.preferences.effort,self.preferences.service_tier)
    local valid, why = valid_settings(self.models, self.preferences.model, self.preferences.effort,self.preferences.service_tier)
    if not valid and models then self:_message("Aseprite", why) end
  end
  -- A custom account's explicit model list replaces the server catalog;
  -- model/list always reports Codex's bundled OpenAI entries anyway.
  local catalog = self.Account.catalog(self.account)
  if catalog then present(catalog); return end
  self.client:list_models(present)
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
      self:_refresh_state()
    end,
    on_message = function(id, text, delta) self.view:add_message(id, "Codex", text, delta) end,
    on_thread = function(id,name) self.view:set_thread(id,name) end,
    on_item = function(item,completed)
      -- Local tool results are authoritative; notifications must not overwrite
      -- cancellation/rejection with a generic completed dynamic-tool status.
      -- User prompts already have one local echo; history projects stored items.
      if item.type=="dynamicToolCall" or item.type=="userMessage" then return end
      local role,text=self.Timeline.item(item)
      if item.type=="reasoning" and completed and not role then role,text="Summary","" end
      if role and text then self.view:add_message("activity:" .. item.id,role,text,false) end
    end,
    on_tool = function(params, reply) self:_tool(params, reply) end,
    on_approval = function(request, reply) self:_approval(request, reply) end,
    thread_settings = function() return self:_thread_settings() end,
    on_cancel = function(reason)
      self:_cancel_pending(reason or "Turn cancelled.")
      self.executor:dispose()
    end,
    on_error = function(text) self:_message("Error", text) end
  }
end

-- The current account's access level becomes the per-thread sandbox and
-- approval routing; cwd is the workspace folder or the user profile, never the
-- extension directory.
function Controller:_thread_settings()
  local account = self.account or {}
  local access = account.access or "canvas"
  local sandbox = ({ canvas = "read-only", read = "read-only",
    workspace = "workspace-write", full = "danger-full-access" })[access] or "read-only"
  local cwd = access == "workspace" and account.workspace or nil
  if not cwd or cwd == "" then cwd = os.getenv("USERPROFILE") end
  return { sandbox = sandbox, cwd = cwd, approvalPolicy = "on-request",
    approvalsReviewer = account.reviewer == "auto_review" and "auto_review" or "user" }
end

--- Forward a Codex boundary approval to the shared approval window. The window
--- shows one request at a time; concurrent requests are declined immediately.
function Controller:_approval(request, reply)
  local titles = { command = "Approve Codex command", fileChange = "Approve file changes",
    permissions = "Approve permissions" }
  local title = titles[request.kind] or "Approve Codex request"
  if self.pending or self.codex_approval then
    self.view:add_message("approval-decline:" .. self.message_id, "Tool",
      title .. " · Declined · another request is awaiting approval", false)
    reply("decline")
    return
  end
  local lines = {}
  if request.command then lines[#lines + 1] = "Command:\n" .. request.command end
  if request.cwd then lines[#lines + 1] = "Directory: " .. request.cwd end
  if request.reason then lines[#lines + 1] = "Reason: " .. request.reason end
  if request.changes then lines[#lines + 1] = "Changes:\n" .. request.changes end
  if request.permissions then lines[#lines + 1] = "Permissions:\n" .. request.permissions end
  local body = #lines > 0 and table.concat(lines, "\n\n") or "Codex requested an approval."
  self.message_id = self.message_id + 1
  local id = "approval:" .. self.message_id
  self.codex_approval = { reply = reply, id = id }
  self.view:add_message(id, "Tool", title .. " · Awaiting approval\n" .. body, false)
  self.view:request_approval({ title = title, body = body,
    note = "Approved requests run outside the canvas sandbox for this turn." }, function(accepted)
      local held = self.codex_approval
      if not held or held.id ~= id then return end
      self.codex_approval = nil
      self.view:add_message(id, "Tool", title .. " · " .. (accepted and "Approved" or "Declined") .. "\n" .. body, false)
      held.reply(accepted and "accept" or "decline")
    end)
end

--- Assemble one editor session; path is the installed extension directory.
function Main.create(options)
  local self = setmetatable({ preferences = options.preferences, message_id = 0,auto_approve=false }, Controller)
  self.Codex = dofile(app.fs.joinPath(options.path, "codex.lua"))
  self.Executor = dofile(app.fs.joinPath(options.path, "executor.lua"))
  self.Timeline = dofile(app.fs.joinPath(options.path,"timeline.lua"))
  self.Account = dofile(app.fs.joinPath(options.path, "account.lua"))
  self.account, self.account_error = self.Account.load(self.Account.path())
  local Launcher = dofile(app.fs.joinPath(options.path, "launcher.lua"))
  self.launcher = Launcher.new {path=options.path}
  local Chat = dofile(app.fs.joinPath(options.path, "chat.lua"))
  self.executor = self.Executor.new()
  self.view = Chat.new({
    on_connect = function(endpoint) self:connect(endpoint) end,
    on_settings = function(model, effort, tier) return self:select_settings(model, effort, tier) end,
    on_disconnect = function() self:disconnect() end,
    on_send = function(text) return self:send(text) end,
    on_stop = function() self:stop() end,
    on_new_chat = function() self:new_chat() end,
    on_list_threads = function(search,cursor,callback) return self.client:list_threads({search=search,cursor=cursor},callback) end,
    on_open_thread = function(id) return self:open_thread(id) end,
    on_approval_mode = function(enabled) return self:set_approval_mode(enabled) end,
    on_rename = function(name,callback) return self.client:rename_thread(name,callback) end,
    on_account_get = function() return self:account_view() end,
    on_account_apply = function(draft) return self:apply_account(draft) end,
    on_access_get = function() return self:access_view() end,
    on_access_apply = function(draft) return self:apply_access(draft) end,
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
  if self.account_error then
    self:_message("Error", self.account_error)
    self.account_error = nil
  end
  if not self.site_listener then
    self.site_listener = app.events:on("sitechange", function() self:_refresh_state() end)
  end
  if (self.client.state == "disconnected" or self.client.state == "error") and not self.launcher.pending then
    self:connect(self.preferences.manual_server and self.preferences.endpoint or nil)
  end
end

function Controller:_connect_endpoint(endpoint, manual)
  local ok, connected, err = pcall(self.client.connect, self.client, endpoint)
  if not ok then self:_message("Error", connected)
  elseif not connected then self:_message("Error", err or "Connection was not started.")
  elseif manual then self.preferences.endpoint = endpoint end
  self:_refresh_state()
end

--- Resolve a local service automatically; an explicit endpoint opts into advanced manual mode.
--- Automatic port changes retain the Codex thread; explicit server changes start a fresh one.
function Controller:connect(endpoint)
  if self.launcher.pending then return end
  local manual = endpoint ~= nil
  if manual then endpoint = endpoint:match("^%s*(.-)%s*$") end
  local mode_changed = (self.preferences.manual_server == true) ~= manual
  local server_changed = manual and self.preferences.endpoint and self.preferences.endpoint ~= endpoint
  if mode_changed or server_changed then
    self:disconnect()
    self:set_approval_mode(false)
    self.client = self:_create_client()
    self.view:clear()
  else self.client:disconnect() end
  self.preferences.manual_server = manual
  self.startup_error = nil
  if manual then self:_connect_endpoint(endpoint, true); return end
  local ok, err = pcall(self.launcher.ensure, self.launcher, function(resolved, error_text)
    if resolved then self:_connect_endpoint(resolved, false)
    else
      self.startup_error = error_text or "本地服务没有启动成功。请点击 Retry 重试。"
      self:_message("Error", self.startup_error)
      self:_refresh_state()
    end
  end)
  if not ok then
    print("Aseprite Chat startup diagnostic: " .. tostring(err))
    self.startup_error = "无法启动本地服务。请允许 Aseprite 启动插件的连接程序，然后点击 Retry。"
    self:_message("Error", self.startup_error)
  end
  self:_refresh_state()
end

--- Permit automatic captured-sprite edits only for this open chat, never preferences.
--- Enabling requires an idle client; disabling is valid during lifecycle cleanup.
function Controller:set_approval_mode(enabled)
  if type(enabled)~="boolean" then return false,"Approval mode must be a boolean." end
  if enabled and (self.client.state~="ready" or self.pending) then return false,"Wait until the chat is idle." end
  self.auto_approve=enabled
  self.view:set_approval_mode(enabled)
  return true
end

--- Restore a persisted plugin conversation as display data; historical tools never run.
function Controller:open_thread(id)
  if self.client.state~="ready" or self.pending then return false,"Wait until the chat is idle." end
  return self.client:open_thread(id,function(result,err)
    if not result then self:_message("Error",err or "Cannot open conversation."); return end
    self:set_approval_mode(false)
    self.executor:dispose()
    self.view:clear()
    for _,row in ipairs(self.Timeline.history(result.turns)) do self.view:add_message(row.id,row.role,row.text,false) end
    local name=result.thread.name
    if not name or name=="" then name=result.thread.id end
    self:_message("Aseprite","Opened conversation: " .. name)
  end)
end

--- Select catalog-supported settings for the next turn without replacing its thread.
function Controller:select_settings(model, effort, tier)
  if self.client.state ~= "ready" then return false, "Wait for the current turn to finish." end
  tier=tier or "default"
  local valid, why = valid_settings(self.models, model, effort,tier)
  if not valid then return false, why end
  self.preferences.model, self.preferences.effort, self.preferences.service_tier = model, effort, tier
  self.view:set_models(self.models, model, effort,tier)
  return true
end

--- Start a turn or steer its direction; steering retires proposals and rebinds the target.
function Controller:send(text)
  if not text or text:match("^%s*$") then return false end
  local steering=self.client.state=="working"
  if self.client.state ~= "ready" and not steering then self:_message("Aseprite", "Wait for the current request or connect first."); return false end
  if steering and not self.client:can_steer() then self:_message("Aseprite","Wait for the active turn before steering."); return false end
  local valid, why = valid_settings(self.models, self.preferences.model, self.preferences.effort,self.preferences.service_tier)
  if not valid then self:_message("Aseprite", why); return false end
  if not app.sprite and not steering then self:_message("Aseprite", "Open a sprite before sending a message."); return false end
  if steering then self:_cancel_pending("Superseded by your steering instruction.") end
  local ok, context = pcall(function()
    if not app.sprite then self.executor:dispose(); return "No open sprite. Canvas tools are unavailable." end
    return json.encode(self.executor:bind(app.sprite, app.frame, app.layer))
  end)
  if not ok then self:_message("Error", context); return false end
  local sent, err
  if steering then sent,err=self.client:steer(text,context)
  else sent,err=self.client:send(text, context, {model=self.preferences.model, effort=self.preferences.effort,
    summary=self.preferences.effort and "auto" or nil,serviceTier=self.preferences.service_tier or "default"}) end
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
  self.launcher:cancel()
  self.startup_error = nil
  self:_cancel_pending("Disconnected before execution.")
  self.client:disconnect()
  self.executor:dispose()
  self:_refresh_state()
end

--- The sanitized account projection shown in Settings; the stored key itself
--- never reaches the view, only a trailing hint.
function Controller:account_view()
  local account = self.account or {}
  local key = type(account.apiKey) == "string" and account.apiKey or ""
  return {
    mode = account.mode == "custom" and "custom" or "default",
    codexHome = account.codexHome or self.Account.default_home(),
    baseUrl = account.baseUrl or "",
    models = table.concat(account.models or {}, ", "),
    keyHint = key ~= "" and (#key > 4 and "…" .. key:sub(-4) or "…") or nil
  }
end

--- Replace the stored account and restart the connection on its new home.
--- draft={mode,codexHome,baseUrl,apiKey=nonempty replacement or nil,clearKey,models=csv}.
--- Custom fields are retained while mode is default so toggling back keeps them.
function Controller:apply_account(draft)
  local offline = self.client.state == "disconnected" or self.client.state == "error"
  if (self.client.state ~= "ready" and not offline) or self.pending or self.launcher.pending then
    return false, "Wait until the chat is idle."
  end
  draft = draft or {}
  local key
  if draft.clearKey then key = ""
  elseif type(draft.apiKey) == "string" and draft.apiKey ~= "" then key = draft.apiKey
  else key = self.account and self.account.apiKey or "" end
  local models = {}
  for name in tostring(draft.models or ""):gmatch("[^,]+") do
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed ~= "" then models[#models + 1] = trimmed end
  end
  local account = {
    version = 1,
    mode = draft.mode == "custom" and "custom" or "default",
    codexHome = tostring(draft.codexHome or ""):match("^%s*(.-)%s*$"),
    baseUrl = tostring(draft.baseUrl or ""):match("^%s*(.-)%s*$"),
    apiKey = key,
    models = models
  }
  local valid, invalid = self.Account.validate(account)
  if not valid then return false, invalid end
  local current = self.account or {}
  local current_models = current.models or {}
  local unchanged = account.mode == (current.mode or "default")
    and account.codexHome == (current.codexHome or "")
    and account.baseUrl == (current.baseUrl or "")
    and account.apiKey == (current.apiKey or "")
    and #account.models == #current_models
  if unchanged then
    for index, name in ipairs(account.models) do
      if name ~= current_models[index] then unchanged = false; break end
    end
  end
  if unchanged then return true end
  local saved, save_error = self.Account.save(self.Account.path(), account)
  if not saved then return false, save_error or "Cannot save the account file." end
  self.account = account
  self.preferences.model, self.preferences.effort, self.preferences.service_tier = nil, nil, "default"
  self:disconnect()
  self:set_approval_mode(false)
  self.client = self:_create_client()
  self.view:clear()
  self:_message("Aseprite", "The Codex account changed; a new conversation started.")
  self:connect(self.preferences.manual_server and self.preferences.endpoint or nil)
  return true
end

--- The sanitized access projection shown in Settings.
function Controller:access_view()
  local account = self.account or {}
  return { access = account.access or "canvas",
    workspace = account.workspace or "",
    reviewer = account.reviewer or "user" }
end

--- Change the file-access level and reconnect so the current thread resumes
--- under the new sandbox and approval routing, keeping the conversation.
function Controller:apply_access(draft)
  local offline = self.client.state == "disconnected" or self.client.state == "error"
  if (self.client.state ~= "ready" and not offline) or self.pending or self.launcher.pending then
    return false, "Wait until the chat is idle."
  end
  draft = draft or {}
  local current = self.account or {}
  local account = {}
  for key, value in pairs(current) do account[key] = value end
  account.access = draft.access or "canvas"
  account.workspace = tostring(draft.workspace or ""):match("^%s*(.-)%s*$")
  account.reviewer = draft.reviewer == "auto_review" and "auto_review" or "user"
  local valid, invalid = self.Account.validate(account)
  if not valid then return false, invalid end
  if account.access == (current.access or "canvas")
      and account.workspace == (current.workspace or "")
      and account.reviewer == (current.reviewer or "user") then return true end
  local saved, save_error = self.Account.save(self.Account.path(), account)
  if not saved then return false, save_error or "Cannot save the account file." end
  self.account = account
  self:disconnect()
  self:connect(self.preferences.manual_server and self.preferences.endpoint or nil)
  local labels = { canvas = "canvas only", read = "file read", workspace = "workspace write", full = "full access" }
  self:_message("Aseprite", "File access changed to " .. (labels[account.access] or account.access)
    .. "; the conversation continues on a reconnected session.")
  return true
end

--- Start a fresh conversation while retaining connection settings.
function Controller:new_chat()
  local ok, err = self.client:new_chat()
  if ok then
    self:set_approval_mode(false)
    self:_cancel_pending("New conversation.")
    self.executor:dispose()
    self.view:clear()
  else self:_message("Error", err or "Cannot start a new chat during a turn.") end
end

--- Release all native resources owned by this editor session.
function Controller:close()
  self:set_approval_mode(false)
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
  plugin:newCommand {
    id="AsepriteChatSend",title="Aseprite Chat: Send / Steer",group="view_controls",
    onenabled=function() return controller~=nil and controller.view:can_submit(true) end,
    onclick=function() if controller then controller.view:submit(true) end end
  }
  -- Enter normally plays animation. Route it to chat only while that window
  -- exists; preserve the editor action after closing chat. Transformation keeps
  -- its more specific native key context through the non-transformation bindings.
  plugin:newCommand {
    id="AsepriteChatEnter",title="Aseprite Chat: Enter",
    onclick=function()
      if controller and controller.view.dialog then controller.view:submit(true)
      else app.command.PlayAnimation() end
    end
  }
  -- The initial menu/key import precedes Lua plugin init, so refresh only after
  -- these command IDs exist. Refresh queues its reload on the native UI thread.
  if app.isUIAvailable then app.command.Refresh() end
end

function exit(plugin)
  if controller then controller:close(); controller = nil end
end

return Main
