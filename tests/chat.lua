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
    local dialog = {data={},widgets={},buttons={},spec=spec,bounds=Rectangle(0,0,500,420)}
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
  local dialog = setmetatable({data=data,bounds=Rectangle(0,0,500,420)}, {__index=function(_,method)
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
  assert(widgets.model.options[2]=="Plain", "unique display name repeats its technical model ID")
  data.model="Plain"; widgets.model.onchange()
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

test("speed selection uses advertised IDs, locks while working and repairs a missing tier",function()
  local chosen
  local view,dialogs=native_view({on_settings=function(model,effort,tier) chosen={model,effort,tier} end})
  local main=dialogs[1]
  local models={{model="sol",displayName="Sol",supportedReasoningEfforts={{reasoningEffort="low"}},
    serviceTiers={{id="priority",name="Fast",description="More usage"}}}}
  view:set_models(models,"sol","low","default"); view:set_state("ready")
  assert(main.data.speed=="Standard" and #main.widgets.speed.options==2)
  main.data.speed="Fast"; main.widgets.speed.onchange()
  assert(chosen[1]=="sol" and chosen[2]=="low" and chosen[3]=="priority")
  view:set_models(models,"sol","low","priority"); view:set_state("working")
  assert(not main.widgets.speed.enabled)
  models[1].serviceTiers={}
  view:set_models(models,"sol","low","priority"); view:set_state("ready")
  assert(not view.selection_valid and main.data.speed=="Select level")
  main.data.speed="Standard"; main.widgets.speed.onchange()
  assert(chosen[3]=="default")
  view:set_models(models,"sol","low","default"); assert(view.selection_valid)
  view:close()
end)

test("rename waits for acknowledgement, preserves named titles and cleans up on disconnect",function()
  local callback,requested
  local view,dialogs=native_view({on_rename=function(name,done) requested,callback=name,done; return true end})
  assert(not dialogs[1].widgets.rename.enabled)
  view:set_thread("one","魔法书"); view:set_state("ready")
  assert(dialogs[1].widgets.rename.enabled)
  view:add_message("u","You","A different preview",false)
  assert(dialogs[1].widgets.conversation.text=="魔法书")
  dialogs[1].widgets.rename.onclick()
  local rename=dialogs[2]; assert(rename.data.name=="魔法书")
  rename.data.name="封面"; rename.widgets.save.onclick(); assert(requested=="封面" and view.rename_dialog==rename)
  view:set_state("renaming"); assert(not rename.widgets.save.enabled)
  view:set_state("ready"); callback(false,"Server refused")
  assert(view.rename_dialog==rename and rename.widgets.error.text=="Server refused")
  rename.widgets.save.onclick(); view:set_thread("one","封面"); callback(true)
  assert(rename.closed and not view.rename_dialog and dialogs[1].widgets.conversation.text=="封面")
  view:show_rename(); local stale=dialogs[3]
  stale.widgets.save.onclick(); view:set_state("disconnected"); callback(true)
  assert(stale.closed and not view.rename_dialog)
  view:close()
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

test("message cards measure actual fallback glyphs across font sizes and retain bottom padding",function()
  local view,dialogs,gc=native_view()
  gc.height=500
  local font_height,drawn=20,{}
  function gc:measureText(text) return {width=utf8.len(text)*6,height=text:find("龘",1,true) and font_height or 10} end
  function gc:fillText(text,x,y) drawn[#drawn+1]={text=text,x=x,y=y,height=self:measureText(text).height} end
  view:add_message("a","Codex","English line",false)
  view:add_message("b","Codex","龘",false)
  for _,height in ipairs({20,38,16}) do
    font_height,drawn=height,{}
    dialogs[1].widgets.transcript.onpaint {context=gc}
    for _,card in ipairs(view.scroll.cards) do
      for _,line in ipairs(drawn) do if line.text==card.message.text then
        assert(line.y+line.height+8<=card.top+card.height, "actual fallback glyphs exceed message bottom padding")
      end end
    end
  end
  view:close()
end)

test("history and approval code measure fallback glyphs absent from a fixed sample",function()
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="a",name="龘",preview="龘 preview"}}}); return true
  end})
  gc.height=500
  function gc:measureText(text) return {width=utf8.len(text)*6,height=text:find("龘",1,true) and 37 or 10} end
  local title,preview,background
  function gc:fillRect(rect) if rect.x==6 then background=rect end end
  function gc:fillText(text,_,y)
    if text=="龘" then title={y=y,height=37} elseif text=="龘 preview" then preview={y=y,height=37} end
  end
  view:set_state("ready"); view:show_history(); dialogs[2].widgets.threads.onpaint {context=gc}
  assert(title and preview and preview.y>=title.y+title.height+4, "actual history title overlaps preview")
  assert(preview.y+preview.height+8<=background.y+background.height, "actual history preview exceeds card")
  local code_rows={}
  function gc:fillText(text,_,y) if text:find("龘",1,true) then code_rows[#code_rows+1]=y end end
  view:request_approval({summary="龘",code="龘"},function() end)
  dialogs[3].widgets.code.onpaint {context=gc}
  assert(#code_rows==2 and code_rows[2]>=code_rows[1]+37+4, "approval glyphs overlap")
  view:close()
end)

test("user bubbles and You labels align right while body text remains left aligned",function()
  local view,dialogs,gc=native_view(); gc.height=500
  local drawn={}; function gc:fillText(text,x,y) drawn[#drawn+1]={text=text,x=x,y=y} end
  view:add_message("a","Codex","Assistant",false)
  view:add_message("u","You","My question",false)
  dialogs[1].widgets.transcript.onpaint {context=gc}
  local card=view.scroll.cards[2]
  assert(card.x and card.x>view.scroll.cards[1].x and card.width<view.scroll.cards[1].width, "user bubble stays on the left")
  for _,line in ipairs(drawn) do
    if line.text=="You" then assert(line.x+gc:measureText("You").width==card.x+card.width-8)
    elseif line.text=="My question" then assert(line.x==card.x+8) end
  end
  view:close()
end)

test("history background contains the full preview and bottom font-bearing allowance",function()
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="one",name="Remember opal",preview="Tail pgy_",updatedAt=1700000000}}}); return true
  end})
  local background,preview
  gc.height=300
  function gc:fillRect(rect) if rect.x==6 and rect.width==self.width-24 then background=rect end end
  function gc:fillText(text,_,y) if text=="Tail pgy_" then preview={y=y,height=self:measureText(text).height} end end
  view:set_state("ready"); view:show_history(); dialogs[2].widgets.threads.onpaint {context=gc}
  assert(background and preview and preview.y+preview.height+8<=background.y+background.height, "preview extends below its entry background")
  view:close()
