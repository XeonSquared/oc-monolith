-- The core --

_G._START = computer.uptime()

local flags = ... or {}
flags.init = flags.init or "/sbin/init.lua"
flags.quiet = flags.quiet or false

local _KERNEL_NAME = "Monolith"
local _KERNEL_REVISION = "7f227a1"
local _KERNEL_BUILDER = "ocawesome101@manjaro-pbp"
local _KERNEL_COMPILER = "luacomp 1.2.0"

_G._OSVERSION = string.format("%s revision %s (%s, %s)", _KERNEL_NAME, _KERNEL_REVISION, _KERNEL_BUILDER, _KERNEL_COMPILER)

_G.kernel = {}

kernel.info = {
  name          = _KERNEL_NAME,
  revision      = _KERNEL_REVISION,
  builder       = _KERNEL_BUILDER,
  compiler      = _KERNEL_COMPILER
}

if computer.setArchitecture then
  computer.setArchitecture("Lua 5.3")
end


-- bootlogger --

kernel.logger = {}
kernel.logger.log = function()end

do
  local y, w, h = 0
  local gpu = component.list("gpu")()
  local screen = component.list("screen")()
  if gpu and screen then
    gpu = component.proxy(gpu)
    gpu.bind(screen)
    w, h = gpu.maxResolution()
    gpu.setResolution(w, h)
    gpu.setForeground(0xDDDDDD)
    gpu.fill(1, 1, w, h, " ")
    local function log(msg)
      msg = string.format("[%3.3f] %s", computer.uptime() - _START, tostring(msg))
      if y == h then
        gpu.copy(1, 2, w, h, 0, -1)
        gpu.fill(1, h, w, 1, " ")
      else
        y = y + 1
      end
      gpu.set(1, y, msg)
    end
    function kernel.logger.log(msg)
      for line in msg:gmatch("[^\n]+") do
        log(line)
      end
    end
  end
end

kernel.logger.log(_OSVERSION)

function kernel.logger.panic(reason)
  reason = tostring(reason)
  kernel.logger.log("==== Crash ".. os.date() .." ====")
  local trace = debug.traceback(reason):gsub("\t", "  ")
  for line in trace:gmatch("[^\n]+") do
    kernel.logger.log(line)
  end
  kernel.logger.log("=========== End trace ===========")
  while true do computer.pullSignal(1) computer.beep(200, 1) end
end


-- component API metatable allowing component.filesystem, and component.get --

