local Mcp={}
local Session={}
Session.__index=Session

local function failure(message)
  return {success=false,contentItems={{type="inputText",text=tostring(message)}}}
end

--- One native control endpoint, independent of the internal chat/account lifecycle.
--- Each host client owns its Executor observation and temporary export artifacts.
function Mcp.new(options)
  local root=assert(options.path)
  local self=setmetatable({path=root,preferences=options.preferences or {},sessions={},state="Disconnected"},Session)
  self.Executor=dofile(app.fs.joinPath(root,"executor.lua"))
  self.Launcher=dofile(app.fs.joinPath(root,"launcher.lua"))
  self.Account=dofile(app.fs.joinPath(root,"account.lua"))
  self.approval=dofile(app.fs.joinPath(root,"chat.lua")).new({},self.preferences)
  return self
end

function Session:_status(state,detail)
  self.state,self.detail=state,detail or ""
  if self.dialog then
    self.dialog:modify{id="status",text=state}
    self.dialog:modify{id="detail",text=self.detail}
    local idle=not self.startup and not self.connection
    self.dialog:modify{id="home",enabled=idle}
    self.dialog:modify{id="register",enabled=idle}
    self.dialog:modify{id="connect",enabled=idle}
    self.dialog:modify{id="disconnect",enabled=not idle}
  end
end

-- Retired sessions remain the sole owners of failed deletions. Bounded retry
-- ticks never operate on live clients or introduce a second list of file paths.
function Session:_collect()
  if self.collecting then return end
  self.collecting=true
  local pending=false
  for id,session in pairs(self.sessions) do
    if session.retired and session.cleanup_attempts<3 then
      session.cleanup_attempts=session.cleanup_attempts+1
      local ok,errors=session.executor.exports:clear(session.cleanup_attempts>1)
      if ok then self.sessions[id]=nil
      else
        local message="导出临时文件清理失败：\n"..table.concat(errors,"\n")
        print("Aseprite MCP: "..message)
        if not self.closed then self:_status(self.state,message) end
        if session.cleanup_attempts<3 then pending=true end
      end
    end
  end
  self.collecting=false
  if pending and not self.cleanup_timer then
    local timer
    timer=Timer{interval=1.0,ontick=function()
      if self.cleanup_timer~=timer or self.collecting then return end
      self:_collect()
    end}
    self.cleanup_timer=timer; timer:start()
  elseif not pending and self.cleanup_timer then
    self.cleanup_timer:stop(); self.cleanup_timer=nil
  end
end

function Session:_retire(clientId)
  local session=self.sessions[clientId]
  if not session then return end
  session.retired=true; session.cleanup_attempts=0
  session.executor:dispose()
  self:_collect()
end

function Session:_send(connection,id,result)
  if self.connection~=connection or not connection.connected then return false end
  local ok,sent=pcall(function()
    return connection.socket:sendText(json.encode{type="result",id=id,result=result})
  end)
  if not ok or sent==false then
    self:disconnect()
    self:_status("Disconnected","工具可能已在本机完成，但结果未送达。请先检查画布，再重新连接。")
    return false
  end
  return true
end

function Session:_finish(active,result)
  if self.active~=active then return end
  self.active=nil
  self.approval:dismiss_approval()
  self:_status("Connected",self.notice)
  self:_send(active.connection,active.id,result)
end