end)

test("CJK activity titles fit folded cards and do not overlap expanded details",function()
  local view,dialogs,gc=native_view(); gc.height=500; gc.width=500
  function gc:measureText(text) return {width=utf8.len(text)*6,height=text:find("魔",1,true) and 22 or 10} end
  local title,body
  function gc:fillText(text,_,y)
    if text:match("^%[[+-]%]") and text:find("魔",1,true) then title={y=y,height=self:measureText(text).height}
    elseif text=="魔法工具 · Succeeded" then body={y=y} end
  end
  view:add_message("t","Tool","魔法工具 · Succeeded\nDetails",false)
  local canvas=dialogs[1].widgets.transcript; canvas.onpaint {context=gc}
  local card=view.scroll.cards[1]
  assert(title and title.y+title.height+5<=card.top+card.height, "tall title extends below folded card")
  canvas.onmousedown {button=MouseButton.LEFT,x=20,y=card.top+6}
  title,body=nil,nil
  canvas.onpaint {context=gc}
  assert(title and body and body.y>=title.y+title.height+5, "expanded details overlap the title")
  view:close()
end)

test("tool and summary cards collapse details, preserve expansion on updates and support keyboard",function()
  local view,dialogs,gc=native_view()
  gc.height=600
  local canvas=dialogs[1].widgets.transcript
  local visible={}; function gc:fillText(text) visible[#visible+1]=text end
  view:add_message("tool","Tool",'read_sprite · Running\nResult:\n{"secretDetail":123}',false)
  view:add_message("reason","Summary","Detailed reasoning summary",false)
  canvas.onpaint {context=gc}
  assert(not table.concat(visible):find("secretDetail",1,true) and not table.concat(visible):find("Detailed reasoning",1,true), "activity floods the default transcript")
  local card=view.scroll.cards[1]
  canvas.onmousedown {button=MouseButton.LEFT,x=20,y=card.top-view.scroll.offset+6}
  visible={}; canvas.onpaint {context=gc}
  assert(table.concat(visible):find("secretDetail",1,true), "tool details did not expand")
  view:add_message("tool","Tool",'read_sprite · Succeeded\nResult:\n{"secretDetail":456}',false)
  visible={}; canvas.onpaint {context=gc}
  assert(table.concat(visible):find("456",1,true), "stream update reset expansion")
  canvas.onkeydown {code="Enter",stopPropagation=function() end}
  visible={}; canvas.onpaint {context=gc}
  assert(not table.concat(visible):find("secretDetail",1,true), "keyboard did not collapse selected activity")
  assert(view.by_id.tool.text:find("456",1,true), "folding discarded the result")
  view:clear(); assert(not view.focused_message)
  view:close()
end)

test("reading history exposes an in-transcript Latest control that resumes following",function()
  local view,dialogs,gc=native_view()
  local canvas=dialogs[1].widgets.transcript
  for i=1,4 do
    view:add_message("u"..i,"You","Prompt "..i,false)
    view:add_message("a"..i,"Codex",string.rep("Answer line\n",8),false)
  end
  canvas.onpaint {context=gc}
  canvas.onkeydown {code="Home",stopPropagation=function() end}; canvas.onpaint {context=gc}
  assert(view.scroll.offset==0 and not view.scroll.follow)
  assert(not dialogs[1].widgets.latest, "latest still occupies the composer toolbar")
  assert(view.scroll.latest, "no in-transcript jump control while reading history")
  local jump=view.scroll.latest
  canvas.onmousedown {button=MouseButton.LEFT,x=jump.x+2,y=jump.y+2}; canvas.onpaint {context=gc}
  assert(view.scroll.follow and view.scroll.offset==view.scroll.maximum)
  assert(not view.scroll.latest, "jump control remains visible at the bottom")
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
  assert(main.widgets.history and main.widgets.history.text=="Chats...", "missing History button")
  main.widgets.history.onclick()
  local picker=dialogs[2]
  assert(picker and picker.widgets.search.kind=="entry" and picker.widgets.threads.kind=="canvas")
  assert(#requests==1 and requests[1].search=="" and requests[1].cursor==nil, "picker did not load first page")
  requests[1].callback({data={{id="thread-1",name="A long conversation title",preview="",updatedAt="today",status="idle"}},nextCursor="next"})
  assert(picker.widgets.more.enabled and picker.widgets.open.enabled)
  picker.widgets.more.onclick()
  assert(requests[2].cursor=="next")
  requests[2].callback({data={{id="thread-1",name="duplicate",preview="",updatedAt="today"}},nextCursor="later"})
  assert(#view.history.entries==1, "duplicate thread was appended")
  picker.widgets.more.onclick()
  requests[3].callback({data={},nextCursor="last"})
  assert(picker.widgets.more.enabled, "empty page discarded its next cursor")
  picker.widgets.more.onclick()
  requests[4].callback({data={{id="thread-2",preview="preview",updatedAt="yesterday"}}})
  assert(#view.history.entries==2 and not picker.widgets.more.enabled)
  assert(view.history.entries[1].id=="thread-1")
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
  assert(#view.history.entries==1 and view.history.entries[1].id=="new-thread")
  first.widgets.done.onclick()
  dialogs[1].widgets.history.onclick()
  local reopened=dialogs[3]
  requests[1].callback({data={{id="late-thread",name="Late"}}})
  assert(#view.history.entries==0, "closed picker callback changed reopened picker")
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
  view.history.selected=1
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
  view.history.selected=1
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

test("history canvas displays bounded UTF-8 titles and distinct selectable rows",function()
  local opened
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="same-prefix-1",name=string.rep("界",50)},{id="same-prefix-2",name=string.rep("界",50)}}}); return true
  end,on_open_thread=function(id) opened=id; return true end})
  view:set_state("ready"); view:show_history()
  local picker=dialogs[2]
  gc.height=300
  local visible={}; function gc:fillText(text) visible[#visible+1]=text end
  picker.widgets.threads.onpaint {context=gc}
  assert(table.concat(visible):find("界",1,true) and utf8.len(table.concat(visible))<100, "history title was not bounded")
  picker.widgets.threads.onmousedown {button=MouseButton.LEFT,x=20,y=8+view.history.row_height+12}
  assert(view.history.selected==2)
  picker.widgets.threads.onkeydown {code="Enter",stopPropagation=function() end}
  assert(opened=="same-prefix-2" and not view.history_dialog, "keyboard did not open selected row")
  view:close()
end)

test("history keyboard pages independently, single click selects, and busy double click cannot open",function()
  local opened
  local entries={}
  for i=1,20 do entries[i]={id="thread-"..i,name="Conversation "..i,status=i==1 and "active" or "idle"} end
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback) callback({data=entries}); return true end,
    on_open_thread=function(id) opened=id; return true end})
  view:set_state("ready"); view:show_history(); gc.height=180
  local picker=dialogs[2]; local canvas=picker.widgets.threads
  local function key(code) canvas.onkeydown {code=code,stopPropagation=function() end} end
  canvas.onpaint {context=gc}; key("End")
  assert(view.history.selected==20 and view.history.scroll.offset>0 and view.scroll.offset==0)
  key("PageUp"); assert(view.history.selected<20)
  key("Home"); canvas.onpaint {context=gc}
  canvas.ondblclick {button=MouseButton.LEFT,x=20,y=12}
  assert(not opened and view.history_dialog, "busy conversation was opened")
  local y=8+view.history.row_height+10-view.history.scroll.offset
  canvas.onmousedown {button=MouseButton.LEFT,x=20,y=y}
  assert(view.history.selected==2 and not opened, "single click opened a conversation")
  view:set_state("working"); canvas.ondblclick {button=MouseButton.LEFT,x=20,y=y}
  assert(not opened, "double click opened during generation")
  view:set_state("ready"); canvas.ondblclick {button=MouseButton.LEFT,x=20,y=y}
  assert(opened=="thread-2" and not view.history_dialog)
  view:close()
