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
assert(view.dialog.data.model=="Model: Native model" and view.dialog.data.effort=="Reasoning: high")
view:set_models({{model="other-model",displayName="Other",defaultReasoningEffort="medium",
  supportedReasoningEfforts={{reasoningEffort="medium"}}}},"other-model","medium")
assert(view.dialog.data.model=="Model: Other" and view.dialog.data.effort=="Reasoning: medium")
plain={{model="plain",displayName="Plain",supportedReasoningEfforts={}}}
view:set_models(plain,"plain","high")
assert(not view.selection_valid and view.dialog.data.model=="Model: Confirm model selection")
view.dialog:modify {id="model",option="Model: Plain"}
assert(chosen_model=="plain" and chosen_effort==nil and view.selection_valid,
  "native model change could not explicitly clear stale reasoning")
view:add_message("user", "You", "让当前画布的高光暗一点。", false)
view:add_message("agent", "Codex", string.rep("Streaming plain text · 你好世界\n", 40), false)
view:set_state("working")
local timer
timer = Timer { interval = 0.5, ontick = function()
  timer:stop()
  local ok, err = xpcall(function()
    assert(view.scroll.maximum > 0, "native canvas did not measure long transcript")
    assert(view.scroll.track and view.scroll.track.width >= 8, "native scrollbar has no usable hit area")
    view:show_settings()
    assert(view.settings_dialog and view.settings_dialog.data.endpoint=="ws://127.0.0.1:4500")
    local settings=view.settings_dialog
    settings:close()
    assert(view.settings_dialog==nil and view.dialog, "closing settings closed the chat")
    view:show_settings()
    local called = 0
    view:request_approval({summary="Native approval test", code=string.rep("local value=1\n",30)}, function(accepted)
      assert(accepted); called = called + 1
    end)
    local approval=view.approval.dialog
    local bounds=approval.bounds
    approval.bounds=Rectangle(bounds.x,bounds.y,bounds.width+80,bounds.height+100)
    approval:repaint()
    approval.bounds=bounds
    approval:repaint()
    view.approval.finish(true)
    assert(called == 1 and view.approval == nil)
    view:close()
    assert(view.settings_dialog==nil, "settings window survived chat close")
    view:show()
    view:close()
  end, debug.traceback)
  view:show()
  view:clear()
  view:add_message("long-result", "Codex", string.rep("Scrollable conversation history\n", 60), false)
  view:add_message("test-result", "Test", ok
    and "PASS native settings lifecycle, scrollbar layout, approval resize, model/reasoning, close/reopen"
    or ("FAIL " .. tostring(err)), false)
  view:set_state("ready")
  view.dialog:modify {title="AUTOMATED TEST RESULT · Native chat and settings"}
  view:show_settings()
end }
timer:start()
