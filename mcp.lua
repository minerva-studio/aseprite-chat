local Mcp={}
local windows=package.config:sub(1,1)=="\\"
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
    local idle=not self.startup and not self.watch_timer
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
    self:_detach(); self.retry_ticks=2
    self:_status("Waiting for use","工具可能已完成，但结果未送达。请先检查画布；下一次调用会重新连接，不会重发本次操作。")
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

local function same_path(a,b)
  if type(a)~="string" or type(b)~="string" then return false end
  a,b=app.fs.normalizePath(a),app.fs.normalizePath(b)
  if windows then a,b=a:gsub("\\","/"):lower(),b:gsub("\\","/"):lower() end
  return a:gsub("/+$","")==b:gsub("/+$","")
end

-- Native normalizePath does not resolve directory links. Equal runtime bytes
-- permit an aliased/copy installation without trusting a different tool version.
local function same_runtime(a,b)
  if same_path(a,b) then return true end
  if type(a)~="string" then return false end
  for _,name in ipairs {"package.json","tools.json","mcp.lua","executor.lua","export.lua","chat.lua","timeline.lua"} do
    local function read(root)
      local file=assert(io.open(app.fs.joinPath(root,name),"rb"))
      local ok,text=pcall(file.read,file,524289)
      file:close()
      if not ok then error(text,0) end
      return text
    end
    local first,second=read(a),read(b)
    if not first or #first>524288 or first~=second then return false end
  end
  return true
end

-- Retire the native scope before closing transport; callbacks never replay work.
function Session:_detach()
  local connection=self.connection; self.connection=nil
  self.active=nil; self.approval:dismiss_approval()
  if connection and connection.socket then pcall(connection.socket.close,connection.socket) end
  for _,session in pairs(self.sessions) do
    session.retired=true; session.cleanup_attempts=0; session.executor:dispose()
  end
  self:_collect()
end

function Session:_attach(endpoint)
  local connection={connected=false,ticks=0,opening=true}
  self.connection=connection
  local ok,err=pcall(function()
    connection.socket=WebSocket{url=endpoint,deflate=false,onreceive=function(kind,data,socket_error)
      if self.connection~=connection then
        if kind==WebSocketMessageType.OPEN and connection.socket then connection.socket:close() end
        return
      end
      if kind==WebSocketMessageType.OPEN then
        connection.connected=true; self:_status("Connected",self.notice)
      elseif kind==WebSocketMessageType.TEXT then
        local received,receive_error=pcall(self._receive,self,connection,data)
        if not received then
          print("Aseprite MCP diagnostic: "..tostring(receive_error))
          self:_detach(); self.retry_ticks=10
          self:_status("Waiting for use","MCP 请求处理失败，已断开；等待下一次连接。")
        end
      elseif kind==WebSocketMessageType.CLOSE or kind==WebSocketMessageType.ERROR then
        self:_detach(); self.retry_ticks=2
        self:_status("Waiting for use",self.notice)
        if socket_error then print("Aseprite MCP transport: "..tostring(socket_error)) end
      end
    end}
    if self.connection~=connection then connection.socket:close(); return end
    connection.socket:connect()
  end)
  connection.opening=false
  if self.connection~=connection then return end
  if not ok then
    print("Aseprite MCP connect: "..tostring(err))
    self:_detach(); self.retry_ticks=10
    self:_status("Waiting for use","无法建立本地连接。请允许网络访问；稍后自动重试。")
  end
end

