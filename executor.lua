local Executor = {}
Executor.__index = Executor

--- Dynamic app-server function tools; approval and active-turn validation belong to the controller.
Executor.tools = {
  {
    type = "function", name = "read_sprite",
    description = "Inspect the bound live, possibly unsaved Aseprite sprite and its current revision. " ..
      "Returns JSON metadata and a rendered PNG preview capped to 1024 pixels. " ..
      "The optional 1-based frame selects the preview only; it does not change the captured editing context.",
    inputSchema = {
      type = "object", properties = { frame = { type = "integer", minimum = 1 } },
      required = json.decode("[]"), additionalProperties = false
    }
  },
  {
    type = "function", name = "execute_lua",
    description = "Propose short, terminating Lua for the captured sprite; the user must approve the complete code. " ..
      "Inspect first and pass that expectedRevision. The plugin rechecks the active sprite/frame/layer and revision, " ..
      "then owns one app.transaction and returns the result and new revision. " ..
      "For undoable pixels: local image = cel.image:clone(); image:drawPixel(x,y,pixel); cel.image = image. " ..
      "Raw drawPixel/pixels/bytes writes to an attached image do not create Undo and cannot roll back. " ..
      "Use native undoable APIs such as cel.image assignment, cel.position/opacity, layer.name/opacity/blendMode, " ..
      "and sprite:newLayer/newCel; layer visibility and locking are undoable inside this transaction. " ..
      "Only edit the captured sprite; do not save/open/close documents or cause external side effects. " ..
      "Environment: sprite, native app, Aseprite constructors/constants, basic Lua functions, math/string/table/utf8; " ..
      "no io/os/debug/package/require/dofile/loadfile/load. Native app is powerful: this is trusted approved automation, " ..
      "not a hostile-code sandbox. Errors roll back undoable edits only. Running Lua cannot be interrupted by Stop.",
    inputSchema = {
      type = "object", properties = {
        code = { type = "string", minLength = 1 }, summary = { type = "string", minLength = 1 },
        expectedRevision = { type = "integer", minimum = 0 }
      }, required = { "code", "summary", "expectedRevision" }, additionalProperties = false
    }
  }
}

local function result(ok, value)
  return { success = ok, contentItems = { { type = "inputText", text = value } } }
end

