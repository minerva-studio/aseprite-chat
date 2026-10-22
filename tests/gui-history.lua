-- Deterministic native UI test in a disposable editor/profile; no real connection.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local Chat=dofile(app.fs.joinPath(root,"chat.lua"))
local view,opened
view=Chat.new({
  on_list_threads=function(search,cursor,callback)
    callback({data={{id="native-one",name="Native history · 以前的画布",preview="Inspect layers",updatedAt=1700000000,status="idle"},
      {id="native-busy",name="Active in another editor",preview="Busy",status="active"}},nextCursor=nil})
    return true
  end,
  on_open_thread=function(id) opened=id; return true end,
  on_approval_mode=function(enabled) view:set_approval_mode(enabled); return true end
},{})
view:show()
view.dialog:modify {title="UI TEST · History and activity (no connection)"}
view:set_state("ready")
local ok,err=xpcall(function()
  view:show_history()
  assert(view.history_dialog and view.history_dialog.data.threads:find("Native history",1,true), "native history options were not populated")
  assert(view.history_dialog.bounds.width<=560,"native picker is too wide")
  view.history_dialog:close(); assert(not view.history_dialog)
  view:show_history(); view.history_dialog:close()
  view:show_settings(); assert(view.settings_dialog.data.auto_approve==false)
  view:set_approval_mode(true); assert(view.settings_dialog.data.auto_approve==true)
  assert(view.dialog.data.status:find("Auto-approve: on",1,true))
  view:set_approval_mode(false); view.settings_dialog:close()
  view:add_message("summary","Summary","Inspect the layers before editing.",false)
  view:add_message("tool","Tool","read_sprite · Succeeded\nFrame: 1",false)
  view:add_message("answer","Codex","UI fixture only: history, summaries and tools share the transcript.",false)
  view:show_history()
  view.history_dialog:modify {title="UI TEST · History picker (no connection)"}
end,debug.traceback)
local result=Dialog {title="AUTOMATED HISTORY UI RESULT"}
result:label {text=ok and "PASS native history, approval checkbox and activity" or "FAIL native history UI"}
if not ok then for line in tostring(err):gmatch("[^\n]+") do result:newrow(); result:label {text=line} end end
result:newrow(); result:button {text="Close test editor",onclick=function() result:close(); view:close(); app.exit() end}
result:show {wait=false}
local bounds=result.bounds; result.bounds=Rectangle(8,8,bounds.width,bounds.height)
