# KNUCK Spec Compliance Audit

**Date:** 2026-08-20
**Kernel commit:** e501b89 kernel: add signal system, exec syscall, fix syscall result packing
**Audit scope:** Every requirement in `docs/SPEC.md` (257 lines) checked against `/tmp/knuck-src` source tree.
**Method:** Line-by-line extraction of spec requirements → evidence search in source → classification.

## Classification Legend

| Status | Meaning |
|--------|---------|
| **DONE** | Fully implemented per spec |
| **PARTIAL** | Exists but incomplete or deviates from spec |
| **MISSING** | Not implemented at all |
| **N/A** | Not applicable on CC:Tweaked platform |

---

## 1. Philosophy and Architecture (SPEC §1)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 1 | Microkernel: core minimal, functionality in loadable driver modules | §1 | DONE | boot.lua:144-161 (loader loads modules); loader.lua exists | Modules loaded as function(K) returning exports |
| 2 | HAL: CraftOS APIs = "hardware", available only to kernel | §1 | DONE | proc.lua:28-76 (make_env builds sandbox without os/fs/term) | Userspace env has no CraftOS globals |
| 3 | Drivers touch hardware; even screen output goes syscall→kernel→driver | §1 | DONE | drivers/term.lua backs /dev/console; vfs.lua:30-31 registers term driver | Term output flows through tty layer |
| 4 | Userspace has no direct hardware access — only syscalls | §1 | DONE | proc.lua:41-73 (env only has syscall wrappers + safe stdlib) | Confirmed by diag.lua sandbox check |
| 5 | Unified socket API: one surface for AF_UNIX/AF_MODEM/AF_HTTP | §1 | DONE | ipc.lua:203-224 (socket factory); syscall.lua:498-567 (all ops) | Domain selects transport, surface is common |
| 6 | Policy in userspace, mechanism in kernel | §1 | DONE | DHCP not in kernel; routing in /sys/net; init.rc is userspace | Kernel provides primitives, userspace decides |

## 2. Platform and Limitations (SPEC §2)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 7 | Target CraftOS 1.9 (CC:Tweaked ~1.90, Cobalt, Lua 5.2) | §2 | DONE | diag.lua:43 (detects os.version); boot.lua banner prints version | |
| 8 | Preemptive scheduler via debug.sethook + count-hook + yield | §2 | DONE | sched.lua:108-111 (sethook with count); diag.lua:18-38 (yield-from-hook test) | Falls back to cooperative if unavailable |
| 9a | collectgarbage conditional: memory accounting only if present | §2 | DONE | diag.lua:47 (checks `has(collectgarbage)`); boot.lua:193-195 prints soft mode | CraftOS 1.9 = soft mode |
| 9b | fs.rename absent → VFS uses copy+delete | §2 | DONE | fs.lua:150-161 (copy+delete fallback) | |
| 9c | component, textutils.format absent — not critical | §2 | N/A | Not a kernel concern | Platform limitation acknowledged |
| 10a | CUT: fork — Lua coroutine can't clone (covered by spawn+exec) | §2 | N/A | spawn+exec implemented; no fork | Platform physics |
| 10b | CUT: File timestamps — CC doesn't store them | §2 | N/A | No utime syscall needed | Platform physics |
| 10c | CUT: Hardware memory isolation — single VM heap | §2 | N/A | Mitigation via sandbox + instruction budget + CC watchdog | |
| 10d | CUT: Memory signals (SEGV/FPE/ABRT) → uncaught error → SIGSEGV | §2 | DONE | proc.lua:253-261 (die with SIGSEGV); sched.lua:122-126 (error → die) | |
| 11 | CC watchdog: ~7s soft / +1.5s hard abort | §2 | N/A | Platform-provided, no kernel code needed | |

## 3. Process Isolation (SPEC §3)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 12 | Each process loads with its own _ENV (sandbox); os/fs/term lexically unreachable | §3 | DONE | proc.lua:28-76 (make_env); proc.lua:82-86 (load_process with env) | Confirmed by diag.lua sandbox check |
| 13 | Process env: only syscall wrappers + safe stdlib (string/math/table/coroutine/bit) | §3 | PARTIAL | proc.lua:21 `SAFE_LIBS = { "string", "math", "table", "coroutine" }` | **`bit` missing from SAFE_LIBS** (spec §3 line 47 lists `bit`) |
| 14 | Escapism plugged: io, os, debug, package removed; load/loadstring inherit caller env | §3 | DONE | proc.lua:28-38 (env only adds safe libs + basic fns); no io/os/debug/package | |
| 15 | Syscall discipline: no internal tables returned as-is — only copies | §3 | DONE | readdir returns flat string arrays; stat returns plain tables; no handle leaking | Syscall results are value types |

