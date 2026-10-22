local Executor = {}
Executor.__index = Executor

--- Dynamic app-server function tools; approval and active-turn validation belong to the controller.
Executor.tools = {
  {
    type = "function", name = "read_sprite",
    description = "Inspect a live, possibly unsaved Aseprite sprite. Returns JSON metadata " ..
      "(openSprites, palette, tags, slices, layers, cels for the rendered frames) and rendered PNG " ..
      "previews (one image per sheet when several frames are rendered). Reading the editing target " ..
      "returns the current revision; another open sprite from openSprites is read-only and has no " ..
      "revision. Options: spriteId (open sprite id), frame, frames (array of 1-based frames, no cap), " ..
      "tag (tag name), layers (array of layer ids; group ids include their children and selected " ..
      "layers render in isolation without changing the document), region {x,y,width,height} to crop, " ..
      "grid (source-pixel spacing, drawn when the preview scale is 4 or more).",
    inputSchema = {
      type = "object", properties = {
        spriteId = { type = "integer", minimum = 1 },
        frame = { type = "integer", minimum = 1 },
        frames = { type = "array", items = { type = "integer", minimum = 1 } },
        tag = { type = "string", minLength = 1 },
        layers = { type = "array", items = { type = "integer", minimum = 1 } },
        region = { type = "object", properties = {
          x = { type = "integer", minimum = 0 }, y = { type = "integer", minimum = 0 },
          width = { type = "integer", minimum = 1 }, height = { type = "integer", minimum = 1 } },
          required = { "x", "y", "width", "height" }, additionalProperties = false },
        grid = { type = "integer", minimum = 1 }
      },
      required = json.decode("[]"), additionalProperties = false
    }
  },
  {
    type = "function", name = "read_pixels",
    description = "Read exact pixel values of a small region (width*height must not exceed 4096). " ..
      "Without layer, returns the composited visible layers as #rrggbbaa hex strings. With layer " ..
      "(a layer id), returns that layer's cel pixels in sprite coordinates, transparent outside " ..
      "the cel: palette indices for INDEXED sprites, #vvaa for GRAY, #rrggbbaa for RGB. " ..
      "Optional spriteId and frame; no approval or revision required.",
    inputSchema = {
      type = "object", properties = {
        spriteId = { type = "integer", minimum = 1 },
        frame = { type = "integer", minimum = 1 },
        layer = { type = "integer", minimum = 1 },
        x = { type = "integer", minimum = 0 }, y = { type = "integer", minimum = 0 },
        width = { type = "integer", minimum = 1 }, height = { type = "integer", minimum = 1 }
      }, required = { "x", "y", "width", "height" }, additionalProperties = false
    }
  },
  {
    type = "function", name = "switch_sprite",
    description = "Move the editing target to another open sprite by its openSprites spriteId. " ..
      "Activates it in the editor and rebinds the canvas context; returns its metadata with a new " ..
      "revision. Later execute_lua edits and read_sprite previews apply to the new target.",
    inputSchema = {
      type = "object", properties = { spriteId = { type = "integer", minimum = 1 } },
      required = { "spriteId" }, additionalProperties = false
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

local function mode_name(colorMode)
  return colorMode == ColorMode.RGB and "RGB" or (colorMode == ColorMode.INDEXED and "INDEXED" or "GRAY")
end

local function rgba_hex(pixel)
  return string.format("#%02x%02x%02x%02x", app.pixelColor.rgbaR(pixel),
    app.pixelColor.rgbaG(pixel), app.pixelColor.rgbaB(pixel), app.pixelColor.rgbaA(pixel))
end

local function open_sprite(id)
  for _, sprite in ipairs(app.sprites) do
    if sprite.id == id then return sprite end
  end
end

-- The open-document list is informational only; it never feeds the revision signature.
local function open_sprites(target)
  local list = {}
  for _, sprite in ipairs(app.sprites) do
    list[#list + 1] = {
      spriteId = sprite.id, filename = sprite.filename, width = sprite.width, height = sprite.height,
      colorMode = mode_name(sprite.colorMode), frameCount = #sprite.frames, isTarget = sprite == target
    }
  end
  return list
end

local function find_layer(layers, id)
  for i = 1, #layers do
    local layer = layers[i]
    if layer.id == id then return layer end
    if layer.isGroup then
      local found = find_layer(layer.layers, id)
      if found then return found end
    end
  end
end

-- Collect selected image layers in paint order; a selected group includes its children.
local function selected_layers(sprite, ids)
  local wanted, known = {}, {}
  for _, id in ipairs(ids) do
    assert(integer(id) and id >= 1, "layers must contain 1-based layer ids.")
    wanted[id] = true
  end
  assert(next(wanted) ~= nil, "layers must not be empty.")
  local function mark(layers)
    for i = 1, #layers do
      local layer = layers[i]
      known[layer.id] = true
      if layer.isGroup then mark(layer.layers) end
    end
  end
  mark(sprite.layers)
  for id in pairs(wanted) do assert(known[id], "Unknown layer id: " .. tostring(id)) end
  local out = {}
  local function collect(layers, inherited)
    for i = 1, #layers do
      local layer = layers[i]
      local selected = inherited or wanted[layer.id] == true
      if layer.isGroup then collect(layer.layers, selected)
      elseif selected then out[#out + 1] = layer end
    end
  end
  collect(sprite.layers, false)
  for _, layer in ipairs(out) do
    assert(not layer.isTilemap, "Tilemap layers cannot be rendered in isolation; omit layers.")
  end
  return out
end

local function render_frame(sprite, frame_number)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawSprite(sprite, frame_number)
  return image
end

-- Compose the selected layers manually; visibility and other document state never change.
local function render_layers(sprite, frame_number, layers)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  for _, layer in ipairs(layers) do
    local cel = layer:cel(frame_number)
    if cel and cel.image then
      image:drawImage(cel.image, cel.position,
        math.floor(cel.opacity * layer.opacity / 255), layer.blendMode)
    end
  end
  return image
end

local function crop(image, region, sprite)
  local x = math.max(0, region.x)
  local y = math.max(0, region.y)
  local x2 = math.min(sprite.width, region.x + region.width)
  local y2 = math.min(sprite.height, region.y + region.height)
  assert(x2 > x and y2 > y, "Region is outside the canvas.")
  local out = Image(x2 - x, y2 - y, ColorMode.RGB)
  out:drawImage(image, Point(-x, -y))
  return out
end

-- Small renders upscale by an integer factor; oversized renders downscale to the
-- 1024 preview cap, and a row of cells must always fit one 2048 sheet width.
local function choose_scale(w, h, n)
  local cols = math.ceil(math.sqrt(n))
  local scale
  if math.max(w, h) > 1024 then
    scale = 1024 / math.max(w, h)
  else
    scale = math.max(1, math.floor(1024 / math.max(w, h)))
    while scale > 1 and cols * (w * scale + 1) - 1 > 2048 do scale = scale - 1 end
  end
  if cols * (math.floor(w * scale) + 1) - 1 > 2048 then
    scale = math.min(scale, (2049 - cols) / (cols * w))
  end
  return scale
end

local function rescale(image, scale)
  if scale == 1 then return end
  image:resize(math.max(1, math.floor(image.width * scale)),
    math.max(1, math.floor(image.height * scale)))
end

-- Tint every Nth source-pixel boundary on an upscaled render with a translucent marker.
local function apply_grid(image, step)
  local rgba = app.pixelColor.rgba
  local R, G, B = app.pixelColor.rgbaR, app.pixelColor.rgbaG, app.pixelColor.rgbaB
  local function tint(pixel)
    return rgba((R(pixel) + 255) // 2, (G(pixel) + 64) // 2, (B(pixel) + 255) // 2, 255)
  end
  for x = step, image.width - 1, step do
    for y = 0, image.height - 1 do image:drawPixel(x, y, tint(image:getPixel(x, y))) end
  end
  for y = step, image.height - 1, step do
    for x = 0, image.width - 1 do image:drawPixel(x, y, tint(image:getPixel(x, y))) end
  end
end

-- Lay out scaled frame renders in a ceil(sqrt(n))-column grid, splitting rows into
-- additional 2048-capped sheets when one cannot hold them all.
local function pack_sheets(renders, frames)
  local n, cols = #renders, math.ceil(math.sqrt(#renders))
  local cw, ch = renders[1].width, renders[1].height
  local rows_per_sheet = math.max(1, math.floor((2048 + 1) / (ch + 1)))
  local per_sheet = cols * rows_per_sheet
  local sheets, layout = {}, {}
  for i, image in ipairs(renders) do
    local index = math.ceil(i / per_sheet)
    local pos = i - (index - 1) * per_sheet - 1
    if not sheets[index] then
      local remaining = n - (index - 1) * per_sheet
      local rows = math.min(rows_per_sheet, math.ceil(remaining / cols))
      sheets[index] = Image(cols * cw + (cols - 1), rows * ch + (rows - 1), ColorMode.RGB)
    end
    local col, row = pos % cols, math.floor(pos / cols)
    local x, y = col * (cw + 1), row * (ch + 1)
    sheets[index]:drawImage(image, Point(x, y))
    layout[i] = { sheet = index, frame = frames[i], x = x, y = y, width = cw, height = ch }
  end
  return sheets, layout
end

local function png_data_url(image)
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
  return "data:image/png;base64," .. encoded
end

local function array_of(value, name)
  local kind = type(value)
  if kind == "userdata" then
    local ok, encoded = pcall(json.encode, value)
    assert(ok and encoded:sub(1, 1) == "[", name .. " must be an array.")
  elseif kind ~= "table" then error(name .. " must be an array.", 0) end
  local out = {}
  for _, item in ipairs(value) do out[#out + 1] = item end
  return out
end

-- Frame selection precedence: frames array > tag name > legacy frame > the bound frame.
local function frames_for(args, sprite, fallback)
  local count = #sprite.frames
  if args.frames ~= nil then
    local out = {}
    for _, frame in ipairs(array_of(args.frames, "frames")) do
      assert(integer(frame) and frame >= 1 and frame <= count,
        "frames must contain 1-based integers within the sprite.")
      out[#out + 1] = frame
    end
    assert(#out > 0, "frames must not be empty.")
    return out
  end
  if args.tag ~= nil then
    assert(type(args.tag) == "string" and args.tag ~= "", "tag must be a tag name.")
    for _, tag in ipairs(sprite.tags) do
      if tag.name == args.tag then
        local out = {}
        for frame = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do out[#out + 1] = frame end
        return out
      end
    end
    error("Unknown tag: " .. args.tag)
  end
  local frame = args.frame
  if frame == nil then frame = fallback end
  assert(integer(frame) and frame >= 1 and frame <= count,
    "Frame must be a 1-based integer within the sprite.")
  return { frame }
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
--- Return the metadata snapshot captured during binding, avoiding a second full document observation.
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
  local ok, captured = pcall(function()
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
    return self:metadata()
  end)
  if not ok then self:dispose(); error(captured) end
  return captured
end

-- Collect the descriptive half of the metadata. When signed is true, also return
-- the observation signature; cels/palettes/tags/slices are document state that
-- bumps the revision, while volatile lists such as openSprites stay outside it.
function Executor:_observe(sprite, signed)
  local bounds = sprite.selection.bounds
  local tags = {}
  for _, tag in ipairs(sprite.tags) do
    tags[#tags + 1] = { name = tag.name, fromFrame = tag.fromFrame.frameNumber,
      toFrame = tag.toFrame.frameNumber, aniDir = tag.aniDir }
  end
  local slices = {}
  for _, slice in ipairs(sprite.slices) do
    local b = slice.bounds
    slices[#slices + 1] = { name = slice.name,
      bounds = { x = b.x, y = b.y, width = b.width, height = b.height } }
  end
  local palette, palette_size = {}, 0
  if sprite.palettes[1] then
    palette_size = #sprite.palettes[1]
    for i = 0, math.min(255, palette_size - 1) do
      local color = sprite.palettes[1]:getColor(i)
      palette[#palette + 1] = string.format("#%02x%02x%02x%02x",
        color.red, color.green, color.blue, color.alpha)
    end
  end
  local data = {
    spriteId = sprite.id, width = sprite.width, height = sprite.height,
    colorMode = mode_name(sprite.colorMode),
    filename = sprite.filename, isModified = sprite.isModified, hasAssociatedFile = sprite.hasAssociatedFile,
    frameCount = #sprite.frames, frames = {}, layers = layers_metadata(sprite.layers),
    frame = self.sprite == sprite and self.frame.frameNumber or 1,
    activeLayer = app.sprite == sprite and app.layer and app.layer.id or nil,
    selection = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height, empty = sprite.selection.isEmpty },
    palette = palette, paletteSize = palette_size, tags = tags, slices = slices
  }
  -- Aseprite Frame identity is (sprite ID, frame number), not the temporary Lua userdata address.
  local frames = sprite.frames
  for i = 1, #frames do
    local frame = frames[i]
    data.frames[#data.frames + 1] = { spriteId = sprite.id, number = frame.frameNumber, duration = frame.duration }
  end
  if not signed then return data end
  local observation = { metadata = data, cels = {}, palettes = {}, tags = tags, slices = slices }
  -- Linked cels share image IDs; reuse only within this observation because drawPixel can bypass image.version.
  local digests = {}
  local cels = sprite.cels
  for i = 1, #cels do
    local cel = cels[i]
    local image, position = cel.image, cel.position
    local digest = digests[image.id]
    if not digest then digest = pixel_digest(image); digests[image.id] = digest end
    observation.cels[#observation.cels + 1] = {
      layer = cel.layer.id, frame = cel.frameNumber, x = position.x, y = position.y,
      opacity = cel.opacity, zIndex = cel.zIndex, imageId = image.id, imageVersion = image.version,
      width = image.width, height = image.height, pixels = digest
    }
  end
  local palettes = sprite.palettes
  for p = 1, #palettes do
    local palette_doc = palettes[p]
    local colors = {}
    for i = 0, #palette_doc - 1 do
      local color = palette_doc:getColor(i)
      colors[#colors + 1] = { color.red, color.green, color.blue, color.alpha }
    end
    observation.palettes[#observation.palettes + 1] = { frame = palette_doc.frame.frameNumber, colors = colors }
  end
  return data, signature(observation)
end

--- Observe live native state and publish its revision after signature comparison. Throws for an invalid target.
function Executor:metadata()
  local sprite = self.sprite
  assert(sprite and sprite.isValid, "The target is closed or unbound; inspect again.")
  local data, current = self:_observe(sprite, true)
  if self.observed and self.observed ~= current then self.revision = self.revision + 1 end
  self.observed = current
  data.openSprites = open_sprites(sprite)
  data.revision = self.revision
  return data
end

-- Resolve the inspected sprite: without spriteId the bound target is required;
-- with it any open sprite qualifies, and only the bound target reports a revision.
function Executor:_sprite_for(args)
  if args.spriteId == nil then
    local sprite = self.sprite
    assert(sprite and sprite.isValid, "The target is closed or unbound; inspect again.")
    return sprite, true
  end
  assert(integer(args.spriteId) and args.spriteId >= 1, "spriteId must be a positive integer.")
  local sprite = open_sprite(args.spriteId)
  assert(sprite, "Sprite is not open; use openSprites.")
  return sprite, self.sprite ~= nil and sprite == self.sprite and sprite.isValid
end

--- Return live metadata and independent RGB PNG previews; never saves or flattens the source document.
function Executor:read(args)
  local ok, value = pcall(function()
    assert(args == nil or arguments_object(args), "read_sprite arguments must be an object.")
    args = args or {}
    local sprite, target = self:_sprite_for(args)
    local data = target and self:metadata() or self:_observe(sprite, false)
    data.target = target
    data.openSprites = open_sprites(self.sprite)
    local frames = frames_for(args, sprite, target and self.frame.frameNumber or 1)
    local isolated
    if args.layers ~= nil then isolated = selected_layers(sprite, array_of(args.layers, "layers")) end
    local region
    if args.region ~= nil then
      assert(arguments_object(args.region), "region must be an object.")
      region = { x = args.region.x, y = args.region.y, width = args.region.width, height = args.region.height }
      assert(integer(region.x) and integer(region.y) and integer(region.width) and integer(region.height)
        and region.width >= 1 and region.height >= 1,
        "region requires integer x, y, width, height.")
    end
    if args.grid ~= nil then
      assert(integer(args.grid) and args.grid >= 1, "grid must be a positive integer.")
    end
    local renders = {}
    for i, frame in ipairs(frames) do
      local image = isolated and render_layers(sprite, frame, isolated) or render_frame(sprite, frame)
      if region then image = crop(image, region, sprite) end
      renders[i] = image
    end
    local scale = choose_scale(renders[1].width, renders[1].height, #renders)
    local grid_skipped = false
    for _, image in ipairs(renders) do
      rescale(image, scale)
      if args.grid then
        if scale >= 4 then apply_grid(image, args.grid * scale) else grid_skipped = true end
      end
    end
    local sheets, layout = pack_sheets(renders, frames)
    local seen = {}
    for _, frame in ipairs(frames) do seen[frame] = true end
    data.cels = {}
    for _, cel in ipairs(sprite.cels) do
      if seen[cel.frameNumber] then
        data.cels[#data.cels + 1] = { layer = cel.layer.id, frame = cel.frameNumber,
          x = cel.position.x, y = cel.position.y,
          width = cel.image.width, height = cel.image.height, opacity = cel.opacity }
      end
    end
    data.frame = frames[1]
    data.selectedFrames = frames
    data.scale = scale
    data.layout = layout
    if args.grid then data.grid = grid_skipped and "skipped (scale < 4)" or args.grid end
    data.preview = { width = sheets[1].width, height = sheets[1].height }
    local response = result(true, json.encode(data))
    for _, sheet in ipairs(sheets) do
      response.contentItems[#response.contentItems + 1] = { type = "inputImage", imageUrl = png_data_url(sheet) }
    end
    return response
  end)
  return ok and value or result(false, tostring(value))
end

--- Read exact pixel values without approval or revision; see Executor.tools for the contract.
function Executor:read_pixels(args)
  local ok, value = pcall(function()
    assert(arguments_object(args), "read_pixels arguments must be an object.")
    local sprite, target = self:_sprite_for(args)
    local x, y, w, h = args.x, args.y, args.width, args.height
    assert(integer(x) and integer(y) and integer(w) and integer(h) and w >= 1 and h >= 1
      and w * h <= 4096, "width*height must not exceed 4096.")
    local frame = args.frame or (target and self.frame.frameNumber or 1)
    assert(integer(frame) and frame >= 1 and frame <= #sprite.frames,
      "Frame must be a 1-based integer within the sprite.")
    local format, sample
    if args.layer ~= nil then
      local layer = find_layer(sprite.layers, args.layer)
      assert(layer, "Unknown layer id: " .. tostring(args.layer))
      assert(not layer.isGroup, "layer must name a non-group layer id.")
      local cel = layer:cel(frame)
      local image, position = cel and cel.image, cel and cel.position or Point(0, 0)
      local function pixel_at(sx, sy)
        if not image then return nil end
        local ix, iy = sx - position.x, sy - position.y
        if ix < 0 or iy < 0 or ix >= image.width or iy >= image.height then return nil end
        return image:getPixel(ix, iy)
      end
      if sprite.colorMode == ColorMode.INDEXED then
        format = "index"
        local transparent = sprite.transparentColor
        sample = function(sx, sy) return pixel_at(sx, sy) or transparent end
      elseif sprite.colorMode == ColorMode.GRAY then
        format = "gray"
        sample = function(sx, sy)
          local pixel = pixel_at(sx, sy)
          return pixel and string.format("#%02x%02x",
            app.pixelColor.grayaV(pixel), app.pixelColor.grayaA(pixel)) or "#0000"
        end
      else
        format = "rgba"
        sample = function(sx, sy)
          local pixel = pixel_at(sx, sy)
          return pixel and rgba_hex(pixel) or "#00000000"
        end
      end
    else
      format = "rgba"
      local canvas = render_frame(sprite, frame)
      sample = function(sx, sy)
        if sx < 0 or sy < 0 or sx >= canvas.width or sy >= canvas.height then return "#00000000" end
        return rgba_hex(canvas:getPixel(sx, sy))
      end
    end
    local rows = {}
    for j = 0, h - 1 do
      local row = {}
      for i = 0, w - 1 do row[#row + 1] = sample(x + i, y + j) end
      rows[#rows + 1] = row
    end
    return result(true, json.encode { spriteId = sprite.id, frame = frame, layer = args.layer,
      x = x, y = y, width = w, height = h, format = format, rows = rows })
  end)
  return ok and value or result(false, tostring(value))
end

--- Activate another open sprite and rebind the executor to it, returning fresh metadata.
function Executor:switch(args)
  local ok, value = pcall(function()
    assert(arguments_object(args), "switch_sprite arguments must be an object.")
    local id = args.spriteId
    assert(integer(id) and id >= 1, "spriteId must be a positive integer.")
    local sprite = open_sprite(id)
    assert(sprite, "Sprite is not open; use openSprites.")
    if app.sprite ~= sprite then app.sprite = sprite end
    self:bind(sprite, app.frame, app.layer)
    return result(true, json.encode(self:metadata()))
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