end)

test("history refresh starts at top and loading more preserves manual reading position",function()
  local requests={}
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback) requests[#requests+1]=callback; return true end})
  view:set_state("ready"); view:show_history(); gc.height=200
  local picker=dialogs[2]; local canvas=picker.widgets.threads
  local rows={}; for i=1,20 do rows[i]={id="thread-"..i,name="Title "..i} end
  requests[1]({data=rows,nextCursor="next"}); canvas.onpaint {context=gc}
  canvas.onwheel {deltaY=10000}; canvas.onpaint {context=gc}
  assert(not view.history.scroll.follow, "manual history scrolling enabled transcript follow mode")
  local bottom=view.history.scroll.offset
  picker.widgets.more.onclick()
  local more={}; for i=21,40 do more[#more+1]={id="thread-"..i,name="Title "..i} end
  requests[2]({data=more}); canvas.onpaint {context=gc}
  assert(view.history.scroll.offset==bottom, "pagination skipped directly to the new bottom")
  canvas.onwheel {deltaY=10000}; picker.widgets.refresh.onclick()
  requests[3]({data=rows}); canvas.onpaint {context=gc}
  assert(view.history.selected==1 and view.history.scroll.offset==0, "refresh hid the selected first result")
  view:close()
end)

test("collapsed tools use one compact line and history uses two dense nonoverlapping lines",function()
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="a",name="魔法书",preview="Preview",updatedAt=1700000000}}}); return true
  end})
  function gc:measureText(text) return {width=utf8.len(text)*6,height=text:find("魔",1,true) and 22 or 10} end
  gc.height=300
  view:add_message("tool","Tool","read_sprite · Succeeded\nResult:\nLong JSON",false)
  dialogs[1].widgets.transcript.onpaint {context=gc}
  assert(view.scroll.cards[1].height<=22, "collapsed tool has a large empty card")
  view:set_state("ready"); view:show_history()
  local positions={}; function gc:fillText(text,_,y) positions[#positions+1]={text=text,y=y,height=self:measureText(text).height} end
  dialogs[2].widgets.threads.onpaint {context=gc}
  assert(view.history.row_height<=2*26+12, "history still has three tall rows")
  local title,preview
  for _,line in ipairs(positions) do if line.text:find("魔",1,true) then title=line elseif line.text=="Preview" then preview=line end end
  assert(title and preview and preview.y>=title.y+title.height, "compact title overlaps its preview")
  view:close()
end)

