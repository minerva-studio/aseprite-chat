-- Native UI integration in a disposable editor/profile. No network, model or sprite.
-- This test proxy captures callback specs while forwarding to real native Dialogs.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local native_dialog=Dialog
local surfaces,widgets={},{}
local environment=setmetatable({Dialog=function(spec)
  local native=native_dialog(spec)
  return setmetatable({}, {__index=function(self,key)
    if key=="data" or key=="bounds" then return native[key] end
    return function(_,...)
      local widget=select(1,...)
      if key=="canvas" then surfaces[widget.id]=widget end
      if key~="modify" and type(widget)=="table" and widget.id then widgets[widget.id]=widget end
      native[key](native,...)
      return self
    end
  end,__newindex=function(_,key,value) native[key]=value end})
end},{__index=_G})
local Chat=assert(loadfile(app.fs.joinPath(root,"chat.lua"),"t",environment))()
local view,opened
local models={{model="gpt-6.1-sol",displayName="GPT-6.1-Sol",defaultReasoningEffort="low",
  supportedReasoningEfforts={{reasoningEffort="low"},{reasoningEffort="high"}},serviceTiers={{id="priority",name="Fast"}}}}
view=Chat.new({
  on_list_threads=function(_,_,callback)
    local entries={}
    for i=1,30 do entries[i]={id="native-"..i,name=i==1 and "魔法书 · 调整封面高光" or "Canvas conversation "..i,
      preview=i==1 and "Remember the word opal. Use read_sprite to inspect this unsaved 8x8 canvas." or "Inspect layers and refine the current sprite.",updatedAt=os.time()-i*3600,status=i==2 and "active" or "idle"} end
    callback({data=entries}); return true
  end,
  on_open_thread=function(id) opened=id; return true end,
  on_approval_mode=function(enabled) view:set_approval_mode(enabled); return true end,
  on_settings=function(model,effort,tier) view:set_models(models,model,effort,tier); return true end,
  on_rename=function(name,callback) view:set_thread("fixture-thread",name); callback(true); return true end
},{})
view:show()
view.dialog:modify {title="UI TEST · Navigation and collapsed activity · no connection"}
view:set_models(models,"gpt-6.1-sol","low","default")
view:set_thread("fixture-thread",nil)
view:set_state("ready")
view.scroll.follow=false
view:add_message("user","You","检查这张画布，帮我调整封面的高光。",false)
view:add_message("tool","Tool",'read_sprite · Succeeded\nResult:\n{"width":32,"height":32,"layers":10,"revision":42}',false)
view:add_message("summary","Summary","先检查图层和当前像素，再决定修改范围。",false)
view:add_message("edit","Tool","execute_lua · Succeeded\nLua:\nlocal image = sprite.cels[1].image:clone()\n-- Fixture display only; never executed",false)
view:add_message("answer","Codex","opal。已将 (1,1) 设为不透明绿色，克隆图像并赋回成功；未保存或打开文档。置信度 100%。",false)
view:add_message("user2","You","What word did I ask you to remember? Call read_sprite to inspect the current sprite without editing it, then reply with that word only.",false)
view:add_message("answer2","Codex","我会先检查画布，再克隆首个 cel 的图像，将 (1,1) 设为不透明绿色并赋回；不会保存或打开文档。",false)
local phase,began,timer,finished,running=1,os.time()
local function finish(ok,err)
  finished=true; timer:stop()
  local file=assert(io.open(app.fs.joinPath(root,"work","navigation-ui-result.json"),"wb"))
  file:write(json.encode({success=ok,error=err,phase=phase,
    historyRowHeight=view.history and view.history.row_height,toolHeight=view.scroll.cards[2].height,mainWidth=view.dialog.bounds.width}))
  file:close()
  local result=native_dialog {title="AUTOMATED NAVIGATION UI RESULT"}
  result:label {text=ok and "PASS native cards, fold/Enter, list paging/open and cleanup" or "FAIL native navigation UI"}
  if not ok then for line in tostring(err):gmatch("[^\n]+") do result:newrow(); result:label {text=line} end end
  result:newrow(); result:button {text="Close test editor",onclick=function() result:close(); view:close(); app.exit() end}
  result:show {wait=false}
  local bounds=result.bounds; result.bounds=Rectangle(8,8,bounds.width,bounds.height)
end
timer=Timer {interval=0.1,ontick=function()
  if finished or running then return end
  running=true
  local ok,err=xpcall(function()
    assert(os.time()-began<15,"native paint did not complete")
    if phase==1 then
      if not view.scroll.cards then return end
      assert(#view.scroll.cards==7 and #view.scroll.cards[2].lines==0)
      surfaces.transcript.onmousedown {button=MouseButton.LEFT,x=20,y=view.scroll.cards[2].top-view.scroll.offset+8}
      phase=2
    elseif phase==2 then
      assert(view.by_id.tool.expanded)
      surfaces.transcript.onkeydown {code="Enter",stopPropagation=function() end}
      assert(not view.by_id.tool.expanded)
      assert(view.scroll.latest,"no transcript jump overlay")
      local jump=view.scroll.latest
      surfaces.transcript.onmousedown {button=MouseButton.LEFT,x=jump.x+2,y=jump.y+2}
      assert(view.scroll.follow)
      surfaces.transcript.onkeydown {code="Home",stopPropagation=function() end}
      view:show_history(); phase=3
    elseif phase==3 then
      if not view.history.row_height then return end
      assert(view.history_dialog.bounds.width<=560)
      surfaces.threads.onkeydown {code="End",stopPropagation=function() end}
      assert(view.history.selected==30 and view.history.scroll.offset>0)
      view:set_state("working")
      surfaces.threads.onkeydown {code="Enter",stopPropagation=function() end}
      assert(not opened)
      view:set_state("ready")
      surfaces.threads.onkeydown {code="Home",stopPropagation=function() end}
      surfaces.threads.ondblclick {button=MouseButton.LEFT,x=20,y=12}
      assert(opened=="native-1" and not view.history_dialog)
      view:show_history(); phase=4
    elseif phase==4 then
      view:set_state("working",true); assert(view.can_steer)
      view:set_state("steering",false); assert(not view.can_steer)
      view:set_state("ready")
      view:show_settings(); assert(view.settings_dialog.data.auto_approve==nil)
      assert(not view.dialog.data.auto_approve)
      widgets.auto_approve.onclick()
      assert(view.auto_approve and view.dialog.data.auto_approve)
      view:set_approval_mode(false); view.settings_dialog:close()
      widgets.speed.onclick()
      assert(view.selected_tier=="priority")
      view:show_rename(); view.rename_dialog:modify {id="name",text="魔法书 · 封面高光"}; widgets.save.onclick()
      assert(view.thread_name=="魔法书 · 封面高光" and not view.rename_dialog)
      local main=view.dialog.bounds
      view.dialog.bounds=Rectangle(8,50,main.width,main.height)
      local history=view.history_dialog.bounds
      view.history_dialog.bounds=Rectangle(20+main.width,50,history.width,history.height)
      view.history_dialog:modify {title="UI TEST · Searchable conversations · no connection"}
      finish(true)
    end
  end,debug.traceback)
  running=false
  if not ok then finish(false,err) end
end}
timer:start()