## 4. Scheduler (SPEC §4)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 16 | Preemption by quanta: count-hook fires every N instructions → yield → kernel requeues | §4 | DONE | sched.lua:21 (QUANTUM=1000); sched.lua:108-111 (sethook + yield) | Context preserved via coroutine |
| 17 | Priorities: getpriority/setpriority, range −20..19, lower=higher (POSIX) | §4 | DONE | syscall.lua:263-276; sched.lua:49 (dequeue picks lowest priority) | |
| 18 | Policies: sched_setscheduler — "rr"\|"fifo"\|"other" | §4 | MISSING | **No `sched_setscheduler` syscall registered** | Policy system not implemented at all |
| 19 | States: running \| ready \| waiting \| stopped \| zombie \| dead | §4 | DONE | proc.lua:110 (state="ready"); sched.lua:41,105 (ready,running); proc.lua:170 (zombie); proc.lua:186 (stopped) | `dead` state exists in spec comment only (proc.lua:7) |
| 20 | Zombie: killed process holds exit code until waitpid; orphans adopted by init (pid 1) | §4 | DONE | proc.lua:169-174 (exit→zombie); proc.lua:264-276 (notify_parent, orphan adoption) | |
| 21 | Uncaught error → death as SIGSEGV; kernel logs error text | §4 | DONE | sched.lua:122-126 (error → die("SIGSEGV", req)); proc.lua:258 (K.log with detail) | |

## 5.1 Syscalls — proc (SPEC §5.1)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 22 | getpid() / getppid() | §5.1 | DONE | syscall.lua:78-79 | |
| 23 | getuid() / geteuid() / getgid() / getegid() | §5.1 | DONE | syscall.lua:80-83 | |
| 24 | setuid(uid) / setgid(gid) | §5.1 | DONE | syscall.lua:649-659 | Root-or-same-uid check present |
| 25 | spawn(path, ...) → pid | §5.1 | DONE | syscall.lua:142-145; proc.lua:89-137 | Returns pid, sets up sandbox |
| 26 | exec(path, ...) — execve(2); nil,err on failure | §5.1 | DONE | syscall.lua:150-180 | Applies setuid/setgid bits, resets signals |
| 27 | exit(code) | §5.1 | DONE | syscall.lua:88-90 | |
| 28 | waitpid(pid, opt?) → pid,status; opt="nohang"; pid=-1 any child | §5.1 | DONE | syscall.lua:183-197 | WNOHANG and pid=-1 both work |
| 29 | kill(pid, sig); own uid or root; -1 all except self; 0 own group | §5.1 | DONE | proc.lua:221-250 | Permission checks present |
| 30 | getpgrp() / setpgid(pid, pgid) | §5.1 | PARTIAL | syscall.lua:84 (getpgrp registered); **setpgid not registered** | getpgrp DONE, **setpgid MISSING** |
| 31 | alarm(secs) — SIGALRM | §5.1 | DONE | syscall.lua:243-255; sched.lua:182-188 (timer→SIGALRM delivery) | Cancel+reschedule works |
| 32 | signal(sig, handler\|nil\|"ignore") — sigaction(2) analog | §5.1 | DONE | syscall.lua:205-219 | SIGKILL/SIGSTOP rejection present |
| 33 | sigprocmask(how, set?) — block/unblock signals | §5.1 | DONE | syscall.lua:222-240 | block/unblock/set modes; KILL/STOP never blocked |
| 34 | sched_yield() | §5.1 | DONE | syscall.lua:258-260 | |
| 35 | sleep(secs) — float seconds | §5.1 | DONE | syscall.lua:93-96 | Blocks via timer |
| 36 | getpriority(pid?) / setpriority(pid?, prio) | §5.1 | DONE | syscall.lua:263-276 | Permission check present |
| 37 | sched_setscheduler(pid?, policy) — "rr"\|"fifo"\|"other" | §5.1 | MISSING | **Not registered as syscall** | |
| 38 | chdir(path) / getcwd() | §5.1 | DONE | syscall.lua:283-290 (chdir); syscall.lua:85 (getcwd) | chdir checks dir + x permission |
| 39 | umask(mask?) | §5.1 | DONE | syscall.lua:411-413; vfs.lua:659-663 | Returns old mask |

