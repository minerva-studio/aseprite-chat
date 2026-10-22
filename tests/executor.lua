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
test("bind returns the exact snapshot captured while installing its listeners",function()
  local s=sprite()
  local e=Executor.new(); executors[#executors+1]=e
  local observed=0
  local metadata=e.metadata
  function e:metadata() observed=observed+1; return metadata(self) end
  local captured=e:bind(s,1,s.layers[1])
  assert(type(captured)=="table" and captured.spriteId==s.id and captured.revision==e.revision)
  eq(observed,1)
end)
test("each observation digests linked pixel data once and rechecks unversioned writes",function()
  local reads,pixels=0,"first"
  local image=setmetatable({id=9,version=1,width=1,height=1},{__index=function(_,key)
    if key=="bytes" then reads=reads+1; return pixels end
  end})
  local frames={{frameNumber=1,duration=0.1},{frameNumber=2,duration=0.1}}
  local target={id=1,width=1,height=1,colorMode=ColorMode.RGB,filename="fixture",isModified=true,
    hasAssociatedFile=false,selection={bounds={x=0,y=0,width=0,height=0},isEmpty=true},
    tags={},slices={},palettes={},frames=frames,layers={},cels={}}
  for i=1,2 do target.cels[i]={image=image,layer={id=3},frameNumber=i,position={x=0,y=0},opacity=255,zIndex=0} end
  local e=Executor.new(); e.sprite,e.frame=target,frames[1]
  local _,first=e:_observe(target,true)
  eq(reads,1)
  pixels="changed"
  local _,second=e:_observe(target,true)
  eq(reads,2); assert(first~=second,"digest caching hid an unversioned pixel change")
end)
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

test("dynamic tools expose valid function schemas", function()
  eq(#Executor.tools, 4)
  local tools = json.decode(json.encode(Executor.tools))
  eq(tools[1].type, "function"); eq(tools[1].name, "read_sprite")
  eq(tools[1].inputSchema.properties.frame.type, "integer")
  eq(tools[1].inputSchema.properties.frames.type, "array")
  eq(tools[1].inputSchema.properties.region.type, "object")
  eq(tools[2].name, "read_pixels"); eq(#tools[2].inputSchema.required, 4)
  eq(tools[3].name, "switch_sprite"); eq(tools[3].inputSchema.required[1], "spriteId")
  eq(tools[4].type, "function"); eq(tools[4].name, "execute_lua")
  eq(tools[4].inputSchema.properties.expectedRevision.type, "integer")
  eq(#tools[4].inputSchema.required, 3)
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
  eq(image:getPixel(m.scale, m.scale), red); eq(m.revision, before.revision)
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

local function sheet_image(result, index)
  local item = result.contentItems[1 + (index or 1)]
  eq(item.type, "inputImage")
  local bytes = decode64(assert(item.imageUrl:match("^data:image/png;base64,(.+)$")))
  eq(bytes:sub(1, 8), "\137PNG\r\n\26\n")
  local width, height = string.unpack(">I4I4", bytes, 17)
  local path = app.fs.joinPath(app.fs.tempPath, "executor-test-" .. tostring(Uuid()) .. ".png")
  local file = assert(io.open(path, "wb")); file:write(bytes); file:close()
  local ok, image = pcall(Image, { fromFile = path })
  os.remove(path)
  assert(ok, image)
  return image, width, height
end

test("frames, tag and frame selection order applies", function()
  local s = sprite(8, 4)
  for i = 2, 4 do s:newEmptyFrame() end
  local image = Image(8, 4); image:drawPixel(0, 0, app.pixelColor.rgba(9, 9, 9, 255))
  s:newCel(s.layers[1], 3, image)
  local tag = s:newTag(2, 3); tag.name = "walk"
  local e = bound(s)
  local m = success(e:read { tag = "walk" })
  eq(#m.selectedFrames, 2); eq(m.selectedFrames[1], 2); eq(m.selectedFrames[2], 3)
  eq(#m.layout, 2); eq(m.layout[1].frame, 2); eq(m.layout[2].frame, 3)
  eq(#m.cels, 1); eq(m.cels[1].frame, 3)
  m = success(e:read { tag = "walk", frames = { 4 } })
  eq(#m.selectedFrames, 1); eq(m.selectedFrames[1], 4)
  m = success(e:read { frame = 2 })
  eq(#m.selectedFrames, 1); eq(m.selectedFrames[1], 2)
  assert(not e:read({ tag = "missing" }).success)
  assert(not e:read({ frames = { 0 } }).success)
  assert(not e:read({ frames = {} }).success)
end)

test("uncapped many-frame reads tile multiple sheets with a correct layout", function()
  local s = sprite(60, 500)
  for _ = 2, 16 do s:newEmptyFrame() end
  local e = bound(s)
  local result = e:read { frames = (function() local f = {}; for i = 1, 16 do f[i] = i end; return f end)() }
  local m = success(result)
  eq(#m.selectedFrames, 16); eq(#m.layout, 16)
  local max_sheet = 0
  for _, cell in ipairs(m.layout) do
    max_sheet = math.max(max_sheet, cell.sheet)
    eq(cell.width, m.layout[1].width); eq(cell.height, m.layout[1].height)
  end
  assert(max_sheet >= 2, "expected at least two sheets")
  eq(#result.contentItems, 1 + max_sheet)
  local image = sheet_image(result, max_sheet)
  assert(image.width <= 2048 and image.height <= 2048)
  for _, cell in ipairs(m.layout) do
    if cell.sheet == max_sheet then
      local pixel = image:getPixel(cell.x + cell.width - 1, cell.y + cell.height - 1)
      assert(pixel, "layout cell outside sheet image")
      break
    end
  end
end)

test("small renders upscale by an integer factor and report scale", function()
  local s = sprite(16, 16); local e = bound(s)
  local m = success(e:read {})
  eq(m.scale, 64); eq(m.preview.width, 1024); eq(m.preview.height, 1024)
end)

test("region crops to the canvas and an empty region fails", function()
  local s = sprite(8, 8)
  s.cels[1].image:drawPixel(2, 2, app.pixelColor.rgba(255, 0, 0, 255))
  local e = bound(s)
  local m = success(e:read { region = { x = 2, y = 2, width = 4, height = 4 } })
  eq(m.preview.width / m.scale, 4); eq(m.preview.height / m.scale, 4)
  local image = sheet_image(e:read { region = { x = 2, y = 2, width = 4, height = 4 } })
  eq(image:getPixel(0, 0), app.pixelColor.rgba(255, 0, 0, 255))
  m = success(e:read { region = { x = 6, y = 6, width = 8, height = 8 } })
  eq(m.preview.width / m.scale, 2)
  assert(not e:read({ region = { x = 20, y = 20, width = 4, height = 4 } }).success)
  assert(not e:read({ region = { x = 0, y = 0, width = 0, height = 4 } }).success)
end)

test("grid draws only when the upscale factor is at least four", function()
  local s = sprite(16, 16)
  s.cels[1].image:drawPixel(0, 0, app.pixelColor.rgba(255, 0, 0, 255))
  local e = bound(s)
  local m = success(e:read { grid = 4 })
  eq(m.grid, 4); eq(m.scale, 64)
  local image = sheet_image(e:read { grid = 4 })
  assert(image:getPixel(4 * m.scale, 2) ~= image:getPixel(4 * m.scale - 1, 2), "grid line did not tint")
  local big = sprite(512, 512); local e2 = bound(big)
  local m2 = success(e2:read { grid = 4 })
  eq(m2.grid, "skipped (scale < 4)"); assert(m2.scale < 4)
end)

test("layer isolation renders a hidden layer without touching the document", function()
  local s = sprite(4, 4)
  local hidden = s:newLayer(); hidden.isVisible = false
  local image = Image(4, 4); image:drawPixel(0, 0, app.pixelColor.rgba(0, 255, 0, 255))
  s:newCel(hidden, 1, image)
  local e = bound(s)
  local revision = e:metadata().revision
  local m = success(e:read { layers = { hidden.id } })
  eq(m.layers[2].visible, false)
  assert(not hidden.isVisible, "isolation changed layer visibility")
  eq(e:metadata().revision, revision, "isolation staled the target")
  local rendered = sheet_image(e:read { layers = { hidden.id } })
  eq(rendered:getPixel(0, 0), app.pixelColor.rgba(0, 255, 0, 255))
  assert(not e:read({ layers = { 9999 } }).success)
end)

test("layer isolation converts indexed and gray cels through their palettes", function()
  local s = sprite(4, 4, ColorMode.INDEXED)
  s.palettes[1]:setColor(1, Color { r = 255, g = 0, b = 0, a = 255 })
  s.palettes[1]:setColor(2, Color { r = 0, g = 255, b = 0, a = 255 })
  s.cels[1].image:drawPixel(0, 0, 1); s.cels[1].image:drawPixel(1, 0, 2)
  local e = bound(s)
  local image = sheet_image(e:read { layers = { s.layers[1].id } })
  eq(image:getPixel(0, 0), app.pixelColor.rgba(255, 0, 0, 255))
  eq(image:getPixel(image.width // 4, 0), app.pixelColor.rgba(0, 255, 0, 255))
  eq(app.pixelColor.rgbaA(image:getPixel(image.width // 2, 0)), 0, "transparent index did not stay transparent")
  local pixels = success(e:read_pixels { x = 0, y = 0, width = 2, height = 1 })
  eq(pixels.format, "rgba"); eq(pixels.rows[1][1], "#ff0000ff"); eq(pixels.rows[1][2], "#00ff00ff")
  local g = sprite(4, 4, ColorMode.GRAY)
  g.cels[1].image:drawPixel(0, 0, app.pixelColor.graya(200, 255))
  e:bind(g, 1, g.layers[1])
  local gray = sheet_image(e:read { layers = { g.layers[1].id } })
  eq(gray:getPixel(0, 0), app.pixelColor.rgba(200, 200, 200, 255))
end)

test("read_pixels composites visible layers and reads single-layer cel pixels", function()
  local s = sprite(8, 8)
  s.cels[1].image:drawPixel(1, 1, app.pixelColor.rgba(10, 20, 30, 255))
  local e = bound(s)
  local data = success(e:read_pixels { x = 0, y = 0, width = 4, height = 4 })
  eq(data.format, "rgba"); eq(data.rows[2][2], "#0a141eff"); eq(data.rows[1][1], "#00000000")
  data = success(e:read_pixels { x = 1, y = 1, width = 2, height = 2, layer = s.layers[1].id })
  eq(data.rows[1][1], "#0a141eff"); eq(data.layer, s.layers[1].id)
  data = success(e:read_pixels { x = 6, y = 6, width = 4, height = 4 })
  eq(data.rows[4][4], "#00000000", "out-of-canvas pixels must be transparent")
end)

test("read_pixels returns palette indices and gray channels per layer", function()
  local s = sprite(4, 4, ColorMode.INDEXED)
  s.cels[1].image:drawPixel(0, 0, 3)
  local e = bound(s)
  local data = success(e:read_pixels { x = 0, y = 0, width = 2, height = 2, layer = s.layers[1].id })
  eq(data.format, "index"); eq(data.rows[1][1], 3); eq(data.rows[2][2], 0)
  local g = sprite(4, 4, ColorMode.GRAY)
  g.cels[1].image:drawPixel(0, 0, app.pixelColor.graya(200, 255))
  e:bind(g, 1, g.layers[1])
  data = success(e:read_pixels { x = 0, y = 0, width = 2, height = 2, layer = g.layers[1].id })
  eq(data.format, "gray"); eq(data.rows[1][1], "#c8ff"); eq(data.rows[2][2], "#0000")
  local composite = success(e:read_pixels { x = 0, y = 0, width = 1, height = 1 })
  eq(composite.format, "rgba")
end)

test("read_pixels enforces the 4096 cell cap and keeps the revision", function()
  local s = sprite(8, 8); local e = bound(s)
  local revision = e:metadata().revision
  assert(not e:read_pixels({ x = 0, y = 0, width = 65, height = 64 }).success)
  assert(not e:read_pixels({ x = 0, y = 0, width = 4096, height = 2 }).success)
  assert(e:read_pixels({ x = 0, y = 0, width = 64, height = 64 }).success)
  eq(e:metadata().revision, revision)
end)

test("openSprites lists documents and never feeds the observation signature", function()
  local s = sprite()
  local e = bound(s)
  e:metadata()
  local other = sprite(4, 4)
  local seen = {}
  for _, entry in ipairs(e:metadata().openSprites) do seen[entry.spriteId] = entry end
  assert(seen[s.id].isTarget and not seen[other.id].isTarget)
  assert(not e.observed:find("openSprites", 1, true), "openSprites leaked into the signature")
  local other_id = other.id
  other:close()
  local open = e:metadata().openSprites
  for _, entry in ipairs(open) do assert(entry.spriteId ~= other_id, "closed sprite still listed") end
end)

test("tags and slices feed metadata and the observation signature", function()
  local s = sprite(); local e = bound(s)
  local m = e:metadata(); eq(#m.tags, 0); eq(#m.slices, 0)
  local revision = m.revision
  local tag = s:newTag(1, 1); tag.name = "walk"
  local m2 = e:metadata()
  assert(m2.revision > revision, "tag change did not bump the revision")
  eq(m2.tags[1].name, "walk"); eq(m2.tags[1].fromFrame, 1); eq(m2.tags[1].toFrame, 1)
  local slice = s:newSlice(Rectangle(1, 1, 3, 2)); slice.name = "cut"
  local m3 = e:metadata()
  assert(m3.revision > m2.revision, "slice change did not bump the revision")
  eq(m3.slices[1].name, "cut"); eq(m3.slices[1].bounds.width, 3)
  assert(e:read({}).success)
end)

test("a non-target sprite reads without a revision and defaults to frame 1", function()
  local s = sprite(); local e = bound(s)
  local other = sprite(4, 4); other:newEmptyFrame()
  local other_id = other.id
  local m = success(e:read { spriteId = other_id })
  eq(m.target, false); eq(m.revision, nil); eq(m.frame, 1)
  assert(m.openSprites and #m.openSprites >= 2)
  local owned = success(e:read { spriteId = s.id })
  eq(owned.target, true); assert(owned.revision)
  assert(not e:read({ spriteId = 99999 }).success)
  other:close()
  assert(not e:read({ spriteId = other_id }).success)
end)

test("switch_sprite activates and rebinds the target with a fresh revision", function()
  local s = sprite(); local e = bound(s)
  local older = e:metadata().revision
  local other = sprite(4, 4)
  local m = success(e:switch { spriteId = other.id })
  eq(app.sprite, other)
  eq(m.spriteId, other.id); assert(m.revision > older)
  eq(e.sprite, other); eq(e.frame.frameNumber, 1)
  assert(e:check(m.revision))
  assert(not e:switch({ spriteId = 424242 }).success)
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
