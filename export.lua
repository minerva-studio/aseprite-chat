local Export = {}
local MAX_PIXELS, MAX_DIMENSION = 16777216, 16384

local function integer(value, minimum, name)
  assert(type(value) == "number" and value < math.huge and value == math.floor(value)
    and value >= minimum, name .. " must be an integer >= " .. minimum)
  return value
end

local function bounded(width, height, name)
  assert(width <= MAX_DIMENSION and height <= MAX_DIMENSION, name .. " dimensions exceed 16384")
  assert(width * height <= MAX_PIXELS, name .. " pixel limit exceeded")
end

-- Each writer owns only paths it created in fresh, per-call temporary directories.
-- write() accepts detached, equally sized RGB Images; it never crops or scales.
-- Defaults: format="png", output="frames", columns=ceil(sqrt(n)), padding=0,
-- metadata=false. GIF supports frames only; JSON metadata supports PNG sheets only.
-- clear() marks the current owned set for cleanup and returns (success, errors).
-- clear(true) retries only that pending set, preserving files created after the boundary.
-- Failed deletions stay tracked for the next retry; paths have one authoritative owner.
function Export.new()
  local owned = {}
  local writer = {}

  local function clean(record)
    local failures = {}
    for i = #record.files, 1, -1 do
      local path = record.files[i]
      local ok, err = pcall(function()
        if app.fs.isFile(path) then
          local removed, why = os.remove(path)
          assert(removed, why or "cannot delete export file")
        end
        assert(not app.fs.isFile(path) and not app.fs.isDirectory(path), "export path still exists")
      end)
      if ok then table.remove(record.files, i)
      else failures[#failures + 1] = path .. ": " .. tostring(err) end
    end
    if #record.files == 0 then
      local ok, err = pcall(function()
        -- Never enumerate or recursively delete directory contents: foreign files survive.
        if app.fs.isDirectory(record.directory) then app.fs.removeDirectory(record.directory) end
        assert(not app.fs.isDirectory(record.directory), "export directory is not empty or cannot be removed")
      end)
      if ok then return true, failures end
      failures[#failures + 1] = record.directory .. ": " .. tostring(err)
    end
    return false, failures
  end

  function writer:clear(pending_only)
    local failures = {}
    for i = #owned, 1, -1 do
      local record=owned[i]
      if not pending_only or record.pending_cleanup then
        record.pending_cleanup=true
        local done, errors = clean(record)
        if done then table.remove(owned, i) end
        for _, err in ipairs(errors) do failures[#failures + 1] = err end
      end
    end
    return #failures == 0, failures
  end

  -- Result frames retain source numbers (including duplicates) and durations in ms.
  -- Files are absolute paths; sheet frames add x/y/width/height, other frames add path.
  -- GIF uses native RGB quantization: <=256 colors, binary alpha, 10ms timing precision.
  function writer:write(renders, frames, durations, args)
    if args == nil then args = {} end
    assert(type(args) == "table", "export arguments must be a table")
    assert(type(renders) == "table" and #renders > 0, "export requires rendered frames")
    local n = #renders
    assert(type(frames) == "table" and #frames == n and type(durations) == "table"
      and #durations == n, "export frame and duration counts must match")
    local format = args.format == nil and "png" or args.format
    local output = args.output == nil and "frames" or args.output
    assert(format == "png" or format == "gif", "export format must be png or gif")
    assert(output == "frames" or output == "sheet", "export output must be frames or sheet")
    assert(format ~= "gif" or output == "frames", "GIF cannot be a sheet")
    assert(args.metadata == nil or type(args.metadata) == "boolean", "metadata must be a boolean")
    assert(not args.metadata or output == "sheet", "metadata is only supported for sheets")
    local columns = math.min(n, integer(args.columns == nil and math.ceil(math.sqrt(n)) or args.columns, 1, "columns"))
    local padding = integer(args.padding == nil and 0 or args.padding, 0, "padding")
    local width = integer(renders[1].width, 1, "render width")
    local height = integer(renders[1].height, 1, "render height")
    bounded(width, height, "render")
    assert(width * height * n <= MAX_PIXELS, "total render pixel limit exceeded")
    local result = { format = format, output = output, width = width, height = height, files = {}, frames = {} }
    for i, im in ipairs(renders) do
      assert(im.width == width and im.height == height and im.colorMode == ColorMode.RGB,
        "rendered frames must be equally sized RGB images")
      integer(frames[i], 1, "source frame")
      local seconds = durations[i]
      assert(type(seconds) == "number" and seconds > 0 and seconds < math.huge,
        "frame duration must be positive finite seconds")
      result.frames[i] = { frame = frames[i], duration = math.floor(seconds * 1000 + 0.5) }
    end
    if output == "sheet" then
      local rows = math.ceil(n / columns)
      -- Float arithmetic prevents Lua integer wrapping from bypassing bounds.
      result.width = width * columns + (padding + 0.0) * (columns - 1)
      result.height = height * rows + (padding + 0.0) * (rows - 1)
      bounded(result.width, result.height, "sheet")
    end

    local directory = app.fs.joinPath(app.fs.tempPath, "aseprite-chat-export-" .. tostring(Uuid()))
    assert(not app.fs.isFile(directory) and not app.fs.isDirectory(directory), "export directory already exists")
    app.fs.makeDirectory(directory)
    assert(app.fs.isDirectory(directory), "cannot create export directory")
    local record = { directory = directory, files = {} }
    owned[#owned + 1] = record
    local function file(name)
      local path = app.fs.joinPath(directory, name)
      record.files[#record.files + 1] = path -- Track before writing, including partial outputs.
      result.files[#result.files + 1] = { path = path }
      return path
    end
    local ok, err = xpcall(function()
      if output == "sheet" then
        local sheet = Image(result.width, result.height, ColorMode.RGB)
        local metadata = { frames = {}, meta = { image = "sheet.png", format = "RGBA8888",
          size = { w = result.width, h = result.height }, scale = tostring(args.scale or 1) } }
        for i, im in ipairs(renders) do
          local x, y = ((i - 1) % columns) * (width + padding), math.floor((i - 1) / columns) * (height + padding)
          sheet:drawImage(im, Point(x, y))
          local f = result.frames[i]
          f.x, f.y, f.width, f.height = x, y, width, height
          metadata.frames[i] = { filename = string.format("frame-%04d", i), sourceFrame = f.frame,
            frame = { x = x, y = y, w = width, h = height }, rotated = false, trimmed = false,
            spriteSourceSize = { x = 0, y = 0, w = width, h = height },
            sourceSize = { w = width, h = height }, duration = f.duration }
        end
        assert(sheet:saveAs(file("sheet.png")), "cannot save PNG sheet")
        if args.metadata then
          local handle = assert(io.open(file("sheet.json"), "wb"))
          local written, why = handle:write(json.encode(metadata))
          local closed, closeError = handle:close()
          assert(written, why); assert(closed, closeError)
        end
      elseif format == "png" then
        for i, im in ipairs(renders) do
          local path = file(string.format("frame-%04d.png", i))
          result.frames[i].path = path
          assert(im:saveAs(path), "cannot save PNG frame")
        end
      else
        local previousSprite, previousFrame, previousLayer = app.sprite, app.frame, app.layer
        local scratch
        local saved, saveError = xpcall(function()
          scratch = Sprite(width, height, ColorMode.RGB)
          for i, im in ipairs(renders) do
            if i > 1 then scratch:newEmptyFrame() end
            scratch:newCel(scratch.layers[1], i, im)
            scratch.frames[i].duration = result.frames[i].duration / 1000
          end
          local path = file("animation.gif")
          -- Saving RGB directly invokes Aseprite's native GIF palette generation.
          -- Converting to indexed first would quantize against the default palette.
          assert(scratch:saveAs(path), "cannot save GIF animation")
          for _, f in ipairs(result.frames) do f.path = path end
        end, debug.traceback)
        local finalized, finalError = pcall(function()
          if scratch and scratch.isValid then scratch:close() end
          app.sprite = previousSprite
          if previousSprite then app.frame = previousFrame; app.layer = previousLayer end
        end)
        assert(saved, saveError)
        assert(finalized, finalError)
      end
      for _, f in ipairs(result.files) do assert(app.fs.isFile(f.path), "export output file is missing") end
    end, debug.traceback)
    if not ok then
      record.pending_cleanup=true
      local done, errors = clean(record)
      if done then table.remove(owned) end
      if #errors > 0 then err = tostring(err) .. "\nCleanup: " .. table.concat(errors, "\n") end
      error(err, 0)
    end
    return result
  end
  return writer
end

return Export
