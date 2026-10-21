local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
assert(app.fs.isFile(app.fs.joinPath(root, "executor.lua")), "executor module is not implemented")
local Executor = dofile(app.fs.joinPath(root, "executor.lua"))
local tests, passed = {}, 0
local function test(name, body) tests[#tests + 1] = { name, body } end
local function eq(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function text(result) return result.contentItems[1].text end
local function success(result)
  assert(result.success, text(result))
  return json.decode(text(result))
end
local function rejected(result)
  assert(not result.success, "unexpected successful execution")
  assert(text(result):lower():find("inspect"), text(result))
end
local owned, executors = {}, {}
local function sprite(width, height, mode)
  local s = Sprite(width or 8, height or 4, mode or ColorMode.RGB)
  owned[#owned + 1] = s
  return s
end
local function bound(s, frame, layer)
  local e = Executor.new()
  executors[#executors + 1] = e
  e:bind(s, frame or app.frame, layer or app.layer)
  return e
end
local function execute(e, code, revision)
  return e:execute { code = code, summary = "Executor test", expectedRevision = revision or e:metadata().revision }
end
local edit = [[local cel = sprite.layers[1]:cel(1)
local image = cel.image:clone()
image:drawPixel(1, 1, app.pixelColor.rgba(255, 0, 0, 255))
cel.image = image
sprite.layers[1].name = "Edited"
return { edited = true }]]
local function decode64(encoded)
  local alphabet, bits, n, out = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 0, 0, {}
  for c in encoded:gmatch(".") do
    if c ~= "=" then
      local index = assert(alphabet:find(c, 1, true)) - 1
      bits, n = (bits << 6) | index, n + 6
      if n >= 8 then
        n = n - 8
        out[#out + 1] = string.char((bits >> n) & 255)
        bits = bits & ((1 << n) - 1)
      end
    end
  end
  return table.concat(out)
end
local function preview(result)
  local metadata = success(result)
  eq(result.contentItems[1].type, "inputText")
  eq(result.contentItems[2].type, "inputImage")
  local encoded = assert(result.contentItems[2].imageUrl:match("^data:image/png;base64,(.+)$"))
  local bytes = decode64(encoded)
  eq(bytes:sub(1, 8), "\137PNG\r\n\26\n")
  local width, height = string.unpack(">I4I4", bytes, 17)
  eq(width, metadata.preview.width); eq(height, metadata.preview.height)
  local path = app.fs.joinPath(app.fs.tempPath, "executor-test-" .. tostring(Uuid()) .. ".png")
  local file = assert(io.open(path, "wb")); file:write(bytes); file:close()
  local ok, image = pcall(Image, { fromFile = path })
  os.remove(path)
  assert(ok, image)
  return metadata, image
end

test("two dynamic tools expose valid function schemas", function()
  eq(#Executor.tools, 2)
  local tools = json.decode(json.encode(Executor.tools))
  eq(tools[1].type, "function"); eq(tools[1].name, "read_sprite")
  eq(tools[1].inputSchema.properties.frame.type, "integer")
  eq(tools[2].type, "function"); eq(tools[2].name, "execute_lua")
  eq(tools[2].inputSchema.properties.expectedRevision.type, "integer")
  eq(#tools[2].inputSchema.required, 3)
end)

test("unsaved RGBA metadata and preview preserve live pixels and document", function()
  local s = sprite()
  local red = app.pixelColor.rgba(255, 0, 0, 255)
  s.cels[1].image:drawPixel(1, 1, red)
  s.layers[1].name = "Live art"
  s.selection:select(Rectangle(1, 1, 3, 2))
  local e = bound(s)
  local before, file = e:metadata(), s.filename
  local m, image = preview(e:read({}))
  eq(m.spriteId, s.id); eq(m.width, 8); eq(m.height, 4); eq(m.colorMode, "RGB")
  eq(m.hasAssociatedFile, false); eq(m.isModified, s.isModified); eq(m.filename, file)
  eq(m.frameCount, 1); eq(m.frames[1].number, 1); eq(m.frames[1].duration, s.frames[1].duration)
  eq(m.layers[1].id, s.layers[1].id); eq(m.layers[1].name, "Live art")
  eq(m.layers[1].type, "image"); eq(m.layers[1].visible, true); eq(m.layers[1].locked, false)
  eq(m.activeLayer, s.layers[1].id); eq(m.selection.x, 1); eq(m.selection.width, 3)
  eq(image:getPixel(1, 1), red); eq(m.revision, before.revision)
  eq(s.filename, file); eq(s.hasAssociatedFile, false); eq(s.cels[1].image:getPixel(1, 1), red)
end)

test("indexed preview renders palette colors into RGB", function()
  local s = sprite(4, 4, ColorMode.INDEXED)
  s.palettes[1]:setColor(1, Color { r = 12, g = 34, b = 56, a = 255 })
  s.cels[1].image:drawPixel(0, 0, 1)
  local e = bound(s)
  local m, image = preview(e:read({}))
  eq(m.colorMode, "INDEXED"); eq(m.hasAssociatedFile, false)
  eq(image.colorMode, ColorMode.RGB)
  eq(image:getPixel(0, 0), app.pixelColor.rgba(12, 34, 56, 255))
end)

test("preview is capped to 1024 preserving aspect ratio", function()
  local s = sprite(2048, 512)
  local e = bound(s)
  local m, image = preview(e:read({}))
  eq(m.width, 2048); eq(m.height, 512)
  eq(m.preview.width, 1024); eq(m.preview.height, 256)
  eq(image.width, 1024); eq(image.height, 256)
end)

test("native Frame and number binding plus optional rendered frame", function()
  local s = sprite()
  s:newEmptyFrame()
  local image = Image(8, 4)
  image:drawPixel(0, 0, app.pixelColor.rgba(0, 255, 0, 255))
  s:newCel(s.layers[1], 2, image)
  app.frame = 2
  local e = bound(s, s.frames[2])
  local m, rendered = preview(e:read({}))
  eq(m.frame, 2); eq(rendered:getPixel(0, 0), app.pixelColor.rgba(0, 255, 0, 255))
  local older = e:metadata().revision
  e:bind(s, 2, s.layers[1])
  assert(e:metadata().revision > older)
  local response = e:read { frame = 1 }
  local other = success(response)
  assert(e:check(other.revision))
  local _, blank = preview(response)
  eq(other.frame, 1); eq(blank:getPixel(0, 0), 0); eq(app.frame.frameNumber, 2)
end)

test("malformed and out-of-range read frames fail", function()
  local e = bound(sprite())
  for _, frame in ipairs { 0, -1, 2, 1.5, "1", true, false } do
    assert(not e:read({ frame = frame }).success)
  end
end)

test("clone assignment plus layer edit share one Undo and new revision", function()
  local s = sprite()
  local e = bound(s)
  local name, pixel, revision = s.layers[1].name, s.cels[1].image:getPixel(1, 1), e:metadata().revision
  local result = success(execute(e, edit, revision))
  eq(s.cels[1].image:getPixel(1, 1), app.pixelColor.rgba(255, 0, 0, 255))
  eq(s.layers[1].name, "Edited"); eq(result.result.edited, true)
  assert(result.revision > revision)
  app.undo()
  eq(s.cels[1].image:getPixel(1, 1), pixel); eq(s.layers[1].name, name)
  assert(not e:check(result.revision))
  local undone = e:metadata().revision
  app.redo()
  eq(s.layers[1].name, "Edited"); assert(not e:check(undone))
end)

test("runtime failure escapes transaction and rolls back all undoable edits", function()
  local s = sprite()
  local e = bound(s)
  local pixel, name = s.cels[1].image:getPixel(1, 1), s.layers[1].name
  local result = execute(e, edit:gsub("return { edited = true }", "error('intentional rollback')"))
  assert(not result.success); assert(text(result):find("intentional rollback", 1, true))
  eq(s.cels[1].image:getPixel(1, 1), pixel); eq(s.layers[1].name, name)
  success(execute(e, edit))
end)

test("compile errors do not mutate document", function()
  local s = sprite(); local e = bound(s)
  local revision, pixel = e:metadata().revision, s.cels[1].image:getPixel(1, 1)
  assert(not execute(e, "local =", revision).success)
  eq(s.cels[1].image:getPixel(1, 1), pixel); assert(e:check(revision))
end)

test("bounded globals and fresh environment allow approved native edits", function()
  local e = bound(sprite())
  success(execute(e, [[assert(io == nil and os == nil and debug == nil and package == nil)
assert(require == nil and dofile == nil and loadfile == nil and load == nil and _G == nil)
assert(app and sprite and Image and ImageSpec and Point and Rectangle and Color and ColorMode and BlendMode)
assert(math.floor(2.9) == 2 and string.upper('ok') == 'OK' and table.concat({'a','b'}) == 'ab')
assert(utf8.len('艺术') == 2)
private_value = 7
return 'ok']]))
  success(execute(e, "assert(private_value == nil); return 'fresh'"))
end)

test("execution rejects malformed arguments", function()
  local e = bound(sprite()); local revision = e:metadata().revision
  for _, args in ipairs {
    {}, { code = "return 1", summary = "test" },
    { code = 1, summary = "test", expectedRevision = revision },
    { code = "return 1", summary = "", expectedRevision = revision },
    { code = "return 1", summary = "test", expectedRevision = "1" },
    { code = "return 1", summary = "test", expectedRevision = revision + 0.5 }
  } do assert(not e:execute(args).success) end
end)

test("direct attached-image pixel mutation invalidates revision", function()
  local s = sprite(); local e = bound(s); local revision = e:metadata().revision
  s.cels[1].image:drawPixel(2, 1, app.pixelColor.rgba(0, 0, 255, 255))
  rejected(execute(e, edit, revision))
  assert(e:metadata().revision > revision)
end)

test("native image version changes invalidate even with identical pixels", function()
  local s = sprite(); local e = bound(s); local revision = e:metadata().revision
  local image = s.cels[1].image
  local version, bytes = image.version, image.bytes
  image:drawImage(image:clone())
  assert(image.version > version, "native drawImage must increment Image.version")
  eq(image.bytes, bytes)
  rejected(execute(e, edit, revision))
end)

test("layer event invalidates revision even after its value is restored", function()
  local s = sprite(); local e = bound(s); local revision = e:metadata().revision
  local name = s.layers[1].name
  s.layers[1].name = "Transient"; s.layers[1].name = name
  rejected(execute(e, edit, revision))
end)

local mutations = {
  { "dimensions", function(s) s.width = 9 end },
  { "filename", function(s) s.filename = "executor-renamed.aseprite" end },
  { "frame duration", function(s) s.frames[1].duration = 0.321 end },
  { "new frame", function(s) s:newEmptyFrame() end },
  { "new layer", function(s) s:newLayer() end },
  { "layer name", function(s) s.layers[1].name = "Renamed" end },
  { "layer visibility", function(s) s.layers[1].isVisible = false end },
  { "layer opacity", function(s) s.layers[1].opacity = 111 end },
  { "layer blend mode", function(s) s.layers[1].blendMode = BlendMode.MULTIPLY end },
  { "layer lock", function(s) s.layers[1].isEditable = false end },
  { "cel position", function(s) s.cels[1].position = Point(1, 2) end },
  { "cel opacity", function(s) s.cels[1].opacity = 123 end },
  { "palette color", function(s) s.palettes[1]:setColor(1, Color { r=9, g=8, b=7 }) end },
  { "selection bounds", function(s) s.selection:select(Rectangle(1, 1, 2, 2)) end }
}
for _, mutation in ipairs(mutations) do
  test("stale " .. mutation[1] .. " is rejected before editing", function()
    local s = sprite(); local e = bound(s); local revision = e:metadata().revision
    mutation[2](s)
    rejected(execute(e, edit, revision))
    assert(e:metadata().revision > revision)
  end)
end

test("nested layers report hierarchy and observe child changes", function()
  local s = sprite(); local original = s.layers[1]
  local group = s:newGroup(); original.parent = group
  app.layer = original
  local e = bound(s); local m = e:metadata()
  eq(m.layers[1].type, "group"); eq(m.layers[1].children[1].id, original.id)
  original.isEditable = false
  assert(not e:check(m.revision))
end)

test("switch away and back keeps old revision stale", function()
  local s = sprite(); local e = bound(s); local revision = e:metadata().revision
  sprite(); app.sprite = s
  eq(app.sprite, s)
  rejected(execute(e, edit, revision))
end)

test("frame switch and back invalidates captured approval", function()
  local s = sprite(); s:newEmptyFrame(); app.frame = 1
  local e = bound(s); local revision = e:metadata().revision
  app.frame = 2
  rejected(execute(e, edit, revision))
  app.frame = 1
  rejected(execute(e, edit, revision))
end)

test("layer switch and back invalidates captured approval", function()
  local s = sprite(); local original = s.layers[1]; local second = s:newLayer(); app.layer = original
  local e = bound(s); local revision = e:metadata().revision
  app.layer = second
  rejected(execute(e, edit, revision))
  app.layer = original
  rejected(execute(e, edit, revision))
end)

test("selection command invalidates even when bounds stay unchanged", function()
  local s = sprite(); s.selection:select(Rectangle(1, 1, 3, 2))
  local e = bound(s); local revision = e:metadata().revision
  app.command.InvertMask(); app.command.InvertMask()
  eq(s.selection.bounds.width, 3)
  rejected(execute(e, edit, revision))
end)

test("closed target never modifies another active document", function()
  local s = sprite(); local e = bound(s); local revision = e:metadata().revision
  s:close(); local other = sprite()
  rejected(execute(e, edit, revision))
  eq(other.cels[1].image:getPixel(1, 1), 0)
  assert(not e:read({}).success)
end)

test("rebind retains monotonic revision and removes old sprite listeners", function()
  local old = sprite(); local e = bound(old); local previous = e:metadata().revision
  local current = sprite(); e:bind(current, 1, current.layers[1])
  local revision = e:metadata().revision
  assert(revision > previous)
  old.layers[1].name = "Unbound change"
  eq(e:metadata().revision, revision)
  assert(e:check(revision))
end)

test("dispose is idempotent, invalidates execution, and releases listener closures", function()
  local s = sprite(); local e = Executor.new(); e:bind(s, 1, s.layers[1])
  local revision = e:metadata().revision
  e:dispose(); e:dispose()
  rejected(execute(e, edit, revision)); assert(not e:read({}).success)
  local weak = setmetatable({ e }, { __mode = "v" }); e = nil
  collectgarbage("collect"); collectgarbage("collect")
  eq(weak[1], nil)
end)

test("closed sprite callbacks do not retain disposed executors", function()
  local s = sprite(); local e = Executor.new(); e:bind(s, 1, s.layers[1])
  s:close(); e:dispose()
  local weak = setmetatable({ e }, { __mode = "v" }); e = nil
  collectgarbage("collect"); collectgarbage("collect")
  eq(weak[1], nil)
end)

test("preview uses unique owned files and removes them after read failures", function()
  local e = bound(sprite())
  local native_open, paths = io.open, {}
  io.open = function(path, mode)
    if mode == "rb" and path:match("%.png$") then
      paths[#paths + 1] = path
      eq(app.fs.filePath(path), app.fs.tempPath:gsub("[\\/]$", ""))
      assert(app.fs.isFile(path), "PNG must exist before reading")
      return nil, "injected preview read failure"
    end
    return native_open(path, mode)
  end
  local ok, err = pcall(function()
    assert(not e:read({}).success)
    assert(not e:read({}).success)
  end)
  io.open = native_open
  assert(ok, err)
  eq(#paths, 2); assert(paths[1] ~= paths[2])
  for _, path in ipairs(paths) do assert(not app.fs.isFile(path), "leaked preview " .. path) end
  preview(e:read({}))
end)

test("native JSON tool arguments inspect the live sprite", function()
  local s = sprite()
  local e = bound(s)
  local data = success(e:read(json.decode("{}")))
  eq(data.width, 8)
end)
test("native JSON tool arguments execute an undoable edit", function()
  local s = sprite()
  local e = bound(s)
  local args = json.decode(json.encode {code = edit, summary = "Wire arguments", expectedRevision = e:metadata().revision})
  success(e:execute(args))
  eq(s.layers[1].name, "Edited")
  app.undo()
  assert(s.layers[1].name ~= "Edited")
end)

for _, item in ipairs(tests) do
  local ok, err = xpcall(item[2], debug.traceback)
  for _, e in ipairs(executors) do e:dispose() end
  executors = {}
  for _, s in ipairs(owned) do if s.isValid then s:close() end end
  owned = {}
  if ok then passed = passed + 1; print("PASS " .. item[1])
  else print("FAIL " .. item[1] .. "\n" .. tostring(err)) end
end
print("executor: " .. passed .. "/" .. #tests .. " tests passed")
assert(passed == #tests, "executor test failures")
