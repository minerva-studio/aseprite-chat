local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local path = app.fs.joinPath(root, "chat.lua")
assert(app.fs.isFile(path), "chat module is not implemented")
local Chat = dofile(path)
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok, name .. ": " .. tostring(err))
  passed = passed + 1
end
local function measure(text) return utf8.len(text) end
local function native_view(callbacks, preferences)
  local dialogs = {}
  local env = setmetatable({Dialog=function(spec)
    local dialog = {data={},widgets={},buttons={},spec=spec}
    setmetatable(dialog,{__newindex=function(_,key) error("Native Dialog cannot own custom field: " .. key) end,
      __index=function(_,method)
      return function(self,widget)
        if method=="close" then rawset(self,"closed",true); if self.spec.onclose then self.spec.onclose() end
        elseif widget and widget.id then
          if method=="modify" then
            for key,value in pairs(widget) do self.widgets[widget.id][key]=value end
          else self.widgets[widget.id]=widget; widget.kind=method end
          if widget.option or widget.text then self.data[widget.id]=widget.option or widget.text end
          if widget.selected ~= nil then self.data[widget.id]=widget.selected end
        end
        if method=="button" then self.buttons[#self.buttons+1]=widget end
        return self
      end
    end})
    dialogs[#dialogs+1]=dialog
    return dialog
  end},{__index=_G})
  local UI=assert(loadfile(path,"t",env))()
  local view=UI.new(callbacks or {},preferences or {})
  view:show()
  local gc={width=240,height=80}
  function gc:measureText(text) return {width=utf8.len(text)*6,height=10} end
  function gc:fillRect() end
  function gc:fillText() end
  return view,dialogs,gc
end
test("UTF-8 characters remain intact when wrapping", function()
  local lines = Chat.wrap("你好世界", 2, measure)
  assert(#lines == 2 and lines[1] == "你好" and lines[2] == "世界")
end)
test("newlines and blank lines are preserved", function()
  local lines = Chat.wrap("a\n\nb\n", 4, measure)
  assert(#lines == 4 and lines[1] == "a" and lines[2] == "" and lines[3] == "b" and lines[4] == "")
end)
test("oversized characters still make forward progress", function()
  local lines = Chat.wrap("你a", 0, measure)
  assert(#lines == 2 and lines[1] == "你" and lines[2] == "a")
end)
test("stream completion replaces deltas without duplication", function()
  local view = Chat.new({}, {})
  view:add_message("a", "Codex", "hel", true)
  view:add_message("a", "Codex", "lo", true)
  view:add_message("a", "Codex", "hello", false)
  view:add_message("a", "Codex", "hello", false)
  assert(#view.messages == 1 and view.messages[1].text == "hello")
  view:add_message("b", "You", "next", false)
  assert(#view.messages == 2 and view.messages[2].text == "next")
end)
test("model and reasoning widgets are actual dropdowns populated from catalog values", function()
  local widgets, data = {}, {}
  local dialog = setmetatable({data=data}, {__index=function(_,method)
    return function(self,spec)
      if spec and spec.id then
        if method == "modify" then
          for key,value in pairs(spec) do widgets[spec.id][key]=value end
          if spec.option then data[spec.id]=spec.option end
        else
          widgets[spec.id]=spec; widgets[spec.id].kind=method
          data[spec.id]=spec.option or spec.text
        end
      end
      return self
    end
  end})
  local env=setmetatable({Dialog=function() return dialog end}, {__index=_G})
  local UI=assert(loadfile(path,"t",env))()
  local chosen
  local view=UI.new({on_settings=function(model,effort) chosen={model,effort} end},{})
  view:show()
  assert(widgets.model.kind=="combobox", "model is still a text entry")
  assert(widgets.effort.kind=="combobox", "missing reasoning dropdown")
  local models={
    {model="wire-a",displayName="Same label",isDefault=true,defaultReasoningEffort="high",
      supportedReasoningEfforts={{reasoningEffort="low"},{reasoningEffort="high"}}},
    {model="wire-b",displayName="Same label",defaultReasoningEffort="medium",
      supportedReasoningEfforts={{reasoningEffort="medium"}}}
  }
  view:set_models(models,"wire-a","high"); view:set_state("ready")
  assert(#widgets.model.options==2 and #widgets.effort.options==2)
  assert(widgets.model.options[1]~=widgets.model.options[2], "duplicate model labels")
  data.model=widgets.model.options[2]; widgets.model.onchange()
  assert(chosen[1]=="wire-b" and chosen[2]=="medium")
  view:set_models(models,"wire-b","medium")
  assert(#widgets.effort.options==1 and data.effort=="medium")
  view:set_state("working"); assert(not widgets.model.enabled and not widgets.effort.enabled)
  local plain={{model="plain",displayName="Plain",supportedReasoningEfforts={}}}
  view:set_models(plain,"plain","high"); view:set_state("ready")
  assert(not view.selection_valid and #widgets.model.options==2, "stale effort cannot be explicitly repaired")
  data.model="Plain (plain)"; widgets.model.onchange()
  assert(chosen[1]=="plain" and chosen[2]==nil)
  view:set_models(plain,"plain",nil)
  assert(view.selection_valid and not widgets.effort.enabled)
  view:close()
end)
test("connection settings live in a separate window and close with the chat",function()
  local connected="not-called"
  local view,dialogs=native_view({on_connect=function(endpoint) connected=endpoint end},{endpoint="ws://127.0.0.1:4500"})
  local main=dialogs[1]
  assert(not main.widgets.endpoint and not main.widgets.connect and not main.widgets.disconnect,
    "connection controls still occupy the chat")
  for _, button in ipairs(main.buttons) do assert(button.text~="Up" and button.text~="Down", "paging buttons remain") end
  main.widgets.retry.onclick()
  assert(connected==nil, "Retry did not request automatic discovery")
  main.widgets.settings.onclick()
  assert(#dialogs==2 and view.settings_dialog==dialogs[2])
  local settings=dialogs[2]
  assert(settings.data.endpoint=="ws://127.0.0.1:4500")
  assert(settings.widgets.endpoint.visible==false and settings.data.manual==false, "manual configuration is the default")
  settings.data.manual=true; settings.widgets.manual.onclick()
  view:set_state("working")
  assert(not settings.widgets.endpoint.enabled and not settings.widgets.connect.enabled and settings.widgets.disconnect.enabled)
  view:set_state("disconnected")
  assert(settings.widgets.endpoint.enabled and settings.widgets.connect.enabled)
  settings.data.endpoint="ws://127.0.0.1:4567"; settings.widgets.connect.onclick()
  assert(connected==settings.data.endpoint and view.preferences.endpoint=="ws://127.0.0.1:4500")
  view:close(); assert(settings.closed and view.settings_dialog==nil)
end)

test("settings show only the current connection action with a short caption",function()
  local view,dialogs=native_view()
  view:set_state("ready"); view:show_settings()
  local settings=dialogs[2]
  assert(settings.widgets.connect.visible==false and settings.widgets.disconnect.visible==true,
    "connected settings still show a disabled retry action")
  assert(settings.widgets.status.text=="Status: Connected", "connection status is an internal state name")
  assert(not settings.widgets.status.label and not settings.widgets.endpoint.label,
    "form labels reserve an unwanted indentation column")
  view:set_state("disconnected")
  assert(settings.widgets.connect.visible==true and settings.widgets.disconnect.visible==false)
  assert(settings.widgets.connect.text=="Retry", "automatic retry caption stretches the window")
  view:set_state("starting")
  assert(settings.widgets.connect.visible==false and settings.widgets.disconnect.visible==true)
  assert(settings.widgets.disconnect.text=="Cancel startup")
  view:close()
end)

test("history picker loads pages, deduplicates threads, and preserves empty-page cursors",function()
  local requests={}
  local view,dialogs=native_view({
    on_list_threads=function(search,cursor,callback)
      requests[#requests+1]={search=search,cursor=cursor,callback=callback}
      return true
    end,
    on_open_thread=function() return true end
  })
  view:set_state("ready")
  local main=dialogs[1]
  assert(main.widgets.history and main.widgets.history.text=="History", "missing History button")
  main.widgets.history.onclick()
  local picker=dialogs[2]
  assert(picker and picker.widgets.search.kind=="entry" and picker.widgets.threads.kind=="combobox")
  assert(#requests==1 and requests[1].search=="" and requests[1].cursor==nil, "picker did not load first page")
  requests[1].callback({data={{id="thread-1",name="A long conversation title",preview="",updatedAt="today",status="idle"}},nextCursor="next"})
  assert(picker.widgets.more.enabled and picker.widgets.open.enabled)
  picker.widgets.more.onclick()
  assert(requests[2].cursor=="next")
  requests[2].callback({data={{id="thread-1",name="duplicate",preview="",updatedAt="today"}},nextCursor="later"})
  assert(#picker.widgets.threads.options==1, "duplicate thread was appended")
  picker.widgets.more.onclick()
  requests[3].callback({data={},nextCursor="last"})
  assert(picker.widgets.more.enabled, "empty page discarded its next cursor")
  picker.widgets.more.onclick()
  requests[4].callback({data={{id="thread-2",preview="preview",updatedAt="yesterday"}}})
  assert(#picker.widgets.threads.options==2 and not picker.widgets.more.enabled)
  assert(picker.widgets.threads.options[1]:find("thread%-1"), "picker title omits short id")
  view:close()
end)

test("history search and picker identity retire stale callbacks",function()
  local requests={}
  local view,dialogs=native_view({on_list_threads=function(search,cursor,callback)
    requests[#requests+1]={search=search,cursor=cursor,callback=callback}; return true
  end})
  view:set_state("ready")
  dialogs[1].widgets.history.onclick()
  local first=dialogs[2]
  first.data.search="old"; first.widgets.search.onchange()
  first.data.search="new"; first.widgets.search.onchange()
  requests[3].callback({data={{id="new-thread",name="New"}}})
  requests[2].callback({data={{id="old-thread",name="Old"}}})
  assert(#first.widgets.threads.options==1 and first.widgets.threads.options[1]:find("new%-thr"))
  first.widgets.done.onclick()
  dialogs[1].widgets.history.onclick()
  local reopened=dialogs[3]
  requests[1].callback({data={{id="late-thread",name="Late"}}})
  assert(#reopened.widgets.threads.options==0, "closed picker callback changed reopened picker")
  view:close()
end)

test("opening a history thread is locked unless ready and closes only after accepted start",function()
  local opened={}
  local view,dialogs=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="thread-1",name="Conversation"}}}); return true
  end,on_open_thread=function(id) opened[#opened+1]=id; return true end})
  dialogs[1].widgets.history.onclick()
  local picker=dialogs[2]
  assert(not picker.widgets.open.enabled, "thread can open before ready")
  picker.data.threads=picker.widgets.threads.options[1]
  view:set_state("working")
  assert(not picker.widgets.open.enabled, "thread can open while working")
  view:set_state("ready")
  assert(picker.widgets.open.enabled)
  picker.widgets.open.onclick()
  assert(opened[1]=="thread-1" and picker.closed, "accepted thread open did not close picker")
  view:close()
end)

test("rejected history open remains visible with error and non-ready states stay locked",function()
  local view,dialogs=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="thread-1",name="Conversation"}}}); return true
  end,on_open_thread=function() return false,"cannot open" end})
  dialogs[1].widgets.history.onclick()
  local picker=dialogs[2]
  view:set_state("loading")
  assert(not picker.widgets.open.enabled)
  view:set_state("ready")
  picker.data.threads=picker.widgets.threads.options[1]
  picker.widgets.open.onclick()
  assert(picker.closed~=true and picker.widgets.status.text:find("cannot open",1,true))
  view:close()
end)

test("history errors remain visible and a failed More request can be retried",function()
  local requests={}
  local view,dialogs=native_view({on_list_threads=function(search,cursor,callback)
    requests[#requests+1]={search=search,cursor=cursor,callback=callback}; return true
  end})
  dialogs[1].widgets.history.onclick()
  local picker=dialogs[2]
  requests[1].callback(nil,"offline")
  assert(picker.widgets.status.text=="offline" and picker.widgets.refresh.enabled)
  picker.data.search="needle"; picker.widgets.search.onchange()
  assert(requests[2].search=="needle" and requests[2].cursor==nil)
  requests[2].callback({data={{id="thread-1",name="A"}},nextCursor="next"})
  picker.widgets.more.onclick()
  requests[3].callback(nil,"page failed")
  assert(picker.widgets.status.text=="page failed" and picker.widgets.more.enabled)
  picker.widgets.more.onclick()
  assert(requests[4].search=="needle" and requests[4].cursor=="next")
  requests[4].callback({data={{id="thread-2",name="B"}}})
  picker.widgets.refresh.onclick()
  assert(requests[5].search=="needle" and requests[5].cursor==nil)
  view:close()
end)

test("history labels truncate on UTF-8 boundaries and distinguish matching titles",function()
  local requests={}
  local view,dialogs=native_view({on_list_threads=function(_,_,callback)
    requests[#requests+1]=callback; return true
  end})
  dialogs[1].widgets.history.onclick()
  local picker=dialogs[2]
  requests[1]({data={
    {id="abcdefgh-1",name=string.rep("界",50)},
    {id="abcdefgh-2",name=string.rep("界",50)}
  }})
  local first,second=picker.widgets.threads.options[1],picker.widgets.threads.options[2]
  assert(first~=second and first:find("abcdefgh%-1",1)==nil and first:find("abcdefgh",1,true))
  assert(utf8.len(first)<50 and utf8.len(second)<50, "long title was not bounded")
  dialogs[1]:close()
  assert(picker.closed==true and view.history_dialog==nil, "closing chat left history open")
end)

test("short history previews hide appended canvas metadata",function()
  local view,dialogs=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="short-id",preview='hi\n\nCurrent Aseprite target:\n{"revision":123}',status="idle"}}}); return true
  end})
  view:set_state("ready"); view:show_history()
  assert(dialogs[2].widgets.threads.options[1]=="hi · short-id", "history title exposed internal canvas context")
  view:close()
end)

test("active history cannot be opened by a state refresh or selection change",function()
  local opened=false
  local view,dialogs=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="busy-thread",name="Busy",status="active"},{id="idle-thread",name="Idle",status="idle"}}}); return true
  end,on_open_thread=function() opened=true; return true end})
  view:set_state("ready"); view:show_history()
  local picker=dialogs[2]
  assert(not picker.widgets.open.enabled)
  picker.widgets.open.onclick(); assert(not opened)
  picker.data.threads=picker.widgets.threads.options[2]; picker.widgets.threads.onchange()
  assert(picker.widgets.open.enabled)
  view:set_state("working"); assert(not picker.widgets.open.enabled)
  view:close()
