-- Run only in a disposable editor; no existing source document is opened.
local root = assert(app.params.extension_root, "extension_root must point to the unpacked extension")
local Main = dofile(app.fs.joinPath(root, "main.lua"))
local controller = Main.create {path=root, preferences={}}
local sprite = Sprite(8, 8)
local timer, result_dialog, finished, running
local began = os.time()
controller:open()
controller.view.dialog:modify {title="AUTOMATED TEST · Automatic connection"}
local function finish(ok, text)
  if finished then return end
  finished = true
  timer:stop()
  result_dialog = Dialog {title="AUTOMATED TEST RESULT"}
  result_dialog:label {text=(ok and "PASS " or "FAIL ") .. text}
  result_dialog:newrow(); result_dialog:label {text="Catalog: " .. #(controller.models or {})}
  result_dialog:newrow(); result_dialog:button {text="Close test editor", onclick=function()
    result_dialog:close(); controller:close(); sprite:close(); app.exit()
  end}
  result_dialog:show {wait=false}
end
timer = Timer {interval=0.1, ontick=function()
  if finished or running then return end
  running = true
  local ok, err = xpcall(function()
    assert(os.time()-began < 90, "automatic GUI connection timed out")
    for _, message in ipairs(controller.view.messages) do assert(message.role ~= "Error", message.text) end
    if controller.client.state == "ready" and controller.view.selection_valid then
      assert(controller.preferences.manual_server == false, "manual server was enabled")
      assert(#controller.models > 0, "catalog missing")
      assert(not sprite.hasAssociatedFile, "disposable sprite was saved")
      finish(true, "automatic startup and native catalog; no address or terminal")
    end
  end, debug.traceback)
  running = false
  if not ok then finish(false, err) end
end}
timer:start()
