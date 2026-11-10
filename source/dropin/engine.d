module dropin.engine;

import core.stdc.string : memcpy;
import dropin.log : logLine;
import dropin.os : currentPid;
import dropin.plugin : Plugin;
import dropin.protocol;
import dropin.ring : Ring;
import dropin.session : logPath;
import dropin.tasksfile : writeFileAtomic;
import std.conv : to;
import std.file : exists, read;
import std.process : Config, spawnProcess;
import std.stdio : stderr, stdin, stdout;

int serve(Ring* ring, string session, string tasksFile, string plugins)
{
    auto me = currentPid();
    ring.recoverDeadOwner(me);
    ring.steal(me);
    auto logFile = logPath(session);
    logLine(logFile, "engine live pid=" ~ to!string(me) ~ " gen=" ~ to!string(loadUlong(&ring.header.engineGen)));
    Plugin plugin;
    scope (exit)
        plugin.unload();

    while (true)
    {
        if (loadUlong(&ring.header.ownerPid) != me)
        {
            logLine(logFile, "handed off");
            return DropinError.ok;
        }
        if (!casUint(&ring.header.busy, 0, 1))
        {
            dropinYield();
            continue;
        }
        if (loadUlong(&ring.header.ownerPid) != me)
        {
            storeUint(&ring.header.busy, 0);
            logLine(logFile, "handed off");
            return DropinError.ok;
        }

        ulong ticket;
        if (!ring.claimNext(&ticket))
        {
            storeUint(&ring.header.busy, 0);
            dropinYield();
            continue;
        }

        auto slot = ring.slots + (ticket % dropinCapacity);
        auto opcode = slot.opcode;
        string req = slot.req[0 .. slot.reqLen].idup;
        char[dropinPayload] resp;
        uint respLen;
        int status;
        bool stop;
        dispatch(ring, &plugin, session, tasksFile, plugins, logFile, opcode, req, resp, respLen, status, stop);
        ring.complete(ticket, status, resp.ptr, respLen);
        storeUint(&ring.header.busy, 0);
        if (stop)
        {
            logLine(logFile, "engine stop");
            return DropinError.ok;
        }
        if (opcode == Opcode.handoff && status == DropinError.ok)
        {
            import std.datetime.systime : Clock;
            import core.time : dur;
            auto start = Clock.currStdTime;
            while (loadUlong(&ring.header.ownerPid) == me)
            {
                if (Clock.currStdTime - start > dur!"seconds"(5).total!"hnsecs")
                {
                    logLine(logFile, "handoff timed out; staying resident");
                    break;
                }
                dropinYield();
            }
            if (loadUlong(&ring.header.ownerPid) != me)
            {
                logLine(logFile, "handed off");
                return DropinError.ok;
            }
        }
    }
}

private void dispatch(Ring* ring, Plugin* plugin, string session, string tasksFile,
    string plugins, string logFile, uint opcode, string req, ref char[dropinPayload] resp,
    ref uint respLen, ref int status, ref bool stop)
{
    uint got;
    auto handled = plugin.call(opcode, req, resp[], &got);
    if (handled == 1)
    {
        respLen = got;
        status = DropinError.ok;
        return;
    }
    if (handled < 0)
    {
        put(resp, respLen, status, "plugin error", handled);
        return;
    }

    switch (opcode)
    {
    case Opcode.ping:
        put(resp, respLen, status, "pong", DropinError.ok);
        return;
    case Opcode.status:
        put(resp, respLen, status, statusText(ring, plugin, tasksFile), DropinError.ok);
        return;
    case Opcode.shutdown:
        storeUint(&ring.header.sessionState, SessionState.drain);
        put(resp, respLen, status, "bye", DropinError.ok);
        stop = true;
        return;
    case Opcode.tasksPut:
        if (!writeFileAtomic(tasksFile, req))
        {
            put(resp, respLen, status, "could not write tasks", DropinError.io);
            return;
        }
        fetchAddUlong(&ring.header.tasksRev, 1);
        put(resp, respLen, status, "wrote " ~ to!string(req.length), DropinError.ok);
        return;
    case Opcode.tasksGet:
        if (!exists(tasksFile))
        {
            put(resp, respLen, status, "", DropinError.ok);
            return;
        }
        auto data = cast(const(ubyte)[]) read(tasksFile);
        if (data.length > dropinPayload)
        {
            put(resp, respLen, status, tasksFile, DropinError.tooBig);
            return;
        }
        putBytes(resp, respLen, status, data, DropinError.ok);
        return;
    case Opcode.notify:
        fetchAddUlong(&ring.header.tasksRev, 1);
        put(resp, respLen, status, tasksFile, DropinError.ok);
        return;
    case Opcode.reload:
        ulong gen = loadUlong(&ring.header.pluginGen);
        auto rc = plugin.reload(req, plugins, &gen);
        storeUlong(&ring.header.pluginGen, gen);
        put(resp, respLen, status, rc == DropinError.ok ? plugin.loadedFrom : "reload failed", rc);
        return;
    case Opcode.handoff:
        if (req.length == 0)
        {
            put(resp, respLen, status, "missing executable path", DropinError.usage);
            return;
        }
        try
        {
            spawnProcess([req, "--session", session, "engine"],
                stdin, stdout, stderr, null, Config.detached);
            logLine(logFile, "handoff spawn " ~ req);
            put(resp, respLen, status, "handoff-started", DropinError.ok);
        }
        catch (Exception e)
        {
            put(resp, respLen, status, e.msg, DropinError.io);
        }
        return;
    default:
        put(resp, respLen, status, "unknown opcode", DropinError.usage);
        return;
    }
}

