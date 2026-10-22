local Chat = {}
Chat.__index = Chat
local access_levels={
  {id="canvas",label="Canvas only"}, {id="read",label="Read files"},
  {id="workspace",label="Workspace write"}, {id="full",label="Full access (danger)"}
}

-- Custom-account settings rows share one visibility toggle keyed on the mode combobox.
local account_rows = { "account_home_label", "account_home", "account_url_label", "account_url",
  "account_url_hint", "account_key_status", "account_key", "account_key_clear",
  "account_models_label", "account_models" }

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
    auto_approve = false,
    scroll = { offset = 0, maximum = 0, follow = true } }, Chat)
end

local function preview_text(text)
  text=text or ""
  local marker=text:find("\n\nCurrent Aseprite target:\n",1,true)
  return (marker and text:sub(1,marker-1) or text):gsub("%s+"," ")
end

local function elide(gc,text,width)
  if gc:measureText(text).width<=width then return text end
  local chars={}
  for _,code in utf8.codes(text) do
    if gc:measureText(table.concat(chars)..utf8.char(code).."…").width>width then break end
    chars[#chars+1]=utf8.char(code)
  end
  return table.concat(chars).."…"
end

-- Action toggles project controller state into a compact canvas row. Selectors
-- remain native comboboxes, with their own native popup and keyboard handling.
local function update_control(view,spec)
  local control=assert(view.controls[spec.id])
  for key,value in pairs(spec) do control[key]=value end
end

local function send_caption(state)
  return state=="working" and "Steer" or state=="steering" and "Steering..." or "Send"
end

--- Check submission eligibility. Shortcut invocations also reject owned child
--- windows; a direct click in the main chat remains usable with background settings.
function Chat:can_submit(shortcut)
  if not self.dialog then return false end
  if shortcut and (self.settings_dialog or self.access_dialog or self.history_dialog
    or self.rename_dialog or self.approval) then return false end
  return (self.state=="working" and self.can_steer==true)
    or (self.state=="ready" and self.selection_valid==true and app.sprite~=nil)
end

--- Submit the native entry through the same path for clicks and registered commands.
--- Preserve the draft on rejection and return focus to the entry only after acceptance.
function Chat:submit(shortcut)
  if not self:can_submit(shortcut) then return false end
  local dlg=self.dialog
  if not self.callbacks.on_send(dlg.data.input) then return false end
  if self.dialog==dlg then dlg:modify {id="input",text="",focus=true} end
  return true
end

-- Setting native options deletes the current popup's items. Cache the last
-- projected list so ordinary selection changes leave an open popup intact.
local function project_selector(view,id,options,selected)
  local previous=view.selector_options[id]
  local changed=not previous or #previous~=#options
  if not changed then
    for index,value in ipairs(options) do if previous[index]~=value then changed=true; break end end
  end
  local spec={id=id,option=selected}
  if changed then spec.options=options; view.selector_options[id]=options end
  view.dialog:modify(spec)
end

local function paint_composer(gc,view)
  local controls,widths={},{}
  for _,id in ipairs {"speed","retry","stop"} do
    local control=view.controls[id]
    if control.visible~=false then
      local width=math.min(132,math.max(28,gc:measureText(control.text).width+16))
      controls[#controls+1],widths[id]=control,width
    end
  end
  view.control_rects={}
  local x=0
  for index,control in ipairs(controls) do
    local width=widths[control.id]
    local rect={id=control.id,x=x,y=0,width=width,height=gc.height}
    view.control_rects[#view.control_rects+1]=rect
    gc.color=Color {r=75,g=80,b=91}; gc:fillRect(Rectangle(x,0,width,gc.height))
    gc.color=control.selected and Color {r=48,g=77,b=96} or Color {r=38,g=41,b=49}
    gc:fillRect(Rectangle(x+1,1,width-2,gc.height-2))
    gc.color=control.enabled and Color {r=231,g=233,b=240} or Color {r=125,g=130,b=141}
    local text=elide(gc,control.text,width-12)
    local size=gc:measureText(text)
    gc:fillText(text,x+6,math.floor((gc.height-size.height)/2))
    if view.control_focus==control.id then
      gc.color=Color {r=137,g=180,b=210}; gc:fillRect(Rectangle(x+2,gc.height-3,width-4,1))
    end
    x=x+width+4
  end
end

local function align_send(gc,view)
  -- The headerless content tab spans the root grid's two columns. Only Send
  -- uses the root label column, so measured padding cannot indent the chat.
  -- Update before relayout to prevent paint/modify recursion on size changes.
  local padding=string.rep(" ",math.max(0,math.floor((gc.width-gc:measureText(send_caption(view.state)).width-24)
    /math.max(1,gc:measureText(" ").width))))
  if view.send_padding~=padding then
    view.send_padding=padding
    -- Native Dialog skips relayout during window resize. Flush on the next UI
    -- tick rather than recursively changing the grid from a paint callback.
    if not view.layout_timer then
      local timer
      timer=Timer {interval=0.05,ontick=function()
        timer:stop()
        if view.layout_timer==timer and view.dialog then view.dialog:modify {id="send",label=view.send_padding} end
      end}
      view.layout_timer=timer
    end
    view.layout_timer:start()
  end
end

local function activate_control(view,id)
  local control=view.controls[id]
  if not control or not control.enabled or control.visible==false then return end
  control.onclick()
end

-- Measure actual text in the current context: fallback fonts and their sizes
-- vary by installed font and glyph. Leading/padding are separate from metrics.
local function line_height(gc,text)
  return math.max(gc:measureText("Mg").height,gc:measureText(text or "").height)+4
end

local function surface(gc,scroll,height)
  gc.color=Color {r=29,g=31,b=37}
  gc:fillRect(Rectangle(0,0,gc.width,gc.height))
  scroll.maximum=math.max(0,height-gc.height)
  scroll.height=gc.height
  scroll.offset=scroll.follow and scroll.maximum or math.max(0,math.min(scroll.offset,scroll.maximum))
end

local function scrollbar(gc,scroll)
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

local function paint(gc, text, scroll)
  local line_height = line_height(gc)
  local lines = Chat.wrap(text, math.max(1, gc.width - 24), function(s)
    return gc:measureText(s).width
  end)
  for _,line in ipairs(lines) do line_height=math.max(line_height,gc:measureText(line).height+4) end
  surface(gc,scroll,#lines*line_height+12)
  gc.color = Color { r = 231, g = 233, b = 240 }
  for index, line in ipairs(lines) do
    local y = 6 + (index - 1) * line_height - scroll.offset
    if y > -line_height and y < gc.height then gc:fillText(line, 8, y) end
  end
  scrollbar(gc,scroll)
end

-- Cards retain one text source; expansion is presentation state on that item.
local function paint_messages(gc,view)
  local scroll=view.scroll
  local full_width=math.max(1,gc.width-26)
  local base_header_height=gc:measureText("Mg").height+10
  local cards,top={},8
  for _,message in ipairs(view.messages) do
    if message.text~="" then
      local folded=message.role=="Tool" or message.role=="Summary"
      local card_width=message.role=="You" and math.max(24,math.floor(full_width*0.86)) or full_width
      local width=math.max(1,card_width-16)
      local title=message.role
      if message.role=="Tool" then
        title=message.text:match("^[^\n]+") or "Tool"
        title=title:gsub("^read_sprite","Read canvas"):gsub("^execute_lua","Edit canvas")
      elseif message.role=="Summary" then title="Thoughts" end
      if folded then title=(message.expanded and "[-] " or "[+] ")..title end
      local header_height=math.max(base_header_height,gc:measureText(title).height+10)
      local lines={}
      if not folded or message.expanded then
        lines=Chat.wrap(message.text,width,function(text) return gc:measureText(text).width end)
      end
      local body_line_height=line_height(gc)
      for _,line in ipairs(lines) do body_line_height=math.max(body_line_height,line_height(gc,line)) end
      local height=header_height+#lines*body_line_height+(#lines>0 and 4 or 0)
      cards[#cards+1]={message=message,top=top,height=height,title=title,lines=lines,folded=folded,
        header_height=header_height,line_height=body_line_height,width=card_width,
        x=message.role=="You" and gc.width-18-card_width or 8}
      top=top+height+(folded and not message.expanded and 4 or 8)
    end
  end
  scroll.cards=cards
  if scroll.anchor then
    for _,card in ipairs(cards) do if card.message.id==scroll.anchor.id then scroll.offset=card.top-scroll.anchor.y; break end end
    scroll.anchor=nil
  end
  surface(gc,scroll,top)
  if #cards==0 then
    gc.color=Color {r=169,g=176,b=191}
    gc:fillText("Start a conversation about your current canvas.",12,16)
  end
  for _,card in ipairs(cards) do
    local y=card.top-scroll.offset
    if y+card.height>0 and y<gc.height then
      local role=card.message.role
      gc.color=role=="You" and Color {r=39,g=54,b=70} or Color {r=39,g=42,b=50}
      gc:fillRect(Rectangle(card.x,y,card.width,card.height))
      gc.color=role=="You" and Color {r=140,g=185,b=229} or role=="Codex" and Color {r=142,g=204,b=174}
        or role=="Error" and Color {r=246,g=145,b=145} or Color {r=180,g=184,b=203}
      if card.message.text:find(" · Failed",1,true) or card.message.text:find(" · Rejected",1,true) then gc.color=Color {r=246,g=163,b=145} end
      local title=elide(gc,card.title,math.max(1,card.width-16))
      local title_x=role=="You" and card.x+card.width-8-gc:measureText(title).width or card.x+8
      if y+5>=0 and y+5<gc.height-gc:measureText(title).height then gc:fillText(title,title_x,y+5) end
      gc.color=Color {r=231,g=233,b=240}
      for index,line in ipairs(card.lines) do
        local line_y=y+card.header_height+(index-1)*card.line_height
        if line_y>=0 and line_y<gc.height-gc:measureText(line).height then gc:fillText(line,card.x+8,line_y) end
      end
    end
  end
  scrollbar(gc,scroll)
  scroll.latest=nil
  if scroll.offset<scroll.maximum then
    local label="Jump to latest"
    local width=gc:measureText(label).width+20
    local height=base_header_height+2
    local x,y=math.max(8,gc.width-width-22),gc.height-height-8
    scroll.latest={x=x,y=y,width=width,height=height}
    gc.color=Color {r=66,g=84,b=108}; gc:fillRect(Rectangle(x,y,width,height))
    gc.color=Color {r=239,g=242,b=249}; gc:fillText(label,x+10,y+5)
  end
end

local function transcript_input(view,action,event)
  local message
  if action=="down" and event.button==MouseButton.LEFT then
    local latest=view.scroll.latest
    if latest and event.x>=latest.x and event.x<latest.x+latest.width and event.y>=latest.y and event.y<latest.y+latest.height then
      view.scroll.follow,view.scroll.anchor,view.focused_message=true,nil,nil
      return true
    end
    for _,card in ipairs(view.scroll.cards or {}) do
      local y=event.y+view.scroll.offset
      if event.x>=card.x and event.x<card.x+card.width
          and y>=card.top and y<card.top+card.header_height then
        view.focused_message=card.message.id
        if card.folded then message=card.message end
        break
      end
    end
  elseif action=="key" and (event.code=="Enter" or event.code=="Space") then
    message=view.by_id[view.focused_message]
    if message and message.role~="Tool" and message.role~="Summary" then message=nil end
    if message then event:stopPropagation() end
  end
  if not message then return false end
  for _,card in ipairs(view.scroll.cards or {}) do
    if card.message==message then view.scroll.anchor={id=message.id,y=card.top-view.scroll.offset}; break end
  end
  message.expanded=not message.expanded
  view.scroll.follow=false
  return true
end

local function scroll_by(scroll, delta)
  scroll.offset = math.max(0, math.min(scroll.maximum, scroll.offset + delta))
  scroll.follow = scroll.auto_follow~=false and scroll.offset >= scroll.maximum
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
    scroll.follow = scroll.auto_follow~=false and scroll.offset >= scroll.maximum
  elseif action == "key" then
    local delta = ({ArrowUp=-30, ArrowDown=30, PageUp=-scroll.height*0.9,
      PageDown=scroll.height*0.9, Home=-scroll.maximum, End=scroll.maximum})[event.code]
    if not delta then return false end
    scroll_by(scroll, delta)
    event:stopPropagation()
  else return false end
  return true
end

-- Both text surfaces share input handling; Aseprite captures the mouse on canvas presses.
local function add_scroll_canvas(dialog, spec, scroll, render, input)
  spec.onpaint = function(ev) render(ev.context) end
  for field, action in pairs {onwheel="wheel", onmousedown="down", onmousemove="move", onmouseup="up", onkeydown="key",ondblclick="double"} do
    local input_action = action
    spec[field] = function(ev)
      local handled
      if input and (input_action=="key" or input_action=="double") then handled=input(input_action,ev) end
      if not handled then handled=scroll_input(scroll,input_action,ev) end
      if not handled and input and input_action~="key" and input_action~="double" then handled=input(input_action,ev) end
      if handled then dialog:repaint() end
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
  if self.dialog then
    if role=="You" then self:set_thread(self.thread_id,self.thread_name) end
    self.dialog:repaint()
  end
end

--- Display the client-owned thread name, falling back to its first user prompt.
function Chat:set_thread(id,name)
  self.thread_id,self.thread_name=id,name
  if not self.dialog then return end
  local title=name
  if not title or title=="" then
    for _,entry in ipairs(self.messages) do if entry.role=="You" then title=preview_text(entry.text); break end end
  end
  title=title or "New chat"
  local stop=utf8.offset(title,61)
  self.dialog:modify {id="conversation",text=stop and title:sub(1,stop-1).."…" or title}
  self.dialog:modify {id="rename",enabled=self.state=="ready" and id~=nil}
end

--- Clear the local transcript when the user starts a new conversation.
function Chat:clear()
  self.messages, self.by_id = {}, {}
  self.focused_message=nil
  self.scroll.cards,self.scroll.anchor,self.scroll.latest=nil,nil,nil
  self.scroll.offset, self.scroll.follow, self.scroll.grab = 0, true, nil
  if self.dialog then self:set_thread(self.thread_id,self.thread_name); self.dialog:repaint() end
end

--- Update controls from protocol state and the current native editor context.
--- can_steer projects the client's live-turn availability, independent of canvas presence.
function Chat:set_state(state,can_steer)
  local previous=self.state
  self.state = state
  if can_steer~=nil then self.can_steer=can_steer==true end
  if state~="working" then self.can_steer=false end
  local idle = state == "ready"
  local offline = state == "disconnected" or state == "error"
  if offline and previous~=state and self.history_dialog then self.history_dialog:close() end
  if self.rename_dialog and state~="ready" and state~="renaming" then self.rename_dialog:close() end
  if self.dialog then
    local status = self.approval and "Awaiting approval"
      or state == "starting" and "正在启动本地连接…" or state
    self.dialog:modify { id = "status", text = status .. " · Auto-approve: " .. (self.auto_approve and "on" or "off") }
    self.dialog:modify {id="model",enabled=idle and self.has_models==true}
    self.dialog:modify {id="effort",enabled=idle and self.has_efforts==true}
    update_control(self,{ id = "speed", visible=self.fast_tier~=nil,enabled=idle and self.fast_tier~=nil,
      selected=self.fast_tier~=nil and self.selected_tier==self.fast_tier })
    local access=self.callbacks.on_access_get and self.callbacks.on_access_get() or {}
    local access_caption="Canvas only"
    for _,level in ipairs(access_levels) do if level.id==access.access then access_caption=level.label end end
    local updating=self.updating_selectors
    self.updating_selectors=true
    self.dialog:modify {id="access",option=access_caption,enabled=idle or offline}
    self.dialog:modify {id="auto_approve",option=self.auto_approve and "Auto-approve edits" or "Ask before edits",
      enabled=idle and self.approval==nil}
    self.updating_selectors=updating
    self.dialog:modify { id = "rename", enabled=idle and self.thread_id~=nil }
    self.dialog:modify { id = "send", enabled = self:can_submit(),text=send_caption(state) }
    self.dialog:modify { id = "new", enabled = (idle and self.models ~= nil) or state == "error" }
    local can_stop=state=="working" or state=="steering" or self.approval~=nil
    update_control(self,{ id = "stop", visible=can_stop or state=="stopping",enabled=can_stop })
    update_control(self,{ id = "retry", visible = offline, enabled = offline })
    self.dialog:modify {id="composer",visible=self.fast_tier~=nil or can_stop or state=="stopping" or offline}
    self.dialog:repaint()
  end
  if self.rename_dialog then
    self.rename_dialog:modify {id="save",enabled=idle}
    self.rename_dialog:modify {id="name",enabled=idle}
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
    local custom = self.settings_dialog.data.account_mode == "Custom Codex home"
    for _, id in ipairs(account_rows) do
      self.settings_dialog:modify { id = id, visible = custom }
    end
    self.settings_dialog:modify { id = "account_apply", enabled = idle or offline }
  end
  if self.access_dialog then
    local panel=self.access_dialog
    local level = panel.data.access_level
    local beyond = level ~= nil and level ~= "Canvas only"
    panel:modify {id="access_level",enabled=idle or offline}
    panel:modify { id = "access_workspace_label", visible = beyond }
    panel:modify { id = "access_workspace", visible = beyond,enabled=idle or offline }
    panel:modify { id = "access_reviewer_label", visible = beyond }
    panel:modify { id = "access_reviewer", visible = beyond, enabled = beyond and (idle or offline) }
    panel:modify { id = "access_note", text =
      level == "Full access (danger)" and "No sandbox: Codex can read and write anywhere."
      or beyond and "Codex may read any file on this PC; writes follow the level."
      or "Codex uses the canvas tools only." }
    panel:modify { id = "access_apply", enabled = idle or offline }
  end
  if self.history_dialog then
    local picker = self.history_dialog
    local selected=self.history and self.history.entries[self.history.selected]
    picker:modify { id = "open", enabled = self.state == "ready" and not self.history.loading
      and selected ~= nil and selected.status ~= "active" }
  end
end

--- Project the controller-owned, per-chat automatic edit approval mode into native controls.
function Chat:set_approval_mode(enabled)
  self.auto_approve = enabled == true
  if self.dialog then self:set_state(self.state) end
end

local function paint_history(gc,history)
  local scroll=history.scroll
  local line_height=line_height(gc)
  for _,thread in ipairs(history.entries) do
    line_height=math.max(line_height,gc:measureText(preview_text(thread.name)).height+4,
      gc:measureText(preview_text(thread.preview)).height+4)
  end
  local row_height=line_height*2+12
  -- Pages only append entries, so the visible row index and relative Y remain
  -- stable even when newly loaded fallback glyphs increase the shared row height.
  if history.row_height and history.row_height~=row_height then
    local first=math.max(1,math.floor((scroll.offset-8)/history.row_height)+1)
    local relative_y=8+(first-1)*history.row_height-scroll.offset
    scroll.offset=8+(first-1)*row_height-relative_y
  end
  history.row_height=row_height
  history.width=gc.width
  surface(gc,scroll,16+#history.entries*history.row_height)
  if #history.entries==0 then
    gc.color=Color {r=178,g=184,b=198}
    gc:fillText(history.loading and "Loading conversations..." or "No conversations found.",12,16)
  end
  for index,thread in ipairs(history.entries) do
    local y=8+(index-1)*history.row_height-scroll.offset
    if y+history.row_height>0 and y<gc.height then
      gc.color=index==history.selected and Color {r=51,g=70,b=91} or Color {r=38,g=41,b=49}
      gc:fillRect(Rectangle(6,y,gc.width-24,history.row_height-4))
      local preview=preview_text(thread.preview)
      local title=thread.name and thread.name~="" and thread.name or preview~="" and preview or "Untitled conversation"
      local date=type(thread.updatedAt)=="number" and os.date("%m-%d %H:%M",thread.updatedAt) or ""
      if thread.status=="active" then date="Active · "..date end
      local date_width=gc:measureText(date).width
      local title_y=y+4
      if title_y>=0 and title_y<gc.height-gc:measureText(title).height then
        gc.color=Color {r=234,g=238,b=246}
        gc:fillText(elide(gc,title,math.max(1,gc.width-48-date_width)),14,title_y)
        gc.color=Color {r=163,g=174,b=193}
        gc:fillText(date,gc.width-30-date_width,title_y)
      end
      local preview_y=title_y+line_height
      gc.color=Color {r=163,g=174,b=193}
      if preview_y>=0 and preview_y<gc.height-gc:measureText(preview).height then gc:fillText(elide(gc,preview,math.max(1,gc.width-42)),14,preview_y) end
    end
  end
  scrollbar(gc,scroll)
end

--- Browse persisted conversations with an independently scrollable, keyboard-driven list.
function Chat:show_history()
  if self.history_dialog then self.history_dialog:show {wait=false}; return end
  local dlg
  local history={entries={},selected=0,serial=0,query="",loading=false,
    scroll={offset=0,maximum=0,follow=false,auto_follow=false}}
  self.history=history
  local function current(request)
    return self.history==history and self.history_dialog==dlg and history.serial==request
  end
  local function open_selected()
    local selected=history.entries[history.selected]
    if self.history~=history or self.state~="ready" or history.loading or not selected or selected.status=="active" then return end
    local started,error_text=self.callbacks.on_open_thread(selected.id)
    if started then dlg:close() else dlg:modify {id="status",text=error_text or "Could not open conversation."} end
  end
  local function load_page(search,cursor,append)
    history.serial=history.serial+1
    local request=history.serial
    history.query,history.loading=search,true
    dlg:modify {id="status",text=cursor and "Loading more..." or "Loading conversations..."}
    dlg:modify {id="more",enabled=false}
    dlg:modify {id="refresh",enabled=false}
    if not append then
      history.entries,history.selected,history.cursor={},0,nil
      history.row_height=nil
      history.scroll.offset,history.scroll.grab,history.scroll.follow=0,nil,false
    end
    self:set_state(self.state); dlg:repaint()
    local function received(page,error_text)
      if not current(request) then return end
      history.loading=false
      if error_text then dlg:modify {id="status",text=error_text}
      else
        local seen={}
        for _,thread in ipairs(history.entries) do seen[thread.id]=true end
        for _,thread in ipairs(page.data or {}) do
          if not seen[thread.id] then history.entries[#history.entries+1]=thread; seen[thread.id]=true end
        end
        if history.selected==0 and #history.entries>0 then history.selected=1 end
        history.cursor=page.nextCursor
        dlg:modify {id="status",text=#history.entries==0 and "No conversations found." or #history.entries.." conversations · Double-click or Enter to open"}
      end
      dlg:modify {id="refresh",enabled=true}
      dlg:modify {id="more",visible=history.cursor~=nil,enabled=history.cursor~=nil}
      self:set_state(self.state); dlg:repaint()
    end
    local started,error_text=self.callbacks.on_list_threads(search,cursor,received)
    if not started and current(request) then received(nil,error_text or "Could not load history.") end
  end
  local function list_input(action,event)
    local selected=history.selected
    if action=="key" then
      if event.code=="Enter" then open_selected(); event:stopPropagation(); return true end
      if event.code=="Escape" then dlg:close(); event:stopPropagation(); return true end
      local page=math.max(1,math.floor((history.scroll.height or 200)/(history.row_height or 40)))
      local delta=({ArrowUp=-1,ArrowDown=1,PageUp=-page,PageDown=page,Home=-#history.entries,End=#history.entries})[event.code]
      if not delta then return false end
      selected=math.max(1,math.min(#history.entries,selected+delta))
      event:stopPropagation()
    elseif (action=="down" or action=="double") and event.button==MouseButton.LEFT then
      if not history.row_height or event.x<6 or event.x>=(history.width or 0)-18 then return false end
      selected=math.floor((event.y+history.scroll.offset-8)/history.row_height)+1
      if selected<1 or selected>#history.entries then return false end
    else return false end
    if #history.entries==0 then return true end
    history.selected=selected
    local top=8+(selected-1)*(history.row_height or 40)
    if top<history.scroll.offset then history.scroll.offset=top
    elseif top+(history.row_height or 40)>history.scroll.offset+(history.scroll.height or 200) then
      history.scroll.offset=top+(history.row_height or 40)-(history.scroll.height or 200)
    end
    history.scroll.offset=math.max(0,math.min(history.scroll.maximum,history.scroll.offset))
    history.scroll.follow=false
    self:set_state(self.state)
    if action=="double" then open_selected() end
    return true
  end
  dlg=Dialog {title="Aseprite Chat · Conversations",resizeable=true,onclose=function()
    if self.history_dialog==dlg then
      self.history_dialog,self.history=nil,nil
      self:set_state(self.state)
    end
  end}
  self.history_dialog=dlg
  dlg:label {text="Search conversations"}
  dlg:newrow()
  dlg:entry {id="search",text="",focus=true,onchange=function() load_page(dlg.data.search or "",nil,false) end}
  dlg:newrow()
  add_scroll_canvas(dlg,{id="threads",width=380,height=250,hexpand=true,vexpand=true},history.scroll,
    function(gc) paint_history(gc,history) end,list_input)
  dlg:newrow()
  dlg:label {id="status",text="Loading conversations..."}
  dlg:newrow()
  dlg:button {id="open",text="Open conversation",enabled=false,onclick=open_selected}
  dlg:button {id="refresh",text="Refresh",onclick=function() load_page(dlg.data.search or history.query,nil,false) end}
  dlg:button {id="more",text="Load more",enabled=false,onclick=function()
    if history.cursor and not history.loading then load_page(history.query,history.cursor,true) end
  end}
  dlg:button {id="done",text="Close",onclick=function() dlg:close() end}
  dlg:show {wait=false}
  load_page("",nil,false)
end

--- Project the server catalog and persisted selection into native dropdowns.
function Chat:set_models(models, model, effort, tier)
  self.models, self.selected_model, self.selected_effort,self.selected_tier = models, model, effort,tier or "default"
  if not self.dialog then return end
  self.updating_selectors = true
  local labels, chosen, selected = {}, nil, nil
  local names={}
  for _,entry in ipairs(models or {}) do names[entry.displayName]=(names[entry.displayName] or 0)+1 end
  self.models_by_label = {}
  for _, entry in ipairs(models or {}) do
    local label = names[entry.displayName]>1 and entry.displayName .. " (" .. entry.model .. ")" or entry.displayName
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
  self.efforts_by_label={}
  if selected then
    for _, option in ipairs(selected.supportedReasoningEfforts) do
      local label=option.reasoningEffort
      efforts[#efforts+1] = label
      self.efforts_by_label[label]=option.reasoningEffort
      if option.reasoningEffort == effort then valid = true end
    end
  end
  self.has_efforts = #efforts > 0
  local chosen_effort = effort
  if #efforts == 0 then
    chosen_effort = "Not supported"; efforts[1] = chosen_effort
    valid = selected ~= nil and effort == nil
  elseif not valid then
    chosen_effort = "Select level"; table.insert(efforts, 1, chosen_effort)
  end
  self.fast_tier=nil
  if selected then
    for _,option in ipairs(selected.serviceTiers or {}) do
      if option.id=="priority" or option.id=="fast" then
        if not self.fast_tier or option.id==self.selected_tier then self.fast_tier=option.id end
      end
    end
  end
  if selected and not self.fast_tier then self.selected_tier="default" end
  self.selection_valid = selected ~= nil and valid and (self.selected_tier=="default" or self.selected_tier==self.fast_tier)
  project_selector(self,"model",labels,chosen)
  project_selector(self,"effort",efforts,chosen_effort)
  self.updating_selectors = false
  self:set_state(self.state)
end

--- Open connection settings independently; drafts are committed by the controller on Connect.
function Chat:show_settings()
  if self.settings_dialog then self.settings_dialog:show {wait=false}; return end
  local dlg
  dlg = Dialog {title="Aseprite Chat · Settings", autofit=Align.LEFT | Align.TOP, onclose=function()
    if self.settings_dialog == dlg then
      self.settings_dialog = nil
      self:set_state(self.state)
    end
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
  local account = self.callbacks.on_account_get and self.callbacks.on_account_get() or {}
  dlg:separator {text="Account"}
  dlg:combobox {id="account_mode", options={"Codex default (~/.codex)","Custom Codex home"},
    option=account.mode=="custom" and "Custom Codex home" or "Codex default (~/.codex)",
    onchange=function() self:set_state(self.state) end}
  dlg:label {id="account_home_label", text="Codex home"}
  dlg:entry {id="account_home", text=account.codexHome or ""}
  dlg:label {id="account_url_label", text="Base URL (empty = the home's own config/login)"}
  dlg:entry {id="account_url", text=account.baseUrl or ""}
  dlg:label {id="account_url_hint", text="A key with an empty URL targets OpenAI official."}
  dlg:label {id="account_key_status",
    text="API key: " .. (account.keyHint and "saved (" .. account.keyHint .. "), leave blank to keep" or "not set")}
  dlg:entry {id="account_key", text=""}
  dlg:check {id="account_key_clear", text="Remove saved key"}
  dlg:label {id="account_models_label", text="Models (comma-separated, optional)"}
  dlg:entry {id="account_models", text=account.models or ""}
  dlg:button {id="account_apply", text="Apply account", onclick=function()
    if not self.callbacks.on_account_apply then return end
    local key = dlg.data.account_key
    local applied, apply_error = self.callbacks.on_account_apply({
      mode = dlg.data.account_mode == "Custom Codex home" and "custom" or "default",
      codexHome = dlg.data.account_home,
      baseUrl = dlg.data.account_url,
      apiKey = type(key) == "string" and key ~= "" and key or nil,
      clearKey = dlg.data.account_key_clear == true,
      models = dlg.data.account_models
    })
    if not applied then
      if apply_error then self:add_message("account-error", "Error", apply_error, false) end
      return
    end
    local refreshed = self.callbacks.on_account_get and self.callbacks.on_account_get() or {}
    dlg:modify {id="account_key_status",
      text="API key: " .. (refreshed.keyHint and "saved (" .. refreshed.keyHint .. "), leave blank to keep" or "not set")}
    dlg:modify {id="account_key", text=""}
    dlg:modify {id="account_key_clear", selected=false}
  end}
  dlg:button {id="done", text="Done"}
  self:set_state(self.state)
  dlg:show {wait=false}
end

--- Edit an access draft separately; requested_level preselects a profile without applying it.
function Chat:show_access(requested_level)
  if self.state~="ready" and self.state~="disconnected" and self.state~="error" then return end
  if self.access_dialog then self.access_dialog:show {wait=false}; return end
  local access=self.callbacks.on_access_get and self.callbacks.on_access_get() or {}
  local access_options,chosen={},"Canvas only"
  for _,level in ipairs(access_levels) do
    access_options[#access_options+1]=level.label
    if level.id==(requested_level or access.access) then chosen=level.label end
  end
  local dlg
  dlg=Dialog {title="Aseprite Chat · Access",autofit=Align.LEFT | Align.TOP,onclose=function()
    if self.access_dialog==dlg then
      self.access_dialog=nil
      self:set_state(self.state)
    end
  end}
  self.access_dialog=dlg
  dlg:combobox {id="access_level", options=access_options,
    option=chosen,
    onchange=function() self:set_state(self.state) end}
  dlg:label {id="access_workspace_label", text="Workspace folder"}
  dlg:entry {id="access_workspace", text=access.workspace or ""}
  dlg:label {id="access_reviewer_label", text="Boundary approvals"}
  dlg:combobox {id="access_reviewer", options={"Ask me","Auto-review"},
    option=access.reviewer=="auto_review" and "Auto-review" or "Ask me"}
  dlg:label {id="access_note", text=""}
  dlg:label {id="access_error",text="",visible=false}
  dlg:button {id="access_apply", text="Apply access", onclick=function()
    if self.state~="ready" and self.state~="disconnected" and self.state~="error" then return end
    if not self.callbacks.on_access_apply then return end
    local chosen_level
    for _,level in ipairs(access_levels) do if level.label==dlg.data.access_level then chosen_level=level.id end end
    local applied, apply_error = self.callbacks.on_access_apply({
      access=chosen_level,
      workspace=dlg.data.access_workspace,
      reviewer=dlg.data.access_reviewer=="Auto-review" and "auto_review" or "user"
    })
    if applied then dlg:close(); self:set_state(self.state)
    elseif self.access_dialog==dlg then dlg:modify {id="access_error",text=apply_error or "无法更改访问设置。",visible=true} end
  end}
  dlg:button {id="done", text="Done"}
  self:set_state(self.state)
  dlg:show {wait=false}
end

--- Rename a persisted current chat; saving waits for the server acknowledgement.
function Chat:show_rename()
  if self.rename_dialog then self.rename_dialog:show {wait=false}; return end
  if self.state~="ready" or not self.thread_id then return end
  local dlg
  dlg=Dialog {title="Rename conversation",onclose=function()
    if self.rename_dialog==dlg then
      self.rename_dialog=nil
      self:set_state(self.state)
    end
  end}
  self.rename_dialog=dlg
  dlg:entry {id="name",text=self.thread_name or "",focus=true}
  dlg:newrow(); dlg:label {id="error",text="Choose a name for this conversation."}
  dlg:newrow(); dlg:button {id="save",text="Save",onclick=function()
    if self.state~="ready" then return end
    local accepted,err=self.callbacks.on_rename(dlg.data.name,function(success,error_text)
      if self.rename_dialog~=dlg then return end
      if success then dlg:close()
      else dlg:modify {id="error",text=error_text or "Could not rename conversation."} end
    end)
    if not accepted and self.rename_dialog==dlg then dlg:modify {id="error",text=err or "Could not rename conversation."} end
  end}
  dlg:button {text="Cancel",onclick=function() dlg:close() end}
  self:set_state(self.state)
  dlg:show {wait=false}
end

--- Open or reveal the modeless chat dialog without blocking painting.
function Chat:show()
  if self.dialog then self.dialog:show { wait = false }; return end
  local dlg
  dlg = Dialog { title = "Aseprite Chat · Codex", resizeable = true, autofit=0, onclose = function()
    if self.dialog == dlg then
      if self.layout_timer then self.layout_timer:stop(); self.layout_timer=nil end
      self.dialog = nil
      self:dismiss_approval()
      local settings = self.settings_dialog
      self.settings_dialog = nil
      if settings then settings:close() end
      local history = self.history_dialog
      self.history_dialog = nil
      self.history = nil
      if history then history:close() end
      if self.rename_dialog then self.rename_dialog:close() end
      if self.access_dialog then self.access_dialog:close() end
      if self.callbacks.on_close then self.callbacks.on_close() end
    end
  end }
  self.dialog = dlg
  self.selector_options={}
  -- A hidden selector gives the content its own grid. Send has no focus magnet;
  -- Enter is routed by a registered command rather than a background button.
  dlg:tab {id="chat_content",text="",visible=false}
  dlg:button {id="history",text="Chats...",onclick=function() self:show_history() end}
  dlg:button {id="new",text="New chat",onclick=self.callbacks.on_new_chat}
  dlg:button {id="rename",text="Rename...",enabled=self.thread_id~=nil,onclick=function() self:show_rename() end}
  dlg:button {id="settings",text="Settings...",onclick=function() self:show_settings() end}
  dlg:newrow()
  dlg:label {id="conversation",text="New chat"}
  dlg:newrow()
  dlg:label {id="status",text=self.state}
  dlg:newrow()
  add_scroll_canvas(dlg,{id="transcript",width=440,height=280,hexpand=true,vexpand=true},self.scroll,
    function(gc) paint_messages(gc,self); align_send(gc,self) end,function(action,event) return transcript_input(self,action,event) end)
  dlg:newrow()
  dlg:entry {id="input",text="",focus=true,vexpand=true,placeholder="Message Codex about the current canvas..."}
  dlg:newrow()
  dlg:combobox {id="model",hexpand=false,options={"Waiting for connection"},onchange=function()
    if self.updating_selectors or self.state~="ready" then return end
    local entry=self.models_by_label[dlg.data.model]
    if entry then
      local tier="default"
      for _,option in ipairs(entry.serviceTiers or {}) do if option.id==self.selected_tier then tier=option.id end end
      self.callbacks.on_settings(entry.model,#entry.supportedReasoningEfforts>0 and entry.defaultReasoningEffort or nil,tier)
    end
  end}
  dlg:combobox {id="effort",hexpand=false,options={"Not supported"},onchange=function()
    if self.updating_selectors or self.state~="ready" then return end
    local entry=self.models_by_label[dlg.data.model]
    if entry then self.callbacks.on_settings(entry.model,self.has_efforts and self.efforts_by_label[dlg.data.effort] or nil,
      self.selected_tier) end
  end}
  local access_options={}
  for _,level in ipairs(access_levels) do access_options[#access_options+1]=level.label end
  access_options[#access_options+1]="Access settings..."
  dlg:combobox {id="access",hexpand=false,options=access_options,onchange=function()
    if self.updating_selectors then return end
    local selected=dlg.data.access
    self:set_state(self.state)
    if self.state~="ready" and self.state~="disconnected" and self.state~="error" then return end
    if selected=="Access settings..." then self:show_access(); return end
    local profile
    for _,level in ipairs(access_levels) do if level.label==selected then profile=level.id end end
    if not profile then return end
    local current=self.callbacks.on_access_get and self.callbacks.on_access_get() or {}
    if profile=="workspace" and (current.workspace or "")=="" then self:show_access(profile); return end
    if not self.callbacks.on_access_apply then return end
    local applied,error_text=self.callbacks.on_access_apply {access=profile,workspace=current.workspace,reviewer=current.reviewer}
    self:set_state(self.state)
    if not applied then self:add_message("access-error","Error","无法更改访问设置。"..(error_text and "\n"..error_text or ""),false) end
  end}
  dlg:combobox {id="auto_approve",hexpand=false,options={"Ask before edits","Auto-approve edits"},onchange=function()
    if self.updating_selectors then return end
    local enabled=dlg.data.auto_approve=="Auto-approve edits"
    if self.state~="ready" or self.approval or enabled==self.auto_approve then self:set_state(self.state); return end
    local accepted,error_text=self.callbacks.on_approval_mode(enabled)
    if accepted then self:set_approval_mode(enabled)
    else self:set_state(self.state); if error_text then self:add_message("approval-mode-error","Error",error_text,false) end end
  end}
  dlg:newrow()
  self.controls={}
  local function add(spec) self.controls[spec.id]=spec end
  add {id="stop",text="Stop",visible=false,onclick=self.callbacks.on_stop}
  add {id="speed",text="Fast",visible=false,onclick=function()
    if self.state~="ready" or not self.fast_tier then self:set_state(self.state); return end
    local tier=self.selected_tier=="default" and self.fast_tier or "default"
    local accepted,error_text=self.callbacks.on_settings(self.selected_model,self.selected_effort,tier)
    self:set_state(self.state)
    if accepted==false and error_text then self:add_message("speed-error","Error",error_text,false) end
  end}
  add {id="retry",text="Retry",onclick=function()
    self.callbacks.on_connect(self.preferences.manual_server and self.preferences.endpoint or nil)
  end}
  dlg:canvas {id="composer",width=440,height=26,hexpand=true,vexpand=false,
    onpaint=function(ev) paint_composer(ev.context,self) end,
    onmousedown=function(ev)
      if ev.button~=MouseButton.LEFT then return end
      for index,rect in ipairs(self.control_rects or {}) do
        if ev.x>=rect.x and ev.x<rect.x+rect.width and ev.y>=0 and ev.y<rect.height then
          self.control_focus=rect.id
          activate_control(self,rect.id); dlg:repaint(); return
        end
      end
    end,
    onkeydown=function(ev)
      local rects=self.control_rects or {}
      if #rects==0 then return end
      local focused=1
      for index,rect in ipairs(rects) do if rect.id==self.control_focus then focused=index end end
      if ev.code=="ArrowLeft" or ev.code=="ArrowRight" then
        self.control_focus=rects[(focused-1+(ev.code=="ArrowLeft" and -1 or 1))%#rects+1].id
      elseif ev.code=="Space" then
        activate_control(self,rects[focused].id)
      else return end
      ev:stopPropagation(); dlg:repaint()
    end}
  dlg:endtabs {selected="chat_content",vexpand=true}
  dlg:newrow()
  self.send_padding=nil
  dlg:button {id="send",label="",text="Send",hexpand=false,onclick=function()
    self:submit()
  end}
  self:set_models(self.models, self.selected_model, self.selected_effort,self.selected_tier)
  self:set_thread(self.thread_id,self.thread_name)
  dlg:show { wait = false }
  -- Retain the native entry's text/IME handling, giving it and the transcript
  -- extra vertical room without changing their minimum native widget sizes.
  local bounds=dlg.bounds
  dlg.bounds=Rectangle(bounds.x,bounds.y,bounds.width,bounds.height+40)
end

--- Show the complete pending action; the caller must revalidate after approval.
--- args: {summary,code} for Lua, or {title,body,note} for other requests.
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
  dlg = Dialog { title = args.title or "Approve Codex Lua", resizeable = true, onclose = function() finish(false) end }
  pending = { dialog = dlg, finish = finish }
  self.approval = pending
  add_scroll_canvas(dlg, {id="code", width=420, height=280, hexpand=true, vexpand=true}, scroll,
    function(gc) paint(gc,args.body or (args.summary .. "\n\n" .. args.code),scroll) end)
  dlg:label { text = args.note or "Approved Lua runs immediately. Running Lua cannot be interrupted." }
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
  if self.layout_timer then self.layout_timer:stop(); self.layout_timer=nil end
  self:dismiss_approval()
  self.scroll.grab = nil
  local settings = self.settings_dialog
  self.settings_dialog = nil
  if settings then settings:close() end
  local history = self.history_dialog
  self.history_dialog = nil
  self.history = nil
  if history then history:close() end
  if self.access_dialog then self.access_dialog:close() end
  if self.rename_dialog then self.rename_dialog:close() end
  local dlg = self.dialog
  self.dialog = nil
  if dlg then dlg:close() end
end

return Chat