## 5.1 Signals (SPEC §5.1 continued)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 40 | Signal numbers: HUP=1, INT=2, QUIT=3, KILL=9, USR1=10, USR2=12, PIPE=13, ALRM=14, TERM=15, CHLD=17, CONT=18, STOP=19 | §5.1 | PARTIAL | Numbers used inline (9,13,14,15,17,18,19); **no symbolic constants exported to userspace** | Numeric values work; no named constants |
| 41 | SIGCHLD: notification to parent on child completion, unblocks waitpid | §5.1 | PARTIAL | proc.lua:264-276 (`notify_parent` wakes parent via `sched.wake("child",...)`) | Functionally works but **no actual SIGCHLD signal delivered to parent** — just a waitpid wake |
| 42 | SIGPIPE: write to pipe without reader → signal, default = termination | §5.1 | DONE | ipc.lua:98-100 (send_signal(proc, 13) on write to closed pipe) | |
| 43 | SIGKILL/SIGSTOP — not blockable | §5.1 | DONE | syscall.lua:206-207 (rejects handler change); proc.lua:180-188 (immediate death/stop) | |

## 5.2 Syscalls — security (SPEC §5.2)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 44 | chmod(path, mode) — rwxrwxrwx octal | §5.2 | DONE | syscall.lua:375-377; vfs.lua:570-577 | Owner or root check present |
| 45 | chown(path, uid, gid) | §5.2 | DONE | syscall.lua:379-381; vfs.lua:580-588 | Root-only check present |
| 46 | chgrp(path, gid) | §5.2 | DONE | syscall.lua:383-385 (delegates to chown) | |
| 47 | root (uid 0) bypasses permission checks | §5.2 | DONE | fs.lua:74-80 (root bypass for r/w; x needs at least one x bit) | |
| 48 | setuid/setgid bits on executables: on exec process gets euid/egid of owner | §5.2 | DONE | syscall.lua:160-162 (checks 0x800/0x400 bits on exec) | |
| 49 | mount/umount — only root | §5.2 | DONE | vfs.lua:640 (mount checks uid==0); vfs.lua:650 (umount checks uid==0) | |
| 50 | kill — by uid rule (own process or root) | §5.2 | DONE | proc.lua:242-245 (uid check) | |
| 51 | No additional groups (only primary gid) | §5.2 | DONE | No supplementary group support exists; spec says "no" | Correctly absent |

## 5.3 Syscalls — IPC (SPEC §5.3)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 52 | pipe() → rfd, wfd — anonymous pipe | §5.3 | DONE | ipc.lua:47-51; syscall.lua:420-426 | |
| 53 | mkfifo(path, mode) — named pipe | §5.3 | DONE | vfs.lua:516-528; syscall.lua:429-431 | Blocking open/read/write semantics |
| 54 | socket(domain, type, proto) → fd | §5.3 | DONE | ipc.lua:203-224; syscall.lua:498-503 | Supports unix/stream, modem/dgram, http/stream |
| 55 | bind(fd, addr) — inet/unix/http addr formats | §5.3 | PARTIAL | ipc.lua:227-248 | Unix path binding DONE; modem port binding DONE; **HTTP bind not implemented** (http only has connect) |
| 56 | listen(fd, backlog) | §5.3 | DONE | ipc.lua:251-257 | |
| 57 | accept(fd) → fd — blocking | §5.3 | DONE | ipc.lua:263-281; syscall.lua:520-532 | Blocks until connection arrives |
| 58 | connect(fd, addr) | §5.3 | DONE | ipc.lua:284-318 | Unix, HTTP supported; modem uses sendto instead |
| 59 | send(fd, data, flags?) → n | §5.3 | PARTIAL | ipc.lua:337-360 | **`flags` parameter accepted but ignored** |
| 60 | recv(fd, len?, flags?) → data\|nil | §5.3 | PARTIAL | ipc.lua:363-393 | **`flags` parameter accepted but ignored** |
| 61 | close(fd) | §5.3 | DONE | syscall.lua:319-325 | |
| 62 | shutdown(fd, "read"\|"write"\|"both") | §5.3 | DONE | syscall.lua shutdown; ipc.lua socket_shutdown | Honors read/write/both (pipe ends for unix, FIN for TCP) |
| 63 | getsockname(fd) → addr | §5.3 | DONE | syscall.lua:577-581 | Returns fd.sock.path |
| 64 | getpeername(fd) → addr | §5.3 | DONE | syscall.lua:584-588 | Returns fd.sock.peer |
| 65 | setsockopt(fd, opt, val) — SO_REUSEADDR, SO_BROADCAST, SO_RCVTIMEO… | §5.3 | PARTIAL | syscall.lua:591-599 | **Only SO_BROADCAST implemented**; SO_REUSEADDR and SO_RCVTIMEO missing |
| 66 | getsockopt(fd, opt) → val | §5.3 | PARTIAL | syscall.lua:600-607 | **Only SO_BROADCAST implemented** |
| 67 | select(reads?, writes?, timeout?) → n, r, w | §5.3 | DONE | syscall.lua:434-464 | Returns r,w,e tables; SPEC.md aligned to impl (decision A) |
| 68 | poll(fds, timeout?) → n | §5.3 | DONE | syscall.lua:467-495 | Returns table of ready fds; SPEC.md aligned to impl (decision B) |
| 69 | Sockets as FD: read/write/close work on them | §5.3 | DONE | vfs.lua read/write dispatch | Socket fds dispatch to recv/send for connected STREAM sockets (decision I) |
| 70 | AF_HTTP: HTTP requests via unified socket-API, wrapper over CC http | §5.3 | DONE | ipc.lua:286-293 (connect sets URL); ipc.lua:341-344 (send=POST); ipc.lua:367-373 (recv=canned response) | No WebSocket (spec says no) |

