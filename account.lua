local Account = {}

-- Aseprite encodes nested JSON userdata as null and empty Lua tables as [].
-- Compose containers explicitly, retaining native JSON encoding for values.
local function encode(value)
  if type(value) == "userdata" then return json.encode(value) end
  if type(value) ~= "table" then
    local wrapped = json.encode({value})
    return wrapped:match("^%[%s*(.-)%s*%]$")
  end
  local parts = {}
  if #value > 0 then
    for i = 1, #value do parts[i] = encode(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    assert(type(key) == "string", "JSON object keys must be strings")
    parts[#parts + 1] = encode(key) .. ":" .. encode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Native decoded JSON containers must not escape into caller-owned state.
local function plain(value)
  if type(value) ~= "table" and type(value) ~= "userdata" then return value end
  local copy = {}
  -- Aseprite's JSON arrays support ipairs, but pairs yields no array entries.
  if encode(value):sub(1, 1) == "[" then
    for index, item in ipairs(value) do copy[index] = plain(item) end
  else
    for key, item in pairs(value) do copy[key] = plain(item) end
  end
  return copy
end

local function object(value)
  return (type(value) == "table" or type(value) == "userdata")
    and encode(value):sub(1, 1) == "{"
end

local function sequence(value)
  return (type(value) == "table" or type(value) == "userdata")
    and encode(value):sub(1, 1) == "["
end

local function absolute(path)
  return type(path) == "string"
    and (path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil or path:match("^/") ~= nil)
end

--- The account file lives beside the bridge's discovery metadata. The bridge
--- reads the same override so tests never touch the user's real file.
function Account.path()
  local override = os.getenv("ASEPRITE_CHAT_ACCOUNT_FILE")
  if override and override ~= "" then return override end
  return app.fs.joinPath(os.getenv("LOCALAPPDATA") or "", "AsepriteChat", "providers.json")
end

function Account.default_home()
  return app.fs.joinPath(os.getenv("LOCALAPPDATA") or "", "AsepriteChat", "codex-home")
end

local function defaults()
  return { version = 1, mode = "default", codexHome = Account.default_home(),
    baseUrl = "", apiKey = "", models = {} }
end

local invalid = "The account file is invalid; save the account settings again."

--- Read the stored account; a missing file is the default account. Returns the
--- account table plus, for an unreadable or invalid file, a short error text as
--- the second return value. app.fs.isFile precedes io.open so a missing file
--- never triggers a native file permission prompt.
function Account.load(path)
  local account = defaults()
  if not app.fs.isFile(path) then return account end
  local file = io.open(path, "rb")
  if not file then return account, invalid end
  local ok, raw = pcall(file.read, file, "*a")
  pcall(file.close, file)
  if not ok or type(raw) ~= "string" then return account, invalid end
  local decoded, parsed = pcall(json.decode, (raw:gsub("^\239\187\191", "")))
  if not decoded or not object(parsed) then return account, invalid end
  local value = plain(parsed)
  local function string_field(name)
    if value[name] == nil then return true end
    return type(value[name]) == "string"
  end
  -- Check the raw decoded container: plain() maps [] to an empty Lua table,
  -- which would be indistinguishable from an object here.
  local models_valid = true
  local models = {}
  if parsed.models ~= nil then
    if not sequence(parsed.models) then models_valid = false
    else
      for _, model in ipairs(parsed.models) do
        if type(model) ~= "string" then models_valid = false; break end
        models[#models + 1] = model
      end
    end
  end
  if value.version ~= 1 or not string_field("codexHome") or not string_field("baseUrl")
      or not string_field("apiKey") or not models_valid
      or (value.mode ~= "default" and value.mode ~= "custom") then
    return defaults(), invalid
  end
  account.mode = value.mode
  if value.codexHome ~= nil then account.codexHome = value.codexHome end
  if value.baseUrl ~= nil then account.baseUrl = value.baseUrl end
  if value.apiKey ~= nil then account.apiKey = value.apiKey end
  account.models = models
  local valid, reason = Account.validate(account)
  if not valid then return defaults(), invalid .. " " .. tostring(reason) end
  return account
end

--- Mirror the bridge's account rules so a rejected draft cannot close the
--- WebSocket later. Returns true or false plus a short reason.
function Account.validate(account)
  if type(account) ~= "table" then return false, "Invalid account settings." end
  if account.mode ~= "default" and account.mode ~= "custom" then
    return false, "Choose a valid account mode."
  end
  if not absolute(account.codexHome) then
    return false, "Codex home must be an absolute path."
  end
  if type(account.baseUrl) ~= "string"
      or (account.baseUrl ~= "" and not account.baseUrl:match("^https?://")) then
    return false, "Base URL must be empty or start with http:// or https://."
  end
  if type(account.apiKey) ~= "string" then return false, "Invalid API key." end
  if type(account.models) ~= "table" then return false, "Invalid model list." end
  for _, model in ipairs(account.models) do
    if type(model) ~= "string" or model:match("^%s*$") then
      return false, "Invalid model list."
    end
  end
  return true
end

--- Write the account file under its own directory, creating it when needed.
--- The API key stays inside this file only: never preferences, config or logs.
function Account.save(path, account)
  local ok, err = pcall(function()
    assert(app.fs.makeAllDirectories(app.fs.filePath(path)),
      "Cannot create the account directory.")
    local file = assert(io.open(path, "wb"))
    local record = {
      version = account.version or 1,
      mode = account.mode,
      codexHome = account.codexHome,
      baseUrl = account.baseUrl,
      apiKey = account.apiKey,
      models = #account.models > 0 and account.models or json.decode("[]")
    }
    local written, write_error = file:write(encode(record) .. "\n")
    local closed, close_error = file:close()
    assert(written and closed, write_error or close_error or "Cannot write the account file.")
  end)
  if ok then return true end
  return false, tostring(err)
end

--- Synthesize picker entries for a custom account's explicit model list, or nil
--- so the caller falls back to the server's own catalog.
function Account.catalog(account)
  if type(account) ~= "table" or account.mode ~= "custom"
      or type(account.models) ~= "table" or #account.models == 0 then return nil end
  local catalog = {}
  for index, name in ipairs(account.models) do
    catalog[index] = {
      model = name, displayName = name, isDefault = index == 1,
      defaultReasoningEffort = "medium",
      supportedReasoningEfforts = {
        { reasoningEffort = "low" },
        { reasoningEffort = "medium" },
        { reasoningEffort = "high" }
      },
      serviceTiers = {}
    }
  end
  return catalog
end

return Account
