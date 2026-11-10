module dropin.protocol;

/++
File-backed ring shared by every CLI, the MCP server, and the resident engine.

The mapping is raw bytes. Nothing here calls `GC.addRange`, so the default
GC, tgc, and `@nogc` callers can all use it. Do not put D pointers or class
references in the file. Surviving state belongs in this ring or in the task
file, not in a plugin's heap.
+/

enum uint dropinMagic = 0x4E495244; // 'DRIN'
enum uint dropinInitializing = 1;
enum ushort dropinVersion = 1;
enum ushort dropinAbi = 1;
enum uint dropinCapacity = 32;
enum uint dropinPayload = 8192;
enum uint dropinPathCap = 512;

enum DropinError : int
{
    ok = 0,
    pending = 1,
    badSession = -1,
    badMagic = -2,
    badVersion = -3,
    tooBig = -4,
    timeout = -5,
    notOwner = -6,
    io = -8,
    noEngine = -9,
    plugin = -10,
    usage = -11,
    busy = -12,
}

enum Opcode : uint
{
    ping = 1,
    status = 2,
    shutdown = 3,
    tasksPut = 4,
    tasksGet = 5,
    reload = 6,
    notify = 7,
    handoff = 8,
}

struct Header
{
align(8):
    uint magic;
    ushort version_;
    ushort abi;
    uint capacity;
    uint payload;
    uint sessionState;
    uint busy;
    ulong ownerPid;
    ulong engineGen;
    ulong ticket;
    ulong head;
    ulong tasksRev;
    ulong pluginGen;
    uint tasksPathLen;
    uint reserved;
    char[dropinPathCap] tasksPath;
}

struct Slot
{
align(8):
    ulong ticket;
    uint state;
    int status;
    uint opcode;
    uint reqLen;
    uint respLen;
    char[dropinPayload] req;
    char[dropinPayload] resp;
}

enum SlotState : uint
{
    free = 0,
    ready = 1,
    claimed = 2,
    done = 3,
}

enum SessionState : uint
{
    empty = 0,
    live = 1,
    drain = 2,
}

static assert(Header.sizeof % 8 == 0);
static assert(Slot.sizeof % 8 == 0);

ulong loadUlong(ulong* p) nothrow @nogc
{
    import core.atomic : atomicLoad;
    return atomicLoad(*(cast(shared(ulong)*) p));
}

void storeUlong(ulong* p, ulong v) nothrow @nogc
{
    import core.atomic : atomicStore;
    atomicStore(*(cast(shared(ulong)*) p), v);
}

bool casUlong(ulong* p, ulong from, ulong to) nothrow @nogc
{
    import core.atomic : cas;
    return cas(cast(shared(ulong)*) p, from, to);
}

uint loadUint(uint* p) nothrow @nogc
{
    import core.atomic : atomicLoad;
    return atomicLoad(*(cast(shared(uint)*) p));
}

void storeUint(uint* p, uint v) nothrow @nogc
{
    import core.atomic : atomicStore;
    atomicStore(*(cast(shared(uint)*) p), v);
}

bool casUint(uint* p, uint from, uint to) nothrow @nogc
{
    import core.atomic : cas;
    return cas(cast(shared(uint)*) p, from, to);
}

ulong fetchAddUlong(ulong* p, ulong n) nothrow @nogc
{
    import core.atomic : atomicFetchAdd;
    return atomicFetchAdd(*(cast(shared(ulong)*) p), n);
}

void dropinYield() nothrow @nogc
{
    version (Windows)
    {
        import core.sys.windows.winbase : Sleep;
        Sleep(1);
    }
    else version (Posix)
    {
        import core.sys.posix.unistd : usleep;
        usleep(1000);
    }
    else
    {
        static assert(0, "dropin needs Windows or Posix");
    }
}