local function integer(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

-- Aseprite decodes wire JSON objects as userdata, while local callers use Lua tables.
local function arguments_object(value)
  if type(value) == "table" then
    for key in pairs(value) do if type(key) ~= "string" then return false end end
    return true
  end
  if type(value) == "userdata" then
    local ok, encoded = pcall(json.encode, value)
    return ok and encoded:sub(1, 1) == "{"
  end
  return false
end

-- Stable encoding avoids depending on Lua table iteration order in observation comparisons.
local function signature(value)
  if type(value) ~= "table" then
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
  end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) end
    return a < b
  end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = signature(key) .. ":" .. signature(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function layers_metadata(layers)
  local out = {}
  for i = 1, #layers do
    local layer = layers[i]
    local data = {
      id = layer.id, name = layer.name,
      type = layer.isGroup and "group" or (layer.isTilemap and "tilemap" or "image"),
      visible = layer.isVisible, locked = not layer.isEditable,
      opacity = layer.opacity, blendMode = layer.blendMode, stackIndex = layer.stackIndex,
      background = layer.isBackground, reference = layer.isReference, continuous = layer.isContinuous
    }
    if layer.isGroup then data.children = layers_metadata(layer.layers) end
    out[#out + 1] = data
  end
  return out
end

local function base64(bytes)
  local alphabet, out = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
  for i = 1, #bytes, 3 do
    local a, b, c = bytes:byte(i, i + 2)
    local word = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = alphabet:sub(((word >> 18) & 63) + 1, ((word >> 18) & 63) + 1)
      .. alphabet:sub(((word >> 12) & 63) + 1, ((word >> 12) & 63) + 1)
      .. (b and alphabet:sub(((word >> 6) & 63) + 1, ((word >> 6) & 63) + 1) or "=")
      .. (c and alphabet:sub((word & 63) + 1, (word & 63) + 1) or "=")
  end
  return table.concat(out)
end

local function pixel_digest(image)
  -- Aseprite 1.3.18.6 drawPixel/iterator writes can bypass Image.version. Keep only a derived FNV-1a digest.
  local hash = 0xcbf29ce484222325
  local bytes = image.bytes
  for i = 1, #bytes do hash = (hash ~ bytes:byte(i)) * 0x100000001b3 end
  return string.format("%016x", hash)
end

local function preview(sprite, frame)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawSprite(sprite, frame)
  local scale = math.min(1, 1024 / math.max(image.width, image.height))
  local width, height = math.max(1, math.floor(image.width * scale)), math.max(1, math.floor(image.height * scale))
  if scale < 1 then image:resize(width, height) end
  local path = app.fs.joinPath(app.fs.tempPath, "aseprite-chat-" .. tostring(Uuid()) .. ".png")
  local file
  local ok, encoded = pcall(function()
    image:saveAs(path)
    local why
    file, why = io.open(path, "rb")
    assert(file, why)
    local bytes = assert(file:read("*a"))
    return base64(bytes)
  end)
  if file then pcall(file.close, file) end
  -- The path is unique and owned by this call, including when save/read/encoding fails.
  local removed, why = os.remove(path)
  if not removed and app.fs.isFile(path) then error("Cannot remove temporary preview: " .. tostring(why)) end
  if not ok then error(encoded) end
  return "data:image/png;base64," .. encoded, { width = width, height = height }
end

local constructors = {
  "Brush", "Color", "ColorSpace", "Image", "ImageSpec", "Palette", "Point", "Rectangle", "Selection", "Size", "Sprite", "Uuid", "Version"
}
local constants = {
  "Align", "AniDir", "BlendMode", "BrushPattern", "BrushType", "ColorMode", "FilterChannels", "FlipType", "Ink",
  "MouseButton", "RangeType", "SelectionMode", "SpriteSheetDataFormat", "SpriteSheetType", "TilemapMode", "TilesetMode"
}
local function environment(sprite)
  local env = {
    sprite = sprite, app = app, assert = assert, error = error, ipairs = ipairs, pairs = pairs, next = next,
    pcall = pcall, xpcall = xpcall, select = select, tonumber = tonumber, tostring = tostring, type = type
  }
  -- Copy library tables so an approved script cannot replace functions used by later turns.
  for name, library in pairs { math = math, string = string, table = table, utf8 = utf8 } do
    env[name] = {}
    for key, value in pairs(library) do env[name][key] = value end
  end
  for _, name in ipairs(constructors) do env[name] = _G[name] end
  for _, name in ipairs(constants) do
    local native = _G[name]
    if type(native) == "table" then
      env[name] = {}
      for key, value in pairs(native) do env[name][key] = value end
    else env[name] = native end
  end
  return env
end

--- Create a reusable executor. Rebinding and disposal never reset its monotonic revision.
function Executor.new()
  return setmetatable({ revision = 0, listeners = {} }, Executor)
end

--- Remove native listener handles and invalidate the binding; safe to call repeatedly.
function Executor:dispose()
  for _, listener in ipairs(self.listeners) do
    -- Native sprite Events pointers are destroyed on close and must never be dereferenced afterwards.
    if not listener.sprite or listener.sprite.isValid then
      listener.events:off(listener.handle)
    end
  end
  self.listeners = {}
  self.sprite, self.frame, self.layer, self.observed = nil, nil, nil, nil
end

--- Capture the turn's native target without changing the active editor. Frame accepts a native Frame or 1-based number.
function Executor:bind(sprite, frame, layer)
  self:dispose()
  assert(sprite and sprite.isValid, "An open sprite is required; inspect again.")
  local number
  if type(frame) == "number" then number = frame
  else
    assert(frame and frame.sprite == sprite, "Frame must belong to the target sprite.")
    number = frame.frameNumber
  end
  assert(integer(number) and number >= 1 and number <= #sprite.frames, "Frame is out of range.")
  assert(layer and layer.sprite == sprite, "Layer must belong to the target sprite.")
  self.sprite, self.frame, self.layer = sprite, sprite.frames[number], layer
  self.revision = self.revision + 1
  local function listen(events, name, callback, owner)
    self.listeners[#self.listeners + 1] = { events = events, handle = events:on(name, callback), sprite = owner }
  end
  local ok, err = pcall(function()
    local weak = setmetatable({ self }, { __mode = "v" })
    for _, name in ipairs { "change", "filenamechange", "layerblendmode", "layername", "layeropacity", "layervisibility" } do
      listen(sprite.events, name, function()
        local owner = weak[1]
        if owner then owner.revision = owner.revision + 1 end
      end, sprite)
    end
    listen(app.events, "sitechange", function() self.revision = self.revision + 1 end)
    listen(app.events, "aftercommand", function()
      if app.sprite == self.sprite then self.revision = self.revision + 1 end
    end)
    self:metadata()
  end)
  if not ok then self:dispose(); error(err) end
end

--- Observe live native state and publish its revision after signature comparison. Throws for an invalid target.
function Executor:metadata()
  local sprite = self.sprite
  assert(sprite and sprite.isValid, "The target is closed or unbound; inspect again.")
  local bounds = sprite.selection.bounds
  local data = {
    spriteId = sprite.id, width = sprite.width, height = sprite.height,
    colorMode = sprite.colorMode == ColorMode.RGB and "RGB" or (sprite.colorMode == ColorMode.INDEXED and "INDEXED" or "GRAY"),
    filename = sprite.filename, isModified = sprite.isModified, hasAssociatedFile = sprite.hasAssociatedFile,
    frameCount = #sprite.frames, frames = {}, layers = layers_metadata(sprite.layers),
    frame = self.frame.frameNumber, activeLayer = app.sprite == sprite and app.layer and app.layer.id or nil,
    selection = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height, empty = sprite.selection.isEmpty }
  }
  local observation = { metadata = data, cels = {}, palettes = {} }
  -- Aseprite Frame identity is (sprite ID, frame number), not the temporary Lua userdata address.
  local frames = sprite.frames
  for i = 1, #frames do
    local frame = frames[i]
    data.frames[#data.frames + 1] = { spriteId = sprite.id, number = frame.frameNumber, duration = frame.duration }
  end
  local cels = sprite.cels
  for i = 1, #cels do
    local cel = cels[i]
    local image, position = cel.image, cel.position
    observation.cels[#observation.cels + 1] = {
      layer = cel.layer.id, frame = cel.frameNumber, x = position.x, y = position.y,
      opacity = cel.opacity, zIndex = cel.zIndex, imageId = image.id, imageVersion = image.version,
      width = image.width, height = image.height, pixels = pixel_digest(image)
    }
  end
  local palettes = sprite.palettes
  for p = 1, #palettes do
    local palette = palettes[p]
    local colors = {}
    for i = 0, #palette - 1 do
      local color = palette:getColor(i)
      colors[#colors + 1] = { color.red, color.green, color.blue, color.alpha }
    end
    observation.palettes[#observation.palettes + 1] = { frame = palette.frame.frameNumber, colors = colors }
  end
  local current = signature(observation)
  if self.observed and self.observed ~= current then self.revision = self.revision + 1 end
  self.observed = current
  data.revision = self.revision
  return data
end

--- Return live metadata and an independent RGB PNG preview; never saves or flattens the source document.
function Executor:read(args)
  local ok, value = pcall(function()
    assert(args == nil or arguments_object(args), "read_sprite arguments must be an object.")
    local data = self:metadata()
    local frame
    if args then frame = args.frame end
    if frame == nil then frame = self.frame.frameNumber end
    assert(integer(frame) and frame >= 1 and frame <= data.frameCount, "Frame must be a 1-based integer within the sprite.")
    local url, dimensions = preview(self.sprite, frame)
    data.frame, data.preview = frame, dimensions
    local response = result(true, json.encode(data))
    response.contentItems[2] = { type = "inputImage", imageUrl = url }
    return response
  end)
  return ok and value or result(false, tostring(value))
end

--- Reobserve immediately before approval/execution and reject stale or changed native context.
function Executor:check(expectedRevision)
  local ok, err = pcall(function()
    assert(integer(expectedRevision), "An integer expectedRevision is required.")
    local metadata = self:metadata()
    assert(app.sprite == self.sprite, "The captured sprite is no longer active.")
    assert(app.frame == self.frame and app.layer == self.layer, "The captured frame or layer has changed.")
    assert(metadata.revision == expectedRevision, "The document revision changed.")
  end)
  if not ok then return false, tostring(err) .. " Inspect the sprite again before proposing an edit." end
  return true
end

--- Execute already-approved trusted Lua. The caller must first validate the active protocol turn and user approval.
function Executor:execute(args)
  if not arguments_object(args) or type(args.code) ~= "string" or not args.code:find("%S")
      or type(args.summary) ~= "string" or not args.summary:find("%S") or not integer(args.expectedRevision) then
    return result(false, "execute_lua requires code, summary, and an integer expectedRevision. Inspect again.")
  end
  local valid, why = self:check(args.expectedRevision)
  if not valid then return result(false, why) end
  local chunk, compileError = load(args.code, "Codex: " .. args.summary, "t", environment(self.sprite))
  if not chunk then return result(false, tostring(compileError)) end
  local returned
  -- Catch outside app.transaction: swallowing chunk errors inside the callback would commit partial edits.
  local ok, err = pcall(function()
    app.transaction("Codex: " .. args.summary, function() returned = chunk() end)
  end)
  if not ok then return result(false, tostring(err)) end
  self.revision = self.revision + 1
  app.refresh()
  local observed, metadata = pcall(self.metadata, self)
  if not observed then return result(false, "Execution completed but observation failed: " .. tostring(metadata) .. " Inspect again.") end
  local encoded, value = pcall(json.encode, { result = returned, revision = metadata.revision })
  if not encoded then
    value = json.encode { result = tostring(returned), revision = metadata.revision }
  end
  return result(true, value)
end

return Executor