test("history pagination with taller glyphs preserves the visible conversation anchor",function()
  local callbacks={}
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback) callbacks[#callbacks+1]=callback; return true end})
  function gc:measureText(text) return {width=utf8.len(text)*6,height=text:find("魔",1,true) and 22 or 10} end
  gc.height=200; view:set_state("ready"); view:show_history()
  local rows={}; for i=1,20 do rows[i]={id="old-"..i,name="Title "..i} end
  callbacks[1]({data=rows,nextCursor="next"})
  local canvas=dialogs[2].widgets.threads
  canvas.onpaint {context=gc}; canvas.onwheel {deltaY=10000}; canvas.onpaint {context=gc}
  local h=view.history
  local first=math.max(1,math.floor((h.scroll.offset-8)/h.row_height)+1)
  local id=h.entries[first].id
  local y=8+(first-1)*h.row_height-h.scroll.offset
  dialogs[2].widgets.more.onclick(); callbacks[2]({data={{id="new",name="魔法书"}}})
  canvas.onpaint {context=gc}
  local visible=math.max(1,math.floor((h.scroll.offset-8)/h.row_height)+1)
  assert(h.entries[visible].id==id and 8+(visible-1)*h.row_height-h.scroll.offset==y, "taller new rows moved the visible conversation")
  view:close()
end)

