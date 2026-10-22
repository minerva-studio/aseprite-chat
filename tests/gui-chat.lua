local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local Chat = dofile(app.fs.joinPath(root, "chat.lua"))
local view, plain
local chosen_model, chosen_effort
view = Chat.new({on_settings=function(model, effort)
  chosen_model, chosen_effort = model, effort
  view:set_models(plain, model, effort)
end}, {})
view:show()
view:set_models({{model="native-model",displayName="Native model",isDefault=true,defaultReasoningEffort="high",
  supportedReasoningEfforts={{reasoningEffort="low"},{reasoningEffort="high"}}}},"native-model","high")
assert(view.dialog.data.model=="Native model (native-model)" and view.dialog.data.effort=="high")
view:set_models({{model="other-model",displayName="Other",defaultReasoningEffort="medium",
  supportedReasoningEfforts={{reasoningEffort="medium"}}}},"other-model","medium")
assert(view.dialog.data.model=="Other (other-model)" and view.dialog.data.effort=="medium")
plain={{model="plain",displayName="Plain",supportedReasoningEfforts={}}}
view:set_models(plain,"plain","high")
assert(not view.selection_valid and view.dialog.data.model=="Confirm model selection")
view.dialog:modify {id="model",option="Plain (plain)"}
assert(chosen_model=="plain" and chosen_effort==nil and view.selection_valid,
  "native model change could not explicitly clear stale reasoning")
view:add_message("user", "You", "让当前画布的高光暗一点。", false)
view:add_message("agent", "Codex", string.rep("Streaming plain text · 你好世界\n", 40), false)
view:set_state("working")
local timer
timer = Timer { interval = 0.5, ontick = function()
  timer:stop()
  local ok, err = xpcall(function()
    local called = 0
    view:request_approval({summary="Native approval test", code="return 'hello'"}, function(accepted)
      assert(accepted); called = called + 1
    end)
    view.approval.finish(true)
    assert(called == 1 and view.approval == nil)
    view:close()
    view:show()
    view:close()
  end, debug.traceback)
  view:show()
  view:clear()
  view:add_message("test-result", "Test", ok
    and "PASS native model/reasoning dropdown updates, explicit stale reasoning reset, canvas, approval, close/reopen"
    or ("FAIL " .. tostring(err)), false)
  view:set_state("ready")
  view.dialog:modify {title="AUTOMATED TEST RESULT · Native selectors"}
end }
timer:start()
