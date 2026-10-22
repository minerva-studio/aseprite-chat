local Timeline={}

local function clipped(text,limit)
  text=type(text)=="string" and text or ""
  if #text<=limit then return text end
  return text:sub(1,(utf8.offset(text,0,limit+1) or 1)-1) .. "\n…"
end

local function listed(value)
  local items={}
  if type(value)=="table" or type(value)=="userdata" then
    for _,item in ipairs(value) do items[#items+1]=tostring(item) end
  end
  return table.concat(items,",")
end

local function rect(prefix,value)
  if (type(value)=="table" or type(value)=="userdata") and value.x then
    return prefix .. tostring(value.x) .. "," .. tostring(value.y)
      .. " " .. tostring(value.width) .. "x" .. tostring(value.height)
  end
end

--- Format one observed local or persisted tool call, omitting image payloads.
--- This is a display projection; status never grants execution permission.
function Timeline.tool(tool,args,status,result)
  args=(type(args)=="table" or type(args)=="userdata") and args or {}
  local parts={tostring(tool) .. " · " .. status}
  if type(args.summary)=="string" and args.summary~="" then parts[#parts+1]=clipped(args.summary,400) end
  if args.frame then parts[#parts+1]="Frame: " .. tostring(args.frame) end
  local labels={}
  if args.spriteId then labels[#labels+1]="sprite="..tostring(args.spriteId) end
  if args.tag then labels[#labels+1]="tag="..tostring(args.tag) end
  if args.frames then labels[#labels+1]="frames="..listed(args.frames) end
  if args.layers then labels[#labels+1]="layers="..listed(args.layers) end
  if args.layer then labels[#labels+1]="layer="..tostring(args.layer) end
  if args.region then labels[#labels+1]=rect("region=",args.region) end
  if args.grid then labels[#labels+1]="grid="..tostring(args.grid) end
  if tool=="read_pixels" and args.width then
    labels[#labels+1]="rect="..tostring(args.x)..","..tostring(args.y)
      .." "..tostring(args.width).."x"..tostring(args.height)
  end
  if #labels>0 then parts[#parts+1]="Args: "..table.concat(labels," · ") end
  if type(args.code)=="string" then parts[#parts+1]="Lua:\n" .. clipped(args.code,6000) end
  local output={}
  for _,item in ipairs(result and result.contentItems or {}) do
    if item.type=="inputText" and type(item.text)=="string" then output[#output+1]=item.text end
  end
  if #output>0 then parts[#parts+1]="Result:\n" .. clipped(table.concat(output,"\n"),1800) end
  return table.concat(parts,"\n")
end

--- Project supported protocol items into plain transcript roles/text.
--- Thoughts prefer supplied reasoning content, with a summary when content is absent.
function Timeline.item(item)
  if item.type=="agentMessage" then return "Codex",item.text end
  if item.type=="userMessage" then
    local text={}
    for _,part in ipairs(item.content or {}) do
      if part.type=="text" and type(part.text)=="string" then
        local marker=part.text:find("\n\nCurrent Aseprite target:\n",1,true)
        text[#text+1]=marker and part.text:sub(1,marker-1) or part.text
      elseif part.type=="image" or part.type=="localImage" then text[#text+1]="[Image]" end
    end
    return "You",table.concat(text,"\n")
  end
  if item.type=="reasoning" then
    for _,channel in ipairs {"content","summary"} do
      local parts={}
      for _,part in ipairs(item[channel] or {}) do if type(part)=="string" and part~="" then parts[#parts+1]=part end end
      if #parts>0 then return "Summary",table.concat(parts,"\n\n") end
    end
  elseif item.type=="plan" and type(item.text)=="string" and item.text~="" then return "Plan",item.text
  elseif item.type=="dynamicToolCall" then
    local status=({inProgress="Running",completed="Succeeded",failed="Failed"})[item.status] or tostring(item.status)
    if item.success==false then status="Failed" end
    return "Tool",Timeline.tool(item.tool,item.arguments,status,item)
  elseif item.type=="commandExecution" then
    return "Tool","commandExecution · " .. tostring(item.status) .. "\n" .. clipped(item.command,6000)
      .. "\n" .. clipped(item.aggregatedOutput,1800)
  elseif item.type=="imageView" then
    return "Tool","view_image\n" .. clipped(tostring(item.path),200)
  elseif item.type=="mcpToolCall" then
    return "Tool",tostring(item.server) .. "/" .. tostring(item.tool) .. " · " .. tostring(item.status)
  elseif item.type=="fileChange" then
    local changes={"fileChange · " .. tostring(item.status)}
    for _,change in ipairs(item.changes or {}) do changes[#changes+1]=tostring(change.path) end
    return "Tool",clipped(table.concat(changes,"\n"),1800)
  end
end

--- Derive chronological display rows from stored turns without applying edits.
function Timeline.history(turns)
  local rows={}
  for _,turn in ipairs(turns) do
    for _,item in ipairs(turn.items or {}) do
      local role,text=Timeline.item(item)
      if role and text and text~="" then
        local prefix=role=="Tool" and "tool:" or (role=="Summary" or role=="Plan") and "activity:" or ""
        rows[#rows+1]={id=prefix .. item.id,role=role,text=text}
      end
    end
  end
  return rows
end

return Timeline