end)

test("connection loss retires an open picker instead of leaving a permanent loading state",function()
  local callbacks={}
  local view,dialogs=native_view({on_list_threads=function(_,_,callback) callbacks[#callbacks+1]=callback; return true end})
  view:set_state("ready"); view:show_history()
  local old=dialogs[2]
  view:set_state("disconnected")
  assert(old.closed and not view.history_dialog and not view.history_loading)
  view:set_state("ready"); view:show_history()
  callbacks[1]({data={{id="stale",name="Old"}}})
  assert(dialogs[3].widgets.open.enabled==false)
  callbacks[2]({data={{id="fresh",name="New",status="idle"}}})
  assert(dialogs[3].widgets.open.enabled)
  view:close()
end)

test("an empty authoritative summary clears the streamed preview without an empty heading",function()
  local view,dialogs,gc=native_view()
  view:add_message("summary","Summary","temporary summary",false)
  view:add_message("summary","Summary","",false)
  local visible={}; function gc:fillText(text) visible[#visible+1]=text end
  dialogs[1].widgets.transcript.onpaint {context=gc}
  assert(not table.concat(visible):find("temporary summary",1,true) and not table.concat(visible):find("Summary",1,true))
  view:close()
end)

test("approval setting projects controller state, reverts rejection, and marks main status",function()
  local decisions={}
  local view,dialogs=native_view({on_approval_mode=function(enabled)
    decisions[#decisions+1]=enabled
    if enabled then return false,"denied" end
    return true
  end})
  view:set_state("ready")
  view:show_settings()
  local settings=dialogs[2]
  assert(settings.widgets.auto_approve and settings.widgets.auto_approve.selected==false,
    "automatic approval does not default off")
  assert(not settings.widgets.auto_approve.label, "approval row adds form label indentation")
  view:set_approval_mode(true)
  assert(settings.widgets.auto_approve.selected==true and dialogs[1].widgets.status.text:find("Auto%-approve: on"))
  settings.data.auto_approve=true; settings.widgets.auto_approve.onclick()
  assert(decisions[1]==true and settings.widgets.auto_approve.selected==true,
    "rejected controller projection was not restored")
  view:set_state("working")
  assert(not settings.widgets.auto_approve.enabled)
  settings.data.auto_approve=false; settings.widgets.auto_approve.onclick()
  assert(#decisions==1, "disabled approval control still changed controller state")
  view:set_state("ready")
  settings.data.auto_approve=false; settings.widgets.auto_approve.onclick()
  assert(decisions[2]==false)
  view:set_approval_mode(false)
  assert(settings.widgets.auto_approve.selected==false)
  view:close()
end)

test("transcript scrolls by wheel, draggable thumb, track and keyboard without losing reading position",function()
  local view,dialogs,gc=native_view()
  local canvas=dialogs[1].widgets.transcript
  view:add_message("long","Codex",string.rep("Long message\n",80),false)
  canvas.onpaint {context=gc}
  local maximum=view.scroll.maximum
  assert(maximum>0 and view.scroll.offset==maximum)
  canvas.onwheel {deltaY=-10000}; canvas.onpaint {context=gc}
  assert(view.scroll.offset==0 and not view.scroll.follow)
  canvas.onmousedown {button=MouseButton.LEFT,x=gc.width-5,y=3}
  canvas.onmousemove {x=gc.width-5,y=gc.height+100}
  canvas.onmouseup {button=MouseButton.LEFT}
  assert(view.scroll.offset==view.scroll.maximum and view.scroll.follow, "thumb did not reach bottom")
  canvas.onwheel {deltaY=-1}; local reading=view.scroll.offset
  view:add_message("more","Codex",string.rep("new content\n",10),false); canvas.onpaint {context=gc}
  assert(view.scroll.offset==reading and not view.scroll.follow, "streaming stole the reading position")
  local consumed=0
  canvas.onkeydown {code="End",stopPropagation=function() consumed=consumed+1 end}
  canvas.onpaint {context=gc}
  assert(view.scroll.offset==view.scroll.maximum and view.scroll.follow and consumed==1)
  canvas.onmousedown {button=MouseButton.LEFT,x=gc.width-5,y=3}
  assert(view.scroll.offset<view.scroll.maximum, "track click did not page up")
  view:close()
end)

test("Lua approval has its own wheel and draggable scrollbar",function()
  local view,dialogs,gc=native_view()
  local lines={}
  for i=1,80 do lines[i]="local value" .. i .. "=" .. i end
  view:request_approval({summary="Long code",code=table.concat(lines,"\n")},function() end)
  local code=dialogs[2].widgets.code
  assert(code and code.onmousedown and code.onmousemove and code.onmouseup, "approval scrollbar is not interactive")
  local visible={}
  function gc:fillText(text) visible[#visible+1]=text end
  code.onpaint {context=gc}
  assert(table.concat(visible):find("Long code",1,true))
  gc.height=5000; code.onpaint {context=gc}
  gc.height=80; visible={}; code.onpaint {context=gc}
  assert(table.concat(visible):find("Long code",1,true), "resizing approval past fitting size jumped to bottom")
  code.onmousedown {button=MouseButton.LEFT,x=gc.width-5,y=3}
  code.onmousemove {x=gc.width-5,y=gc.height+100}
  code.onmouseup {button=MouseButton.LEFT}
  visible={}; code.onpaint {context=gc}
  local bottom=table.concat(visible)
  assert(bottom:find("value80",1,true) and not bottom:find("Long code",1,true), "approval drag did not reveal its final lines")
  code.onwheel {deltaY=-1}
  visible={}; code.onpaint {context=gc}
  assert(table.concat(visible)~=bottom, "approval wheel did not move its content")
  assert(view.scroll.offset==0, "approval scroll changed transcript offset")
  view:close()
end)
print("chat: " .. passed .. " passed")