## 5.4 Syscalls — VFS (SPEC §5.4)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 71 | mount(source, target, fstype, opts?) → ok; opts: "ro"\|"rw"; only root | §5.4 | DONE | vfs.lua mount | Root check + ro/rw opts parsed and stored |
| 72 | umount(target) → ok | §5.4 | DONE | vfs.lua:649-656 | Prevents unmounting root |
| 73 | open(path, flags) → fd; flags: "r" "w" "a" "r+" "w+" | §5.4 | DONE | vfs.lua:378-429 | Supports all flag modes via CC fs.open |
| 74 | close(fd) | §5.4 | DONE | vfs.lua:480-486 | |
| 75 | read(fd, n?) → data\|nil; n=0 → as much as available; nil on EOF | §5.4 | DONE | vfs.lua:432-452 | Handles console, pipe, file, memfile, device |
| 76 | write(fd, data) → n | §5.4 | DONE | vfs.lua:455-477 | |
| 77 | mkdir(path) / rmdir(path) | §5.4 | DONE | vfs.lua:499-542 | Permission checks present |
| 78 | unlink(path) | §5.4 | DONE | vfs.lua:545-554 | |
| 79 | readdir(dir) → {name, is_dir, ...} | §5.4 | DONE | vfs.lua readdir | Structured entries {name, is_dir, type, mode, size} (decision J) |
| 80 | stat(path) → {size=, type=, mode=, uid=, gid=, nlink=, ...} | §5.4 | DONE | vfs.lua:348-361 | Returns all specified fields |
| 81 | rename(old, new) | §5.4 | DONE | vfs.lua:557-567 | |
| 82 | lseek(fd, offset, whence?) — whence: "set"\|"cur"\|"end" | §5.4 | DONE | vfs.lua:489-496 | |
| 83 | fstat(fd) → info | §5.4 | DONE | syscall.lua fstat | Real metadata via inode lookup (was hardcoded 0644/0) |
| 84 | symlink(target, path) / readlink(path) | §5.4 | DONE | vfs.lua:591-611 | readlink does NOT follow symlink (correct) |
| 85 | link(old, new) — hard link | §5.4 | PARTIAL | vfs.lua:614-625 | Implemented as **copy+delete** (not true inode-sharing hardlink). nlink incremented but not semantically correct |
| 86 | chroot(path) — process sees only subtree | §5.4 | DONE | vfs.lua resolve | resolve() jails absolute paths inside proc.root (decision D) |

