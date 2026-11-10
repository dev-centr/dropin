module dropin.ring;

import core.stdc.string : memcpy;
import dropin.os : Mapping, processAlive;
import dropin.protocol;

struct Ring
{
    Mapping map;
    Header* header;
    Slot* slots;

    int open(const(char)[] path, const(char)[] tasks)
    {
        auto bytes = Header.sizeof + Slot.sizeof * dropinCapacity;
        if (!map.open(path, bytes))
            return DropinError.io;
        header = cast(Header*) map.view;
        slots = cast(Slot*) (map.view + Header.sizeof);
        return publishHeader(tasks);
    }

    void close() nothrow @nogc
    {
        header = null;
        slots = null;
        map.close();
    }

    int publishHeader(const(char)[] tasks) nothrow @nogc
    {
        uint spins;
        while (spins++ < 2000)
        {
            auto magic = loadUint(&header.magic);
            if (magic == dropinMagic)
                break;
            if (magic == 0 && casUint(&header.magic, 0, dropinInitializing))
            {
                header.version_ = dropinVersion;
                header.abi = dropinAbi;
                header.capacity = dropinCapacity;
                header.payload = dropinPayload;
                header.sessionState = SessionState.empty;
                storeUint(&header.busy, 0);
                storeUlong(&header.ownerPid, 0);
                storeUlong(&header.engineGen, 0);
                storeUlong(&header.ticket, 0);
                storeUlong(&header.head, 0);
                storeUlong(&header.tasksRev, 0);
                storeUlong(&header.pluginGen, 0);
                rememberTasks(tasks);
                storeUint(&header.magic, dropinMagic);
                break;
            }
            dropinYield();
        }
        if (loadUint(&header.magic) != dropinMagic)
            return DropinError.badMagic;
        if (header.version_ != dropinVersion || header.abi != dropinAbi
            || header.capacity != dropinCapacity || header.payload != dropinPayload)
            return DropinError.badVersion;
        if (header.tasksPathLen == 0)
            rememberTasks(tasks);
        return DropinError.ok;
    }

    void rememberTasks(const(char)[] tasks) nothrow @nogc
    {
        auto n = tasks.length;
        if (n > dropinPathCap)
            n = dropinPathCap;
        if (n)
            memcpy(header.tasksPath.ptr, tasks.ptr, n);
        header.tasksPathLen = cast(uint) n;
    }

    void recoverDeadOwner(ulong me) nothrow @nogc
    {
        auto owner = loadUlong(&header.ownerPid);
        if (owner != 0 && owner != me && !processAlive(owner))
        {
            storeUlong(&header.ownerPid, 0);
            storeUint(&header.busy, 0);
        }
    }

    bool steal(ulong pid) nothrow @nogc
    {
        while (true)
        {
            if (loadUint(&header.busy) != 0)
            {
                dropinYield();
                continue;
            }
            auto cur = loadUlong(&header.ownerPid);
            if (cur == pid)
                return true;
            if (casUlong(&header.ownerPid, cur, pid))
            {
                fetchAddUlong(&header.engineGen, 1);
                storeUint(&header.sessionState, SessionState.live);
                return true;
            }
        }
    }

    int tryPublish(uint opcode, const(void)* req, uint reqLen, ulong* ticket) nothrow @nogc
    {
        if (reqLen > dropinPayload)
            return DropinError.tooBig;
        auto next = loadUlong(&header.ticket);
        auto head = loadUlong(&header.head);
        if (next >= head + dropinCapacity)
            return DropinError.pending;
        if (!casUlong(&header.ticket, next, next + 1))
            return DropinError.pending;
        auto slot = slots + (next % dropinCapacity);
        while (loadUint(&slot.state) != SlotState.free)
        {
            auto st = loadUint(&slot.state);
            if (st == SlotState.done || !processAlive(loadUlong(&header.ownerPid)))
                casUint(&slot.state, st, SlotState.free);
            else
                dropinYield();
        }
        storeUlong(&slot.ticket, next);
        slot.opcode = opcode;
        slot.reqLen = reqLen;
        slot.respLen = 0;
        slot.status = 0;
        if (reqLen && req !is null)
            memcpy(slot.req.ptr, req, reqLen);
        storeUint(&slot.state, SlotState.ready);
        *ticket = next;
        return DropinError.ok;
    }

    bool claimNext(ulong* ticket) nothrow @nogc
    {
        auto head = loadUlong(&header.head);
        if (head == loadUlong(&header.ticket))
            return false;
        auto slot = slots + (head % dropinCapacity);
        if (loadUint(&slot.state) != SlotState.ready || loadUlong(&slot.ticket) != head)
            return false;
        storeUint(&slot.state, SlotState.claimed);
        *ticket = head;
        return true;
    }

    void complete(ulong ticket, int status, const(void)* resp, uint respLen) nothrow @nogc
    {
        auto slot = slots + (ticket % dropinCapacity);
        if (respLen > dropinPayload)
            respLen = dropinPayload;
        if (respLen && resp !is null)
            memcpy(slot.resp.ptr, resp, respLen);
        slot.respLen = respLen;
        slot.status = status;
        storeUint(&slot.state, SlotState.done);
        fetchAddUlong(&header.head, 1);
    }

    int poll(ulong ticket, char* resp, uint respCap, uint* respLen, int* status) nothrow @nogc
    {
        auto slot = slots + (ticket % dropinCapacity);
        if (loadUlong(&slot.ticket) != ticket || loadUint(&slot.state) != SlotState.done)
            return DropinError.pending;
        auto n = slot.respLen;
        if (n > respCap)
            n = respCap;
        if (n && resp !is null)
            memcpy(resp, slot.resp.ptr, n);
        *respLen = n;
        *status = slot.status;
        storeUint(&slot.state, SlotState.free);
        return DropinError.ok;
    }
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto dir = buildPath(tempDir(), "dropin-ring-" ~ randomUUID.toString());
    mkdirRecurse(dir);
    Ring ring;
    scope (exit)
    {
        ring.close();
        rmdirRecurse(dir);
    }
    auto path = buildPath(dir, "ring.bin");
    auto tasks = buildPath(dir, "tasks.sdl");
    assert(ring.open(path, tasks) == DropinError.ok);
    assert(ring.steal(11));
    assert(ring.steal(22));
    assert(loadUlong(&ring.header.ownerPid) == 22);

    ulong ticket;
    immutable msg = "ping";
    assert(ring.tryPublish(Opcode.ping, msg.ptr, cast(uint) msg.length, &ticket) == DropinError.ok);
    ulong claimed;
    assert(ring.claimNext(&claimed));
    assert(claimed == ticket);
    immutable pong = "pong";
    ring.complete(claimed, 0, pong.ptr, cast(uint) pong.length);
    char[16] buf;
    uint n;
    int status;
    assert(ring.poll(ticket, buf.ptr, buf.length, &n, &status) == DropinError.ok);
    assert(status == 0);
    assert(buf[0 .. n] == "pong");
}
