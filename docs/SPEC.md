# KNUCK — Not-Unix-Compliant Kernel

Ядро для CC-компьютеров (ComputerCraft:Tweaked) на Lua 5.2 (рантайм Cobalt).
Микроядро с подгружаемыми модулями. Набор требований к **готовому** ядру.

---

## 1. Философия и архитектура

- **Микроядро**: ядро минимально, функциональность — в подгружаемых модулях-драйверах.
- **HAL**: всё, что даёт CraftOS (`os/fs/term/peripheral/http/...`) — «железо».
  Доступно **только ядру**. Юзер-спейс не имеет прямого доступа к железу.
- **Драйверы**: единственные, кто трогает железо. Даже вывод на экран — сисколл →
  ядро → драйвер `term`. Драйверы регистрируют device-ноды в VFS.
- **Юзер-спейс**: только сисколлы. Прямого доступа к железу нет.
- **Единый socket-API**: одно API на все семейства (AF_UNIX/AF_MODEM4/AF_MODEM6/AF_HTTP),
  домен выбирает транспорт, поверхность общая (как в Linux).
- **Политика — в юзер-спейсе, механизм — в ядре** (DHCP, монтирование, man — юзер-спейс;
  ARP, планировщик, VFS — ядро).

## 2. Платформа и ограничения

- **Целевая платформа: CraftOS 1.9** (CC:Tweaked ~1.90, рантайм Cobalt, Lua 5.2).
  Проверено на реальном железе: `yield_from_hook` работает, `sandbox_env` работает.
- **Вытесняющий планировщик**: `debug.sethook` + count-hook + `coroutine.yield` из hook.
  Работает в Cobalt (официально протестировано). В CraftOS-PC (настоящий Lua C) —
  yield из hook запрещён → планировщик откатывается на кооператив.
- **Ограничения CraftOS 1.9 (проверено тестом):**
  - `collectgarbage` **отсутствует** → учёт памяти через `collectgarbage("count")` недоступен.
    Учёт памяти — **условный**: включается только если `collectgarbage` есть (самодиагностика
    решает на старте). На CraftOS 1.9 — мягкий режим: без жёстких лимитов памяти, защита
    через песочницы `_ENV` + бюджет инструкций + сторож CC.
  - `fs.rename` **отсутствует** → VFS-драйвер `rename` реализует copy+delete, не полагаясь на `fs.rename`.
  - `component`, `textutils.format` отсутствуют — не критично для ядра.
- **Единственные CUT (физика платформы, не выбор):**
  - `fork` — корутину Lua нельзя клонировать (покрывается `spawn`+`exec`).
  - Таймстампы файлов — CC их не хранит (`utime` нечему писать).
  - Аппаратная изоляция памяти — одна куча VM. На CraftOS 1.9 без `collectgarbage`
    жёсткие бюджеты памяти невозможны; смягчение — песочницы + бюджет инструкций + сторож CC.
  - Сигналы памяти (SEGV/FPE/ABRT) — источник в Lua — uncaught error → маппится на SIGSEGV.
  - `bind` для AF_HTTP — CC `http` не имеет серверной стороны; HTTP-сокет только `connect` (клиент).
  - `link` (жёсткая ссылка) — CC не имеет inode; реализуется copy+delete, nlink инкрементируется.
- Сторож CC: ~7s soft abort / +1.5s hard abort — страховка от зависания ядра.

## 3. Изоляция процессов

- Каждый процесс грузится со **своим `_ENV`** (песочница). Имён `os/fs/term/...`
  в цепочке окружений процесса **не существует** — не «договорились», а лексически недостижимо.
- В env процесса: только сисколл-обёртки ядра + безопасные stdlib (`string/math/table/coroutine/bit`).
- Затыкаются эскапизмы: `io`, `os`, `debug`, `package` — убраны из песочницы;
  `load`/`loadstring` наследуют env вызывающего.
- **Дисциплина сисколлов**: ядро не возвращает процессу внутренние таблицы «как есть» —
  только копии/представления. Одна утечка хэндла ломает изоляцию.

## 4. Планировщик

