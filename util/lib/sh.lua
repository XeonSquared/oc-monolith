-- sh libs --

local shell = require("shell")
local fs = require("filesystem")
local sh = {}

local psrep = {
  ["\\w"] = function()
    return os.getenv("PWD") or "/"
  end,
  ["\\W"] = function()
    return fs.name(os.getenv("PWD") or "/")
  end,
  ["\\$"] = function()
    if os.getenv("UID") == 0 then
      return "#"
    else
      return "$"
    end
  end,
  ["\\u"] = function()
    return os.getenv("USER") or ""
  end,
  ["\\h"] = function()
    return os.getenv("HOSTNAME") or "localhost"
  end
}

function sh.prompt(p)
  checkArg(1, p, "string", "nil")
  p = p or os.getenv("PS1") or "\\w\\$ "
  for k, v in pairs(psrep) do
    k = k:gsub("%$", "%%$") -- ouch
    p = p:gsub(k, v())
  end
  return shell.vars(p)
end

-- runs shell scripts
function sh.execute(file)
  checkArg(1, file, "string")
  local handle, err = io.open(file)
  if not handle then
    return nil, err
  end
  for line in file:lines() do
    shell.execute(line)
  end
  file:close()
end

return sh