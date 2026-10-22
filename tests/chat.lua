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
    setmetatable(dialog,{__index=function(_,method)
      return function(self,widget)
        if method=="close" then self.closed=true; if self.spec.onclose then self.spec.onclose() end
        elseif widget and widget.id then
          if method=="modify" then
            for key,value in pairs(widget) do self.widgets[widget.id][key]=value end
          else self.widgets[widget.id]=widget; widget.kind=method end
          if widget.option or widget.text then self.data[widget.id]=widget.option or widget.text end
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
  local connected
  local view,dialogs=native_view({on_connect=function(endpoint) connected=endpoint end},{endpoint="ws://127.0.0.1:4500"})
  local main=dialogs[1]
  assert(not main.widgets.endpoint and not main.widgets.connect and not main.widgets.disconnect,
    "connection controls still occupy the chat")
  for _, button in ipairs(main.buttons) do assert(button.text~="Up" and button.text~="Down", "paging buttons remain") end
  main.widgets.settings.onclick()
  assert(#dialogs==2 and view.settings_dialog==dialogs[2])
  local settings=dialogs[2]
  assert(settings.data.endpoint=="ws://127.0.0.1:4500")
  view:set_state("working")
  assert(not settings.widgets.endpoint.enabled and not settings.widgets.connect.enabled and settings.widgets.disconnect.enabled)
  view:set_state("disconnected")
  assert(settings.widgets.endpoint.enabled and settings.widgets.connect.enabled)
  settings.data.endpoint="ws://127.0.0.1:4567"; settings.widgets.connect.onclick()
  assert(connected==settings.data.endpoint and view.preferences.endpoint=="ws://127.0.0.1:4500")
  view:close(); assert(settings.closed and view.settings_dialog==nil)
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
