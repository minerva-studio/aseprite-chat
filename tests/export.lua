local root = app.fs.filePath(app.fs.filePath(debug.getinfo(1, "S").source:sub(2)))
local tests, passed, writers, sprites = {}, 0, {}, {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function eq(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function writer()
  assert(app.fs.isFile(app.fs.joinPath(root, "export.lua")), "export module is not implemented")
  local w = dofile(app.fs.joinPath(root, "export.lua")).new()
  writers[#writers + 1] = w
  return w
end
local function image(w, h, color)
  local result = Image(w or 3, h or 2, ColorMode.RGB)
  if color then result:clear(color) end
  return result
end
local function contents(path)
  local f = assert(io.open(path, "rb")); local text = f:read("a"); f:close(); return text
end
local function rejected(body, pattern)
  local ok, err = pcall(body)
  assert(not ok, "invalid export unexpectedly succeeded")
  if pattern then assert(tostring(err):lower():find(pattern:lower()), tostring(err)) end
end
local red, blue = app.pixelColor.rgba(213, 37, 91, 255), app.pixelColor.rgba(13, 57, 211, 255)

test("PNG frames preserve dimensions alpha duplicate order and millisecond timing", function()
  local w = writer()
  local first, second = image(3, 2), image(3, 2, blue)
  first:drawPixel(1, 0, app.pixelColor.rgba(11, 29, 53, 101))
  local r = w:write({ second, first, second }, { 5, 2, 5 }, { .123, .237, .08 }, {})
  eq(r.format, "png"); eq(r.output, "frames"); eq(r.width, 3); eq(r.height, 2)
  eq(#r.files, 3); eq(#r.frames, 3)
  local expected = { blue, app.pixelColor.rgba(11, 29, 53, 101), blue }
  for i, file in ipairs(r.files) do
    eq(app.fs.fileName(file.path), string.format("frame-%04d.png", i))
    eq(r.frames[i].path, file.path); eq(r.frames[i].frame, ({5, 2, 5})[i])
    eq(r.frames[i].duration, ({123, 237, 80})[i])
    local decoded = Image { fromFile = file.path }
    eq(decoded.width, 3); eq(decoded.height, 2); eq(decoded:getPixel(1, 0), expected[i])
  end
  eq(Image { fromFile = r.files[2].path }:getPixel(0, 1), 0)
  local dir = app.fs.filePath(r.files[1].path)
  assert(dir:find("aseprite%-chat%-export%-"))
  eq(w:clear(), true); assert(not app.fs.isDirectory(dir)); eq(w:clear(), true)
end)

test("PNG sheets use transparent padding and independent standard JSON coordinates", function()
  local w = writer()
  local r = w:write({image(3,2,red), image(3,2,blue), image(3,2,red)}, {3,1,3}, {.1,.2,.3},
    {output="sheet", columns=2, padding=1, metadata=true, scale=2})
  eq(r.width, 7); eq(r.height, 5); eq(#r.files, 2)
  eq(app.fs.fileName(r.files[1].path), "sheet.png")
  eq(app.fs.fileName(r.files[2].path), "sheet.json")
  local sheet = Image { fromFile=r.files[1].path }
  eq(sheet.width, 7); eq(sheet.height, 5)
  eq(sheet:getPixel(3,0),0); eq(sheet:getPixel(0,2),0); eq(sheet:getPixel(4,3),0)
  eq(sheet:getPixel(0,0),red); eq(sheet:getPixel(4,0),blue); eq(sheet:getPixel(0,3),red)
  local data = json.decode(contents(r.files[2].path))
  eq(data.meta.image,"sheet.png"); eq(data.meta.format,"RGBA8888"); eq(data.meta.scale,"2")
  eq(data.meta.size.w,7); eq(data.meta.size.h,5); eq(#data.frames,3)
  for i, coords in ipairs({{0,0},{4,0},{0,3}}) do
    local f, j = r.frames[i], data.frames[i]
    eq(f.x,coords[1]); eq(f.y,coords[2]); eq(f.width,3); eq(f.height,2)
    eq(j.filename,string.format("frame-%04d",i)); eq(j.sourceFrame,({3,1,3})[i])
    eq(j.frame.x,coords[1]); eq(j.frame.y,coords[2]); eq(j.frame.w,3); eq(j.frame.h,2)
    eq(j.rotated,false); eq(j.trimmed,false); eq(j.spriteSourceSize.x,0); eq(j.spriteSourceSize.y,0)
    eq(j.spriteSourceSize.w,3); eq(j.spriteSourceSize.h,2); eq(j.sourceSize.w,3); eq(j.sourceSize.h,2)
    eq(j.duration,({100,200,300})[i])
  end
end)

test("sheet defaults columns to ceiling square root and clamps explicit columns", function()
  local w = writer(); local im=image(2,1,red)
  local r=w:write({im,im,im},{1,2,3},{.1,.1,.1},{output="sheet"})
  eq(r.width,4); eq(r.height,2); eq(#r.files,1); eq(r.frames[3].y,1)
  local other=w:write({im,im},{2,2},{.1,.1},{output="sheet",columns=99})
  eq(other.width,4); eq(other.height,1)
end)

test("layout validation rejects incompatible options and bounded allocation overflow", function()
  local w = writer(); local im=image(2,2)
  for _,args in ipairs({{format="jpg"},{output="bad"},{format="gif",output="sheet"},
    {metadata=true},{metadata="yes",output="sheet"},{columns=0},{columns=1.5},{padding=-1},
    {padding=.5},{output="sheet",padding=16384},{output="sheet",columns=2,padding=16381}}) do
    rejected(function() w:write({im,im},{1,2},{.1,.1},args) end)
  end
  rejected(function() w:write({}, {}, {}, {}) end)
  rejected(function() w:write({im,image(1,1)},{1,2},{.1,.1},{}) end)
  rejected(function() w:write({im},{1},{},{}) end)
  local huge=image(4096,4096)
  rejected(function() w:write({huge,huge},{1,2},{.1,.1},{}) end,"pixel")
  local narrow=image(16385,1)
  rejected(function() w:write({narrow},{1},{.1},{}) end)
  -- Real inputs fit the render budget, but the proposed sheet does not.
  local small=image(1,1)
  rejected(function() w:write({small,small,small,small},{1,2,3,4},{.1,.1,.1,.1},
    {output="sheet",columns=2,padding=4095}) end,"pixel")
end)

test("GIF decodes native colors frame order transparency timing and restores source editor", function()
  local w = writer()
  local source = Sprite(4,3); sprites[#sprites+1]=source
  source:newEmptyFrame(); local layer=source:newLayer()
  source:newCel(layer,2,image(4,3,red)); app.frame=2; app.layer=layer
  local filename,modified,steps,count = source.filename,source.isModified,source.undoHistory.undoSteps,#app.sprites
  local first=image(3,2,blue); first:drawPixel(2,1,0)
  local second=image(3,2,red); second:drawPixel(2,1,0)
  local r=w:write({first,second,first},{7,2,7},{.123,.237,.08},{format="gif"})
  eq(app.sprite,source); eq(app.frame.frameNumber,2); eq(app.layer,layer); eq(#app.sprites,count)
  eq(source.filename,filename); eq(source.isModified,modified); eq(source.undoHistory.undoSteps,steps)
  eq(layer:cel(2).image:getPixel(0,0),red)
  eq(r.format,"gif"); eq(r.output,"frames"); eq(r.width,3); eq(r.height,2); eq(#r.files,1)
  eq(app.fs.fileName(r.files[1].path),"animation.gif")
  assert(contents(r.files[1].path):sub(1,6):match("^GIF8[79]a$"))
  for i,f in ipairs(r.frames) do eq(f.frame,({7,2,7})[i]); eq(f.path,r.files[1].path) end
  local decoded=Sprite{fromFile=r.files[1].path}; sprites[#sprites+1]=decoded
  eq(#decoded.frames,3); eq(decoded.width,3); eq(decoded.height,2)
  for i,f in ipairs(decoded.frames) do
    local rgb=image(3,2); rgb:drawSprite(decoded,i)
    eq(rgb:getPixel(0,0),({blue,red,blue})[i]); eq(rgb:getPixel(2,1),0)
    eq(math.floor(f.duration*1000+.5),({120,230,80})[i])
  end
end)

test("layout rejects false defaults and integer overflow before native allocation", function()
  local w=writer(); local im=image(1,1)
  for _,args in ipairs({{format=false},{output=false},{columns=false},{padding=false}}) do
    rejected(function() w:write({im},{1},{.1},args) end)
  end
  rejected(function() w:write({im,im,im,im,im},{1,2,3,4,5},{.1,.1,.1,.1,.1},
    {output="sheet",columns=5,padding=4611686018427387904}) end)
end)

test("GIF encodes a native RGB color grid instead of the default palette", function()
  local w=writer(); local grid=image(16,16)
  for y=0,14 do for x=0,15 do
    grid:drawPixel(x,y,app.pixelColor.rgba(7+x*16,9+y*16,43,255))
  end end
  local bytes,id=grid.bytes,grid.id; local count=#app.sprites; local active=app.sprite
  local r=w:write({grid},{8},{.1},{format="gif"})
  eq(grid.bytes,bytes); eq(grid.id,id); eq(#app.sprites,count); eq(app.sprite,active)
  local decoded=Sprite{fromFile=r.files[1].path}; sprites[#sprites+1]=decoded
  local rgb=image(16,16); rgb:drawSprite(decoded,1)
  for y=0,14 do for x=0,15 do
    eq(rgb:getPixel(x,y),app.pixelColor.rgba(7+x*16,9+y*16,43,255))
  end end
  eq(rgb:getPixel(0,15),0)
end)

test("GIF failed native save restores editor and deletes its partial output and scratch", function()
  local w=writer(); local source=Sprite(2,2); sprites[#sprites+1]=source
  source:newEmptyFrame(); local layer=source:newLayer(); app.frame=2; app.layer=layer
  local steps,filename,modified,count=source.undoHistory.undoSteps,source.filename,source.isModified,#app.sprites
  local original=Sprite; local attempted
  -- Only the native save boundary fails; scratch creation, cels, save, and close are real.
  Sprite=setmetatable({}, {__call=function(_,...)
    local native=original(...)
    return setmetatable({}, {
      __index=function(_,key)
        if key=="saveAs" then return function(_,path)
          attempted=path; native:saveAs(path); error("injected partial GIF failure")
        end end
        local value=native[key]
        if type(value)=="function" then return function(_,...) return value(native,...) end end
        return value
      end,
    })
  end})
  local ok,err=pcall(function()
    rejected(function() w:write({image(),image()},{1,2},{.1,.2},{format="gif"}) end,"partial GIF")
  end)
  Sprite=original; assert(ok,err)
  assert(attempted); assert(not app.fs.isDirectory(app.fs.filePath(attempted)))
  eq(#app.sprites,count); eq(app.sprite,source); eq(app.frame.frameNumber,2); eq(app.layer,layer)
  eq(source.undoHistory.undoSteps,steps); eq(source.filename,filename); eq(source.isModified,modified)
end)

test("separate calls own unique directories and never clear foreign files", function()
  local w,other=writer(),writer(); local im=image()
  local a=w:write({im},{1},{.1},{})
  local b=w:write({im},{1},{.1},{})
  local c=other:write({im},{1},{.1},{})
  assert(a.files[1].path~=b.files[1].path and a.files[1].path~=c.files[1].path)
  local dir=app.fs.filePath(a.files[1].path)
  local foreign=app.fs.joinPath(dir,"foreign.txt")
  local f=assert(io.open(foreign,"w")); f:write("keep"); f:close()
  local ok=w:clear(); eq(ok,false)
  eq(contents(foreign),"keep"); assert(app.fs.isFile(c.files[1].path))
  assert(not app.fs.isFile(a.files[1].path)); assert(not app.fs.isDirectory(app.fs.filePath(b.files[1].path)))
  assert(os.remove(foreign)); eq(w:clear(),true); assert(not app.fs.isDirectory(dir))
end)

test("cleanup retries a failed owned deletion", function()
  local w=writer(); local r=w:write({image()},{1},{.1},{})
  local path=r.files[1].path; local remove=os.remove
  os.remove=function(p) if p==path then return nil,"injected locked file" end return remove(p) end
  local ok,err=pcall(function() eq(w:clear(),false); assert(app.fs.isFile(path)) end)
  os.remove=remove; assert(ok,err)
  eq(w:clear(),true); assert(not app.fs.isDirectory(app.fs.filePath(path)))
end)

test("partial write failure removes only that call and preserves earlier exports", function()
  local w=writer(); local im=image()
  local first=w:write({im},{1},{.1},{})
  local attempted={}
  -- Native save is exercised, then its result is failed at the module boundary.
  local wrapped=setmetatable({width=3,height=2,colorMode=ColorMode.RGB}, {__index=function(_,key)
    if key=="saveAs" then return function(_,path)
      attempted[#attempted+1]=path
      im:saveAs(path)
      if #attempted==2 then error("injected partial PNG failure") end
      return true
    end end
  end})
  local ok,err=pcall(function()
    rejected(function() w:write({wrapped,wrapped},{1,2},{.1,.1},{}) end,"partial")
  end)
  assert(ok,err)
  eq(#attempted,2)
  assert(not app.fs.isDirectory(app.fs.filePath(attempted[1])))
  assert(app.fs.isFile(first.files[1].path))
end)

test("failed partial cleanup remains owned and is removed by a later clear", function()
  local w=writer(); local im=image(); local attempted
  local wrapped={width=3,height=2,colorMode=ColorMode.RGB,saveAs=function(_,path)
    attempted=path; im:saveAs(path); error("injected partial export")
  end}
  local remove=os.remove
  os.remove=function(path) if path==attempted then return nil,"injected locked file" end return remove(path) end
  local ok,err=pcall(function()
    rejected(function() w:write({wrapped},{1},{.1},{}) end,"Cleanup")
    assert(attempted and app.fs.isFile(attempted))
  end)
  os.remove=remove; assert(ok,err)
  eq(w:clear(),true)
  assert(not app.fs.isDirectory(app.fs.filePath(attempted)))
end)

test("retry cleanup preserves exports created after the failed boundary",function()
  local w=writer(); local old=w:write({image()},{1},{.1},{})
  local path=old.files[1].path; local remove=os.remove
  os.remove=function(p) if p==path then return nil,"locked fixture" end return remove(p) end
  local ok,err=pcall(function() eq(w:clear(),false) end)
  os.remove=remove; assert(ok,err)
  local fresh=w:write({image()},{2},{.1},{})
  eq(w:clear(true),true)
  assert(not app.fs.isFile(path))
  assert(app.fs.isFile(fresh.files[1].path),"retry deleted a later conversation export")
end)

for _, item in ipairs(tests) do
  local ok,err=xpcall(item[2],debug.traceback)
  for _,w in ipairs(writers) do w:clear() end
  writers={}
  for i=#sprites,1,-1 do if sprites[i].isValid then sprites[i]:close() end end
  sprites={}
  if ok then passed=passed+1; print("PASS "..item[1])
  else print("FAIL "..item[1].."\n"..tostring(err)) end
end
print("export: "..passed.."/"..#tests.." tests passed")
assert(passed==#tests,"export test failures")
