local Codex = {}
local Client = {}
Client.__index = Client

-- Aseprite encodes nested JSON userdata as null and empty Lua tables as [].
-- Compose containers explicitly, retaining native JSON encoding for values.
local function encode(value)
  if type(value) == "userdata" then return json.encode(value) end
  if type(value) ~= "table" then
    local wrapped = json.encode({value})
    return wrapped:match("^%[%s*(.-)%s*%]$")
  end
  local parts = {}
  if #value > 0 then
    for i = 1, #value do parts[i] = encode(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    assert(type(key) == "string", "JSON object keys must be strings")
    parts[#parts + 1] = encode(key) .. ":" .. encode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function array(value)
  if #value == 0 then return json.decode("[]") end
  return value
end

local function object(value)
  return (type(value) == "table" or type(value) == "userdata")
    and encode(value):sub(1, 1) == "{"
end

-- Native decoded JSON containers must not escape into controller-owned state.
local function plain(value)
  if type(value) ~= "table" and type(value) ~= "userdata" then return value end
  local copy = {}
  -- Aseprite's JSON arrays support ipairs, but pairs yields no array entries.
  if encode(value):sub(1, 1) == "[" then
    for index, item in ipairs(value) do copy[index] = plain(item) end
  else
    for key, item in pairs(value) do copy[key] = plain(item) end
  end
  return copy
end

local function sequence(value)
  return (type(value) == "table" or type(value) == "userdata")
    and encode(value):sub(1, 1) == "["
end

-- Summary indexes can arrive out of order; snapshots never share mutable parts.
local function reasoning_item(id, parts)
  local indexes, summary = {}, {}
  for index in pairs(parts) do indexes[#indexes+1] = index end
  table.sort(indexes)
  for _, index in ipairs(indexes) do summary[#summary+1] = parts[index] end
  return {type="reasoning", id=id, summary=summary}
end

local function failure(text)
  return {success=false, contentItems={{type="inputText", text=text}}}
end

local function terminal(status)
  return status == "completed" or status == "interrupted" or status == "failed"
end

-- Construct one direct app-server client. Tools are registered verbatim; callbacks
-- receive derived state, item text, tool requests, cancellation, and visible errors.
-- Options: tools, instructions; on_state(state),
-- on_message(id,text,isDelta), on_tool(params,reply), on_cancel(reason),
-- on_item(item,completed), on_error(text). on_item receives plain Lua non-agent
-- items; reasoning contains only readable summary sections, never raw content.
-- Public state/thread_id/turn_id belong to this client.
-- reply({success=boolean,contentItems=array}) is single-use and generation-bound.
-- Empty schema objects/arrays can use json.decode("{}") / json.decode("[]").
-- socket_factory/timer_factory accept the native constructor specs for tests.
function Codex.new(options)
  options = options or {}
  return setmetatable({state="disconnected", _options=options, _next_id=0,
    _generation=0, _pending={}, _tools={}, _terminal={}, _initialized=false}, Client)
end

function Client:_emit(name, ...)
  local callback = self._options[name]
  if callback then callback(...) end
end

function Client:_report(text)
  local ok, err = pcall(self._emit, self, "on_error", tostring(text))
  if not ok then print("Codex error: " .. tostring(text) .. "\nError callback failed: " .. tostring(err)) end
end

function Client:_state(state)
  self.state = state
  self:_emit("on_state", state)
end

function Client:_clear_requests()
  local pending = self._pending
  self._pending = {}
  for _, request in pairs(pending) do request.timer:stop() end
end

function Client:_cancel(reason, respond)
  local turn = self._turn
  if turn then
    turn.stopped = true
    if turn.id then self._terminal[turn.id] = true end
  end
  local tools = self._tools
  self._tools = {}
  for _, request in pairs(tools) do
    request.valid = false
    if respond then self:_write({id=request.id, result=failure(reason)}) end
  end
  self:_emit("on_cancel", reason)
end

function Client:_retire(state, reason)
  self._opening = nil
  if self._heartbeat then self._heartbeat:stop(); self._heartbeat = nil end
  local lifetime = self._lifetime
  self._lifetime, self._socket = nil, nil
  if lifetime then lifetime.valid = false end
  self._initialized = false
  self:_clear_requests()
  local cancelled, cancel_error = pcall(self._cancel, self, reason, false)
  self._turn, self.turn_id = nil, nil
  if lifetime and lifetime.socket then
    local ok, err = pcall(function() lifetime.socket:close() end)
    if not ok then self:_report(err) end
  end
  self.state = state
  local notified, state_error = pcall(self._emit, self, "on_state", state)
  if not cancelled then self:_report(cancel_error) end
  if not notified then self:_report(state_error) end
end

function Client:_lost(reason)
  -- Retire callbacks immediately, while retaining the socket for native reconnect.
  self._generation = self._generation + 1
  self._opening = nil
  if self._heartbeat then self._heartbeat:stop(); self._heartbeat = nil end
  self._initialized = false
  self:_clear_requests()
  self:_cancel(reason, false)
  self._turn, self.turn_id = nil, nil
  self:_state("disconnected")
end

function Client:_fail(text)
  text = tostring(text)
  self:_retire("error", text)
  self:_report(text)
end

-- Native callbacks must never silently swallow a controller or transport failure.
function Client:_guard(callback)
  local ok, err = xpcall(callback, debug.traceback)
  if not ok then
    local reported, report_error = pcall(function() self:_fail(err) end)
    if not reported then print("Codex callback error: " .. tostring(err) .. "\n" .. tostring(report_error)) end
  end
  return ok, err
end

function Client:_write(message)
  assert(self._socket and self._lifetime.valid, "Socket is disconnected")
  self._socket:sendText(encode(message))
end

function Client:_request(method, params, callback)
  self._next_id = self._next_id + 1
  local id = self._next_id
  local generation, lifetime = self._generation, self._lifetime
  local request = {callback=function(...)
    if self._generation ~= generation or self._lifetime ~= lifetime or not lifetime.valid then return end
    callback(...)
  end}
  request.timer = (self._options.timer_factory or Timer){interval=30, ontick=function()
    if self._generation == generation and self._pending[id] == request then
      self:_guard(function() self:_fail("Request timed out: " .. method) end)
    end
  end}
  self._pending[id] = request
  request.timer:start()
  self:_write({id=id, method=method, params=params})
end

function Client:_request_error(err)
  local message = err.message or tostring(err)
  self:_cancel(message, true)
  self._turn, self.turn_id = nil, nil
  self:_state("error")
  self:_emit("on_error", message)
end

function Client:_interrupt(turn)
  if turn.interrupt_sent or not turn.id or self._turn ~= turn then return end
  turn.interrupt_sent = true
  self:_state("stopping")
  self:_request("turn/interrupt", {threadId=self.thread_id, turnId=turn.id}, function(_, err)
    if self._turn ~= turn then return end
    if err then self:_request_error(err) end
    -- An interrupt acknowledgement is not a terminal turn notification.
  end)
end

function Client:_finish(turn, result)
  if self._turn ~= turn then return end
  if turn.id then self._terminal[turn.id] = true end
  self:_cancel("Turn ended", true)
  self._turn, self.turn_id = nil, nil
  if result and result.error and result.error.message then self:_emit("on_error", result.error.message) end
  self:_state("ready")
end

function Client:_match(thread_id, turn_id)
  local turn = self._turn
  if thread_id ~= self.thread_id or not turn or type(turn_id) ~= "string" then return nil end
  if turn.id then return turn.id == turn_id and turn or nil end
  if self._terminal[turn_id] then return nil end
  turn.id, self.turn_id = turn_id, turn_id
  if turn.stopped then self:_interrupt(turn) end
  return turn
end

function Client:_resume()
  self:_request("thread/resume", {threadId=self.thread_id, excludeTurns=true}, function(result, err)
    if err then self:_request_error(err); return end
    assert(object(result.thread) and result.thread.id == self.thread_id, "Malformed thread/resume response")
    local status = result.thread.status
    assert(object(status), "Missing resumed thread status")
    if status.type == "idle" then self:_state("ready"); return end
    if status.type ~= "active" then self:_request_error({message="Cannot resume thread: " .. tostring(status.type)}); return end
    local turn = {stopped=true, recovery=true, items={}}
    self._turn = turn
    self:_state("stopping")
    self:_request("thread/turns/list", {threadId=self.thread_id, limit=1,
      sortDirection="desc", itemsView="summary"}, function(page, list_error)
      if self._turn ~= turn then return end
      if list_error then self:_request_error(list_error); return end
      local active = page.data and page.data[1]
      if not active or type(active.id) ~= "string" or active.status ~= "inProgress" then
        self:_request_error({message="Cannot identify active turn during recovery"}); return
      end
      if turn.id and turn.id ~= active.id then error("Recovery turn ID mismatch") end
      turn.id, self.turn_id = active.id, active.id
      self:_interrupt(turn)
    end)
  end)
end

function Client:_opened()
  self._opening = nil
  if self._heartbeat then self._heartbeat:stop(); self._heartbeat = nil end
  self._generation = self._generation + 1
  self._initialized = false
  self:_clear_requests()
  self:_cancel("Connection generation changed", false)
  self._turn, self.turn_id = nil, nil
  self:_state("initializing")
  self:_request("initialize", {clientInfo={name="aseprite_chat", title="Aseprite Chat", version="0.3.1"},
    capabilities={experimentalApi=true}}, function(_, err)
    if err then self:_fail(err.message or "Initialization failed"); return end
    self:_write({method="initialized"})
    self._initialized = true
    -- Native IXWebSocket may not discover a peer's abrupt FIN until another write.
    -- Health traffic prompts that detection without limiting model thinking time.
    local generation = self._generation
    self._heartbeat = (self._options.timer_factory or Timer){interval=2, ontick=function()
      if self._generation ~= generation or not self._lifetime or not self._initialized then return end
      local alive = pcall(function() self._socket:sendPing("aseprite-chat") end)
      if not alive then self:_guard(function() self:_lost("Connection lost; pending execution cancelled") end) end
    end}
    self._heartbeat:start()
    if self.thread_id then self:_resume() else self:_state("ready") end
  end)
end

function Client:_tool(message)
  local params = message.params
  assert(object(params) and type(params.tool) == "string" and type(params.callId) == "string",
    "Malformed dynamic tool request")
  local turn = self:_match(params.threadId, params.turnId)
  local known = false
  for _, tool in ipairs(self._options.tools or {}) do if tool.name == params.tool then known = true end end
  if not known or not turn or not self:can_execute(params) or (turn.calls and turn.calls[params.callId]) then
    self:_write({id=message.id, result=failure("Tool call is unsupported or no longer executable; inspect again in a live turn.")})
    return
  end
  local key = type(message.id) .. ":" .. tostring(message.id)
  assert(not self._tools[key], "Duplicate outstanding tool request")
  local request = {id=message.id, valid=true}
  turn.calls = turn.calls or {}
  turn.calls[params.callId] = true
  local generation = self._generation
  self._tools[key] = request
  self:_emit("on_tool", params, function(result)
    if not request.valid or self._generation ~= generation or self._turn ~= turn
      or not self:can_execute(params) then return false end
    request.valid = false
    self._tools[key] = nil
    return self:_guard(function()
      assert(type(result.success) == "boolean" and result.contentItems, "Malformed dynamic tool result")
      self:_write({id=message.id, result={success=result.success, contentItems=array(result.contentItems)}})
    end)
  end)
end

function Client:_server_request(message)
  local method = message.method
  if method == "item/tool/call" then self:_tool(message); return end
  local result
  local explanation = "Built-in shell, filesystem, and permission approvals are declined; use the Aseprite document tools."
  if method == "item/commandExecution/requestApproval" or method == "item/fileChange/requestApproval" then
    result = {decision="decline"}
  elseif method == "item/permissions/requestApproval" then
    result = {permissions={}, scope="turn"}
  elseif method == "execCommandApproval" or method == "applyPatchApproval" then
    result = {decision={denied={rejection=explanation}}}
  end
  if result then
    self:_write({id=message.id, result=result})
    self:_emit("on_error", explanation)
  else
    self:_write({id=message.id, error={code=-32601, message="Unsupported server request: " .. method}})
  end
end

function Client:_notification(message)
  local method, params = message.method, message.params
  local summary_delta = method == "item/reasoning/summaryTextDelta"
  local summary_part = method == "item/reasoning/summaryPartAdded"
  if method ~= "turn/started" and method ~= "turn/completed" and method ~= "item/started"
    and method ~= "item/completed" and method ~= "item/agentMessage/delta" and method ~= "error"
    and not summary_delta and not summary_part then return end
  assert(object(params), "Malformed notification parameters")
  local turn_id = params.turn and params.turn.id or params.turnId
  assert(type(params.threadId) == "string" and type(turn_id) == "string", "Missing thread or turn ID")
  if method == "turn/started" or method == "turn/completed" then
    assert(object(params.turn) and (params.turn.status == "inProgress" or terminal(params.turn.status)), "Malformed turn notification")
    assert(method ~= "turn/completed" or terminal(params.turn.status), "Nonterminal turn/completed notification")
  end
  local turn = self:_match(params.threadId, turn_id)
  if not turn then return end
  if method == "turn/started" then return end
  if method == "turn/completed" then self:_finish(turn, params.turn); return end
  if method == "error" then
    assert(params.error and type(params.error.message) == "string", "Malformed error notification")
    self:_emit("on_error", params.error.message)
    if not params.willRetry then
      self:_cancel(params.error.message, true)
      self:_interrupt(turn)
    end
    return
  end
  if turn.stopped then return end
  if summary_delta or summary_part then
    local index = params.summaryIndex
    assert(type(params.itemId) == "string" and type(index) == "number" and index >= 0
      and index < math.huge and index == math.floor(index), "Malformed reasoning summary index")
    assert(not summary_delta or type(params.delta) == "string", "Malformed reasoning summary delta")
    if turn.items[params.itemId] == "completed" then return end
    turn.reasoning = turn.reasoning or {}
    local parts = turn.reasoning[params.itemId] or {}
    turn.reasoning[params.itemId] = parts
    if summary_part and parts[index] ~= nil then return end
    parts[index] = (parts[index] or "") .. (summary_delta and params.delta or "")
    turn.items[params.itemId] = "streaming"
    self:_emit("on_item", reasoning_item(params.itemId, parts), false)
  elseif method == "item/agentMessage/delta" then
    assert(type(params.itemId) == "string" and type(params.delta) == "string", "Malformed agent delta")
    if turn.items[params.itemId] ~= "completed" then
      turn.items[params.itemId] = "streaming"
      self:_emit("on_message", params.itemId, params.delta, true)
    end
  else
    local item = params.item
    assert(object(item) and type(item.id) == "string" and type(item.type) == "string", "Malformed item notification")
    if turn.items[item.id] == "completed" then return end
    if method == "item/started" and turn.items[item.id] then return end
    local completed = method == "item/completed"
    if item.type ~= "agentMessage" then
      local projected
      if item.type == "reasoning" then
        assert(item.summary == nil or sequence(item.summary), "Malformed reasoning summary")
        local parts = {}
        for index, text in ipairs(item.summary or {}) do
          assert(type(text) == "string", "Malformed reasoning summary text")
          parts[index-1] = text
        end
        turn.reasoning = turn.reasoning or {}
        if completed then turn.reasoning[item.id] = nil else turn.reasoning[item.id] = parts end
        projected = reasoning_item(item.id, parts)
      else projected = plain(item) end
      turn.items[item.id] = completed and "completed" or "started"
      self:_emit("on_item", projected, completed)
      return
    end
    assert(type(item.text) == "string", "Malformed agent message")
    if method == "item/completed" then
      turn.items[item.id] = "completed"
      self:_emit("on_message", item.id, item.text, false)
    elseif not turn.items[item.id] then
      turn.items[item.id] = "started"
      self:_emit("on_message", item.id, item.text, false)
    end
  end
end

function Client:_receive(raw)
  local message = json.decode(raw)
  assert(object(message), "Protocol frame must be an object")
  if message.id ~= nil then
    assert(type(message.id) == "number" or type(message.id) == "string", "Invalid request ID")
  end
  if message.method ~= nil then
    assert(type(message.method) == "string", "Invalid method")
    if message.id ~= nil then self:_server_request(message) else self:_notification(message) end
  else
    assert(message.id ~= nil and ((message.result ~= nil) ~= (message.error ~= nil)), "Malformed response")
    if message.error ~= nil then
      assert(object(message.error) and type(message.error.message) == "string" and type(message.error.code) == "number", "Malformed response error")
    end
    local request = self._pending[message.id]
    if not request then return end
    self._pending[message.id] = nil
    request.timer:stop()
    request.callback(message.result, message.error)
  end
end

-- Connect accepts only ws://127.0.0.1:<port>. Each explicit connection owns a new
-- socket lifetime; automatic OPEN events on that socket start new generations.
function Client:connect(endpoint)
  local port = type(endpoint) == "string" and endpoint:match("^ws://127%.0%.0%.1:(%d+)$")
  if not port or tonumber(port) < 1 or tonumber(port) > 65535 then return false, "Use an IPv4 loopback WebSocket endpoint" end
  self:disconnect()
  local lifetime = {valid=true}
  self._lifetime = lifetime
  local ok, err = self:_guard(function()
    self:_state("connecting")
    lifetime.socket = (self._options.socket_factory or WebSocket){url=endpoint, deflate=false,
      onreceive=function(kind, data, socket_error)
        if not lifetime.valid then
          if kind == WebSocketMessageType.OPEN and lifetime.socket then
            local closed, close_error = pcall(function() lifetime.socket:close() end)
            if not closed then print("Codex retired socket error: " .. tostring(close_error)) end
          end
          return
        end
        self:_guard(function()
          if kind == WebSocketMessageType.OPEN then self:_opened()
          elseif kind == WebSocketMessageType.CLOSE then
            self:_lost("Connection lost; pending execution cancelled")
          elseif kind == WebSocketMessageType.ERROR then
            print("Aseprite Chat transport diagnostic: " .. tostring(socket_error or data))
            self:_fail((self._initialized and "与本地服务的连接已断开，尚未执行的修改已取消。" or "暂时无法连接到本地服务。")
              .. "\n地址：" .. endpoint .. "\n请点击 Retry 重新连接；自动模式会查找并启动所需服务。")
          elseif kind == WebSocketMessageType.TEXT and self.state ~= "disconnected" then self:_receive(data) end
        end)
      end}
    self._socket = lifetime.socket
    lifetime.socket:connect()
  end)
  return ok, err
end

-- Disconnect invalidates execution before closing; the in-memory thread remains
-- available for explicit reconnect. A retired socket can never revive the client.
function Client:disconnect()
  self:_retire("disconnected", "Disconnected")
end

--- Discover picker-visible models and reasoning capabilities across all pages.
--- callback(models, errorText) runs once unless the connection is retired.
function Client:list_models(callback)
  if not self._initialized then return false, "Client is not initialized" end
  return self:_guard(function()
    local models, cursors = {}, {}
    local function page(cursor)
      self:_request("model/list", {limit=100, includeHidden=false, cursor=cursor}, function(result, err)
        if err then callback(nil, err.message or tostring(err)); return end
        assert(result and result.data, "Malformed model/list response")
        for _, entry in ipairs(result.data) do
          assert(type(entry.model)=="string" and type(entry.displayName)=="string"
            and entry.supportedReasoningEfforts, "Malformed model catalog entry")
          local efforts = {}
          for _, option in ipairs(entry.supportedReasoningEfforts) do
            assert(type(option.reasoningEffort)=="string", "Malformed reasoning effort")
            efforts[#efforts+1] = {reasoningEffort=option.reasoningEffort, description=option.description}
          end
          models[#models+1] = {model=entry.model, displayName=entry.displayName,
            isDefault=entry.isDefault, defaultReasoningEffort=entry.defaultReasoningEffort,
            supportedReasoningEfforts=efforts}
        end
        local next_cursor = result.nextCursor
        if next_cursor ~= nil then
          assert(type(next_cursor)=="string" and not cursors[next_cursor], "Invalid model catalog cursor")
          cursors[next_cursor]=true; page(next_cursor)
        else callback(models) end
      end)
    end
    page()
  end)
end

--- Fetch exactly one history page; filtering may leave an empty page with a cursor.
--- callback(page,errorText) receives plain Lua metadata, unless the connection retires.
--- options={cursor?,search?}; source and originator restrictions are not caller options.
function Client:list_threads(options, callback)
  if not self._initialized then return false, "Client is not initialized" end
  options = options or {}
  if options.cursor ~= nil and (type(options.cursor) ~= "string" or options.cursor == "") then
    return false, "Invalid thread cursor"
  end
  if options.search ~= nil and type(options.search) ~= "string" then return false, "Invalid history search" end
  local cursor = options.cursor
  return self:_guard(function()
    -- Local scan-and-repair can block on large rollout stores; persisted threads
    -- are already indexed by Codex, so query that authoritative index directly.
    self:_request("thread/list", {cursor=cursor, searchTerm=options.search, limit=50, useStateDbOnly=true,
      sortKey="updated_at", sortDirection="desc", sourceKinds={"cli", "vscode", "appServer"}}, function(result, err)
      if err then callback(nil, err.message); return end
      local ok, page = pcall(function()
        assert(object(result) and sequence(result.data), "Malformed thread/list page")
        local next_cursor = result.nextCursor
        assert(next_cursor == nil or (type(next_cursor) == "string" and next_cursor ~= ""
          and next_cursor ~= cursor), "Invalid thread history cursor")
        local data = {}
        for _, entry in ipairs(result.data) do
          assert(object(entry), "Malformed thread entry")
          if entry.originator == "aseprite_chat" then
            assert(type(entry.id) == "string" and entry.id ~= "" and type(entry.preview) == "string"
              and type(entry.updatedAt) == "number" and object(entry.status)
              and type(entry.status.type) == "string"
              and (entry.name == nil or type(entry.name) == "string"), "Malformed Aseprite thread metadata")
            data[#data+1] = {id=entry.id, name=entry.name, preview=entry.preview,
              updatedAt=entry.updatedAt, status=entry.status.type}
          end
        end
        return {data=data, nextCursor=next_cursor}
      end)
      if ok then callback(page) else callback(nil, tostring(page)) end
    end)
  end)
end

--- Reopen an idle Aseprite conversation without replaying historical tool calls.
--- callback({thread=metadata,turns=fullTurns},errorText) runs after all pages load.
--- Failure retains the old binding; retirement cancels the callback entirely.
function Client:open_thread(id, callback)
  if not self._initialized or self.state ~= "ready" or self._turn or self._opening then
    return false, "Client is not idle"
  end
  if type(id) ~= "string" or id == "" then return false, "Invalid thread ID" end
  return self:_guard(function()
    local operation = {}
    local generation, lifetime = self._generation, self._lifetime
    self._opening = operation
    local function live()
      return self._opening == operation and self._generation == generation
        and self._lifetime == lifetime and lifetime.valid and self._initialized
    end
    local function finish(result, err)
      if not live() then return end
      self._opening = nil
      if result then
        self.thread_id, self.turn_id, self._terminal = id, nil, {}
        for _, turn in ipairs(result.turns) do self._terminal[turn.id] = true end
      end
      self:_state("ready")
      -- State observers can synchronously disconnect or replace this generation.
      if self._generation == generation and self._lifetime == lifetime and lifetime.valid
        and self._initialized then callback(result, err) end
    end
    local function validate_thread(result, resumed)
      assert(object(result) and object(result.thread) and result.thread.id == id, "Malformed history thread response")
      local thread = result.thread
      assert(thread.originator == "aseprite_chat", "Only Aseprite Chat history can be opened")
      assert(object(thread.status), "Missing history thread status")
      local status = thread.status.type
      assert(status == "idle" or (not resumed and status == "notLoaded"),
        "Cannot open history thread: " .. tostring(status))
      return plain(thread)
    end
    self:_state("loading")
    if not live() then return end
    self:_request("thread/read", {threadId=id, includeTurns=false}, function(read, read_error)
      if not live() then return end
      if read_error then finish(nil, read_error.message); return end
      local ok, thread = pcall(validate_thread, read, false)
      if not ok then finish(nil, tostring(thread)); return end
      self:_request("thread/resume", {threadId=id, excludeTurns=true,
        developerInstructions=self._options.instructions, sandbox="read-only",
        approvalPolicy="on-request", approvalsReviewer="user"}, function(resumed, resume_error)
        if not live() then return end
        if resume_error then finish(nil, resume_error.message); return end
        local valid, metadata = pcall(validate_thread, resumed, true)
        if not valid then finish(nil, tostring(metadata)); return end
        local turns, cursors = {}, {}
        local function page(cursor)
          if not live() then return end
          self:_request("thread/turns/list", {threadId=id, cursor=cursor, limit=50,
            sortDirection="asc", itemsView="full"}, function(result, list_error)
            if not live() then return end
            if list_error then finish(nil, list_error.message); return end
            local parsed, next_cursor = pcall(function()
              assert(object(result) and sequence(result.data), "Malformed history turns page")
              for _, turn in ipairs(result.data) do
                assert(object(turn) and type(turn.id) == "string" and turn.id ~= ""
                  and (terminal(turn.status) or turn.status == "inProgress")
                  and sequence(turn.items), "Malformed history turn")
                for _, item in ipairs(turn.items) do
                  assert(object(item) and type(item.id) == "string" and type(item.type) == "string",
                    "Malformed history item")
                end
                turns[#turns+1] = plain(turn)
              end
              local next_page = result.nextCursor
              assert(next_page == nil or (type(next_page) == "string" and next_page ~= ""
                and not cursors[next_page]), "Invalid history turns cursor")
              return next_page
            end)
            if not parsed then finish(nil, tostring(next_cursor)); return end
            if next_cursor then
              cursors[next_cursor] = true
              page(next_cursor)
            else finish({thread=metadata, turns=turns}) end
          end)
        end
        page()
      end)
    end)
  end)
end

function Client:_start_turn(turn, prompt, context_text)
  if self._turn ~= turn then return end
  if turn.stopped then self:_finish(turn); return end
  self:_request("turn/start", {threadId=self.thread_id, model=turn.model, effort=turn.effort, summary=turn.summary,
    input={{type="text", text=prompt .. "\n\nCurrent Aseprite target:\n" .. context_text}}}, function(result, err)
    if self._turn ~= turn then return end
    if err then self:_request_error(err); return end
    assert(result.turn and type(result.turn.id) == "string", "Malformed turn/start response")
    if turn.id and turn.id ~= result.turn.id then error("Turn/start ID mismatch") end
    turn.id, self.turn_id = result.turn.id, result.turn.id
    if terminal(result.turn.status) then self:_finish(turn, result.turn)
    elseif turn.stopped then self:_interrupt(turn) end
  end)
end

-- Send accepts exactly one active turn and returns whether the request was sent
-- locally. Later protocol failures are reported through on_error, without replay.
-- Optional settings={model=canonicalModel,effort=advertisedEffort,summary=mode}
-- is snapshotted for this turn. The caller supplies summary only for capable models;
-- omission never enables summaries globally. Overrides preserve the thread.
function Client:send(prompt, context_text, settings)
  if self.state ~= "ready" or self._turn then return false, "Client is not ready" end
  if type(prompt) ~= "string" or prompt:match("^%s*$") then return false, "Prompt is empty" end
  if type(context_text) ~= "string" then return false, "Context must be text" end
  return self:_guard(function()
    local turn = {items={}, model=settings and settings.model, effort=settings and settings.effort,
      summary=settings and settings.summary}
    self._turn = turn
    self:_state("working")
    if self.thread_id then self:_start_turn(turn, prompt, context_text); return end
    self:_request("thread/start", {dynamicTools=array(self._options.tools or {}), model=turn.model,
      developerInstructions=self._options.instructions, sandbox="read-only", approvalPolicy="on-request",
      approvalsReviewer="user", allowProviderModelFallback=false}, function(result, err)
      if self._turn ~= turn then return end
      if err then self:_request_error(err); return end
      assert(result.thread and type(result.thread.id) == "string", "Malformed thread/start response")
      self.thread_id = result.thread.id
      self:_start_turn(turn, prompt, context_text)
    end)
  end)
end

-- Stop invalidates local tools first, even while the server has not supplied an
-- ID. A deferred interrupt waits for that ID and then for terminal confirmation.
function Client:stop()
  if not self._turn then return end
  self:_guard(function()
    self:_cancel("Stopped", true)
    self:_state("stopping")
    self:_interrupt(self._turn)
  end)
end

-- New chat discards only the local thread binding while idle. After a failed
-- resume it is the explicit way to abandon that history and enable a fresh send.
function Client:new_chat()
  if self._turn or not self._initialized or (self.state ~= "ready" and self.state ~= "error") then
    return false, "Cannot create a new chat while disconnected or working"
  end
  return self:_guard(function()
    self.thread_id, self.turn_id, self._terminal = nil, nil, {}
    self:_cancel("New chat", false)
    self:_state("ready")
  end)
end

-- Execution permission is derived from the live generation and active turn;
-- recovery, stop, disconnect, and terminal completion revoke it immediately.
function Client:can_execute(params)
  local turn = self._turn
  return self._initialized and self._lifetime ~= nil and self._lifetime.valid
    and self.state == "working" and turn ~= nil and not turn.stopped
    and turn.id ~= nil and params.threadId == self.thread_id and params.turnId == turn.id
end

return Codex