test("expanding activity keeps its header anchored and pauses automatic following",function()
  local view,dialogs,gc=native_view()
  local canvas=dialogs[1].widgets.transcript
  view:add_message("first","You",string.rep("before\n",20),false)
  view:add_message("tool","Tool","execute_lua · Succeeded\nLua:\n"..string.rep("code\n",40),false)
  view:add_message("last","Codex",string.rep("after\n",30),false)
  canvas.onpaint {context=gc}
  view.scroll.follow=false; view.scroll.offset=view.scroll.cards[2].top-20
  canvas.onpaint {context=gc}
  canvas.onmousedown {button=MouseButton.LEFT,x=20,y=25}
  canvas.onpaint {context=gc}
  assert(view.by_id.tool.expanded and not view.scroll.follow and view.scroll.cards[2].top-view.scroll.offset==20)
  canvas.onkeydown {code="Enter",stopPropagation=function() end}; canvas.onpaint {context=gc}
  assert(not view.by_id.tool.expanded and view.scroll.cards[2].top-view.scroll.offset==20)
  view:close()
end)

test("short history previews hide appended canvas metadata",function()
  local view,dialogs,gc=native_view({on_list_threads=function(_,_,callback)
    callback({data={{id="short-id",preview='hi\n\nCurrent Aseprite target:\n{"revision":123}',status="idle"}}}); return true
  end})
  view:set_state("ready"); view:show_history()
  local visible={}; function gc:fillText(text) visible[#visible+1]=text end
  dialogs[2].widgets.threads.onpaint {context=gc}
  local text=table.concat(visible)
  assert(text:find("hi",1,true) and not text:find("Current Aseprite",1,true), "history exposed internal canvas context")
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
  picker.widgets.threads.onkeydown {code="ArrowDown",stopPropagation=function() end}
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
  assert(old.closed and not view.history_dialog and not view.history)
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
  local settings=dialogs[1]
  assert(settings.widgets.auto_approve and settings.data.auto_approve=="Ask before edits",
    "automatic approval does not default off")
  assert(not settings.widgets.auto_approve.label, "approval row adds form label indentation")
  view:set_approval_mode(true)
  assert(settings.data.auto_approve=="Auto-approve edits" and dialogs[1].widgets.status.text:find("Auto%-approve: on"))
  settings.data.auto_approve="Auto-approve edits"; settings.widgets.auto_approve.onchange()
  assert(decisions[1]==true and settings.data.auto_approve=="Auto-approve edits",
    "rejected controller projection was not restored")
  view:set_state("working")
  assert(not settings.widgets.auto_approve.enabled)
  settings.data.auto_approve="Ask before edits"; settings.widgets.auto_approve.onchange()
  assert(#decisions==1, "disabled approval control still changed controller state")
  view:set_state("ready")
  settings.data.auto_approve="Ask before edits"; settings.widgets.auto_approve.onchange()
  assert(decisions[2]==false)
  view:set_approval_mode(false)
  assert(settings.data.auto_approve=="Ask before edits")
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
