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