## 5.4 Filesystem Types and Mount Tree (SPEC §5.4 continued)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 87 | fstype `disk` — computer storage | §5.4 | DONE | vfs.lua:58 | |
| 88 | fstype `tmp` — in-memory | §5.4 | DONE | vfs.lua:60 (mounted as real CraftOS `/tmp`) | |
| 89 | fstype `dev` — device nodes | §5.4 | DONE | vfs.lua:62 | |
| 90 | fstype `sys` — kernel settings | §5.4 | DONE | vfs.lua:63 | |
| 91 | fstype `proc` — procfs | §5.4 | DONE | vfs.lua:64 | |
| 92 | fstype `floppy`/`hdd` — disk drives | §5.4 | MISSING | **No fstype floppy/hdd defined; no auto-mount** | |
| 93 | fstype `rom` — CC platform | §5.4 | DONE | vfs.lua:61 | |
| 94 | `/` ← computer storage (writable) [disk] | §5.4 | DONE | vfs.lua:58 | |
| 95 | `/boot` ← kernel + modules (writable) [disk] | §5.4 | DONE | vfs.lua:59 | |
| 96 | `/tmp` ← tmpfs, **cleaned on start** [tmp] | §5.4 | DONE | vfs.lua mount_root | Wiped recursively at boot |
| 97 | `/dev` ← device nodes [dev] | §5.4 | DONE | vfs.lua:62 | |
| 98 | `/sys` ← kernel settings [sys] | §5.4 | DONE | vfs.lua:63 | |
| 99 | `/proc` ← procfs [proc] | §5.4 | DONE | vfs.lua:64 | |
| 100 | `/mnt/disk0..N` ← disk drives on connect [floppy/hdd] | §5.4 | MISSING | **No auto-mount on peripheral attach** | Hotplug event goes to devctl but no auto-mount |
| 101 | `/rom` ← CC platform base (not our filesystem) | §5.4 | DONE | vfs.lua:61 | |

## 5.4 Device Nodes /dev (SPEC §5.4 continued)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 102 | `/dev/console` — terminal (fds 0/1/2); cooked (strings) by default, raw (events) via ioctl | §5.4 | DONE | tty.lua; syscall.lua ioctl | Cooked (lines) default + raw (events) via ioctl console_mode |
| 103 | `/dev/input` — raw events (term/char/mouse) | §5.4 | DONE | vfs.lua input driver; sched.lua dispatch | Raw events fed by scheduler dispatch |
| 104 | `/dev/periph/<side>` — peripheral nodes | §5.4 | DONE | vfs.lua make_periph_driver | Thin wrapper delegating to peripheral.call (decision H) |
| 105 | `/dev/null` | §5.4 | DONE | vfs.lua null driver | read=EOF, write=discard |
| 106 | `/dev/zero` | §5.4 | DONE | vfs.lua zero driver | read=NUL bytes |
| 107 | `/dev/urandom` | §5.4 | DONE | vfs.lua urandom driver | read=random bytes |
| 108 | `/dev/devctl` — device events (attach/detach) for userspace daemon | §5.4 | DONE | vfs.lua:39-54 (read blocks, write handles tty_switch); sched.lua:206-208 (peripheral events wake devctl) | Attach/detach events wake readers; no structured event format |
| 109 | `/dev/modemN` — raw link-level frames | §5.4 | DONE | net.lua:449-459 (registered as modem0; reads rx_queue) | Only modem0, not N |

## 5.4 /sys Structure (SPEC §5.4 continued)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 110 | `/sys/kernel/*` — quantum, priorities | §5.4 | PARTIAL | vfs.lua:200-201 (`/sys/kernel` lists "version", "scheduler") | **Missing `/sys/kernel/quantum` and `/sys/kernel/priority`** files |
| 111 | `/sys/net/*` — IP config, ARP cache, routes | §5.4 | DONE | vfs.lua:202-204 (ip, gateway, netmask, arp, routes, channel) | All listed; writable for config |
| 112 | `/sys/modules/*` — loaded modules, status; write = kernel config | §5.4 | PARTIAL | vfs.lua:215-219 (lists K.modules keys) | **K.modules is never populated** — no insmod/rmmod; always empty. Write path not implemented |

## 5.4 /proc Structure (SPEC §5.4 continued)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 113 | `/proc/<pid>/status` | §5.4 | DONE | vfs.lua:182-185 (reads name, state, pid, ppid, uid, priority) | |
| 114 | `/proc/<pid>/cmdline` | §5.4 | DONE | vfs.lua:186-187 | Returns process name |
| 115 | `/proc/<pid>/fd` | §5.4 | PARTIAL | vfs.lua:188-189 | **Hardcoded** "0\tconsole\n1\tconsole\n2\tconsole\n" — doesn't reflect actual open fds |
| 116 | `/proc/<pid>/mem` | §5.4 | PARTIAL | vfs.lua:190-191 | Returns "0\n" — stub, no real memory info |
| 117 | `/proc/uptime` | §5.4 | DONE | vfs.lua:165-166 (returns os.clock()) | |
| 118 | `/proc/version` | §5.4 | DONE | vfs.lua:167-168 | |