- Вытеснение по квантам: `resume(proc, quantum=N)` → count-hook тикает каждые N инструкций →
  `coroutine.yield(SENTINEL)` → ядро выбирает следующего → `resume(proc)`.
  Контекст (локалы, апвалью, стек) сохраняется — процесс не знает, что его прерывали.
- Приоритеты: `getpriority`/`setpriority`, диапазон −20..19, **меньше = выше** (POSIX).
- Политики: `sched_setscheduler` — `"rr" | "fifo" | "other"`. Квант — атрибут политики `rr`, не сисколл.
- Состояния: `running | ready | waiting | stopped | zombie | dead`.
- Zombie: убитый процесс держит код выхода до `waitpid`; сироты усыновляет init (pid 1).
- Uncaught error процесса → смерть как от SIGSEGV; ядро логирует текст ошибки.

## 5. Сисколлы

### 5.1 proc

```
getpid() / getppid()
getuid() / geteuid() / getgid() / getegid()
setuid(uid) / setgid(gid)
spawn(path, ...) → pid            -- posix_spawn(3)
exec(path, ...)                   -- execve(2); только nil,err на неудачу
exit(code)
waitpid(pid, opt?) → pid,status   -- opt="nohang" (WNOHANG); pid=-1 любой потомок
kill(pid, sig)                    -- правило: свой uid или root; -1 всем кроме себя; 0 своей группе
getpgrp() / setpgid(pid, pgid)
alarm(secs)                       -- SIGALRM
signal(sig, handler|nil|"ignore") -- sigaction(2)-аналог
sigprocmask(how, set?)            -- блокировка/разблокировка сигналов
sched_yield()
sleep(secs)                       -- float-секунды
getpriority(pid?) / setpriority(pid?, prio)   -- -20..19, меньше=выше
sched_setscheduler(pid?, policy)  -- "rr"|"fifo"|"other"
chdir(path) / getcwd()
umask(mask?)
```

**Сигналы** (номера Linux/POSIX):
`HUP 1, INT 2, QUIT 3, KILL 9, USR1 10, USR2 12, PIPE 13, ALRM 14, TERM 15, CHLD 17, CONT 18, STOP 19`.

- SIGCHLD — уведомление родителя о завершении потомка (разблокирует waitpid).
- SIGPIPE — write в пайп без читателя → сигнал, дефолт = завершение.
- SIGKILL/SIGSTOP — не блокируемы.

### 5.2 security

```
chmod(path, mode)                 -- rwxrwxrwx (восьмеричный режим)
chown(path, uid, gid)
chgrp(path, gid)
```

- root (uid 0) обходит проверки прав.
- setuid/setgid-биты на исполняемых файлах: при exec процесс получает euid/egid владельца.
- mount/umount — только root.
- kill — по правилу uid (свой процесс или root).
- Дополнительные группы — **нет** (только основная gid).

### 5.3 ipc

```
pipe() → rfd, wfd                 -- анонимный пайп
mkfifo(path, mode)                -- именованный пайп
socket(domain, type, proto) → fd  -- AF_UNIX|AF_MODEM4|AF_MODEM6|AF_HTTP × STREAM|DGRAM|RAW
bind(fd, addr)                    -- inet: {ip=, port=}; unix: {path=}; http: {host=, port=} [CUT: http — только connect]
listen(fd, backlog)
accept(fd) → fd                   -- блокирующий
connect(fd, addr)
send(fd, data, flags?) → n
recv(fd, len?, flags?) → data|nil
close(fd)
shutdown(fd, "read"|"write"|"both")
getsockname(fd) → addr
getpeername(fd) → addr
setsockopt(fd, opt, val)          -- SO_REUSEADDR, SO_BROADCAST, SO_RCVTIMEO…
getsockopt(fd, opt) → val
select(reads?, writes?, timeout?) → r, w, e   -- таблицы готовых fd (не счётчик)
poll(fds, timeout?) → ready_fds               -- массив готовых fd
```

