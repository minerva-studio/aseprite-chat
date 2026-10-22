-- Run only in a disposable editor. This driver uses no network or source sprite.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local Chat=dofile(app.fs.joinPath(root,"chat.lua"))
local view=Chat.new({}, {})
local metrics={}
local ok,err=xpcall(function()
  view:set_state("ready"); view:show_settings()
  local settings=view.settings_dialog
  view:set_state("working"); view:set_state("ready")
  local automatic=settings.bounds
  metrics[#metrics+1]="Auto: " .. automatic.width .. " x " .. automatic.height
  assert(automatic.height<=120, "automatic settings contain excessive blank height: " .. automatic.height)
  assert(automatic.width<=340, "automatic settings are too wide: " .. automatic.width)
  view:set_state("disconnected")
  settings:modify {id="manual",selected=true}
  view:set_state("disconnected")
  local manual=settings.bounds
  metrics[#metrics+1]="Manual: " .. manual.width .. " x " .. manual.height
  assert(manual.height<=140 and manual.width<=340, "manual settings are not compact")
  settings:modify {id="manual",selected=false}
  view:set_state("ready")
  local restored=settings.bounds
  assert(restored.height<=120 and restored.width<=340, "return to automatic mode retained empty space")
  settings:close(); assert(view.settings_dialog==nil)
  view:show_settings()
  assert(view.settings_dialog.bounds.height<=120, "reopened settings retained empty space")
end,debug.traceback)
if view.settings_dialog then view.settings_dialog:modify {title="LAYOUT TEST · Settings (no connection)"} end
local result=Dialog {title="AUTOMATED SETTINGS RESULT"}
result:label {text=ok and "PASS compact auto/manual/reopened settings" or "FAIL settings layout"}
for _,text in ipairs(metrics) do result:newrow(); result:label {text=text} end
if not ok then
  for line in tostring(err):gmatch("[^\n]+") do result:newrow(); result:label {text=line} end
end
result:newrow(); result:button {text="Close test editor",onclick=function() result:close(); view:close(); app.exit() end}
result:show {wait=false}
local bounds=result.bounds
result.bounds=Rectangle(8,8,bounds.width,bounds.height)