private string statusText(Ring* ring, Plugin* plugin, string tasksFile)
{
    return "pid=" ~ to!string(loadUlong(&ring.header.ownerPid))
        ~ " gen=" ~ to!string(loadUlong(&ring.header.engineGen))
        ~ " tasksRev=" ~ to!string(loadUlong(&ring.header.tasksRev))
        ~ " plugin=" ~ (plugin.loaded ? "1" : "0")
        ~ "\ntasks=" ~ tasksFile;
}

private void put(ref char[dropinPayload] resp, ref uint respLen, ref int status, string text, int code)
{
    putBytes(resp, respLen, status, text, code);
}

private void putBytes(ref char[dropinPayload] resp, ref uint respLen, ref int status, const(void)[] text, int code)
{
    auto n = text.length;
    if (n > resp.length)
        n = resp.length;
    if (n)
        memcpy(resp.ptr, text.ptr, n);
    respLen = cast(uint) n;
    status = code;
}

unittest
{
    import core.thread : Thread;
    import core.time : dur;
    import std.datetime.systime : Clock;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : environment;
    import std.uuid : randomUUID;

    auto dir = buildPath(tempDir(), "dropin-engine-" ~ randomUUID.toString());
    mkdirRecurse(dir);
    environment["DROPIN_HOME"] = dir;
    scope (exit)
    {
        environment.remove("DROPIN_HOME");
        rmdirRecurse(dir);
    }

    auto session = "unit";
    auto ringFile = buildPath(dir, "sessions", session, "ring.bin");
    auto tasks = buildPath(dir, "sessions", session, "tasks.sdl");
    mkdirRecurse(buildPath(dir, "sessions", session));
    Ring ring;
    assert(ring.open(ringFile, tasks) == DropinError.ok);
    scope (exit)
        ring.close();

    auto worker = new Thread({
        serve(&ring, session, tasks, buildPath(dir, "plugins"));
    });
    worker.start();

    auto start = Clock.currStdTime;
    while (loadUlong(&ring.header.ownerPid) == 0
        && Clock.currStdTime - start < dur!"seconds"(3).total!"hnsecs")
        dropinYield();
    assert(loadUlong(&ring.header.ownerPid) != 0);

    ulong ticket;
    immutable body = "x";
    int published = DropinError.pending;
    while (published == DropinError.pending
        && Clock.currStdTime - start < dur!"seconds"(3).total!"hnsecs")
        published = ring.tryPublish(Opcode.ping, body.ptr, 1, &ticket);
    assert(published == DropinError.ok);

    char[32] buf;
    uint n;
    int status = -1;
    int polled = DropinError.pending;
    while (polled == DropinError.pending
        && Clock.currStdTime - start < dur!"seconds"(3).total!"hnsecs")
        polled = ring.poll(ticket, buf.ptr, buf.length, &n, &status);
    assert(polled == DropinError.ok);
    assert(buf[0 .. n] == "pong");

    int stopped = DropinError.pending;
    while (stopped == DropinError.pending
        && Clock.currStdTime - start < dur!"seconds"(3).total!"hnsecs")
        stopped = ring.tryPublish(Opcode.shutdown, null, 0, &ticket);
    assert(stopped == DropinError.ok);
    worker.join();
    assert(!worker.isRunning);
}