**Address families (AF_*)** — числовые константы, доступны из юзер-спейса:
```
AF_UNIX   = 1    -- локальные (UNIX domain) сокеты
AF_MODEM4 = 2    -- IPv4 поверх CC-модема (основной сетевой домен)
AF_INET   = 2    -- алиас для AF_MODEM4
AF_ICMP   = 2    -- УСТАРЕЛ: алиас для AF_MODEM4 (используйте AF_MODEM4 + IPPROTO_ICMP)
AF_HTTP   = 3    -- HTTP поверх CraftOS http API
AF_MODEM6 = 10   -- IPv6 поверх CC-модема (зарезервирован, не реализован)
AF_INET6  = 10   -- алиас для AF_MODEM6
```

**Socket types (SOCK_*)**:
```
SOCK_STREAM = 1  -- потоковый (TCP для AF_MODEM4)
SOCK_DGRAM  = 2  -- датаграммный (UDP для AF_MODEM4)
SOCK_RAW    = 3  -- сырой (ICMP для AF_MODEM4)
```

**IP protocol numbers (IPPROTO_*)**:
```
IPPROTO_IP   = 0   -- IP (не указывать явно)
IPPROTO_ICMP = 1   -- ICMP (ping, traceroute)
IPPROTO_TCP  = 6   -- TCP
IPPROTO_UDP  = 17  -- UDP
```

- Сокеты — FD: `read/write/close` работают на них (POSIX).
- AF_HTTP — HTTP-запросы (GET/POST/заголовки) через единый socket-API, обёртка над CC `http`.
  WebSocket — нет.
- ICMP raw: `socket("modem4", "raw", 1)` (AF_MODEM4 + SOCK_RAW + IPPROTO_ICMP).
  Deprecated: `socket("icmp", "dgram", 1)` — работает как алиас, логирует предупреждение.
- Константы AF_*/SOCK_*/IPPROTO_* доступны в песочнике процесса как глобальные переменные.

### 5.4 vfs

```
mount(source, target, fstype, opts?) → ok   -- opts: "ro"|"rw"; только root
umount(target) → ok
open(path, flags) → fd            -- flags: "r" "w" "a" "r+" "w+"
close(fd)
read(fd, n?) → data|nil           -- n=0 → сколько есть; nil на EOF
write(fd, data) → n
mkdir(path) / rmdir(path)
unlink(path)
readdir(dir) → {name, is_dir, ...}
stat(path) → {size=, type=, mode=, uid=, gid=, nlink=, ...}
rename(old, new)
lseek(fd, offset, whence?)        -- whence: "set"|"cur"|"end"
fstat(fd) → info
symlink(target, path) / readlink(path)
link(old, new)                    -- жёсткая ссылка [CUT: copy+delete, нет inode]
chroot(path)                      -- процесс видит только поддерево
```

**fstype**: `disk` (хранилище компьютера), `tmp` (в памяти), `dev` (device-ноды),
`sys` (настройки ядра), `proc` (procfs), `floppy`/`hdd` (дисководы), `rom` (платформа CC).

**Дерево монтирования:**
```
/            <- хранилище компьютера (writable)   [disk]
/boot        <- образ ядра + модули (writable)    [disk]
/tmp         <- tmpfs, чистится при старте        [tmp]
/dev         <- device-ноды                        [dev]
/sys         <- настройки ядра                     [sys]
/proc        <- procfs                             [proc]
/mnt/disk0..N <- дисководы при подключении          [floppy/hdd]
/rom         <- платформенная база CC (не наша система)
```

**Device-ноды `/dev`:** `console`, `input`, `periph/<side>`, `null`, `zero`, `urandom`, `devctl`.
- `/dev/console` — терминал (fds 0/1/2, controlling terminal). Cooked (строки) по умолчанию,
  raw (события) через `ioctl`.
- `/dev/input` — сырые события (term/char/mouse).
- `/dev/devctl` — события устройств (attach/detach) для юзер-спейс-демона монтирования.
- `/dev/modemN` — сырые фреймы линк-уровня (диагностика).

**`/sys`:** `/sys/kernel/*` (квант, приоритеты), `/sys/net/*` (IP-конфиг, ARP-кэш, маршруты),
`/sys/modules/*` (загруженные модули, статус). Запись в файл = конфигурация ядра.

