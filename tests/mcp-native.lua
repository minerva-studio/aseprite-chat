-- Persistent batch document fixture. Stdin substitutes only the editor WebSocket
-- delivery; the production MCP controller, executor and native encoders run here.
local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
local native_dofile=dofile
local socket
local env=setmetatable({
  WebSocket=function(spec)
    socket={spec=spec}
    function socket:connect() spec.onreceive(WebSocketMessageType.OPEN) end
    function socket:close() end
    function socket:sendText(wire)
      io.stdout:write("NATIVE_MCP_RESULT "..wire.."\n"); io.stdout:flush(); return true
    end
    return socket
  end,
  dofile=function(path)
    if app.fs.fileName(path)=="launcher.lua" then return {new=function()
      return {cancel=function() end,ensure=function(_,callback) callback("ws://127.0.0.1:1/editor/fixture"); return true end}
    end} end
    return native_dofile(path)
  end
},{__index=_G})
local Mcp=assert(loadfile(app.fs.joinPath(root,"mcp.lua"),"t",env))()
local sprite=Sprite(4,4)
local originalName=sprite.layers[1].name
local image=Image(4,4,ColorMode.RGB); image:drawPixel(1,1,app.pixelColor.rgba(219,47,91,128))
sprite:newCel(sprite.layers[1],1,image)
sprite:newEmptyFrame()
local second=Image(4,4,ColorMode.RGB); second:clear(app.pixelColor.rgba(13,97,251,255))
sprite:newCel(sprite.layers[1],2,second); app.frame=1
local sourcePixel=sprite.layers[1]:cel(1).image:getPixel(1,1)
local steps,filename,dirty=sprite.undoHistory.undoSteps,sprite.filename,sprite.isModified
local m=Mcp.new{path=root,preferences={}}
-- Explicit fixture decision; no GUI is opened and production always asks the user.
function m.approval:request_approval(_,decision) decision(true) end
assert(m:start("C:\\native-fixture",false))
io.stdout:write("NATIVE_MCP_READY\n"); io.stdout:flush()
for line in io.stdin:lines() do
  local packet=json.decode(line)
  if packet.type=="fixture_shutdown" then break end
  socket.spec.onreceive(WebSocketMessageType.TEXT,line)
end
m:close()
assert(sprite.layers[1].name=="MCP Native","MCP edit never reached native document")
assert(sprite.undoHistory.undoSteps==steps+1,"MCP edit did not create one transaction")
assert(sprite.filename==filename and sprite.isModified==dirty,"export changed source save state")
app.command.Undo()
assert(sprite.layers[1].name==originalName and sprite.layers[1]:cel(1).image:getPixel(1,1)==sourcePixel)
sprite:close()
print("native-mcp: passed; one Undo restored source")
