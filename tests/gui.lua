-- Run only in a disposable editor instance; all approval decisions target its temporary sprite.
local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local mode = app.params.mode or "fixture"
local log = assert(io.open(app.fs.joinPath(root, "work", "gui-" .. mode .. ".txt"), "w"))
local function record(text) log:write(text .. "\n"); log:flush() end
local Main = dofile(app.fs.joinPath(root, "main.lua"))
local c = Main.create { path = root, preferences = {} }
local sprite = Sprite(8, 8)
local initial = sprite.cels[1].image:clone()
initial:drawPixel(0, 0, app.pixelColor.rgba(255, 0, 0, 255))
sprite.cels[1].image = initial
local before = sprite.cels[1].image:getPixel(1, 1)
local green = app.pixelColor.rgba(0, 255, 0, 255)
local steps = mode == "fixture" and { "accept", "reject", "stale", "stop", "stream-stop", "break", "post-reconnect" }
  or { "live-first", "live-second", "live-reconnect" }
local prompts = {
  ["live-first"] = "Remember the word cobalt. Call read_sprite to inspect my unsaved sprite. Tell me the color at the top left using the image. Then call execute_lua to set pixel (1,1) in sprite.cels[1] to RGBA(0,255,0,255), cloning the image and assigning the clone. Do not save the document. After the tool succeeds reply with cobalt and a short confirmation.",
  ["live-second"] = "What word did I ask you to remember? Reply with it. Call read_sprite again and use execute_lua to set pixel (1,1) green (0,255,0,255) using clone and assignment again. I undid your previous edit.",
  ["live-reconnect"] = "After reconnecting, recall the remembered word, then call read_sprite and execute_lua to set pixel (1,1) green (0,255,0,255) using clone/assignment. Do not save."
}
local index, phase, began, thread = 1, "ready", os.time(), nil
local approvals, reads, stream_items = 0, 0, {}
local needs_undo = false
local timer
local read_original = c.executor.read
function c.executor:read(args)
  reads = reads + 1
  return read_original(self, args)
end
local function finish(ok, reason)
  timer:stop()
  record((ok and "PASS " or "FAIL ") .. reason)
  for _, message in ipairs(c.view.messages) do record(message.role .. ": " .. message.text) end
  c:close()
  sprite:close()
  log:close()
  app.exit()
end
c:open()
c.view.dialog:modify { title = "AUTOMATED TEST · Aseprite Chat (" .. mode .. ")" }
c.view.dialog:modify { id = "endpoint", text = mode == "fixture" and "ws://127.0.0.1:4517" or "ws://127.0.0.1:4500" }
c:connect(mode == "fixture" and "ws://127.0.0.1:4517" or "ws://127.0.0.1:4500", "")
timer = Timer { interval = 0.1, ontick = function()
  local ok, err = xpcall(function()
    assert(os.time() - began < (mode == "fixture" and 100 or 240), "GUI test timed out in " .. phase .. " / " .. tostring(c.client.state))
    for _, message in ipairs(c.view.messages) do
      if message.role == "Error" then error(message.text) end
      if message.role == "Codex" and #message.text > 0 then stream_items[message.id] = true end
    end
    local step = steps[index]
    if not step then
      assert(reads >= (mode == "fixture" and 5 or 3), "document inspection was not invoked")
      assert(approvals >= (mode == "fixture" and 5 or 3), "Lua tools were not invoked")
      assert(next(stream_items), "no streamed response")
      assert(not sprite.hasAssociatedFile, "test sprite was saved")
      if mode ~= "fixture" then
        local text = ""
        for _, message in ipairs(c.view.messages) do if message.role == "Codex" then text = text .. message.text end end
        assert(text:lower():find("cobalt", 1, true), "conversation context not retained")
      end
      record("thread=" .. tostring(thread) .. " reads=" .. reads .. " approvals=" .. approvals)
      for _, message in ipairs(c.view.messages) do record(message.role .. ": " .. message.text) end
      c:close(); c:open(); assert(c.client.thread_id == nil, "reopened session retained thread")
      finish(true, mode == "fixture"
        and "native chat, streaming, live unsaved sprite, edits, Undo, rejection/stale/stop and abrupt reconnect"
        or "authenticated native chat, streaming, live unsaved sprite, edits, Undo and explicit reconnect")
      return
    end
    if phase == "ready" and c.client.state == "ready" then
      if mode ~= "fixture" and step == "live-reconnect" then
        c:disconnect(); c:connect("ws://127.0.0.1:4500", ""); phase = "reconnecting"; return
      end
      assert(c:send(prompts[step] or ("fixture-" .. step)))
      record("sent " .. step); phase = "working"
    elseif phase == "reconnecting" and c.client.state == "ready" then
      assert(c.client.thread_id == thread, "reconnect lost thread")
      assert(c:send(prompts[step])); record("sent " .. step); phase = "working"
    elseif phase == "working" then
      if c.client.thread_id then
        if thread then assert(c.client.thread_id == thread, "continuous chat changed thread") else thread = c.client.thread_id end
      end
      if c.pending then
        approvals = approvals + 1
        if step == "reject" then c.view.approval.finish(false)
        elseif step == "stale" then
          sprite.cels[1].image:drawPixel(2, 2, app.pixelColor.rgba(255, 0, 0, 255))
          c.view.approval.finish(true)
          assert(sprite.cels[1].image:getPixel(1, 1) == before, "stale edit executed")
        elseif step == "stop" then
          local late = c.view.approval.finish
          c:stop(); late(true)
          assert(sprite.cels[1].image:getPixel(1, 1) == before, "stopped edit executed")
        else
          c.view.approval.finish(true)
          assert(sprite.cels[1].image:getPixel(1, 1) == green, "approved pixel edit was not applied")
          needs_undo = true
        end
      elseif step == "stream-stop" and c.client.turn_id then c:stop() end
      if c.client.state == "ready" then
        if needs_undo then
          app.undo(); needs_undo = false
          assert(sprite.cels[1].image:getPixel(1, 1) == before, "single Undo did not restore pixel")
        end
        assert(sprite.cels[1].image:getPixel(1, 1) == before, "step left unexpected pixel")
        record("completed " .. step)
        index, phase = index + 1, "ready"
      end
    end
  end, debug.traceback)
  if not ok then finish(false, err) end
end }
timer:start()
