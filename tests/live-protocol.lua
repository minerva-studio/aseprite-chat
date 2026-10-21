-- Real authenticated inference smoke test, separate from deterministic protocol tests.
local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local Codex = dofile(app.fs.joinPath(root, "codex.lua"))
local output = assert(io.open(app.fs.joinPath(root, "work", "live-protocol.txt"), "w"))
local texts, errors, sent, first_thread = {}, {}, 0, nil
local client = Codex.new {
  tools = {}, instructions = "Reply in plain text. Only answer the user's short memory test. Do not use any tools.",
  on_message = function(id, text, append) texts[id] = append and ((texts[id] or "") .. text) or text end,
  on_error = function(text) errors[#errors + 1] = text end
}
local began, timer = os.time()
local function finish(ok, why)
  timer:stop(); client:disconnect()
  output:write((ok and "PASS " or "FAIL ") .. why .. "\n")
  for _, text in pairs(texts) do output:write(text .. "\n") end
  for _, text in ipairs(errors) do output:write("ERROR " .. text .. "\n") end
  output:close(); app.exit()
end
client:connect("ws://127.0.0.1:4500")
timer = Timer { interval = 0.1, ontick = function()
  local ok, err = xpcall(function()
    assert(os.time() - began < 150, "live protocol timeout: " .. client.state)
    assert(#errors == 0, errors[1])
    if client.state ~= "ready" then return end
    if sent == 0 then
      assert(client:send("Remember the word cobalt for my next question. Reply with cobalt only.", "Memory test in Aseprite.")); sent = 1
    elseif sent == 1 then
      first_thread = client.thread_id
      assert(client:send("Which word did I ask you to remember? Reply with that word only.", "Same Aseprite conversation.")); sent = 2
    else
      assert(client.thread_id == first_thread, "thread changed")
      local count = 0
      for _, text in pairs(texts) do assert(text:lower():find("cobalt", 1, true), "memory reply incorrect: " .. text); count = count + 1 end
      assert(count >= 2, "missing responses")
      finish(true, "real Aseprite WebSocket, initialize, two model turns, retained context; thread=" .. first_thread)
    end
  end, debug.traceback)
  if not ok then finish(false, err) end
end }
timer:start()
