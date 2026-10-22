-- Run in a disposable editor against the actual bridge. No source document is opened.
local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local Main = dofile(app.fs.joinPath(root, "main.lua"))
local controller = Main.create {path=root, preferences={}}
local sprite = Sprite(8, 8)
local timer, thread, result_dialog
local phase, index, began = "ready", 1, os.time()
local models = {"gpt-6.1-sol", "gpt-6-luna"}
local results = {}
local prompts = {
  "Remember the word orchid. Reply with orchid. Do not call any tools; this is a model selection test.",
  "What word did I ask you to remember? Reply with that word only. Do not call tools."
}
controller:open()
controller.view.dialog:modify {title="AUTOMATED TEST · Model and reasoning selectors"}
local function finish(ok, reason)
  timer:stop()
  result_dialog = Dialog {title="AUTOMATED TEST RESULT"}
  local result = result_dialog
  result:label {text=(ok and "PASS " or "FAIL ") .. reason}
  for _, text in ipairs(results) do result:newrow(); result:label {text=text} end
  result:newrow(); result:label {text="Thread: " .. tostring(thread)}
  for _, message in ipairs(controller.view.messages) do
    if message.role=="Codex" or message.role=="Error" then result:newrow(); result:label {text=message.role .. ": " .. message.text} end
  end
  result:newrow(); result:button {text="Close test editor", onclick=function() result_dialog:close(); controller:close(); sprite:close(); app.exit() end}
  result:show {wait=false}
end
timer = Timer {interval=0.1, ontick=function()
  local ok, err = xpcall(function()
    assert(os.time()-began < 180, "model test timed out in " .. phase)
    for _, message in ipairs(controller.view.messages) do
      assert(message.role ~= "Error", message.text)
    end
    if phase == "ready" and controller.client.state == "ready" and controller.view.selection_valid then
      local selected
      for _, model in ipairs(controller.models) do if model.model == models[index] then selected=model end end
      assert(selected, "expected test model missing from catalog: " .. models[index])
      local effort = selected.supportedReasoningEfforts[1].reasoningEffort
      assert(controller:select_settings(selected.model, effort))
      assert(controller.view.dialog.data.model == selected.displayName .. " (" .. selected.model .. ")")
      assert(controller.view.dialog.data.effort == effort)
      results[#results+1]="Catalog: " .. #controller.models .. "; model: " .. selected.model .. "; reasoning: " .. effort
      assert(controller:send(prompts[index])); phase="working"
    elseif phase == "working" then
      if controller.client.thread_id then
        if thread then assert(thread==controller.client.thread_id, "model switch replaced thread")
        else thread=controller.client.thread_id end
      end
      assert(not controller.pending, "unexpected tool request")
      if controller.client.state == "ready" then
        if index == 1 then index,phase=2,"ready"
        else
          local reply
          for _, message in ipairs(controller.view.messages) do if message.role=="Codex" then reply=message.text end end
          assert(reply and reply:lower():find("orchid",1,true), "model switch lost conversation context")
          assert(not sprite.hasAssociatedFile, "test sprite was saved")
          finish(true, "actual catalog, native dropdowns, reasoning selection and same-thread Sol/Luna conversation")
        end
      end
    end
  end, debug.traceback)
  if not ok then finish(false, err) end
end}
timer:start()
