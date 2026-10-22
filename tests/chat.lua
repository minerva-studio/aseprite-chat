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
print("chat: " .. passed .. " passed")
