local Chat = {}
Chat.__index = Chat

--- Wrap plain text without splitting UTF-8 code points. measure returns pixel width.
function Chat.wrap(text, width, measure)
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for _, code in utf8.codes(paragraph:gsub("\r$", ""):gsub("\t", "    ")) do
      local char = utf8.char(code)
      if line ~= "" and measure(line .. char) > width then
        lines[#lines + 1] = line
        line = ""
      end
      line = line .. char
    end
    lines[#lines + 1] = line
  end
  return lines
end

--- Create a native view. Construction alone does not open a window.
function Chat.new(callbacks, preferences)
  return setmetatable({ callbacks = callbacks, preferences = preferences,
    messages = {}, by_id = {}, state = "disconnected",
    scroll = { offset = 0, maximum = 0, follow = true } }, Chat)
end

local function paint(gc, text, scroll)
  gc.color = Color { r = 32, g = 34, b = 40 }
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  local line_height = gc:measureText("Mg").height + 3
  local lines = Chat.wrap(text, math.max(1, gc.width - 24), function(s)
    return gc:measureText(s).width
  end)
  scroll.maximum = math.max(0, #lines * line_height + 12 - gc.height)
  scroll.height = gc.height
  scroll.offset = scroll.follow and scroll.maximum or math.min(scroll.offset, scroll.maximum)
  gc.color = Color { r = 231, g = 233, b = 240 }
  for index, line in ipairs(lines) do
    local y = 6 + (index - 1) * line_height - scroll.offset
    if y > -line_height and y < gc.height then gc:fillText(line, 8, y) end
  end
  if scroll.maximum > 0 then
    local height = math.max(1, gc.height - 4)
    local thumb_height = math.min(height, math.max(14, height * gc.height / (scroll.maximum + gc.height)))
    local top = 2 + (height - thumb_height) * scroll.offset / scroll.maximum
    scroll.track = {x=gc.width-12, y=2, width=10, height=height, thumb_y=top, thumb_height=thumb_height}
    gc.color = Color {r=48, g=50, b=58}
    gc:fillRect(Rectangle(scroll.track.x, 2, 10, height))
    gc.color = scroll.grab and Color {r=170,g=179,b=197} or Color {r=115,g=122,b=139}
    gc:fillRect(Rectangle(scroll.track.x+1, top, 8, thumb_height))
  else scroll.track, scroll.grab = nil, nil end
end

local function scroll_by(scroll, delta)
  scroll.offset = math.max(0, math.min(scroll.maximum, scroll.offset + delta))
  scroll.follow = scroll.offset >= scroll.maximum
end

local function scroll_input(scroll, action, event)
  if action == "wheel" then
    scroll_by(scroll, event.deltaY * 30)
  elseif action == "down" then
    local track = scroll.track
    if event.button ~= MouseButton.LEFT or not track or event.x < track.x or event.x >= track.x+track.width
        or event.y < track.y or event.y >= track.y+track.height then return false end
    if event.y >= track.thumb_y and event.y < track.thumb_y+track.thumb_height then
      scroll.grab = (event.y-track.thumb_y)/track.thumb_height
      scroll.follow = false
    else scroll_by(scroll, event.y < track.thumb_y and -scroll.height*0.9 or scroll.height*0.9) end
  elseif action == "move" then
    local track = scroll.track
    if scroll.grab == nil or not track or track.height <= track.thumb_height then return false end
    scroll.offset = math.max(0, math.min(scroll.maximum,
      (event.y-track.y-scroll.grab*track.thumb_height)/(track.height-track.thumb_height)*scroll.maximum))
    scroll.follow = false
  elseif action == "up" then
    if event.button ~= MouseButton.LEFT or scroll.grab == nil then return false end
    scroll.grab = nil
    scroll.follow = scroll.offset >= scroll.maximum
  elseif action == "key" then
    local delta = ({ArrowUp=-30, ArrowDown=30, PageUp=-scroll.height*0.9,
      PageDown=scroll.height*0.9, Home=-scroll.maximum, End=scroll.maximum})[event.code]
    if not delta then return false end
    scroll_by(scroll, delta)
    event:stopPropagation()
  end
  return true
end

-- Both text surfaces share input handling; Aseprite captures the mouse on canvas presses.
local function add_scroll_canvas(dialog, spec, scroll, text)
  spec.onpaint = function(ev) paint(ev.context, text(), scroll) end
  for field, action in pairs {onwheel="wheel", onmousedown="down", onmousemove="move", onmouseup="up", onkeydown="key"} do
    local input_action = action
    spec[field] = function(ev)
      if scroll_input(scroll, input_action, ev) then dialog:repaint() end
    end
  end
  dialog:canvas(spec)
end

--- Append streaming output or replace it with the server's completed item text.
function Chat:add_message(id, role, text, append)
  local message = self.by_id[id]
  if not message then
    message = { id = id, role = role, text = "" }
    self.messages[#self.messages + 1] = message
    self.by_id[id] = message
  end
  message.text = append and (message.text .. text) or text
  if self.dialog then self.dialog:repaint() end
end

--- Clear the local transcript when the user starts a new conversation.
function Chat:clear()
  self.messages, self.by_id = {}, {}
  self.scroll.offset, self.scroll.follow, self.scroll.grab = 0, true, nil
  if self.dialog then self.dialog:repaint() end
end

--- Update controls from protocol state and the current native editor context.
function Chat:set_state(state)
  self.state = state
  local idle = state == "ready"
  local offline = state == "disconnected" or state == "error"
  if self.dialog then
    self.dialog:modify { id = "status", text = self.approval and "Awaiting approval"
      or state == "starting" and "正在启动本地连接…" or state }
    self.dialog:modify { id = "model", enabled = idle and self.has_models == true }
    self.dialog:modify { id = "effort", enabled = idle and self.has_efforts == true }
    self.dialog:modify { id = "send", enabled = idle and self.selection_valid == true and app.sprite ~= nil }
    self.dialog:modify { id = "new", enabled = (idle and self.models ~= nil) or state == "error" }
    self.dialog:modify { id = "stop", enabled = state == "working" or self.approval ~= nil }
    self.dialog:modify { id = "retry", visible = offline, enabled = offline }
    self.dialog:modify { id = "latest", visible = not offline }
  end
  if self.settings_dialog then
    local manual = self.settings_dialog.data.manual == true
    local status = ({ready="Connected",working="Generating",starting="Starting local service",
      connecting="Connecting",initializing="Connecting to Codex",recovering="Restoring conversation",
      disconnected="Disconnected",error="Connection failed"})[state] or state
    self.settings_dialog:modify { id = "status", text = "Status: " .. status }
    self.settings_dialog:modify { id = "manual", enabled = offline }
    self.settings_dialog:modify { id = "auto_info", visible = not manual }
    self.settings_dialog:modify { id = "endpoint", visible = manual, enabled = offline and manual }
    self.settings_dialog:modify { id = "connect", visible = offline, enabled = offline, text = manual and "Connect" or "Retry" }
    self.settings_dialog:modify { id = "disconnect", visible = not offline, enabled = not offline, text = state == "starting" and "Cancel startup" or "Disconnect" }
  end
end

--- Project the server catalog and persisted selection into native dropdowns.
function Chat:set_models(models, model, effort)
  self.models, self.selected_model, self.selected_effort = models, model, effort
  if not self.dialog then return end
  self.updating_selectors = true
  local labels, chosen, selected = {}, nil, nil
  self.models_by_label = {}
  for _, entry in ipairs(models or {}) do
    local label = entry.displayName .. " (" .. entry.model .. ")"
    labels[#labels+1], self.models_by_label[label] = label, entry
    if entry.model == model then chosen, selected = label, entry end
  end
  self.has_models = #labels > 0
  local confirm_model = selected and #selected.supportedReasoningEfforts == 0 and effort ~= nil
  if confirm_model then chosen, selected = nil, nil end
  if not chosen then
    chosen = confirm_model and "Confirm model selection" or not models and "Waiting for connection"
      or model and ("Unavailable: " .. model) or "Select a model"
    table.insert(labels, 1, chosen)
  end
  local efforts, valid = {}, false
  if selected then
    for _, option in ipairs(selected.supportedReasoningEfforts) do
      efforts[#efforts+1] = option.reasoningEffort
      if option.reasoningEffort == effort then valid = true end
    end
  end
  self.has_efforts = #efforts > 0
  local chosen_effort = effort
  if #efforts == 0 then
    chosen_effort = "Not supported"; efforts[1] = chosen_effort
    valid = selected ~= nil and effort == nil
  elseif not valid then
    chosen_effort = "Select reasoning level"; table.insert(efforts, 1, chosen_effort)
  end
  self.selection_valid = selected ~= nil and valid
  self.dialog:modify {id="model", options=labels, option=chosen}
  self.dialog:modify {id="effort", options=efforts, option=chosen_effort}
  self.updating_selectors = false
  self:set_state(self.state)
end

--- Open connection settings independently; drafts are committed by the controller on Connect.
function Chat:show_settings()
  if self.settings_dialog then self.settings_dialog:show {wait=false}; return end
  local dlg
  dlg = Dialog {title="Aseprite Chat · Settings", autofit=Align.LEFT | Align.TOP, onclose=function()
    if self.settings_dialog == dlg then self.settings_dialog = nil end
  end}
  self.settings_dialog = dlg
  -- Native label= fields reserve a form column for every subsequent row.
  dlg:label {id="status", text="Status: " .. self.state}
  dlg:check {id="manual", text="Manual server (advanced)", selected=self.preferences.manual_server == true,
    onclick=function() self:set_state(self.state) end}
  dlg:label {id="auto_info", text="Local service starts automatically."}
  dlg:entry {id="endpoint", text=self.preferences.endpoint or "ws://127.0.0.1:4500"}
  dlg:button {id="connect", text="Connect", onclick=function()
    self.callbacks.on_connect(dlg.data.manual and dlg.data.endpoint or nil)
  end}
  dlg:button {id="disconnect", text="Disconnect", onclick=self.callbacks.on_disconnect}
  dlg:button {id="done", text="Done"}
  self:set_state(self.state)
  dlg:show {wait=false}
end

--- Open or reveal the modeless chat dialog without blocking painting.
function Chat:show()
  if self.dialog then self.dialog:show { wait = false }; return end
  local dlg
  dlg = Dialog { title = "Aseprite Chat · Codex", resizeable = true, onclose = function()
    if self.dialog == dlg then
      self.dialog = nil
      self:dismiss_approval()
      local settings = self.settings_dialog
      self.settings_dialog = nil
      if settings then settings:close() end
      if self.callbacks.on_close then self.callbacks.on_close() end
    end
  end }
  self.dialog = dlg
  dlg:combobox { id = "model", label = "Model", options = {"Waiting for connection"}, onchange = function()
    if self.updating_selectors then return end
    local entry = self.models_by_label[dlg.data.model]
    if entry then
      self.callbacks.on_settings(entry.model, #entry.supportedReasoningEfforts > 0 and entry.defaultReasoningEffort or nil)
    end
  end }
  dlg:combobox { id = "effort", label = "Reasoning", options = {"Not supported"}, onchange = function()
    if self.updating_selectors then return end
    local entry = self.models_by_label[dlg.data.model]
    if entry then self.callbacks.on_settings(entry.model, self.has_efforts and dlg.data.effort or nil) end
  end }
  dlg:label { id = "status", label = "Status", text = self.state }
  dlg:newrow()
  add_scroll_canvas(dlg, {id="transcript", width=360, height=260, hexpand=true, vexpand=true}, self.scroll,
    function()
      local parts = {}
      for _, m in ipairs(self.messages) do parts[#parts + 1] = m.role .. ":\n" .. m.text end
      return #parts > 0 and table.concat(parts, "\n\n") or "Chat with Codex about the current sprite. The local connection starts automatically."
    end)
  dlg:newrow()
  dlg:entry { id = "input", label = "Message", text = "", focus = true }
  dlg:button { id = "send", text = "Send", focus = true, onclick = function()
    local text = dlg.data.input
    if self.callbacks.on_send(text) then dlg:modify { id = "input", text = "" } end
  end }
  dlg:button { id = "stop", text = "Stop", onclick = self.callbacks.on_stop }
  dlg:button { id = "new", text = "New Chat", onclick = self.callbacks.on_new_chat }
  dlg:button { id = "latest", text = "Latest", onclick = function() self.scroll.follow = true; dlg:repaint() end }
  dlg:button { id = "retry", text = "Retry", onclick = function()
    self.callbacks.on_connect(self.preferences.manual_server and self.preferences.endpoint or nil)
  end }
  dlg:button { id = "settings", text = "Settings...", onclick = function() self:show_settings() end }
  self:set_models(self.models, self.selected_model, self.selected_effort)
  dlg:show { wait = false }
end

--- Show complete Lua and summary; the caller must revalidate after approval.
function Chat:request_approval(args, callback)
  self:dismiss_approval()
  local dlg, pending
  local scroll = { offset = 0, maximum = 0, follow = false }
  local function finish(accepted)
    if self.approval ~= pending then return end
    self.approval = nil
    dlg:close()
    self:set_state(self.state)
    callback(accepted)
  end
  dlg = Dialog { title = "Approve Codex Lua", resizeable = true, onclose = function() finish(false) end }
  pending = { dialog = dlg, finish = finish }
  self.approval = pending
  add_scroll_canvas(dlg, {id="code", width=420, height=280, hexpand=true, vexpand=true}, scroll,
    function() return args.summary .. "\n\n" .. args.code end)
  dlg:label { text = "Approved Lua runs immediately. Running Lua cannot be interrupted." }
  dlg:newrow()
  dlg:button { id = "approve", text = "Approve once", onclick = function() finish(true) end }
  dlg:button { id = "reject", text = "Reject", onclick = function() finish(false) end }
  dlg:show { wait = false }
  self:set_state(self.state)
end

--- Dismiss an invalidated approval without invoking its user-decision callback.
function Chat:dismiss_approval()
  local pending = self.approval
  self.approval = nil
  if pending then pending.dialog:close() end
  self:set_state(self.state)
end

--- Close owned native dialogs. on_close is reserved for user-initiated closing.
function Chat:close()
  self:dismiss_approval()
  self.scroll.grab = nil
  local settings = self.settings_dialog
  self.settings_dialog = nil
  if settings then settings:close() end
  local dlg = self.dialog
  self.dialog = nil
  if dlg then dlg:close() end
end

return Chat