do
  function component.get(addr)
    checkArg(1, addr, "string")
    for ca, ct in component.list() do
      if ca:sub(1, #addr) == addr then
        return ca, ct
      end
    end
    return nil, "no such compoennt"
  end

  function component.isAvailable(name)
    checkArg(1, name, "string")
    local ok, comp = pcall(function()return component[name]end)
    return ok
  end

  local mt = {
    __index = function(tbl, k)
      local addr = component.list(k, true)()
      if not addr then
        error("component of type '" .. k .. "' not found")
      end
      tbl[k] = component.proxy(addr)
      return tbl[k]
    end
  }

  setmetatable(component, mt)
end

-- --#include "module/initfs.lua"

-- users --

do
  kernel.logger.log("initializing user subsystem")
  local cuid = 0

  local u = {}

  u.sha = {}
  u.passwd = {}
  u.psave = function()end

  local sha = u.sha
  local function hex(s)
    local r = ""
    for char in s:gmatch(".") do
      r = r .. string.format("%02x", char:byte())
    end
    return r
  end

  function u.authenticate(uid, password)
    checkArg(1, uid, "number")
    checkArg(2, password, "string")
    if not u.passwd[uid] then
      return nil, "no such user"
    end
    return hex(u.sha.sha256(password)) == u.passwd[uid].p, "invalid password"
  end

  function u.login(uid, password)
    local yes, why = u.authenticate(uid, password)
    if not yes then
      return yes, why or "invalid credentials"
    end
    cuid = uid
    return yes
  end

  function u.uid()
    return cuid
  end

  function u.add(password, cansudo)
    checkArg(1, password, "string")
    checkArg(2, cansudo, "boolean", "nil")
    if u.uid() ~= 0 then
      return nil, "only root can do that"
    end
    local nuid = #u.passwd + 1
    u.passwd[nuid] = {p = hex(u.sha.sha256(password)), c = (cansudo and true) or false}
    u.psave()
    return nuid
  end

  function u.del(uid)
    checkArg(1, uid, "number")
    if u.uid()  ~= 0 then
      return nil, "only root can do that"
    end
    if not u.passwd[uid] then
      return nil, "no such user"
    end
    u.passwd[uid] = nil
    u.psave()
    return true
  end

  -- run `func` as another user. Somewhat hacky.
  function u.sudo(func, uid, password)
    checkArg(1, func, "function")
    checkArg(2, uid, "number")
    checkArg(3, password, "string")
    if not u.passwd[u.uid()].c then
      return nil, "user is not allowed to sudo"
    end
    if hex(u.sha.sha256(password)) == u.passwd[u.uid()].p then
      local uuid = u.uid
      function u.uid()
        return uid
      end
      local s, r = pcall(func)
      u.uid = uuid
      return true, s, r
    end
    return nil, "permission denied"
  end

  kernel.users = u
end


-- kernel modules-ish --

do
  kernel.logger.log("initializing kernel module service")
  local m = {}
  local l = {}
  kernel.modules = l
  setmetatable(kernel, {__index = l})

  function m.load(mod)
    checkArg(1, mod, "string")
    if kernel.users.uid() ~= 0 then
      return nil, "permission denied"
    end
    local handle, err = kernel.filesystem.open("/lib/modules/" .. mod .. ".lua", "r")
    if not handle then
      return nil, err
    end
    local read = handle:read("*a")
    handle:close()
    local ok, err = load(read, "=" .. mod, "bt", _G)
    if not ok then
      return nil, err
    end
    l[mod] = ok()
    return true
  end

  function m.unload(mod)
    checkArg(1, mod, "string")
    if kernel.users.uid() ~= 0 then
      return nil, "permission denied"
    end
    l[mod] = nil
    return true
  end

  kernel.module = m
end


-- filesystem management --

do
  local fs = {}
--local log = component.sandbox.log
  local mounts = {}

  local protected = {
    "/boot",
    "/sbin",
    "/initramfs.bin"
  }

  local function split(path)
    local segments = {}
--  log("split " .. path)
    for seg in path:gmatch("[^/]+") do
      if seg == ".." then
        table.remove(segments, #segments)
      else
        table.insert(segments, seg)
      end
    end
    return segments
  end

  function fs.name(path)
    checkArg(1, path, "string")
    local s = split(path)
    return s[#s] or "/"
  end

  function fs.path(path)
    checkArg(1, path, "string")
    local s = split(path)
    return fs.canonical(table.concat(s, "/", 1, #s - 1))
  end

  local function resolve(path, noexist)
--  log("resolve " .. path)
    if path == "." then path = os.getenv("PWD") or "/" end
    if path:sub(1,1) ~= "/" then path = (os.getenv("PWD") or "/") .. path end
    local s = split(path)
    for i=#s, 1, -1 do
      local cur = "/" .. table.concat(s, "/", 1, i)
      local try = "/" .. table.concat(s, "/", i + 1)
      if mounts[cur] and (mounts[cur].exists(try) or noexist) then
        --component.sandbox.log("found", try, "on mount", cur, mounts[cur].address)
        return mounts[cur], try
      end
    end
    if mounts[path] then
      return mounts[path], "/"
    end
    if mounts["/"].exists(path) or noexist then
      return mounts["/"], path
    end
--  log("no such file or directory")
    return nil, path .. ": no such file or directory"
  end

  local basic =  {"makeDirectory", "exists", "isDirectory", "lastModified", "remove", "size", "spaceUsed", "spaceTotal", "isReadOnly", "getLabel"}
  for k, v in pairs(basic) do
    fs[v] = function(path)
      checkArg(1, path, "string", "nil")
--    log("called basic function " .. v .. " with argument " .. tostring(path))
      local mt, p = resolve(path, v == "makeDirectory")
      if path and not mt then
        return nil, p
      end
--    log("resolved to " .. mt.address .. ", path " .. p)
      return mt[v](p)
    end
  end

  function fs.list(path)
    checkArg(1, path, "string")
    local mt, p = resolve(path)
    if not mt then
      return nil, p
    end
    local files = mt.list(p or "/")
    local i = 0
    return setmetatable(files, {__call = function() i=i+1 return files[i] or nil end})
  end

  local function fread(self, amount)
    checkArg(1, amount, "number", "string")
    if amount == math.huge or amount == "*a" then
      local r = ""
      repeat
        local d = self.fs.read(self.handle, math.huge)
        r = r .. (d or "")
      until not d
      return r
    end
    return self.fs.read(self.handle, amount)
  end

  local function fwrite(self, data)
    checkArg(1, data, "string")
    return self.fs.write(self.handle, data)
  end

  local function fseek(self, whence, offset)
    checkArg(1, whence, "string")
    checkArg(2, offset, "number", "nil")
    offset = offset or 0
    return self.fs.seek(self.handle, whence, offset)
  end

  local open = {}

  local function fclose(self)
    open[self.handle] = nil
    return self.fs.close(self.handle)
  end

  function fs.open(path, mode)
    checkArg(1, path, "string")
    checkArg(2, mode, "string", "nil")
    local m = mode or "r"
    mode = {}
    for c in m:gmatch(".") do
      mode[c] = true
    end
    local node, rpath = resolve(path, true)
    if not node then
      return nil, rpath
    end

    local handle = node.open(rpath, m)
    if handle then
      local ret = {
        fs = node,
        handle = handle,
        seek = fseek,
        close = fclose
      }
      open[handle] = ret
      if mode.r then
        ret.read = fread
      end
      if mode.w or mode.a then
        ret.write = fwrite
      end
      return ret
    else
      return nil, path .. ": no such file or directory"
    end
  end

  function fs.closeAll()
    for _, h in pairs(open) do
      h:close()
    end
  end

  function fs.copy(from, to)
    checkArg(1, from, "string")
    checkArg(2, to, "string")
    local fhdl, ferr = fs.open(from, "r")
    if not fhdl then
      return nil, ferr
    end
    local thdl, terr = fs.open(to, "w")
    if not thdl then
      return nil, terr
    end
    thdl:write(fhdl:read("*a"))
    thdl:close()
    fhdl:close()
    return true
  end

  function fs.rename(from, to)
    checkArg(1, from, "string")
    checkArg(2, to, "string")
    local ok, err = fs.copy(from, to)
    if not ok then
      return nil, err
    end
    local ok, err = fs.remove(from)
    if not ok then
      return nil, err
    end
    return true
  end

  function fs.canonical(path)
    checkArg(1, path, "string")
    if path == "." then
      path = os.getenv("PWD") or "/"
    elseif path:sub(1,1) ~= "/" then
      path = (os.getenv("PWD") or "/") .. "/" .. path
    end
    local p = "/" .. table.concat(split(path), "/")
    --component.sandbox.log(p)
    return p
  end

  function fs.concat(path1, path2, ...)
    checkArg(1, path1, "string")
    checkArg(2, path2, "string")
    local args = {...}
    for i=1, #args, 1 do
      checkArg(i + 2, args[i], "string")
    end
    local path = table.concat({path1, path2, ...}, "/")
    return fs.canonical(path)
  end

  local function rowrap(prx)
    local function t()
      return true
    end
    local function roerr()
      error(prx.address:sub(1,8) .. ": filesystem is read-only")
    end
    local mt = {
      __index = prx,
      __newindex = function()error("table is read-only")end,
      __ro = true
    }
    return setmetatable({
      isReadOnly = t,
      write = roerr,
      makeDirectory = roerr,
      remove = roerr,
      setLabel = roerr,
      open = function(f, m)
        m = m or "r"
        if m:find("[wa]") then
          return nil, "filesystem is read-only"
        end
        return prx.open(f, m)
      end
    }, mt)
  end

  local function proxywrap(prx)
    local mt = {
      __index = prx,
      __newindex = function()error("table is read-only")end,
      __ro = true
    }
    return setmetatable({}, mt)
  end

  function fs.mount(fsp, path, ro)
    checkArg(1, fsp, "string", "table")
    checkArg(2, path, "string")
    checkArg(2, ro, "boolean", "nil")
    --path = fs.canonical(path)
    if path ~= "/" and not fs.exists(path) then fs.makeDirectory(path) end
    if type(fsp) == "string" then
      fsp = component.proxy(fsp)
    end
    if mounts[path] == fsp then
      return true
    end
    if ro then
      mounts[path] = rowrap(fsp)
    else
      mounts[path] = proxywrap(fsp)
    end
    return true
  end

  function fs.mounts()
    local m = {}
    for path, proxy in pairs(mounts) do
      m[path] = proxy.address
    end
    return m
  end

  function fs.umount(path)
    checkArg(1, path, "string")
    if not mounts[path] then
      return nil, "no filesystem mounted at " .. path
    end
    if path == "/" then
      return nil, "cannot unmount /"
    end
    mounts[path] = nil
    return true
  end

  function fs.get(path)
    checkArg(1, path, "string")
    return resolve(path)
  end

  fs.mount(computer.getBootAddress(), "/")
  fs.mount(computer.tmpAddress(), "/tmp")

  kernel.filesystem = fs
end


-- computer.shutdown stuff --

do
  --local log = component.sandbox.log
  local shutdown = computer.shutdown
  local closeAll = kernel.filesystem.closeAll
  kernel.filesystem.closeAll = nil
  function computer.shutdown(reboot)
    checkArg(1, reboot, "boolean", "nil")
    local running = kernel.thread.threads()
    computer.pushSignal("shutdown")
    --log("shutdown")
    coroutine.yield()
    for i=1, #running, 1 do
      kernel.thread.signal(running[i], kernel.thread.signals.term)
    end
    coroutine.yield()
    --log("close all file handles")
    closeAll()
    -- clear all GPUs
    --log("clear all the screens")
    for addr, _ in component.list("gpu") do
      local w, h = component.invoke(addr, "getResolution")
      component.invoke(addr, "fill", 1, 1, w, h, " ")
    end
    --log("shut down")
    shutdown(reboot)
  end
end


-- userspace sandbox and some security features --

kernel.logger.log("wrapping setmetatable, getmetatable for security, type for reasons")

local smt, gmt, typ, err = setmetatable, getmetatable, type, error

function _G.error(e, l)
  local pref = "/"
  if kernel.filesystem.get("/").isReadOnly() then
    pref = "/tmp/"
  end
  local handle = kernel.filesystem.open(pref .. "err_" .. os.date():gsub("[ :\\/]", "_"), "a")
  handle:write(debug.traceback(e).."\n")
  --kernel.logger.log(debug.traceback(e))
  handle:close()
  err(e, l)
end

function _G.setmetatable(tbl, mt)
  checkArg(1, tbl, "table")
  checkArg(2, mt, "table")
  local _mt = gmt(tbl)
  if _mt and _mt.__ro then
    error("table is read-only")
  end
  return smt(tbl, mt)
end

function _G.getmetatable(tbl)
  checkArg(1, tbl, "table")
  local mt = gmt(tbl)
  local _mt = {
    __index = mt,
    __newindex = function()error("metatable is read-only")end,
    __ro = true
  }
  if mt and mt.__ro then
    return smt({}, _mt)
  else
    return mt
  end
end

function _G.type(obj)
  local t = typ(obj)
  if t == "table" and getmetatable(obj) and getmetatable(obj).__type then
    return getmetatable(obj).__type
  end
  return t
end

kernel.logger.log("setting up userspace sandbox")

local sandbox = {}

for k, v in pairs(_G) do
  if v ~= _G then -- prevent recursion hopefully
    if type(v) == "table" then
      sandbox[k] = setmetatable({}, {__index = v})
    else
      sandbox[k] = v
    end
  end
end

sandbox._G = sandbox
sandbox.computer.pullSignal = coroutine.yield


-- big fancy scheduler --

do
  kernel.logger.log("initializing scheduler")
  local thread, tasks, sbuf, last, cur = {}, {}, {}, 0, 0
  local lastKey = math.huge

  local function checkDead(thd)
    local p = tasks[thd.parent] or {dead = false, coro = coroutine.create(function()end)}
    if thd.dead or p.dead or coroutine.status(thd.coro) == "dead" or coroutine.status(p.coro) == "dead" then
      return true
    end
    return false
  end

  local function getMinTimeout()
    local min = math.huge
    for pid, thd in pairs(tasks) do
      if thd.deadline - computer.uptime() < min then
        min = computer.uptime() - thd.deadline
      end
      if min <= 0 then
        min = 0
        break
      end
    end
    return min
  end

  local function cleanup()
    local dead = {}
    for pid, thd in pairs(tasks) do
      if checkDead(thd) then
        computer.pushSignal("thread_died", pid)
        dead[#dead + 1] = pid
      end
    end
    for i=1, #dead, 1 do
      tasks[dead[i]] = nil
    end

    local timeout = getMinTimeout()
    local sig = {computer.pullSignal(timeout)}
    if #sig > 0 then
      sbuf[#sbuf + 1] = sig
    end
  end

  local function getHandler(thd)
    local p = tasks[thd.parent] or {handler = kernel.logger.panic}
    return thd.handler or p.handler or getHandler(p) or kernel.logger.panic
  end

  local function handleProcessError(thd, err)
    local h = getHandler(thd)
    tasks[thd.pid] = nil
    computer.pushSignal("thread_errored", thd.pid, err)
    h(thd.name .. ": " .. err)
  end

  local global_env = {}

  function thread.spawn(func, name, handler, env, stdin, stdout, priority)
    checkArg(1, func, "function")
    checkArg(2, name, "string")
    checkArg(3, handler, "function", "nil")
    checkArg(4, env, "table", "nil")
    checkArg(5, stdin, "table", "nil")
    checkArg(6, stdout, "table", "nil")
    checkArg(7, priority, "number", "nil")
    last = last + 1
    env = setmetatable(env or {}, {__index = (tasks[cur] and tasks[cur].env) or global_env})
    stdin = stdin or (tasks[cur] and tasks[cur].stdin)
    stdout = stdout or (tasks[cur] and tasks[cur].stdout)
    env.STDIN = stdin or env.STDIN
    env.STDOUT = stdout or env.STDOUT
    env.OUTPUT = stdout or env.OUTPUT or env.STDOUT
    env.INPUT = stdin or env.INPUT or env.STDIN
    priority = priority or math.huge
    local new = {
      coro = coroutine.create( -- the thread itself
        function()
          local ok, err = xpcall(func, debug.traceback)
          if not ok and err then error(err) end
        end
      ),
      pid = last,                               -- process/thread ID
      parent = cur,                             -- parent thread's PID
      name = name,                              -- thread name
      handler = handler or kernel.logger.panic, -- error handler
      user = kernel.users.uid(),                -- current user
      users = {},                               -- user history
      owner = kernel.users.uid(),               -- thread owner
      sig = {},                                 -- signal buffer
      ipc = {},                                 -- IPC buffer
      env = env,                                -- environment variables
      deadline = computer.uptime(),             -- signal deadline
      priority = priority,                      -- thread priority
      uptime = 0,                               -- thread uptime
      stopped = false,                          -- is it stopped?
      started = computer.uptime()               -- time of thread creation
    }
    if not new.env.PWD then
      new.env.PWD = "/"
    end
    setmetatable(new, {__index = tasks[cur] or {}})
    tasks[last] = new
    computer.pushSignal("thread_spawned", last)
    return last
  end

  function os.setenv(var, val)
    checkArg(1, var, "string", "number")
    checkArg(2, val, "string", "number", "boolean", "table", "nil", "function")
    --kernel.logger.log("SET " .. var .. "=" .. tostring(val))
    if tasks[cur] then
      tasks[cur].env[var] = val
    else
      global_env[var] = val
    end
  end

  function os.getenv(var)
    checkArg(1, var, "string", "number", "nil")
    if not var then -- return a table of all environment variables
      local vtbl = {}
      if tasks[cur] then vtbl = tasks[cur].env
      else vtbl = global_env end
      local r = {}
      for k, v in pairs(vtbl) do
        r[k] = v
      end
      return r
    end
    if tasks[cur] then
      return tasks[cur].env[var] or nil
    else
      return global_env[var] or nil
    end
  end

  -- (re)define kernel.users stuff to be thread-local. Not done in module/users.lua as it requires low-level thread access.
  local ulogin, ulogout, uuid = kernel.users.login, kernel.users.logout, kernel.users.uid
  function kernel.users.login(uid, password)
    checkArg(1, uid, "number")
    checkArg(2, password, "string")
    local ok, err = kernel.users.authenticate(uid, password)
    if not ok then
      return nil, err
    end
    if tasks[cur] then
      table.insert(tasks[cur].users, 1, tasks[cur].user)
      tasks[cur].user = uid
      return true
    end
    return ulogin(uid, password)
  end

  function kernel.users.logout()
    if tasks[cur] then
      tasks[cur].user = -1
      if #tasks[cur].users > 0 then
        tasks[cur].user = table.remove(tasks[cur].users, 1)
      else
        tasks[cur].user = -1 -- guest, no privileges
      end
      return true
    end
    return false -- kernel is always root
  end

  function kernel.users.uid()
    if tasks[cur] then
      return tasks[cur].user
    else
      return 0 -- again, kernel is always root
    end
  end

  function thread.threads()
    local t = {}
    for pid, _ in pairs(tasks) do
      t[#t + 1] = pid
    end
    return t
  end

  function thread.info(pid)
    checkArg(1, pid, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    local t = tasks[pid]
    local inf = {
      name = t.name,
      owner = t.owner,
      priority = t.priority,
      parent = t.parent,
      uptime = t.uptime,
      started = t.started
    }
    return inf
  end

  function thread.signal(pid, sig)
    checkArg(1, pid, "number")
    checkArg(2, sig, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    if tasks[pid].owner ~= tasks[cur].user and tasks[cur].user ~= 0 then
      return nil, "permission denied"
    end
    local msg = {
      "signal",
      cur,
      sig
    }
    table.insert(tasks[pid].sig, msg)
    return true
  end

  function thread.ipc(pid, ...)
    checkArg(1, pid, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    local ipc = {
      "ipc",
      cur,
      ...
    }
    table.insert(tasks[pid].ipc, ipc)
    return true
  end

  function thread.current()
    return cur
  end

  -- detach from the parent thread
  function thread.detach()
    tasks[cur].parent = 1
  end

  -- detach any child thread, parent it to init
  function thread.orphan(pid)
    checkArg(1, pid, "number")
    if not tasks[pid] then
      return nil, "no such thread"
    end
    if tasks[pid].parent ~= cur then
      return nil, "thread is not a child of current"
    end
    tasks[pid].parent = 1 -- init
  end

  thread.signals = {
    interrupt = 2,
    quit      = 3,
    stop      = 19,
    continue  = 18,
    term      = 15,
    usr1      = 65,
    usr2      = 66,
    kill      = 9
  }

  function os.exit(code)
    checkArg(1, code, "number")
    thread.signal(thread.current(), thread.signals.kill)
    if thread.info(thread.current()).parent then
      thread.ipc(thread.info(thread.current()).parent, "child_exited", thread.current())
    end
  end

  function thread.kill(pid, sig)
    return thread.signal(pid, sig or thread.signals.term)
  end

  function thread.start()
    thread.start = nil
    while #tasks > 0 do
      local run = {}
      for pid, thd in pairs(tasks) do
        tasks[pid].uptime = computer.uptime() - thd.started
        if (thd.deadline <= computer.uptime() or #sbuf > 0 or #thd.ipc > 0 or #thd.sig > 0) and not thd.stopped then
          run[#run + 1] = thd
        end
      end

      --[[table.sort(run, function(a, b)
        if a.priority > b.priority then
          return a, b
        elseif a.priority < b.priority then
          return b, a
        else
          return a, b
        end
      end)]]

      local sig = table.remove(sbuf, 1)

      for i, thd in ipairs(run) do
        cur = thd.pid
        local ok, p1, p2
        if #thd.ipc > 0 then
          local ipc = table.remove(thd.ipc, 1)
          ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(ipc))
        elseif #thd.sig > 0 then
          local nsig = table.remove(thd.sig, 1)
          if nsig[3] == thread.signals.kill then
            thd.dead = true
            ok, p1, p2 = true, nil, "killed"
          elseif nsig[3] == thread.signals.stop then
            thd.stopped = true
          elseif nsig[3] == thread.signals.continue then
            thd.stopped = false
          else
            ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(nsig))
          end
        elseif sig and #sig > 0 then
          ok, p1, p2 = coroutine.resume(thd.coro, table.unpack(sig))
        else
          ok, p1, p2 = coroutine.resume(thd.coro)
        end
        --kernel.logger.log(tostring(ok) .. " " .. tostring(p1) .. " " .. tostring(p2))
        if (not (p1 or ok)) and p2 then
          --component.sandbox.log("thread error", thd.name, ok, p1, p2)
          handleProcessError(thd, p2 or p1)
        elseif ok then
          if p2 and type(p2) == "number" then
            thd.deadline = thd.deadline + p2
          elseif p1 and type(p1) == "number" then
            thd.deadline = thd.deadline + p1
          else
            thd.deadline = math.huge
          end
          thd.uptime = computer.uptime() - thd.started
        end

        -- this might reduce performance, we shall see
        if computer.freeMemory() < 1024 then -- oh no, we're out of memory
          --kernel.logger.log("low memory after thread " .. thd.name .. " - collecting garbage")
          for i=1, 50 do -- invoke GC
            computer.pullSignal(0)
          end
          if computer.freeMemory() < 512 then -- GC didn't help. Panic!
            for i=1, 50 do -- invoke GC
              computer.pullSignal(0)
            end
          end
          if computer.freeMemory() < 1024 then -- GC didn't help. Panic!
            kernel.logger.panic("out of memory")
          end
        end
      end

      cleanup()
    end
  end

  kernel.thread = thread
end


-- basic loadfile function --

local function loadfile(file, mode, env)
  checkArg(1, file, "string")
  checkArg(2, mode, "string", "nil")
  checkArg(3, env, "table", "nil")
  mode = mode or "bt"
  env = env or sandbox
  local handle, err = kernel.filesystem.open(file, "r")
  if not handle then
    return nil, err
  end
  --kernel.logger.log("loadfile " .. file)
  local data = handle:read("*a")
  handle:close()
  if data:sub(1,1) == "#" then -- crude shebang detection
    data = "--" .. data
  end
  return load(data, "=" .. file, mode, env)
end

sandbox.loadfile = loadfile


kernel.logger.log("loading init from " .. flags.init)

local ok, err = loadfile(flags.init, "bt", sandbox)
if not ok then
  kernel.logger.panic(err)
end

kernel.thread.spawn(ok, flags.init, kernel.logger.panic)

kernel.thread.start()
