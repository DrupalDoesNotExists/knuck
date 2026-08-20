--[[
  KNUCK self-diagnostics
  ======================
  Runs at boot before init. Detects platform capabilities and decides
  kernel behavior (preemptive vs cooperative, memory accounting on/off).
  Result stored in K.selfcheck and exposed via /proc/selfcheck.
]]

return function(K)
  local M = {}

  -- Check a global function exists
  local function has(fn)
    return type(fn) == "function"
  end

  -- Check yield-from-hook (key for preemptive scheduler)
  local function check_yield_from_hook()
    if not has(debug.sethook) then return false end
    local co = coroutine.create(function()
      local n = 0
      for i = 1, 10000 do n = n + i end
      return n
    end)
    local fired, yielded = false, false
    local ok = pcall(function()
      debug.sethook(co, function()
        fired = true
        coroutine.yield("HOOK_YIELD")
      end, "", 100)
      local ok_res, val = coroutine.resume(co)
      if ok_res and val == "HOOK_YIELD" then
        yielded = true
        coroutine.resume(co)
      end
    end)
    debug.sethook(co)
    return ok and fired and yielded
  end

  function M.run(K)
    local sc = {
      lua = _VERSION or "unknown",
      craftos = (type(os) == "table" and type(os.version) == "function") and os.version() or "unknown",
      sethook = has(debug.sethook),
      preempt = check_yield_from_hook(),
      collectgarbage = has(collectgarbage),
      fs_rename = (type(fs) == "table" and type(fs.rename) == "function"),
      sandbox = false,
    }

    -- Sandbox check: load with custom env hides os/fs
    local ok_load, load_res = pcall(function()
      local sandbox = {
        type = type, tostring = tostring, pairs = pairs, ipairs = ipairs,
        string = string, math = math, table = table,
      }
      local chunk = load("return type(os) == 'nil' and type(fs) == 'nil'", "diag", "t", sandbox)
      return chunk and chunk()
    end)
    sc.sandbox = ok_load and load_res == true

    return sc
  end

  return M
end