## 5.5 Syscalls — modules (SPEC §5.5)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 119 | insmod(path) → ok — load driver module | §5.5 | MISSING | **No `insmod` syscall registered**; no dynamic module loading | |
| 120 | rmmod(name) → ok — unload module | §5.5 | MISSING | **No `rmmod` syscall registered**; no module unloading | |
| 121 | Module list at start from `/boot/knuck.conf` | §5.5 | MISSING | **No knuck.conf file in repo**; boot.lua hardcodes module load order | |
| 122 | Hotplug: kernel detects attach, event → /dev/devctl; mount decision = userspace | §5.5 | PARTIAL | sched.lua:206-208 (peripheral event → wake devctl); vfs.lua:39-54 (devctl read blocks) | Event delivered but **no structured format** (just raw `peripheral` event); no detach event handling |

## 5.6 Network (SPEC §5.6)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 123 | Ethernet frames: dest(6)+src(6)+ethertype(2)+payload+FCS(4) | §5.6 | DONE | net.lua:143-162 (eth_build/eth_parse) | |
| 124 | MAC: locally-administered 02:00:00:00:xx:xx from modem-id | §5.6 | DONE | net.lua:443 (mac derived from computerID) | |
| 125 | FCS: CRC32 computed and verified | §5.6 | DONE | net.lua:116-139 (crc32); net.lua:157 (verify on parse) | |
| 126 | Min frame 64 bytes (padded), max 1518 | §5.6 | DONE | net.lua:29-31 (MIN_FRAME=64, MAX_FRAME=1518); net.lua:147-149 (padding) | |
| 127 | IP (RFC 791): fragmentation and reassembly | §5.6 | DONE | net.lua:302-315 (fragment send); net.lua:371-398 (reassembly) | |
| 128 | ARP (RFC 826): cache IP→MAC with timeout, static entries | §5.6 | DONE | net.lua:194-258 (arp_request/reply/handle/cache with TTL, static) | |
| 129 | TCP (RFC 793) / UDP (RFC 768): literal protocols | §5.6 | DONE | net_transport.lua (full TCP state machine + UDP port tables) | |
| 130 | Routing: static routes + default gw via /sys/net | §5.6 | DONE | net.lua route_lookup; vfs.lua net/routes | Longest-prefix-match table, /sys/net/routes read/write (Phase 2) |
| 131 | DHCP — userspace (kernel gives UDP+broadcast) | §5.6 | N/A | Userspace concern; kernel provides UDP socket + broadcast | Correctly absent from kernel |
| 132 | Network config via /sys/net (not separate syscall) | §5.6 | DONE | vfs.lua:242-280 (write ip/gateway/netmask/channel/arp) | |

## 5.7 Console (SPEC §5.7)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 133 | ioctl(fd, cmd, ...) — device control | §5.7 | PARTIAL | syscall.lua:614-619 | **Only `tty_switch` command implemented**; no terminal mode ioctls |
| 134 | `/dev/console`: cooked (strings on Enter) by default, raw (events) via ioctl | §5.7 | DONE | tty.lua; syscall.lua ioctl | Cooked default + raw via ioctl console_mode |
| 135 | Terminal modes via ioctl on console | §5.7 | DONE | syscall.lua ioctl console_mode | cooked/raw switching implemented |

