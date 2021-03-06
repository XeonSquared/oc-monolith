-- relatively flexible readline implementation --

local component = require("component")
local thread = require("thread")
local rl = {}

local buffers = {}
--[[setmetatable(buffers, {__index = function(tbl, k)
  local n = {keyboards = {}, down = {}, buffer = ""}
  buffers[k] = n
  return n
end})]]

local replacements = {
  [200] = "\27[A", -- up
  [201] = "\27[5", -- page up
  [203] = "\27[D", -- left
  [205] = "\27[C", -- right
  [208] = "\27[B", -- down
  [209] = "\27[6"  -- page down
}

-- setup the metatable for convenience
setmetatable(replacements, {__index = function() return "" end})

-- first, we need to set up the key listener
-- on a keypress, this does a couple of things
-- 1. it checks if the keyboard is registered
-- 2. if the keyboard is registered, it checks the character code
-- 3. if the character code is >0, we concatenate it to the screen's buffer with string.char, else goto step 4
-- 4. if the character code is 0, we concatenate one of the keycode replacements, or nothing
local function listener()
  while true do
    local signal, keyboard, character, keycode = coroutine.yield()
    if signal == "key_down" and buffers[keyboard] then
      local screen = buffers[keyboard]
      --if character == 13 or keycode == 28 then character = 10 end -- if enter, just write a newline
      local concat = string.char(character)
      if character == 0 then
        concat = replacements[keycode]
      end
      buffers[screen].buffer = buffers[screen].buffer .. concat
      buffers[screen].down[keycode] = true
    elseif signal == "key_up" and buffers[keyboard] then
      local screen = buffers[keyboard]
      buffers[screen].down[keycode] = false
    elseif signal == "clipboard" and buffers[keyboard] then
      local screen = buffers[keyboard]
      buffers[screen].buffer = buffers[screen].buffer .. character
    end
  end
end

thread.spawn(listener, "readline")

function rl.addscreen(screen, gpu)
  checkArg(1, screen, "string")
  checkArg(2, gpu, "string", "table")
  if buffers[screen] then return true end
  if type(gpu) == "string" then
    gpu = assert(component.proxy(gpu))
  end
  buffers[screen] = {keyboards = {}, down = {}, buffer = ""}
  buffers[gpu] = buffers[screen]
  for k, v in pairs(component.invoke(screen, "getKeyboards")) do
    buffers[screen].keyboards[v] = true
    buffers[v] = screen
  end
  return true
end

-- basic readline function similar to the original vt100.session one
function rl.readlinebasic(screen, n)
  checkArg(1, screen, "string")
  checkArg(1, n, "number", "nil")
  if not buffers[screen] then
    return nil, "no such screen"
  end
  local buf = buffers[screen]
  while #buf.buffer < n or (not n and not buf.buffer:find("\n")) do
    --print("RLBY")
    coroutine.yield()
  end
  local n = n or buf.buffer:find("\n")
  local returnstr = buf.buffer:sub(1, n)
  if returnstr:sub(-1) == "\n" then returnstr = returnstr:sub(1,-2) end
  buf.buffer = buf.buffer:sub(n + 1)
  return returnstr
end

function rl.buffersize(screen)
  checkArg(1, screen, "string")
  if not buffers[screen] then
    return nil, "no such screen"
  end
  return buffers[screen].buffer:len()
end

-- fancier readline designed to be used directly
function rl.readline(prompt, opts)
  checkArg(1, prompt, "string", "number", "table", "nil")
  checkArg(2, opts, "table", "nil")
  local screen = io.output().screen
  if type(prompt) == "table" then opts = prompt prompt = nil end
  if type(prompt) == "number" then return rl.readlinebasic(screen, prompt) end
  opts = opts or {}
  local pwchar = opts.pwchar or nil
  local history = opts.history or {}
  local ent = #history + 1
  local prompt = prompt or opts.prompt
  local arrows = opts.arrows
  if arrows == nil then arrows = true end
  local pos = 1
  local buffer = ""
  local acts = opts.acts or opts.actions or 
    {
      up = function()
        if ent > 1 then
          ent = ent - 1
          buffer = history[ent] or ""
        end
      end,
      down = function()
        if ent <= #history then
          ent = ent + 1
          buffer = history[ent] or ""
        end
      end,
      left = function()
        if pos <= #buffer then
          pos = pos + 1
        end
      end,
      right = function()
        if pos > 1 then
          pos = pos - 1
        end
      end
    }
  if not buffers[screen] then
    rl.addscreen(screen, io.output().gpu)
  end
  -- this lets us get a direct response from the terminal, which is nice
  local resp = io.output().stream:write("\27[6n")
  local y, x = resp:match("\27%[(%d+);(%d+)R")
  local w, h = io.output().gpu.getResolution() -- :^)
  local sy = tonumber(y) or 1
  prompt = prompt or ("\27[C"):rep((tonumber(x) or 1))
  local function redraw()
    local write = buffer
    if pwchar then write = pwchar:rep(#buffer) end
    io.write(string.format("\27[%d;%dH%s%s \27[2K", sy, 1, prompt, write))
    --local span = math.max(1, math.ceil(#prompt + #buffer / w))
    io.write(string.rep("\8", pos)) -- move the cursor to where it should be
  end
  while true do
    redraw()
    local char, err = rl.readlinebasic(screen, 1)
    --coroutine.yield()
    if char == "\27" then
      if arrows then -- ANSI escape start
        local esc = rl.readlinebasic(screen, 2)
        if esc == "[A" and acts.up then
          pcall(acts.up)
        elseif esc == "[B" and acts.down then
          pcall(acts.down)
        elseif esc == "[C" then
          pcall(acts.right)
        elseif esc == "[D" then
          pcall(acts.left)
        end
      else
        buffer = buffer .. "^"
      end
    elseif char == "\8" then
      if #buffer > 0 and pos <= #buffer then
        buffer = buffer:sub(1, (#buffer - pos)) .. buffer:sub((#buffer - pos) + 2)
      end
    elseif char == "\127" then
      buffer = buffer .. ""
    elseif char == "\13" or char == "\10" or char == "\n" then
      table.insert(history, buffer)
      buffer = buffer .. "\n"
      redraw()
      if opts.notrail then buffer = buffer:sub(1, -2) end
      return buffer, history
    else
      buffer = buffer:sub(1, (#buffer - pos) + 1) .. char .. buffer:sub((#buffer - pos) + 2)
    end
  end
end

-- we don't need readlinebasic
return { readline = rl.readline, addscreen = rl.addscreen, buffersize = rl.buffersize }
