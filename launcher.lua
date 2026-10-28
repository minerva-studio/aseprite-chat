local Launcher = {}
local windows = package.config:sub(1, 1) == "\\"
local Instance = {}
Instance.__index = Instance

local function encoded_command(text)
  local bytes = {}
  for _, code in utf8.codes(text) do
    if code >= 0x10000 then
      local value = code - 0x10000
      local high, low = 0xD800 + (value >> 10), 0xDC00 + (value & 0x3FF)
      bytes[#bytes+1] = string.char(high & 255, high >> 8, low & 255, low >> 8)
    else
      bytes[#bytes+1] = string.char(code & 255, code >> 8)
    end
  end
  local raw, output = table.concat(bytes), {}
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for index=1,#raw,3 do
    local a, b, c = raw:byte(index, index+2)
    local value = (a << 16) | ((b or 0) << 8) | (c or 0)
    output[#output+1] = alphabet:sub((value >> 18)+1, (value >> 18)+1)
      .. alphabet:sub(((value >> 12) & 63)+1, ((value >> 12) & 63)+1)
      .. (b and alphabet:sub(((value >> 6) & 63)+1, ((value >> 6) & 63)+1) or "=")
      .. (c and alphabet:sub((value & 63)+1, (value & 63)+1) or "=")
  end
  return table.concat(output)
end

local function quote(text) return "'" .. text:gsub("'", "''") .. "'" end
local function shell_quote(text) return "'" .. text:gsub("'", "'\"'\"'") .. "'" end
local function close_probe(attempt)
  local probe=attempt.probe; attempt.probe=nil
  if probe and probe.socket then pcall(function() probe.socket:close() end) end
end

-- Construct a native bootstrap launcher for the extension directory `path`.
-- POSIX uses the same Node Chat/registration operations through private jobs.
-- timer_factory accepts a native Timer spec; execute has os.execute semantics.
-- pending is the current opaque attempt (or nil), never connection state.
-- script selects the MCP bootstrap; parameters carries named string/switch
-- arguments in encoded PowerShell on Windows and a JSON Node job on Linux.
-- Without script, Chat launches native Node without waiting for PowerShell.
-- node optionally supplies the native executable at the process-launch test seam.
-- accountFile supplies Chat's authoritative account path to its Node child.
-- socket_factory accepts a native WebSocket spec. A verified endpoint/PID is
-- cached only in this instance and revalidated asynchronously before warm reuse.
function Launcher.new(options)
  assert(type(options) == "table" and type(options.path) == "string", "Launcher requires an extension path")
  return setmetatable({_options=options}, Instance)
end

-- Accept one attempt while idle; repeated calls while pending are ignored.
-- callback(result, errorText) runs once; result is a Chat endpoint or true for MCP
-- registration. Exactly one argument is non-nil,
-- unless canceled. Retiring the attempt precedes callback invocation, so a
-- callback may immediately retry. Returns false only when already pending.
function Instance:ensure(callback)
  if self.pending then return false end
  assert(type(callback) == "function", "Launcher.ensure requires a callback")
  local attempt = {result_path=app.fs.joinPath(app.fs.tempPath, "aseprite-chat-" .. tostring(Uuid()) .. ".json"),
    ticks=0, started_at=os.time()}
  self.pending = attempt
  local cold_start
  local function finish(endpoint, error_text, pid)
    if self.pending ~= attempt then return end
    self.pending = nil
    close_probe(attempt)
    if not self._options.script then self.cached=endpoint and {endpoint=endpoint,pid=pid} or nil end
    if attempt.timer then pcall(function() attempt.timer:stop() end) end
    if attempt.command_path then pcall(os.remove, attempt.command_path) end
    if attempt.command_source_path then pcall(os.remove, attempt.command_source_path) end
    pcall(os.remove, attempt.result_path)
    if attempt.private_dir then pcall(app.fs.removeDirectory,attempt.private_dir) end
    callback(endpoint, error_text)
  end
  local function tick()
    if self.pending ~= attempt or attempt.polling or attempt.probe_starting or attempt.launching then return end
    if attempt.probe then
      attempt.probe_ticks=attempt.probe_ticks+1
      if attempt.probe_ticks>=10 or os.clock()-attempt.probe_started_at>=1 then cold_start() end
      return
    end
    -- Native file permission dialogs pump timers while io.open is suspended.
    attempt.polling = true
    attempt.ticks = attempt.ticks + 1
    local read_ok, raw = pcall(function()
      -- Aseprite checks io.open permission before testing file existence. Avoid
      -- requesting access on every tick while the background process starts.
      if not app.fs.isFile(attempt.result_path) then return nil end
      local file = assert(io.open(attempt.result_path, "rb"))
      local ok, contents, read_error = pcall(file.read, file, 65537)
      local close_ok, closed, close_error = pcall(file.close, file)
      if not ok then error(contents, 0) end
      if not contents and read_error then error(read_error, 0) end
      if not close_ok then error(closed, 0) end
      if not closed then error(close_error or "Cannot close startup result", 0) end
      return contents or ""
    end)
    attempt.polling = false
    if self.pending ~= attempt then return end
    if not read_ok then
      finish(nil, "无法读取自动启动结果。请在 Aseprite 安全提示中允许文件访问，然后重试。")
      return
    end
    if raw then
      if #raw > 65536 then
        finish(nil, "自动启动结果过大。请关闭聊天窗口后重新打开并重试。")
        return
      end
      local ok, result = pcall(json.decode, (raw:gsub("^\239\187\191", "")))
      -- A reader can observe a file while the bootstrap is still writing it.
      -- Incomplete JSON keeps polling, bounded by the same startup deadline.
      if ok then
        local container = type(result) == "table" or type(result) == "userdata"
        if self._options.script=="mcp-launch.ps1" and container and result.registered==true then
          finish(true,nil); return
        end
        local endpoint = container and result.endpoint
        local pattern = "^ws://127%.0%.0%.1:(%d+)$"
        local port = type(endpoint) == "string" and tonumber(endpoint:match(pattern))
        local pid=container and result.pid
        local identity=self._options.script or (type(pid)=="number" and pid>0 and pid%1==0 and pid<=4294967295)
        if not self._options.script and port and port >= 1 and port <= 65535 and identity then finish(endpoint, nil,pid)
        elseif container and type(result.error) == "string" and result.error ~= "" then
          finish(nil, result.error)
        else finish(nil, "自动启动返回了无效结果。请重新打开聊天窗口后重试。") end
        return
      end
    end
    if attempt.ticks >= 200 or os.time() - attempt.started_at >= 20 then
      finish(nil, "自动启动在 20 秒内未完成。请检查 Node.js、扩展依赖及文件和进程权限，重新打开窗口后重试。")
    end
  end
  local timer_ok, timer = pcall(self._options.timer_factory or Timer, {interval=0.1, ontick=tick})
  if not timer_ok then
    finish(nil, "无法创建自动启动计时器。请重新打开聊天窗口后重试。")
    return true
  end
  attempt.timer = timer
  cold_start=function()
  if self.pending~=attempt then return end
  attempt.launching=true
  pcall(function() timer:stop() end)
  close_probe(attempt); self.cached=nil
  attempt.ticks=0
  local script_path = self._options.script and app.fs.joinPath(self._options.path, "scripts", self._options.script)
  local parameters=""
  for name,value in pairs(self._options.parameters or {}) do
    assert(type(name)=="string" and name:match("^[%a][%w]*$"),"Invalid bootstrap parameter")
    assert(type(value)=="string" or type(value)=="boolean","Invalid bootstrap parameter value")
    if type(value)=="string" then parameters=parameters.." -"..name.." "..quote(value)
    elseif value then parameters=parameters.." -"..name end
  end
  local name = "aseprite-chat-" .. tostring(Uuid()) .. ".cmd"
  local source_name,source,command
  if not windows then
    local registration=self._options.script=="mcp-launch.ps1"
    if self._options.script and not registration then
      finish(nil,"不支持此 Linux 启动操作，请重新打开插件后重试。")
      return true
    end
    if registration and (not self._options.parameters or type(self._options.parameters.CodexHome)~="string") then
      finish(nil,"请填写要连接或注册的 Codex home 绝对路径。")
      return true
    end
    local node=self._options.node
    if not node then
      for directory in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        local candidate=app.fs.joinPath(directory,"node")
        if candidate:sub(1,1)=="/" and app.fs.isFile(candidate) then node=candidate; break end
      end
    end
    if type(node)~="string" or node:sub(1,1)~="/" or node:find('[\0\r\n]') or not node:match("/node$") then
      finish(nil,"未找到原生 Node.js。请安装 Node.js 24 或更新版本，并将 node 加入 Aseprite 的 PATH 后重试。")
      return true
    end
    -- /tmp can be shared between OS users. Establish an exclusive private
    -- directory before exposing the job/result names; never chmod/reuse an
    -- existing directory. Native process permission remains required here.
    local private_dir=app.fs.joinPath(app.fs.tempPath,"aseprite-chat-"..tostring(Uuid()))
    local made,status=pcall(self._options.execute or os.execute,"umask 077; mkdir -- "..shell_quote(private_dir))
    if not made or (status~=true and status~=0) then
      finish(nil,"无法创建私有临时目录。请允许 Aseprite 启动进程，并检查临时目录权限后重试。")
      return true
    end
    attempt.private_dir=private_dir
    if self.pending~=attempt then pcall(app.fs.removeDirectory,private_dir); return true end
    attempt.result_path=app.fs.joinPath(private_dir,"result.json")
    source_name=name:gsub("%.cmd$",".mjs")
    local job={extensionRoot=self._options.path,resultPath=attempt.result_path}
    if registration then
      job.home=self._options.parameters.CodexHome
    else
      job.accountFile=self._options.accountFile
    end
    local operation=registration and "registerMcp" or "startChat"
    local module=registration and "register-mcp.mjs" or "start-chat.mjs"
    source=[[import {pathToFileURL} from 'node:url';
import {writeFile,rename,unlink} from 'node:fs/promises';
const job=]]..json.encode(job)..[[;
try {
  if (Number(process.versions.node.split('.')[0])<24) throw Error('Unsupported Node');
  const {]]..operation..[[}=await import(pathToFileURL(job.extensionRoot+'/scripts/]]..module..[['));
  await ]]..operation..[[(job);
} catch {
  const temporary=job.resultPath+'.bootstrap.tmp';
  try {
    await writeFile(temporary,JSON.stringify({error:'无法运行本地连接。请确认 Node.js 24 或更新版本、插件依赖和进程权限。'}),{flag:'wx',mode:0o600});
    await rename(temporary,job.resultPath);
  } finally { await unlink(temporary).catch(()=>{}); }
} finally { await unlink(process.argv[1]).catch(()=>{}); }
]]
    command=shell_quote(node).." "..shell_quote(app.fs.joinPath(attempt.private_dir,source_name))
      .." </dev/null >/dev/null 2>&1 &"
  elseif not self._options.script then
    local node=self._options.node
    if not node then
      local candidates={}
      for directory in (os.getenv("PATH") or ""):gmatch("[^;]+") do
        directory=directory:gsub('^"',''):gsub('"$','')
        candidates[#candidates+1]=app.fs.joinPath(directory,"node.exe")
      end
      for _,variable in ipairs({"ProgramFiles","ProgramFiles(x86)","LOCALAPPDATA"}) do
        local directory=os.getenv(variable)
        if directory then
          candidates[#candidates+1]=app.fs.joinPath(directory,"nodejs","node.exe")
          if variable=="LOCALAPPDATA" then candidates[#candidates+1]=app.fs.joinPath(directory,"Programs","nodejs","node.exe") end
        end
      end
      for _,candidate in ipairs(candidates) do
        if candidate:match("^%a:[\\/]") and app.fs.isFile(candidate) then node=candidate; break end
      end
    end
    if type(node)~="string" or not node:match("^%a:[\\/]") or node:find('["\r\n]') or not node:lower():match("[\\/]node%.exe$") then
      finish(nil,"未找到原生 Node.js。请安装 Node.js 24 或更新版本后重试。")
      return true
    end
    source_name=name:gsub("%.cmd$",".mjs")
    local job=json.encode{extensionRoot=self._options.path,resultPath=attempt.result_path,accountFile=self._options.accountFile}
    source=[[import {pathToFileURL} from 'node:url';
import {writeFile,rename,unlink} from 'node:fs/promises';
const job=]]..job..[[;
try {
  const {startChat}=await import(pathToFileURL(job.extensionRoot+'/scripts/start-chat.mjs'));
  await startChat(job);
} catch {
  const temporary=job.resultPath+'.bootstrap.tmp';
  try {
    await writeFile(temporary,JSON.stringify({error:'无法运行后台连接程序。请重新安装插件并重试。'}));
    await rename(temporary,job.resultPath);
  } finally { await unlink(temporary).catch(()=>{}); }
} finally { await unlink(process.argv[1]).catch(()=>{}); }
]]
    -- Only the executable and owned ASCII entry name enter cmd. The installed
    -- path and result path remain JSON data; percent signs in an exe are literal.
    command='setlocal DisableDelayedExpansion\r\nchcp 65001 >nul\r\nstart "" /b "'..node:gsub("%%","%%%%")
      ..'" "%TEMP%\\'..source_name..'" >nul 2>&1'
  else
    local inner = "$ErrorActionPreference='Stop'; try { & ([scriptblock]::Create([IO.File]::ReadAllText("
      .. quote(script_path) .. "))) -ResultPath " .. quote(attempt.result_path)
      .. " -ExtensionRoot " .. quote(self._options.path)
      .. parameters
      .. " } catch { [IO.File]::WriteAllText(" .. quote(attempt.result_path)
      .. ",'{\"error\":\"无法读取或执行插件连接程序。请重新安装插件并重试。\"}',[Text.UTF8Encoding]::new($false)) }"
    -- Explicit bootstraps retain the existing hidden PowerShell mechanism.
    local outer = "$ErrorActionPreference='Stop'; try { Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe')"
      .. " -WindowStyle Hidden -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden',"
      .. "'-EncodedCommand','" .. encoded_command(inner) .. "') | Out-Null } catch { "
      .. "[IO.File]::WriteAllText(" .. quote(attempt.result_path)
      .. ",'{\"error\":\"无法启动后台连接进程。请允许 Aseprite 启动进程并重试。\"}',[Text.UTF8Encoding]::new($false)) }"
    source_name = name:gsub("%.cmd$", ".ps1")
    -- The short cmd line is independent of installed paths.
    command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "& ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $env:TEMP '
      .. quote(source_name) .. '))))"'
    source=outer
  end
  local written = pcall(function()
    local temporary = windows and assert(os.getenv("TEMP")) or attempt.private_dir
    attempt.command_source_path = app.fs.joinPath(temporary, source_name)
    local entries={{attempt.command_source_path,source}}
    if windows then
      attempt.command_path = app.fs.joinPath(temporary, name)
      entries[#entries+1]={attempt.command_path, "@echo off\r\n" .. command .. "\r\n"}
    end
    for _, entry in ipairs(entries) do
      local file = assert(io.open(entry[1], "wb"))
      local ok, result = pcall(file.write, file, entry[2])
      local closed, close_result = pcall(file.close, file)
      assert(ok and result and closed and close_result, "Cannot write startup command")
    end
  end)
  if not written then
    finish(nil, "无法写入临时启动程序。请允许 Aseprite 访问临时文件，然后重试。")
    return true
  end
  if self.pending ~= attempt then
    pcall(os.remove, attempt.command_path); pcall(os.remove, attempt.command_source_path)
    if attempt.private_dir then pcall(app.fs.removeDirectory,attempt.private_dir) end
    return true
  end
  local execute_ok, status = pcall(self._options.execute or os.execute, windows and '"%TEMP%\\' .. name .. '"' or command)
  pcall(os.remove, attempt.command_path)
  if windows and self._options.script then pcall(os.remove, attempt.command_source_path) end
  if self.pending ~= attempt then return true end
  if not execute_ok or (status ~= true and status ~= 0) then
    finish(nil, "无法启动本机连接。请在 Aseprite 的安全提示中允许脚本访问文件和启动进程，再点击重试。")
    return true
  end
  -- Initial native write/process permission decisions have no startup deadline.
  attempt.started_at = os.time()
  attempt.launching=nil
  local started = pcall(function() attempt.timer:start() end)
  if not started then finish(nil, "无法启动连接计时器。请重新打开聊天窗口后重试。") end
  end
  if not self._options.script and self.cached then
    local cached=self.cached
    local probe={}; attempt.probe=probe; attempt.probe_ticks=0; attempt.probe_starting=true
    local ok=pcall(function()
      probe.socket=(self._options.socket_factory or WebSocket){url=cached.endpoint.."/readyz",deflate=false,
        onreceive=function(kind,data)
          if self.pending~=attempt or attempt.probe~=probe then return end
          if kind==WebSocketMessageType.TEXT then
            local decoded,health=pcall(function()
              assert(type(data)=="string" and #data<=16384)
              return json.decode(data)
            end)
            local container=decoded and (type(health)=="table" or type(health)=="userdata")
            local port=tonumber(cached.endpoint:match(":(%d+)$"))
            if container and health.service=="aseprite-chat" and health.protocolVersion==4
                and health.pid==cached.pid and health.port==port and health.busy==false then
              finish(cached.endpoint,nil,cached.pid)
            else cold_start() end
          elseif kind==WebSocketMessageType.CLOSE or kind==WebSocketMessageType.ERROR then cold_start() end
        end}
      probe.socket:connect()
    end)
    attempt.probe_starting=false
    if self.pending==attempt then
      if not ok then cold_start()
      elseif attempt.probe==probe then
        attempt.probe_started_at=os.clock()
        local started=pcall(function() timer:start() end)
        if not started then finish(nil,"无法启动连接计时器。请重新打开聊天窗口后重试。") end
      end
    end
  else cold_start() end
  return true
end

-- Invalidate queued timer callbacks and suppress this attempt's notification.
-- A bootstrap already launched may finish independently; its bridge owns its
-- idle lifetime. Cancellation never kills an editor or an existing bridge.
function Instance:cancel()
  local attempt = self.pending
  self.pending = nil
  if not attempt then return end
  close_probe(attempt)
  if attempt.timer then pcall(function() attempt.timer:stop() end) end
  if attempt.command_path then pcall(os.remove, attempt.command_path) end
  if attempt.command_source_path then pcall(os.remove, attempt.command_source_path) end
  pcall(os.remove, attempt.result_path)
  if attempt.private_dir then pcall(app.fs.removeDirectory,attempt.private_dir) end
end

return Launcher