**`/proc`:** `/proc/<pid>/{status,cmdline,fd,mem}`, `/proc/uptime`, `/proc/version`.

### 5.5 modules

```
insmod(path) → ok                 -- загрузить модуль-драйвер
rmmod(name) → ok                  -- выгрузить
```

- Список модулей на старте — `/boot/knuck.conf`.
- Hotplug: ядро детектит подключение устройства (механизм), событие уходит в `/dev/devctl`;
  решение о монтировании — юзер-спейс (политика).

### 5.6 network

- **Ethernet** (литеральные фреймы): dest(6)+src(6)+ethertype(2)+payload+FCS(4).
  MAC — локально-администрируемый `02:00:00:00:xx:xx` из modem-id. FCS считается и проверяется.
- **IP** (RFC 791): фрагментация и сборка. Протоколы: IPPROTO_ICMP=1, IPPROTO_TCP=6, IPPROTO_UDP=17.
- **ICMP** (RFC 792): модуль `net_icmp.lua`. Сокет: `socket("modem4", "raw", IPPROTO_ICMP)`.
  Deprecated: `socket("icmp", "dgram", IPPROTO_ICMP)` — алиас для обратной совместимости.
- **ARP** (RFC 826): в ядре, на каждом узле. Кэш `IP→MAC` с таймаутом, статические записи.
- **TCP** (RFC 793) / **UDP** (RFC 768): литеральные протоколы.
- Маршрутизация: статические маршруты + default gw через `/sys/net`. Маршруты привязаны к address family (AF_MODEM4/AF_MODEM6).
- DHCP — юзер-спейс (ядро даёт UDP + broadcast; демон прописывает IP через `/sys/net`).
- Конфигурация сети — через `/sys/net` (не отдельный сисколл).

### 5.7 console

```
ioctl(fd, cmd, ...)               -- управление устройством
```

- `/dev/console`: cooked (строки по Enter) по умолчанию, raw (события) через `ioctl`.
- Режимы терминала — через `ioctl` на консоли.

### 5.8 time

```
time() → secs                     -- time(2): эпоха, UTC
clock() → cpu_secs                -- clock(3): CPU-время процесса
sleep(secs)                       -- (в proc)
alarm(secs)                       -- (в proc)
clock_gettime(clock) → secs, nsecs -- CLOCK_REALTIME | CLOCK_MONOTONIC
```

### 5.9 power

```
reboot() → ok                     -- reboot(8): перезагрузка
halt() → ok                       -- halt(8): выключение
```

`shutdown(fd, how)` — сокетный сисколл (POSIX shutdown(2)), не путать с питанием.

## 6. Boot

- `/boot/knuck.conf`: список модулей + путь init + параметры ядра.
- Ядро грузит модули по конфигу, запускает pid 1 (`/sbin/init`) с root-кредами.
- init работает по **init.rc** (стиль Android: сервисы, действия). Формат init.rc — дело init;
  ядро даёт `spawn`/`exec`/`waitpid` для этого.
- **Boot-time self-diagnostics**: перед запуском init ядро прогоняет самопроверку платформы
  (наличие `debug.sethook`, yield-from-hook, `collectgarbage`, fs-хэндлов, версии Lua/CraftOS).
  Результат пишется в `/proc/selfcheck` и в лог. Если критичная фича отсутствует
  (например, нет yield-from-hook) — ядро откатывает планировщик на кооператив и помечает
  это в `/proc/selfcheck`. Диагностика — часть ядра, не отдельный скрипт.

## 7. man

- man-страницы на **каждый сисколл** — часть дистрибутива.
- Хранятся в VFS (например `/usr/share/man/man2/`), читаются юзер-спейс-командой `man`.
- Формат: простой текст/roff-подобный. Ядро лишь хранит их как файлы; рендер — юзер-спейс.

## 8. Тестирование

- `tests/conformance.lua` — один большой тест-файл.
  - Секция 1 (Платформа): проверка допущений о рантайме на голом CraftOS.
  - Секция 2 (Ядро): прогон по всем сисколлам, матрица `OK / LIMITED / CUT / ERROR / SKIP`.
- Запуск на реальном CC-компьютере, вывод присылается разработчику.