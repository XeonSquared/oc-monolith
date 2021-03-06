-- FLED: Fullscreen Lua EDitor --

local args = {...}

local w, h = io.output().gpu.getResolution() -- tee hee hee --rsp:match("\27%[(%d+);(%d+)R")
w = tonumber(w)
h = tonumber(h)

local readline = require("readline").readline

local buf = {}
local cur = 1

local opts = {
  arrows = {
    up = function()
      if buf[cur] then
        if buf[cur].scroll > 0 then
          buf[cur].scroll = buf[cur].scroll - 1
        end
      end
    end,
    down = function()
      if buf[cur] then
        if buf[cur].scroll <= #buf[cur].buffer - (h - 2) then
          buf[cur].scroll = buf[cur].scroll + 1
        end
      end
    end
  }
}

local function promptread()
  return readline(string.format("\27[%d;1H\27[91m:\27[37m", h), opts)
end

local function lineread(line, y)
  return readline(string.format("\27[%d;1H\27[91m%4d \27[37m", y, line), opts)
end

local function split(w)
  local W = {}
  for _w in w:gmatch("[^ \n]+") do
    table.insert(W, _w)
  end
  return W
end

local function fload(f)
  local handle, err = io.open(f, 'r')
  if not handle then return nil, err end
  local nb = #buf + 1
  local b = {}
  for line in handle:lines() do
    b[#b+1] = line .. "\n"
  end
  handle:close()
  buf[nb] = {scroll = 0, vscroll = 0, buf = b, name = f, lang = f:match("[%g]%.(%g+)")}
  return nb
end

local function fsave(b,f)
  b=tonumber(b)or cur
  if not buf[b] then return nil, "no such buffer" end
  while (not f or f == "") and not buf[b].name do
    f = io.read():gsub("\n", "")
  end
  buf[b].name = buf[b].name or f
  local hdl, err = io.open(f or buf[b].name, "w")
  if hdl then
    hdl:write(table.concat(buf[b].buf))
    hdl:close()
    return true
  end
  return nil, err
end

local function bnew(n)
  local nb = #buf + 1
  buf[nb] = {scroll = 0, vscroll = 0, buf = {}, lang = (n or ""):match("[%g]%.(%g+)") or "txt", name = n}
  return nb, buf[nb].lang
end

local function bname(b,n)
  b=tonumber(b)or cur
  if not buf[b] then return nil, "no such buffer" end
  buf[b].name = n
end

local function blist()
  for id,b in ipairs(buf) do
    print(string.format("\27[91m%02d.\27[37m %s", id, b.name))
  end
end

local function ndraw(y,l,n,v)
  io.write(string.format("\27[%d;1H\27[2K\27[91m%4d\27[37m %s", y, n, l))
end

local function tdraw(y)
  io.write(string.format("\27[%d;1H\27[2K\27[93m   ~\27[37m", y))
end

local function bdraw(b)
  b=tonumber(b)or cur
  if not buf[b] then return nil, "no such buffer" end
  local b = buf[b]
  local s = b.scroll
  local n = #b.buf
  --local hl = langs[b.lang] or langs["txt"]
  for i=1, h - 1, 1 do
    if b.buf[i+s] then
      ndraw(i, b.buf[i+s], i+s, b.vscroll)
    else
      tdraw(i)
    end
  end
  if #b.buf >= (s + h - 1) then return s + h - 1 else return #b.buf - s end
end

local function binst(b, l)
  b,l=tonumber(b),tonumber(l) or 1
  if not buf[b] then return nil, "no such buffer" end
  bdraw(b)
  local _b=buf[b]
  local c = l
  while true do
    opts.text = _b.buf[c] or ""
    local ln = lineread(c, c - _b.scroll)
    if ln:sub(1,1) == "." then break end
    table.insert(_b.buf,c,ln)
    c=c+1
    local bot = bdraw(b)
    if bot > h - 1 then
      _b.scroll = _b.scroll +  1
    end
  end
end

local help = [[FLED - Fullscreen Lua EDitor (c) 2020 Ocawesome101 under the MIT license.
Commands:
  o | open <file>       Open <file> for editing. <file> must exist in your filesystem.
  n | new  [name]       Create a new buffer with filename [name]. If no [name] is provided you will be prompted when saving.
  w | save [file]       Save the current buffer to a file. If no [file] is provided and the buffer has no name you will be prompted.
  b        <num>        Selects buffer <num> as the current.
  bl                    Lists all loaded buffers.
  db       <num>        Delete buffer <num>.
  i        [line]       Insert into the current buffer at [line], or line 1.
  q                     Quit. Do not save any buffers.
  wq                    Quit. Save all open buffers.
  l                     Prints the number of lines in the current buffer.
  dl       [line]       Delete line ([line] or 1) from the current buffer.
  sc       [line]       Scroll to line [line], or line 1. [line] will be the top line of the screen.]]
local exit = false
local funcs = {
  help = function()return help end,
  h = function()return help end,
  open = fload,
  o = fload,
  new = bnew,
  n = bnew,
  save = function(f)return fsave(cur,f)end,
  w = function(f)return fsave(cur,f)end,
  b = function(n)if not buf[tonumber(n)]then return nil, "no such buffer" end cur = n bdraw(cur) return true end,
  bl = blist,
  db = function(n)n=tonumber(n)if not n then return nil, "too few arguments" end if not buf[n] then return nil, "no such buffer" end buf[n] = nil return true end,
  i = function(n)return binst(cur,n)end,
  q = function()exit = true end,
  l = function()if buf[cur] then print(#buf[cur].buf) return end return nil, "no buffer selected" end,
  dl = function(n)n=tonumber(n)or 1 if buf[cur] and buf[cur].buf[n] then table.remove(buf[cur].buf, n) end end,
  sc = function(l) --[[scroll]] l = tonumber(l) or 1 if not buf[cur] then return nil, cur .. " has no buffer" end if l > #buf[cur].buf then return nil, "no such line" end buf[cur].scroll = l bdraw(cur) end,
  wq = function()for id, b in pairs(buf) do fsave(id) end exit = true end,
  ["\27[B"] = function()if buf[cur] then buf[cur].scroll = buf[cur].scroll + 1 end bdraw() end,
  ["\27[A"] = function()if buf[cur] and buf[cur].scroll > 0 then buf[cur].scroll = buf[cur].scroll - 1 bdraw() end end
}

io.write("\27[2J")

if args[1] then cur = fload(args[1]) bdraw(cur) end
while not exit do
  local cmd = promptread():gsub("\n", "")
  if cmd ~= "" then
    local c = split(cmd)
    if c[1] then
      local ok, err, msg = xpcall(funcs[c[1]], debug.traceback, table.unpack(c, 2))
      if err or msg then
        print(err, msg)
      end
    end
  end
end

io.write("\27[2J")
