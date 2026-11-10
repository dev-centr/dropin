module dropin.client;

import core.time : Duration, dur;
import dropin.os : processAlive;
import dropin.protocol;
import dropin.ring : Ring;
import dropin.session : logPath, ringPath, tasksPath;
import std.datetime.systime : Clock;
import std.file : thisExePath;
import std.process : Config, spawnProcess;
import std.stdio : stderr, stdin, stdout;

struct CallResult
{
    int code;
    string response;
    string tasks;
    string logFile;
}

CallResult callSession(string session, uint opcode, const(void)[] body, bool spawn, Duration budget)
{
    CallResult result;
    result.tasks = tasksPath(session);
    result.logFile = logPath(session);
    auto path = ringPath(session);
    if (opcode == Opcode.shutdown)
        spawn = false;
    if (!engineAlive(path, result.tasks))
    {
        if (!spawn)
        {
            result.code = DropinError.noEngine;
            result.response = "engine is not running";
            return result;
        }
        if (!startEngine(session, path, result.tasks))
        {
            result.code = DropinError.noEngine;
            result.response = "engine did not start";
            return result;
        }
    }

    Ring ring;
    scope (exit)
        ring.close();
    auto opened = ring.open(path, result.tasks);
    if (opened != DropinError.ok)
    {
        result.code = opened;
        result.response = "ring unavailable";
        return result;
    }

    char[dropinPayload] buf;
    uint n;
    int status;
    auto rc = publishAndWait(&ring, opcode, body, buf[], &n, &status, budget);
    if (rc != DropinError.ok)
    {
        result.code = rc;
        result.response = rc == DropinError.timeout ? "timed out" : "publish failed";
        return result;
    }
    result.code = status;
    result.response = buf[0 .. n].idup;
    return result;
}

bool engineAlive(string path, string tasks)
{
    import std.file : exists;
    if (!exists(path))
        return false;
    Ring ring;
    scope (exit)
        ring.close();
    if (ring.open(path, tasks) != DropinError.ok)
        return false;
    return processAlive(loadUlong(&ring.header.ownerPid));
}

bool startEngine(string session, string path, string tasks)
{
    try
    {
        spawnProcess([thisExePath, "--session", session, "engine"],
            stdin, stdout, stderr, null, Config.detached);
    }
    catch (Exception)
    {
        return false;
    }
    auto deadline = Clock.currStdTime + dur!"seconds"(3).total!"hnsecs";
    while (Clock.currStdTime < deadline)
    {
        if (engineAlive(path, tasks))
            return true;
        dropinYield();
    }
    return false;
}

int publishAndWait(Ring* ring, uint opcode, const(void)[] body, char[] resp,
    uint* respLen, int* status, Duration budget)
{
    auto deadline = Clock.currStdTime + budget.total!"hnsecs";
    ulong ticket;
    int published = DropinError.pending;
    while (Clock.currStdTime < deadline)
    {
        published = ring.tryPublish(opcode, body.ptr, cast(uint) body.length, &ticket);
        if (published != DropinError.pending)
            break;
        dropinYield();
    }
    if (published != DropinError.ok)
        return published == DropinError.pending ? DropinError.timeout : published;

    while (Clock.currStdTime < deadline)
    {
        auto polled = ring.poll(ticket, resp.ptr, cast(uint) resp.length, respLen, status);
        if (polled != DropinError.pending)
            return polled;
        dropinYield();
    }
    return DropinError.timeout;
}

string opcodeName(uint opcode)
{
    switch (opcode)
    {
    case Opcode.ping:
        return "ping";
    case Opcode.status:
        return "status";
    case Opcode.shutdown:
        return "shutdown";
    case Opcode.tasksPut:
        return "tasks-put";
    case Opcode.tasksGet:
        return "tasks-get";
    case Opcode.reload:
        return "reload";
    case Opcode.notify:
        return "notify";
    case Opcode.handoff:
        return "handoff";
    default:
        return "";
    }
}

uint opcodeByName(string name)
{
    switch (name)
    {
    case "ping":
        return Opcode.ping;
    case "status":
        return Opcode.status;
    case "shutdown":
        return Opcode.shutdown;
    case "tasks-put":
        return Opcode.tasksPut;
    case "tasks-get":
        return Opcode.tasksGet;
    case "reload":
        return Opcode.reload;
    case "notify":
        return Opcode.notify;
    case "handoff":
        return Opcode.handoff;
    default:
        return 0;
    }
}

Duration defaultBudget(uint opcode)
{
    if (opcode == Opcode.handoff || opcode == Opcode.reload)
        return dur!"seconds"(10);
    return dur!"seconds"(5);
}