function Session:_call(connection,packet)
  local id,clientId=packet.id,packet.clientId
  assert(type(id)=="string" and #id>0 and #id<=128 and type(clientId)=="string"
    and #clientId>0 and #clientId<=128,"Invalid MCP request identity")
  if self.active then self:_send(connection,id,failure("Another Aseprite operation is awaiting completion.")); return end
  local methods={list_sprites="list",view_sprite="view",inspect_sprite="inspect",read_pixels="read_pixels",
    switch_sprite="switch",export_sprite="export",execute_lua="execute"}
  local method=methods[packet.tool]
  if not method then self:_send(connection,id,failure("Unknown Aseprite tool.")); return end
  local args=packet.arguments
  if type(args)~="table" and type(args)~="userdata" then self:_send(connection,id,failure("Arguments must be an object.")); return end
  local session=self.sessions[clientId]
  if not session then session={executor=self.Executor.new()}; self.sessions[clientId]=session end
  if session.retired then self:_send(connection,id,failure("MCP client has disconnected.")); return end
  local executor=session.executor
  local active={id=id,clientId=clientId,connection=connection}
  self.active=active
  self:_status("Working: "..packet.tool,"Edits require approval in Aseprite.")
  if packet.tool~="execute_lua" then
    local ok,result=pcall(function()
      if not app.sprite then executor:dispose() end
      if packet.tool~="switch_sprite" and packet.tool~="list_sprites" and app.sprite then
        local current=executor.sprite and executor.sprite.isValid and executor.sprite==app.sprite
          and executor.frame==app.frame and executor.layer==app.layer
        if not executor.sprite or (args.spriteId==nil and not current) then
          executor:bind(app.sprite,app.frame,app.layer)
        end
      end
      return executor[method](executor,args)
    end)
    self:_finish(active,ok and result or failure(result))
    return
  end
  if not executor.sprite or not executor.sprite.isValid then
    if not app.sprite then
      self:_finish(active,failure(json.encode{error={code="NO_OPEN_SPRITE",message="请先打开一个 Aseprite 文档。"}}))
    else self:_finish(active,failure("Use view_sprite or inspect_sprite to inspect the current sprite before editing.")) end
    return
  end
  if type(args.code)~="string" or #args.code>65536 or type(args.summary)~="string" or #args.summary>1000 then
    self:_finish(active,failure("A short Lua code and summary are required.")); return
  end
  local valid,why=executor:check(args.expectedRevision)
  if not valid then self:_finish(active,failure(why)); return end
  self:_status("Awaiting approval",args.summary)
  self.approval:request_approval({title="Aseprite MCP · Approve edit",summary=args.summary,code=args.code},function(accepted)
    if self.active~=active or self.connection~=connection or not connection.connected or session.retired then return end
    if not accepted then self:_finish(active,failure("User rejected the edit.")); return end
    local ok,result=pcall(function()
      local current,reason=executor:check(args.expectedRevision)
      if not current then return failure(reason) end
      return executor:execute(args)
    end)
    self:_finish(active,ok and result or failure(result))
  end)
end

function Session:_receive(connection,wire)
  assert(type(wire)=="string" and #wire<=16*1024*1024,"Invalid MCP message")
  local packet=json.decode(wire)
  if packet.type=="call" then self:_call(connection,packet)
  elseif packet.type=="cancel" then
    if self.active and self.active.id==packet.id then self:_finish(self.active,failure("MCP request cancelled.")) end
  elseif packet.type=="client_closed" then
    if self.active and self.active.clientId==packet.clientId then self:_finish(self.active,failure("MCP client disconnected.")) end
    self:_retire(packet.clientId)
  else error("Unknown MCP bridge message") end
end

--- Start the async registration/connect bootstrap for an explicit absolute home.
--- register=false connects without touching config.toml; true uses Codex's CLI.
function Session:start(home,register)
  if self.startup or self.connection then return false,"请先断开当前 MCP 连接。" end
  if type(home)~="string" then return false,"请填写 Codex home。" end
  home=home:match("^%s*(.-)%s*$")
  if not home:match("^%a:[\\/]") and not home:match("^\\\\") then return false,"Codex home 必须是绝对路径。" end
  self.closed=false
  self.preferences.mcp_home=home
  local attempt={}
  self.startup=attempt
  attempt.launcher=self.Launcher.new{path=self.path,script="mcp-launch.ps1",
    parameters={CodexHome=home,ConnectOnly=not register}}
  self:_status(register and "Registering..." or "Connecting...","Connecting to the selected Codex home.")
  local started,why=pcall(function() return attempt.launcher:ensure(function(endpoint,err)
    if self.startup~=attempt then return end
    self.startup=nil
    if not endpoint then self:_status("Error",err or "无法启动 MCP 连接。"); return end
    self.notice=register and "Registered aseprite_chat. Restart Codex to load its tools."
      or "External Codex can use this editor. Edits require native approval."
    local connection={connected=false}
    self.connection=connection
    local ok,connect_error=pcall(function()
      connection.socket=WebSocket{url=endpoint,deflate=false,onreceive=function(kind,data,socket_error)
        if self.connection~=connection then
          if kind==WebSocketMessageType.OPEN and connection.socket then connection.socket:close() end
          return
        end
        if kind==WebSocketMessageType.OPEN then connection.connected=true; self:_status("Connected",self.notice)
        elseif kind==WebSocketMessageType.TEXT then
          local received,receive_error=pcall(self._receive,self,connection,data)
          if not received then
            print("Aseprite MCP diagnostic: "..tostring(receive_error))
            self:disconnect(); self:_status("Error","MCP 请求处理失败，连接已关闭。请重新连接。")
          end
        elseif kind==WebSocketMessageType.CLOSE or kind==WebSocketMessageType.ERROR then
          self:disconnect()
          self:_status("Disconnected","MCP 连接已断开，未执行的审批已取消。请点击 Connect 重连。")
          if socket_error then print("Aseprite MCP transport: "..tostring(socket_error)) end
        end
      end}
      connection.socket:connect()
    end)
    if not ok then
      print("Aseprite MCP connect: "..tostring(connect_error))
      self:disconnect(); self:_status("Error","无法建立 MCP 本地连接。请允许网络访问后重试。")
    end
  end) end)
  if not started then
    self:disconnect(); self:_status("Error","无法启动 MCP 配置程序："..tostring(why)); return false,why
  end
  return true
end

--- Retire callbacks before closing transport; never replay requests on reconnect.
function Session:disconnect()
  local startup=self.startup; self.startup=nil
  if startup then startup.launcher:cancel() end
  local connection=self.connection; self.connection=nil
  self.active=nil; self.approval:dismiss_approval()
  if connection and connection.socket then pcall(connection.socket.close,connection.socket) end
  for _,session in pairs(self.sessions) do
    session.retired=true; session.cleanup_attempts=0; session.executor:dispose()
  end
  self:_collect()
  self:_status("Disconnected","")
end

function Session:show()
  if self.dialog then return end
  self.closed=false
  local account=self.Account.load(self.Account.path()) or {}
  local home=self.preferences.mcp_home or (account.mode=="custom" and account.codexHome) or self.Account.default_home()
  local dialog
  dialog=Dialog{title="Aseprite MCP",autofit=Align.LEFT|Align.TOP,onclose=function()
    if self.dialog==dialog then self.dialog=nil; self:close() end
  end}
  self.dialog=dialog
  dialog:label{text="Connect external Codex to this running editor."}
  dialog:newrow()
  dialog:label{text="Target Codex home"}
  dialog:entry{id="home",text=home,hexpand=true}
  dialog:newrow(); dialog:label{id="status",text=self.state}
  dialog:newrow(); dialog:label{id="detail",text=self.detail or "Edits require approval in Aseprite."}
  dialog:newrow(); dialog:label{text="Register backs up config.toml and adds only aseprite_chat."}
  dialog:newrow()
  local function start(register)
    local ok,err=self:start(dialog.data.home,register)
    if not ok then self:_status(self.state,err) end
  end
  dialog:button{id="register",text="Register & connect",onclick=function() start(true) end}
  dialog:button{id="connect",text="Connect",onclick=function() start(false) end}
  dialog:button{id="disconnect",text="Disconnect",onclick=function() self:disconnect() end}
  dialog:show{wait=false}
  self:_status(self.state,self.detail)
end

function Session:close()
  self.closed=true
  self:disconnect()
  local dialog=self.dialog; self.dialog=nil
  if dialog then dialog:close() end
end

return Mcp
