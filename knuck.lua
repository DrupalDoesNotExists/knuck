--[[
  KNUCK kernel entry
  ==================
  Boot sequence:
    1. Build kernel namespace K (kernel env = full globals).
    2. Load module loader.
    3. Run self-diagnostics (diag).
    4. Load core modules (sched, syscall, proc, vfs).
    5. Init modules, mount VFS.
    6. Start scheduler -> run init process.

  Run: lua /knuck/knuck.lua
]]

-- Kernel namespace. Kernel code runs with full globals (os/fs/term/...).
local K = {
  env = _G,
  modules = {},
  selfcheck = {},
}

-- 1. Loader
K.loader = loadfile("/knuck/kernel/loader.lua", "t", K.env)()

-- 2. Self-diagnostics
local diag = K.loader.load("/knuck/kernel/diag.lua", K)
K.diag = diag
K.selfcheck = diag.run(K)

-- 3. Core modules
K.sched = K.loader.load("/knuck/kernel/sched.lua", K)
K.syscall = K.loader.load("/knuck/kernel/syscall.lua", K)
K.proc = K.loader.load("/knuck/kernel/proc.lua", K)
K.vfs = K.loader.load("/knuck/kernel/vfs.lua", K)

-- 4. Init modules (dependency order)
K.syscall.init(K)
K.proc.init(K)
K.vfs.init(K)
K.sched.init(K)

-- 5. Mount VFS
K.vfs.mount_root()

-- 6. Boot banner
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("KNUCK " .. (K.selfcheck.craftos or "?") .. " boot")
term.setTextColor(colors.white)
if K.selfcheck.preempt then
  print("  scheduler: preemptive")
else
  print("  scheduler: cooperative (no yield-from-hook)")
end
if not K.selfcheck.collectgarbage then
  print("  memory: soft mode (no collectgarbage)")
end

-- 7. Start scheduler (never returns)
K.sched.start()