--- Enable process-free discovery for one absolute home. The client creates the
--- capability file only on a tool call. Registering writes config but no hub.
function Session:start(home,register)
  if self.startup or self.watch_timer then return false,"请先停用当前 MCP 连接。" end
  if type(home)~="string" then return false,"请填写 Codex home。" end
  home=home:match("^%s*(.-)%s*$")
  local absolute=windows and (home:match("^%a:[\\/]") or home:match("^\\\\"))
    or (not windows and home:match("^/"))
  if not absolute then return false,"Codex home 必须是绝对路径。" end
  self.closed=false
  local function watch()
    self.preferences.mcp_home=home; self.preferences.mcp_enabled=true
    self.notice="Starts on tool use. Edits require approval in Aseprite."
    self:_status("Waiting for use",self.notice)
    local descriptorPath=app.fs.joinPath(home,".aseprite-chat","mcp-bridge.json")
    local timer,polling
    timer=Timer{interval=0.5,ontick=function()
      if self.watch_timer~=timer or polling then return end
      if self.connection then
        if self.connection.connected or self.connection.opening then return end
        self.connection.ticks=self.connection.ticks+1
        if self.connection.ticks<20 then return end
        self:_detach(); self.retry_ticks=10
      end
      if (self.retry_ticks or 0)>0 then self.retry_ticks=self.retry_ticks-1; return end
      polling=true
      local ok,raw=pcall(function()
        if not app.fs.isFile(descriptorPath) then return nil end
        local file=assert(io.open(descriptorPath,"rb"))
        local read_ok,text=pcall(file.read,file,16385)
        file:close()
        if not read_ok then error(text,0) end
        return text
      end)
      polling=false
      if self.watch_timer~=timer then return end
      if not ok then
        self:disconnect()
        self:_status("Error","无法读取 MCP 发现文件。请允许文件访问后重新启用 MCP。")
        return
      end
      if not raw or #raw>16384 then return end
      local decoded,d=pcall(json.decode,raw)
      if not decoded or (type(d)~="table" and type(d)~="userdata") then return end
      local token=d.token
      if d.protocol~="aseprite-chat-mcp/2" or type(d.identity)~="string" or d.identity==""
        or type(token)~="string" or #token~=64 or token:find("[^a-f0-9]") then return end
      local port=type(d.endpoint)=="string" and tonumber(d.endpoint:match("^ws://127%.0%.0%.1:(%d+)/editor/"..token.."$"))
      if not port or port<1 or port>65535 then return end
      -- The descriptor's location establishes home ownership, including symlink
      -- aliases. Node independently validates canonical home/root before use.
      polling=true
      local checked,matching=pcall(same_runtime,d.extensionRoot,self.path)
      polling=false
      if self.watch_timer~=timer then return end
      if not checked or not matching then
        self:disconnect()
        self:_status("Error","MCP 服务与当前扩展版本不一致，或无法读取扩展。请允许文件访问并重启客户端后重新启用。")
        return
      end
      self:_attach(d.endpoint)
    end}
    self.watch_timer=timer; timer:start()
    self:_status("Waiting for use",self.notice)
  end
  if not register then watch(); return true end
  local attempt={}
  self.startup=attempt
  attempt.launcher=self.Launcher.new{path=self.path,script="mcp-launch.ps1",parameters={CodexHome=home}}
  self:_status("Registering...","Registering in the selected Codex home; no hub is started.")
  local started,why=pcall(function() return attempt.launcher:ensure(function(registered,err)
    if self.startup~=attempt then return end
    self.startup=nil
    if not registered then self:_status("Error",err or "无法注册 MCP。"); return end
    watch()
  end) end)
  if not started then
    self:disconnect(); self:_status("Error","无法启动 MCP 配置程序："..tostring(why)); return false,why
  end
  return true
end

--- Disable discovery and cancel approvals. preserve=true is reserved for plugin
--- shutdown, which must retain the user's enabled preference for the next launch.
function Session:disconnect(preserve)
  if not preserve then self.preferences.mcp_enabled=false end
  local startup=self.startup; self.startup=nil
  if startup then startup.launcher:cancel() end
  local timer=self.watch_timer; self.watch_timer=nil
  if timer then timer:stop() end
  self.retry_ticks=nil
  self:_detach()
  self:_status("Disabled","")
end

function Session:show()
  if self.dialog then return end
  self.closed=false
  local account=self.Account.load(self.Account.path()) or {}
  local home=self.preferences.mcp_home or (account.mode=="custom" and account.codexHome) or self.Account.default_home()
  local dialog
  dialog=Dialog{title="Aseprite MCP",autofit=Align.LEFT|Align.TOP,onclose=function()
    if self.dialog==dialog then self.dialog=nil end
  end}
  self.dialog=dialog
  dialog:label{text="Allow MCP clients to use this editor on demand."}
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
  dialog:button{id="register",text="Register & enable",onclick=function() start(true) end}
  dialog:button{id="connect",text="Enable",onclick=function() start(false) end}
  dialog:button{id="disconnect",text="Disable",onclick=function() self:disconnect() end}
  dialog:show{wait=false}
  self:_status(self.state,self.detail)
end

function Session:close()
  self.closed=true
  self:disconnect(true)
  local dialog=self.dialog; self.dialog=nil
  if dialog then dialog:close() end
end

return Mcp
