local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local path = app.fs.joinPath(root, "account.lua")
assert(app.fs.isFile(path), "account module is not implemented")
local Account = dofile(path)
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok, name .. ": " .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end
local function tempdir()
  local directory = app.fs.joinPath(app.fs.tempPath, "aseprite-chat-account-" .. tostring(Uuid()))
  assert(app.fs.makeAllDirectories(directory))
  return directory
end

test("a missing file loads default values without touching io.open", function()
  local account, err = Account.load(app.fs.joinPath(tempdir(), "absent", "providers.json"))
  assert(not err, tostring(err))
  assert(account.mode == "default" and account.codexHome == Account.default_home())
  assert(account.baseUrl == "" and account.apiKey == "" and type(account.models) == "table" and #account.models == 0)
  assert(account.version == 1)
  assert(Account.path():find("providers%.json$"), "account path does not name providers.json")
end)

test("save and load roundtrip every field through a Unicode path with spaces", function()
  local file = app.fs.joinPath(tempdir(), "我的 账户", "providers.json")
  local account = { version = 1, mode = "custom", codexHome = "D:\\Codex 主页",
    baseUrl = "http://127.0.0.1:8080/v1", apiKey = "sk-秘密-1234", models = { "模型-a", "model b" } }
  local saved, save_error = Account.save(file, account)
  assert(saved, tostring(save_error))
  assert(app.fs.isFile(file), "account file was not created")
  local loaded, err = Account.load(file)
  assert(not err, tostring(err))
  assert(loaded.mode == "custom" and loaded.codexHome == account.codexHome)
  assert(loaded.baseUrl == account.baseUrl and loaded.apiKey == account.apiKey)
  assert(#loaded.models == 2 and loaded.models[1] == "模型-a" and loaded.models[2] == "model b")
end)

test("an empty model list persists as a JSON array", function()
  local file = app.fs.joinPath(tempdir(), "providers.json")
  assert(Account.save(file, { version = 1, mode = "default", codexHome = Account.default_home(),
    baseUrl = "", apiKey = "", models = {} }))
  local raw = assert(io.open(file, "rb")):read("*a")
  assert(raw:match('"models"%s*:%s*%[%s*%]'), "empty models did not encode as []: " .. raw)
  local loaded, err = Account.load(file)
  assert(not err and #loaded.models == 0 and loaded.mode == "default")
end)

test("invalid files fall back to defaults with an error text", function()
  local file = app.fs.joinPath(tempdir(), "providers.json")
  for _, content in ipairs({ "not json", "[1,2]", '{"version":2,"mode":"custom"}',
    '{"version":1,"mode":"custom","codexHome":"relative","baseUrl":"","apiKey":"","models":[]}',
    '{"version":1,"mode":"invented","codexHome":"D:\\\\h","baseUrl":"","apiKey":"","models":[]}' }) do
    local handle = assert(io.open(file, "wb")); handle:write(content); handle:close()
    local loaded, err = Account.load(file)
    assert(err, "invalid file reported no error: " .. content)
    assert(loaded.mode == "default" and loaded.codexHome == Account.default_home())
  end
end)

test("validate mirrors the bridge's account rules", function()
  local function account(overrides)
    local value = { version = 1, mode = "custom", codexHome = "D:\\home",
      baseUrl = "", apiKey = "", models = {} }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
  end
  assert(Account.validate(account()))
  assert(Account.validate(account { mode = "default" }))
  assert(Account.validate(account { baseUrl = "https://example.com/v1" }))
  assert(Account.validate(account { baseUrl = "http://127.0.0.1:9" }))
  assert(Account.validate(account { models = { "a", "b" } }))
  assert(not Account.validate(account { mode = "elsewhere" }))
  assert(not Account.validate(account { codexHome = "relative" }))
  assert(not Account.validate(account { codexHome = "D:relative" }))
  assert(not Account.validate(account { baseUrl = "ftp://x" }))
  assert(not Account.validate(account { apiKey = 5 }))
  assert(not Account.validate(account { models = "a,b" }))
  assert(not Account.validate(account { models = { "a", 3 } }))
end)

test("catalog synthesizes picker entries only for a custom model list", function()
  assert(Account.catalog({ mode = "default", models = { "m" } }) == nil)
  assert(Account.catalog({ mode = "custom", models = {} }) == nil)
  assert(Account.catalog(nil) == nil)
  local catalog = Account.catalog { mode = "custom", models = { "m1", "m2" } }
  assert(#catalog == 2)
  assert(catalog[1].model == "m1" and catalog[1].displayName == "m1" and catalog[1].isDefault)
  assert(not catalog[2].isDefault)
  assert(catalog[1].defaultReasoningEffort == "medium")
  assert(#catalog[1].supportedReasoningEfforts == 3
    and catalog[1].supportedReasoningEfforts[1].reasoningEffort == "low"
    and catalog[1].supportedReasoningEfforts[3].reasoningEffort == "high")
  assert(#catalog[1].serviceTiers == 0)
end)

print("account: " .. passed .. " passed")
