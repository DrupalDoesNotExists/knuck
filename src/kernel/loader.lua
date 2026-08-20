--[[
  KNUCK module loader
  ===================
  CraftOS 1.9 has no `require`/`package`. This loader loads kernel modules
  via loadfile with a shared kernel environment. Each module is a function
  that takes the kernel namespace `K` and returns its exports.

  Usage:
    local loader = loadfile("/lib/knuck/kernel/loader.lua", "t", K.env)()
    local sched = loader.load("/lib/knuck/kernel/sched.lua", K)
]]

local M = {}
local loaded = {}

-- Load a module file. `K` is the kernel namespace (has .env = kernel env).
-- Module files return `function(K) ... return M end`. We execute the chunk
-- to get that function, then call it with K to get the module's exports.
-- Returns the module's exports (cached).
function M.load(path, K)
  if loaded[path] then return loaded[path] end
  local f, err = loadfile(path, "t", K.env)
  if not f then
    error("load " .. path .. ": " .. tostring(err))
  end
  local modfn = f()
  local mod = modfn(K)
  loaded[path] = mod
  return mod
end

-- Load a plain data file (returns its value, e.g. a config table).
function M.loadfile(path, K)
  local f, err = loadfile(path, "t", K.env)
  if not f then
    error("load " .. path .. ": " .. tostring(err))
  end
  return f()
end

-- Reset the loader cache (used on kernel restart).
function M.reset()
  loaded = {}
end

-- Drop a single module from the cache (used by rmmod).
function M.unload(path)
  loaded[path] = nil
end

return M