-- Authenticated integration in an isolated test profile and disposable sprite.
-- The test profile grants only this driver and its production modules native IO.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local Main=dofile(app.fs.joinPath(root,"main.lua"))
local controller=Main.create {path=root,preferences={}}
local sprite=Sprite(8,8)
local before=sprite.cels[1].image:getPixel(1,1)
local green=app.pixelColor.rgba(0,255,0,255)
local timer,finished,running,thread
-- A previous successful edit can be reused while debugging metadata/recovery.
local restoring=app.params["thread"]
if restoring and restoring~="" then thread=restoring else restoring=nil end
local phase,began="ready",os.time()
local saw_history=false
controller:open()
controller.view.dialog:modify {title="LIVE TEST · Disposable sprite, history and auto approval"}
local function finish(ok,reason)
  if finished then return end
  finished=true
  if timer then timer:stop() end
  local tools,summaries=0,0
  for _,message in ipairs(controller.view.messages) do
    if message.role=="Tool" then tools=tools+1 end
    if message.role=="Summary" and message.text~="" then summaries=summaries+1 end
  end
  local file=assert(io.open(app.fs.joinPath(root,"work","history-live-result.json"),"wb"))
  file:write(json.encode({success=ok,reason=tostring(reason),thread=thread,phase=phase,
    tools=tools,summaries=summaries,listed=saw_history,messages=controller.view.messages}))
  file:close()
  controller:close(); sprite:close(); app.exit()
end
timer=Timer {interval=0.1,ontick=function()
  if finished or running then return end
  running=true
  local ok,err=xpcall(function()
    assert(os.time()-began<240,"live history test timed out in " .. phase)
    for _,message in ipairs(controller.view.messages) do assert(message.role~="Error",message.text) end
    assert(not controller.pending and not controller.view.approval,"automatic edit displayed an approval dialog")
    if controller.client.state~="ready" then return end
    if phase=="ready" and controller.view.selection_valid then
      if restoring then phase="first"; return end
      assert(controller:select_settings("gpt-6.1-sol","medium"))
      assert(not controller.auto_approve); assert(controller:set_approval_mode(true))
      assert(controller:send("Remember the word opal. Use read_sprite to inspect this unsaved 8x8 sprite. Then use execute_lua to set pixel (1,1) in sprite.cels[1] to RGBA(0,255,0,255), cloning its image and assigning the clone back. Do not save or open documents. After success, reply with opal and a short confirmation."))
      phase="first"
    elseif phase=="first" then
      if not restoring then
        thread=assert(controller.client.thread_id)
        assert(sprite.cels[1].image:getPixel(1,1)==green,"automatic edit did not change the live pixel")
        app.command.Undo(); assert(sprite.cels[1].image:getPixel(1,1)==before,"single Undo failed")
      end
      phase="listing"
      assert(controller.client:list_threads({},function(page,why)
        local valid,problem=xpcall(function()
          assert(page,why)
          for _,entry in ipairs(page.data) do if entry.id==thread then saw_history=true end end
          assert(saw_history,"new Aseprite conversation missing from real history")
          controller:new_chat(); assert(not controller.auto_approve and not controller.client.thread_id)
          phase="opening"
          assert(controller:open_thread(thread))
        end,debug.traceback)
        if not valid then finish(false,problem) end
      end))
    elseif phase=="opening" then
      assert(controller.client.thread_id==thread and not controller.auto_approve)
      assert(sprite.cels[1].image:getPixel(1,1)==before,"opening history replayed an edit")
      local historical_tools=0
      for _,message in ipairs(controller.view.messages) do if message.role=="Tool" then historical_tools=historical_tools+1 end end
      assert(historical_tools>=2,"restored history omitted tool activity")
      assert(controller:select_settings("gpt-6.1-sol","low"))
      assert(controller:send("What word did I ask you to remember? Call read_sprite to inspect the current sprite without editing it, then reply with that word only."))
      phase="second"
    elseif phase=="second" then
      local reply
      for _,message in ipairs(controller.view.messages) do if message.role=="Codex" then reply=message.text end end
      assert(reply and reply:lower():find("opal",1,true),"reopened conversation lost context")
      assert(sprite.cels[1].image:getPixel(1,1)==before and not sprite.hasAssociatedFile)
      finish(true,restoring and "fresh process restored persisted context/tools without history replay"
        or "real persisted list/open/context, tool history, automatic edit, one Undo and no history replay")
    end
  end,debug.traceback)
  running=false
  if not ok then finish(false,err) end
end}
timer:start()
