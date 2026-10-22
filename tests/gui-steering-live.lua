-- Real authenticated steering in a disposable editor/profile and unsaved sprite.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local Main=dofile(app.fs.joinPath(root,"main.lua"))
local controller=Main.create {path=root,preferences={manual_server=true,endpoint=assert(app.params.endpoint)}}
local sprite=Sprite(8,8)
local before=sprite.cels[1].image:getPixel(1,1)
local phase,began,finished,running="ready",os.time(),false,false
local thread,turn,late_approval,timer
controller:open()
controller.view.dialog:modify {title="LIVE TEST · Steering, disposable canvas"}
local function finish(success,reason)
  if finished then return end
  finished=true; timer:stop()
  local result={success=success,reason=tostring(reason),phase=phase,thread=thread,turn=turn,messages=controller.view.messages,
    pixelUnchanged=sprite.cels[1].image:getPixel(1,1)==before}
  local file=assert(io.open(app.fs.joinPath(root,"work","steering-live-result.json"),"wb"))
  file:write(json.encode(result)); file:close()
  controller:close(); sprite:close(); app.exit()
end
timer=Timer {interval=0.1,ontick=function()
  if finished or running then return end
  running=true
  local ok,err=xpcall(function()
    assert(os.time()-began<150,"live steering deadline in " .. phase)
    for _,message in ipairs(controller.view.messages) do assert(message.role~="Error",message.text) end
    if phase=="ready" and controller.client.state=="ready" and controller.models then
      assert(controller:select_settings("gpt-6.1-sol","low","default"))
      assert(controller:send("Call read_sprite, then request execute_lua to set pixel (1,1) to opaque green. Use a cloned cel image and assign it back. Wait for the tool result before answering."))
      phase="approval"
    elseif phase=="approval" and controller.pending then
      assert(controller.client:can_steer())
      thread,turn=controller.client.thread_id,controller.client.turn_id
      late_approval=controller.view.approval.finish
      assert(controller:send("Change of plan: cancel the green edit. Do not edit any pixels or retry execute_lua. Reply with only the word azure."))
      assert(not controller.pending and not controller.view.approval)
      late_approval(true)
      assert(sprite.cels[1].image:getPixel(1,1)==before,"old approval executed after steering")
      phase="finish"
    elseif phase=="finish" and controller.client.state=="ready" then
      assert(controller.client.thread_id==thread,"steering changed threads")
      assert(sprite.cels[1].image:getPixel(1,1)==before,"steering changed pixels")
      local users,answer=0
      for _,message in ipairs(controller.view.messages) do
        if message.role=="You" then users=users+1 elseif message.role=="Codex" then answer=message.text end
      end
      assert(users==2,"steering duplicated or lost the user echo")
      assert(answer and answer:lower():match("^%s*azure[%.。]?%s*$"),"model did not follow steering: " .. tostring(answer))
      finish(true,"Same live turn steered; old approval cancelled; pixel unchanged; answer azure")
    end
  end,debug.traceback)
  running=false
  if not ok then finish(false,err) end
end}
timer:start()