## 5.8 Time (SPEC §5.8)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 136 | time() → secs — epoch, UTC | §5.8 | DONE | syscall.lua:279 (delegates to os.time()) | |
| 137 | clock() → cpu_secs — process CPU time | §5.8 | DONE | syscall.lua:280 (delegates to os.clock()) | Returns wall-clock time, not true CPU time (CC limitation) |
| 138 | sleep(secs) | §5.8 | DONE | syscall.lua:93-96 | (Also in §5.1 #35) |
| 139 | alarm(secs) | §5.8 | DONE | syscall.lua:243-255 | (Also in §5.1 #31) |
| 140 | clock_gettime(clock) → secs, nsecs — CLOCK_REALTIME \| CLOCK_MONOTONIC | §5.8 | MISSING | **No `clock_gettime` syscall registered** | |

## 5.9 Power (SPEC §5.9)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 141 | reboot() → ok — reboot(8) | §5.9 | MISSING | **No `reboot` syscall registered** (CC has os.reboot but kernel doesn't expose it) | |
| 142 | halt() → ok — halt(8) | §5.9 | MISSING | **No `halt` syscall registered** (CC has os.shutdown but kernel doesn't expose it) | |
| 143 | `shutdown(fd, how)` is socket syscall, not power | §5.9 | DONE | syscall.lua:570-574 | (Documented as distinct from power) |

## 6. Boot (SPEC §6)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 144 | `/boot/knuck.conf`: module list + init path + kernel params | §6 | MISSING | **No knuck.conf file exists** in repo; no config parser | boot.lua hardcodes everything |
| 145 | Kernel loads modules per config, launches pid 1 with root creds | §6 | PARTIAL | boot.lua:198 (spawn init with uid=0 gid=0) | **Init path hardcoded** (`/knuck/sbin/init.lua`), not from config |
| 146 | init works per init.rc (Android-style: services, actions) | §6 | DONE | userspace/init.lua:24-48 (parses `service <name> <path>`) | |
| 147 | Boot-time self-diagnostics: before init, check platform capabilities | §6 | DONE | diag.lua:41-63; boot.lua:147-149 (runs diag before core modules) | |
| 148 | Results written to /proc/selfcheck and log | §6 | DONE | vfs.lua:169-175 (/proc/selfcheck readable); boot.lua:186-195 (banner output) | |
| 149 | Critical feature missing → rollback to cooperative, mark in /proc/selfcheck | §6 | DONE | boot.lua:188-191 (checks selfcheck.preempt, prints scheduler mode); sched.lua:108 (skips sethook if !preempt) | |
| 150 | Diagnostics are part of kernel, not separate script | §6 | DONE | diag.lua loaded by boot.lua as kernel module | |

## 7. Man Pages (SPEC §7)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 151 | man pages for every syscall — part of distribution | §7 | MISSING | **No man pages exist** in the repository | |
| 152 | Stored in VFS (e.g., `/usr/share/man/man2/`) | §7 | MISSING | No `/usr/share/man` directory | |
| 153 | Readable by userspace `man` command | §7 | MISSING | No `man` command exists | |
| 154 | Format: plain text/roff-like; kernel stores, userspace renders | §7 | MISSING | No man page files | |

## 8. Testing (SPEC §8)

| # | Requirement | Spec ref | Status | Evidence | Notes |
|---|-------------|----------|--------|----------|-------|
| 155 | `tests/conformance.lua` — one big test file | §8 | DONE | tests/conformance.lua (688 lines) | Exists |
| 156 | Section 1 (Platform): check runtime assumptions on bare CraftOS | §8 | DONE | conformance.lua:72-263 (sections 1.1-1.14: Lua, CraftOS APIs, events, hardware, sandbox, timing) | |
| 157 | Section 2 (Kernel): run all syscalls, matrix OK/LIMITED/CUT/ERROR/SKIP | §8 | PARTIAL | conformance.lua:267-617 (sections 2-6) | **Section tests CraftOS APIs, NOT KNUCK syscalls**. No kernel syscall test matrix exists |
| 158 | Run on real CC computer, output sent to developer | §8 | N/A | Process requirement; not testable in source | |

---

## SUMMARY

### Totals

| Status | Count |
|--------|-------|
| **DONE** | 123 |
| **PARTIAL** | 18 |
| **MISSING** | 15 |
| **N/A** | 7 |
| **Total requirements** | **163** |

### Every MISSING item (backlog)

| # | Requirement | Spec ref | Notes |
|---|-------------|----------|-------|
| 18 | sched_setscheduler(pid?, policy) — "rr"\|"fifo"\|"other" | §4, §5.1 | Scheduler policy system entirely absent |
| 30b | setpgid(pid, pgid) | §5.1 | getpgrp exists but setpgid not registered |
| 37 | sched_setscheduler(pid?, policy) | §5.1 | (Same as #18, listed in syscall table) |
| 92 | fstype floppy/hdd | §5.4 | No disk drive filesystem type |
| 100 | /mnt/disk0..N auto-mount | §5.4 | No auto-mount on peripheral attach |
| 119 | insmod(path) syscall | §5.5 | No module loading |
| 120 | rmmod(name) syscall | §5.5 | No module unloading |
| 121 | /boot/knuck.conf config file | §5.5, §6 | No config file or parser |
| 140 | clock_gettime(clock) → secs, nsecs | §5.8 | Not registered |
| 141 | reboot() syscall | §5.9 | Not registered |
| 142 | halt() syscall | §5.9 | Not registered |
| 151 | Man pages for every syscall | §7 | No man pages |
| 152 | /usr/share/man/man2/ in VFS | §7 | No man directory |
| 153 | `man` userspace command | §7 | No man command |
| 154 | Man page format (plain text/roff) | §7 | Nothing to format |

### Every PARTIAL item (needs completion)

| # | Requirement | Spec ref | What's missing |
|---|-------------|----------|----------------|
| 13 | Process env safe stdlib includes `bit` | §3 | `bit` not in SAFE_LIBS (proc.lua:21) |
| 30a | getpgrp() | §5.1 | Exists but paired setpgid missing |
| 40 | Signal number constants exported | §5.1 | Numbers work inline; no named constants for userspace |
| 41 | SIGCHLD signal delivery to parent | §5.1 | Only wakes waitpid; no actual signal #17 queued |
| 55 | bind(fd, addr) for HTTP | §5.3 | HTTP bind not implemented |
| 59 | send flags parameter | §5.3 | Flags accepted but ignored |
| 60 | recv flags parameter | §5.3 | Flags accepted but ignored |
| 65 | setsockopt — SO_REUSEADDR, SO_RCVTIMEO | §5.3 | Only SO_BROADCAST implemented |
| 66 | getsockopt — full options | §5.3 | Only SO_BROADCAST |
| 85 | link(old, new) — true hardlink | §5.4 | Copy+delete, not inode-sharing |
| 110 | /sys/kernel/quantum, /sys/kernel/priority | §5.4 | Only version + scheduler |
| 112 | /sys/modules/* with status, writable | §5.4 | K.modules empty; no write handling |
| 115 | /proc/<pid>/fd — actual open fd list | §5.4 | Hardcoded "0\tconsole\n1\tconsole\n2\tconsole\n" |
| 116 | /proc/<pid>/mem — memory info | §5.4 | Stub returning "0\n" |
| 122 | Hotplug — structured event format | §5.5 | Raw CC event passed, no KNUCK format |
| 133 | ioctl — more than tty_switch | §5.7 | Only tty_switch |
| 157 | conformance.lua tests KNUCK syscalls | §8 | Tests CraftOS APIs, not kernel syscalls |

---

## Process: Ambiguous / Needs Decision

| # | Spec text | Issue | Recommendation |
|---|-----------|-------|----------------|
| A | `select(reads?, writes?, timeout?) → n, r, w` | Spec says 3 args + count return. Impl has 4 args (adds exceptfds) + table returns. | Clarify: keep extension (exceptfds) or align? Return tables or (n, tables)? |
| B | `poll(fds, timeout?) → n` | Spec says return count. Impl returns ready-fd table. | Table is more useful. Align spec or keep impl? |
| C | `clock() → cpu_secs — clock(3): CPU-время процесса` | CC's os.clock() returns wall time, not CPU time. | Accept as platform limitation (add to CUTs) or note deviation? |
| D | `chroot(path)` enforcement | Spec says "process sees only subtree." Impl sets proc.root but resolve() ignores it. | Must fix resolve() to enforce chroot jail, or mark as CUT (platform has no real isolation anyway). |
| E | `/proc/<pid>/fd` hardcoded | Always shows 0/1/2 to console. Should reflect actual fd table. | Low priority; consider fixing for debugging value. |
| F | `link()` hardlink semantics | CC has no inode concept. Copy-based "hardlink" doesn't share writes. | Accept as platform CUT. Update spec to document? |
| G | Signal number constants in userspace | Numbers work; no named constants like `SIGTERM=15`. | Export a `signals` table in process env? |
| H | `/dev/input` and `/dev/periph/<side>` | Listed in readdir but can't open. Design question: should kernel delegate to CC peripheral API? | Implement thin wrappers or remove from dev_list? |
| I | Socket fds vs send/recv | POSIX allows read/write on stream sockets. Impl requires send/recv. | Add socket dispatch to vfs.read/vfs.write for STREAM sockets? |
| J | `readdir` return format | Spec says `{name, is_dir, ...}`. Impl returns `{"name1", "name2", ...}`. | Redesign return format or update spec? Structured entries are more useful. |
