-- Deterministic native UI validation in an isolated disposable editor.
-- No service, account file, model request or source sprite is accessed.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local native_dialog=Dialog
local widgets={}
local environment=setmetatable({Dialog=function(spec)
  local native=native_dialog(spec)
  return setmetatable({}, {__index=function(_,key)
    if key=="data" or key=="bounds" then return native[key] end
    return function(self,widget,...)
      if type(widget)=="table" and widget.id then
        if key=="modify" then for field,value in pairs(widget) do widgets[widget.id][field]=value end
        else widgets[widget.id]=widget; widget.kind=key end
      end
      native[key](native,widget,...); return self
    end
  end,__newindex=function(_,key,value) native[key]=value end})
end},{__index=_G})
local Chat=assert(loadfile(app.fs.joinPath(root,"chat.lua"),"t",environment))()
local access={access="canvas",workspace="",reviewer="user"}
local models={
  {model="ds",displayName="DeepSeek-Flash",defaultReasoningEffort="high",supportedReasoningEfforts={{reasoningEffort="high"}}},
  {model="sol",displayName="GPT-6.1-Sol",defaultReasoningEffort="low",supportedReasoningEfforts={{reasoningEffort="low"}},serviceTiers={{id="priority",name="Fast"}}}
}
local view
view=Chat.new({
  on_settings=function(model,effort,tier) view:set_models(models,model,effort,tier); return true end,
  on_approval_mode=function(enabled) view:set_approval_mode(enabled); return true end,
  on_access_get=function() return access end,
  on_access_apply=function(draft)
    if draft.access=="workspace" and draft.workspace=="" then return false,"Choose a workspace folder." end
    access=draft; return true
  end,
  on_account_get=function() return {mode="default"} end
},{})
local variant=app.params.variant=="fast" and "fast" or "unsupported"
local report={variant=variant}
local ok,err=xpcall(function()
  view:show(); view:set_models(models,"ds","high","priority"); view:set_state("ready")
  assert(not view.controls.speed.visible and not view.controls.stop.visible and view.selection_valid)
  assert(widgets.model.kind=="combobox" and widgets.effort.kind=="combobox" and widgets.access.kind=="combobox")
  view.controls.auto_approve.onclick(); assert(view.auto_approve and view.controls.auto_approve.selected)
  view.controls.auto_approve.onclick(); assert(not view.auto_approve)
  view:show_access(); assert(view.access_dialog)
  view.access_dialog:modify {id="access_level",option="Workspace write"}; widgets.access_level.onchange()
  widgets.access_apply.onclick(); assert(view.access_dialog and widgets.access_error.visible)
  view.access_dialog:modify {id="access_workspace",text="D:\\Fixture workspace"}
  widgets.access_apply.onclick(); assert(not view.access_dialog and access.access=="workspace")
  view:show_access(); assert(view.access_dialog.data.access_level=="Workspace write")
  view.access_dialog:close()
  view:set_models(models,"sol","low","default"); assert(view.controls.speed.visible and not view.controls.speed.selected)
  view.controls.speed.onclick(); assert(view.selected_tier=="priority" and view.controls.speed.selected)
  view:set_state("working",true); assert(view.controls.stop.visible and view.controls.stop.enabled and not view.controls.speed.enabled)
  view:set_state("stopping"); assert(view.controls.stop.visible and not view.controls.stop.enabled)
  view:set_state("ready"); assert(not view.controls.stop.visible)
  view:show_settings(); assert(view.settings_dialog.data.access_level==nil)
  report.settingsWidth,report.settingsHeight=view.settings_dialog.bounds.width,view.settings_dialog.bounds.height
  view.settings_dialog:close()
  access={access="canvas",workspace="",reviewer="user"}
  if variant=="fast" then
    view:set_approval_mode(true); view:set_state("working",true)
  else
    view:set_models(models,"ds","high","default"); view:set_state("ready"); view:show_access()
  end
  view.dialog:modify {title="UI TEST · " .. variant .. " action bar · no connection"}
  local bounds=view.dialog.bounds
  view.dialog.bounds=Rectangle(8,42,bounds.width,bounds.height)
  assert(bounds.width<=560,"action bar made the chat too wide: " .. bounds.width)
  if view.access_dialog then
    local panel=view.access_dialog.bounds
    view.access_dialog.bounds=Rectangle(bounds.width+20,42,panel.width,panel.height)
  end
  local rects=assert(view.control_rects)
  assert(rects[1].id=="auto_approve" and not view.controls.send)
  assert(widgets.send.kind=="button" and widgets.send.focus==true)
  for i=2,#rects do assert(rects[i].x>=rects[i-1].x+rects[i-1].width,"controls overlap") end
  report.controls=rects
  report.mainWidth,report.mainHeight=bounds.width,bounds.height
  report.fastVisible,report.stopVisible=view.controls.speed.visible,view.controls.stop.visible
end,debug.traceback)
report.success=ok
if not ok then report.error=tostring(err) end
local file=assert(io.open(app.fs.joinPath(root,"work","actionbar-ui-"..variant..".json"),"wb"))
file:write(json.encode(report)); file:close()
local result=native_dialog {title="ACTION BAR UI RESULT"}
result:label {text=ok and "PASS native Fast/Stop/approval/access interactions" or "FAIL native action bar"}
if not ok then for line in tostring(err):gmatch("[^\n]+") do result:newrow(); result:label {text=line} end end
result:newrow(); result:button {text="Close test editor",onclick=function() view:close(); result:close(); app.exit() end}
result:show {wait=false}
local bounds=result.bounds; result.bounds=Rectangle(8,8,bounds.width,bounds.height)
