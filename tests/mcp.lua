local root=app.fs.filePath(app.fs.filePath(debug.getinfo(1,"S").source:sub(2)))
assert(app.fs.isFile(app.fs.joinPath(root,"mcp.lua")),"MCP native controller is not implemented")
local passed=0
local function scenario(name,body)
  local h={sockets={},launchers={},dialogs={},timers={},owned={}}
  local real_dofile=dofile
  local env=setmetatable({
    -- Registration scenarios retain the Windows contract; POSIX is tested in linux.lua.
    package={config="\\"},
    Timer=function(spec)
      local timer={spec=spec,running=false}; function timer:start() self.running=true end; function timer:stop() self.running=false end
      h.timers[#h.timers+1]=timer; return timer
    end,
    WebSocket=function(spec)
      local socket={spec=spec,sent={}}
      function socket:connect() end
      function socket:close() self.closed=true end
      function socket:sendText(text) self.sent[#self.sent+1]=json.decode(text); return true end
      h.sockets[#h.sockets+1]=socket; return socket
    end,
    Dialog=function(spec)
      local dialog={spec=spec,data={},widgets={},bounds=Rectangle(0,0,500,250)}
      setmetatable(dialog,{__index=function(_,method) return function(self,widget)
        if method=="close" then self.closed=true; if spec.onclose then spec.onclose() end
        elseif method=="show" then self.shown=true
        elseif widget and widget.id then
          if method=="modify" then for key,value in pairs(widget) do self.widgets[widget.id][key]=value end
          else self.widgets[widget.id]=widget; self.data[widget.id]=widget.text end
        end
        return self
      end end})
      h.dialogs[#h.dialogs+1]=dialog; return dialog
    end,
    dofile=function(path)
      local name=app.fs.fileName(path)
      if name=="launcher.lua" then return {new=function(options)
        local launcher={options=options}
        function launcher:ensure(callback) self.callback=callback; self.pending=true; return true end
        function launcher:cancel() self.pending=nil end
        h.launchers[#h.launchers+1]=launcher; return launcher
      end} end
      if name=="account.lua" then return {path=function() return "fixture" end,
        load=function() return {mode="custom",codexHome="C:\\selected-home"} end,
        default_home=function() return "C:\\default-home" end} end
      if name=="chat.lua" then return {new=function()
        local view={}; h.approval=view
        function view:request_approval(args,callback) self.args,self.callback=args,callback end
        function view:dismiss_approval() self.dismissed=true end
        return view
      end} end
      return real_dofile(path)
    end
  },{__index=_G})
  local Mcp=assert(loadfile(app.fs.joinPath(root,"mcp.lua"),"t",env))()
  local m=Mcp.new{path=root,preferences={}}
  function h:connect(register)
    assert(m:start("C:\\selected-home",register==true))
    local launcher=self.launchers[#self.launchers]
    launcher.pending=nil; launcher.callback("ws://127.0.0.1:45123/editor/fixture-token")
    self.socket=self.sockets[#self.sockets]
    self.socket.spec.onreceive(WebSocketMessageType.OPEN)
  end
  function h:packet(packet)
    self.socket.spec.onreceive(WebSocketMessageType.TEXT,json.encode(packet))
  end
  function h:call(id,tool,args,client)
    local packet=json.encode{type="call",id=id,clientId=client or "client-a",tool=tool}
    local encoded=args and next(args) and json.encode(args) or "{}"
    self.socket.spec.onreceive(WebSocketMessageType.TEXT,packet:sub(1,-2)..',"arguments":'..encoded..'}')
    return self.socket.sent[#self.socket.sent]
  end
  function h:sprite()
    local s=Sprite(4,4); self.owned[#self.owned+1]=s; return s
  end
  local ok,err=xpcall(function() body(m,h) end,debug.traceback)
  m:close()
  for _,s in ipairs(h.owned) do if s.isValid then s:close() end end
  assert(ok,name..": "..tostring(err)); passed=passed+1; print("PASS "..name)
end

scenario("panel uses the selected home and registration is explicit",function(m,h)
  m:show(); local dialog=h.dialogs[1]
  assert(dialog.data.home=="C:\\selected-home")
  assert(#h.launchers==0,"opening panel changed config")
  dialog.widgets.register.onclick()
  local options=h.launchers[1].options
  assert(options.script=="mcp-launch.ps1" and options.parameters.CodexHome=="C:\\selected-home")
  assert(options.parameters.ConnectOnly==false)
  m:disconnect(); h:connect(false)
  assert(h.launchers[#h.launchers].options.parameters.ConnectOnly)
end)
scenario("cancelled startup cannot attach a late socket",function(m,h)
  assert(m:start("C:\\selected-home",true)); local launcher=h.launchers[1]
  m:disconnect(); launcher.callback("ws://127.0.0.1:45123/editor/late")
  assert(#h.sockets==0)
end)
scenario("native reads return real previews and inspect the current context",function(m,h)
  local s=h:sprite(); h:connect()
  local reply=h:call("read","view_sprite")
  assert(reply.type=="result" and reply.id=="read" and reply.result.success)
  assert(reply.result.contentItems[2].type=="inputImage")
  assert(json.decode(reply.result.contentItems[1].text).spriteId==s.id)
  local other=h:sprite()
  reply=h:call("next","view_sprite")
  assert(json.decode(reply.result.contentItems[1].text).spriteId==other.id)
end)
scenario("external edits need inspection and explicit native approval",function(m,h)
  local s=h:sprite(); h:connect()
  local bad=h:call("no-read","execute_lua",{code="sprite.layers[1].name='bad'",summary="bad",expectedRevision=0})
  assert(not bad.result.success and not h.approval.callback)
  local read=h:call("read","view_sprite")
  local revision=json.decode(read.result.contentItems[1].text).revision
  h:call("edit","execute_lua",{code="sprite.layers[1].name='Approved'",summary="Rename layer",expectedRevision=revision})
  assert(h.approval.callback and s.layers[1].name~="Approved")
  local decide=h.approval.callback; decide(true); decide(true)
  assert(s.layers[1].name=="Approved")
  assert(h.socket.sent[#h.socket.sent].id=="edit" and h.socket.sent[#h.socket.sent].result.success)
  app.command.Undo(); assert(s.layers[1].name~="Approved")
end)
scenario("cancellation and stale approval never execute Lua",function(m,h)
  local s=h:sprite(); h:connect()
  local read=h:call("read","view_sprite")
  local revision=json.decode(read.result.contentItems[1].text).revision
  h:call("edit","execute_lua",{code="sprite.layers[1].name='bad'",summary="Rename",expectedRevision=revision})
  local decide=h.approval.callback
  h:packet{type="cancel",id="edit"}; decide(true)
  assert(s.layers[1].name~="bad" and not h.socket.sent[#h.socket.sent].result.success)
  read=h:call("read2","view_sprite"); revision=json.decode(read.result.contentItems[1].text).revision
  h:call("edit2","execute_lua",{code="sprite.layers[1].name='bad'",summary="Rename",expectedRevision=revision})
  s.layers[1].name="Manual"; h.approval.callback(true)
  assert(s.layers[1].name=="Manual" and not h.socket.sent[#h.socket.sent].result.success)
end)
scenario("client observations are isolated and exports end with their owner",function(m,h)
  h:sprite(); h:connect()
  h:call("a","view_sprite",{},"client-a")
  local reply=h:call("export","export_sprite",{},"client-a")
  local path=json.decode(reply.result.contentItems[1].text).files[1].path
  local b=h:call("b","execute_lua",{code="return 1",summary="Test",expectedRevision=1},"client-b")
  assert(not b.result.success,"one client's inspection authorized another")
  assert(app.fs.isFile(path))
  h:packet{type="client_closed",clientId="client-a"}
  assert(not app.fs.isFile(path))
end)
scenario("disconnect retires approval and all old socket callbacks",function(m,h)
  local s=h:sprite(); h:connect()
  local read=h:call("read","view_sprite")
  h:call("edit","execute_lua",{code="sprite.layers[1].name='bad'",summary="Rename",
    expectedRevision=json.decode(read.result.contentItems[1].text).revision})
  local decide,old=h.approval.callback,h.socket
  m:disconnect(); decide(true); old.spec.onreceive(WebSocketMessageType.OPEN)
  assert(s.layers[1].name~="bad" and old.closed)
end)
scenario("empty editor lists normally and document errors leave MCP online",function(m,h)
  assert(not app.sprite); h:connect()
  local listed=h:call("empty-list","list_sprites")
  assert(listed.result.success)
  local data=json.decode(listed.result.contentItems[1].text)
  assert(data.sprites.total==0 and #data.sprites.items==0)
  for _,tool in ipairs {"view_sprite","inspect_sprite","read_pixels","export_sprite","execute_lua"} do
    local args=tool=="read_pixels" and {x=0,y=0,width=1,height=1}
      or tool=="execute_lua" and {code="return 1",summary="No document",expectedRevision=0} or {}
    local reply=h:call(tool,tool,args)
    assert(not reply.result.success)
    assert(json.decode(reply.result.contentItems[1].text).error.code=="NO_OPEN_SPRITE")
    assert(not h.socket.closed)
  end
  local s=h:sprite()
  listed=h:call("now-open","list_sprites")
  assert(listed.result.success and json.decode(listed.result.contentItems[1].text).sprites.items[1].spriteId==s.id)
end)
print("mcp: "..passed.." passed")
