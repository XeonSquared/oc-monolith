-- `io` library --

do
  log("InitMe: Initialing IO library")

  _G.io = {}
  package.loaded.io = io

  local buffer = require("buffer")
  local fs = require("filesystem")
  local thread = require("thread")
  local stream = require("stream")

  setmetatable(io, {__index = function(tbl, k)
    if k == "stdin" then
      return os.getenv("STDIN")
    elseif k == "stdout" or k == "stderr" then
      return os.getenv("STDOUT")
    end
  end})

  function io.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    file = fs.canonical(file)
    mode = mode or "r"
    local handle, err = fs.open(file, mode)
    if not handle then
      return nil, err
    end
    return buffer.new(mode, handle)
  end

  function io.output(file)
    checkArg(1, file, "string", "table", "nil")
    if type(file) == "string" then
      file = io.open(file, "w")
    end
    if file then
      os.setenv("OUTPUT", file)
    end
    return os.getenv("OUTPUT")
  end

  function io.input(file)
    checkArg(1, file, "string", "table", "nil")
    if type(file) == "string" then
      file = io.open(file, "r")
    end
    if file then
      os.setenv("INPUT", file)
    end
    return os.getenv("INPUT")
  end

  function io.lines(file, ...)
    checkArg(1, file, "string", "table", "nil")
    if file then
      local err
      if type(file) == "string" then
        file, err = io.open(file)
      end
      if not file then return nil, err end
      return file:lines()
    end
    return io.input():lines()
  end

  function io.close(file)
    checkArg(1, file, "table", "nil")
    if file then
      return file:close()
    end
    return nil, "cannot close standard file"
  end

  function io.flush(file)
    checkArg(1, file, "table", "nil")
    file = file or io.output()
    return file:flush()
  end

  function io.type(file)
    checkArg(1, file, "table")
    if file.closed then
      return "closed file"
    elseif (file.read or file.write) and file.close then
      return "file"
    end
    return nil
  end

  function io.read(...)
    return io.input():read(...)
  end

  function io.write(...)
    return io.output():write(table.concat({...}))
  end

  function _G.print(...)
    local args = table.pack(...)
    local tp = ""
    local n = args.n
    for i=1, n, 1 do
      local k, v = i, args[i]
      tp = tp .. tostring(v) .. (k < n and "\t" or "")
    end
    return io.stdout:write(tp .. "\n")
  end
end
