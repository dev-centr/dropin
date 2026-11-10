module dropin.cli;

import core.time : dur;
import dropin.client : callSession, defaultBudget, opcodeByName;
import dropin.engine : serve;
import dropin.os : processAlive;
import dropin.protocol;
import dropin.ring : Ring;
import dropin.session : logPath, pluginDir, ringPath, sanitizeSession, tasksPath;
import dropin.mcp : runMcp;
import dropin.tasksfile : writeFileAtomic;
import std.file : exists, read, readText, remove;
import std.json : JSONValue;
import std.process : environment;
import std.stdio : stderr, stdin, stdout, writeln;

int main(string[] args)
{
    bool asJson;
    bool verbose;
    bool spawn = true;
    string session;
    string[] rest;
    for (size_t i = 1; i < args.length; i++)
    {
        auto arg = args[i];
        if (arg == "--json")
            asJson = true;
        else if (arg == "--verbose")
            verbose = true;
        else if (arg == "--no-spawn")
            spawn = false;
        else if (arg == "--session" && i + 1 < args.length)
            session = args[++i];
        else if (arg == "--version")
        {
            writeln("dropin 0.1.0");
            return 0;
        }
        else if (arg == "--help" || arg == "-h")
        {
            help();
            return 0;
        }
        else
            rest ~= arg;
    }
    if (session.length == 0)
    {
        session = environment.get("DROPIN_SESSION");
        if (session.length == 0)
            session = "devcentr";
    }
    session = sanitizeSession(session);
    if (session.length == 0)
        return fail(asJson, "session name must be letters, numbers, dot, underscore, or hyphen", DropinError.badSession, "");

    if (rest.length == 0)
    {
        help();
        return DropinError.usage;
    }

    auto command = rest[0];
    if (command == "engine")
        return runEngine(session, asJson);
    if (command == "mcp")
        return runMcp(session);
    if (command == "reset")
        return reset(session, asJson);
    if (command == "tasks")
        return tasksCommand(session, rest[1 .. $], asJson, verbose, spawn);
    if (command == "call" && rest.length >= 2)
        return callCommand(session, rest[1], rest.length > 2 ? rest[2] : "", asJson, spawn);
    if (command == "handoff" && rest.length >= 2)
        return callCommand(session, "handoff", rest[1], asJson, true);
    if (command == "plugin" && rest.length >= 3 && rest[1] == "reload")
        return callCommand(session, "reload", rest[2], asJson, true);

    help();
    return DropinError.usage;
}

private int runEngine(string session, bool asJson)
{
    auto tasks = tasksPath(session);
    auto path = ringPath(session);
    auto logFile = logPath(session);
    Ring ring;
    scope (exit)
        ring.close();
    auto opened = ring.open(path, tasks);
    if (opened != DropinError.ok)
        return fail(asJson, "could not open ring", opened, logFile);
    if (!asJson)
    {
        writeln("engine live");
        writeln(logFile);
        stdout.flush();
    }
    auto code = serve(&ring, session, tasks, pluginDir(session));
    if (!asJson)
    {
        writeln("engine stopped");
        writeln(logFile);
    }
    else
    {
        JSONValue obj = ["ok": JSONValue(code == 0), "log": JSONValue(logFile)];
        writeln(obj.toString());
    }
    return code == 0 ? 0 : 1;
}

private int tasksCommand(string session, string[] args, bool asJson, bool verbose, bool spawn)
{
    auto path = tasksPath(session);
    auto logFile = logPath(session);
    if (args.length == 0)
        return fail(asJson, "usage: dropin tasks write <file> | read | path", DropinError.usage, logFile);
    if (args[0] == "path")
    {
        if (asJson)
        {
            JSONValue obj = ["ok": JSONValue(true), "tasks": JSONValue(path), "log": JSONValue(logFile)];
            writeln(obj.toString());
        }
        else
        {
            writeln(path);
            writeln(logFile);
        }
        return 0;
    }
    if (args[0] == "read")
    {
        auto text = exists(path) ? readText(path) : "tasks {\n}\n";
        if (asJson)
        {
            JSONValue obj = ["ok": JSONValue(true), "tasks": JSONValue(path), "content": JSONValue(text), "log": JSONValue(logFile)];
            writeln(obj.toString());
        }
        else
        {
            stdout.write(text);
            stderr.writeln(logFile);
        }
        return 0;
    }
    if (args[0] == "write" && args.length >= 2)
    {
        string text;
        try
            text = args[1] == "-" ? readStdin() : readText(args[1]);
        catch (Exception e)
            return fail(asJson, e.msg, DropinError.io, logFile);
        if (!writeFileAtomic(path, text))
            return fail(asJson, "could not write " ~ path, DropinError.io, logFile);
        string note = "file written";
        if (spawn)
        {
            auto noted = callSession(session, opcodeByName("notify"), "", true, defaultBudget(opcodeByName("notify")));
            if (noted.code == 0)
                note = "file written; engine notified";
            else
                note = "file written; engine did not acknowledge";
        }
        if (verbose)
            stderr.writeln(note);
        if (asJson)
        {
            JSONValue obj = ["ok": JSONValue(true), "tasks": JSONValue(path), "note": JSONValue(note), "log": JSONValue(logFile)];
            writeln(obj.toString());
        }
        else
        {
            writeln(note);
            writeln(path);
            writeln(logFile);
        }
        return 0;
    }
    return fail(asJson, "usage: dropin tasks write <file> | read | path", DropinError.usage, logFile);
}

private int callCommand(string session, string name, string body, bool asJson, bool spawn)
{
    auto opcode = opcodeByName(name);
    auto logFile = logPath(session);
    if (opcode == 0)
        return fail(asJson, "unknown command " ~ name, DropinError.usage, logFile);
    const(void)[] payload = body;
    if (name == "tasks-put" && body.length && exists(body))
    {
        try
            payload = cast(void[]) read(body);
        catch (Exception e)
            return fail(asJson, e.msg, DropinError.io, logFile);
    }
    auto result = callSession(session, opcode, payload, spawn, defaultBudget(opcode));
    auto ok = result.code == 0;
    if (asJson)
    {
        JSONValue obj = [
            "ok": JSONValue(ok),
            "code": JSONValue(result.code),
            "op": JSONValue(name),
            "response": JSONValue(result.response),
            "tasks": JSONValue(result.tasks),
            "log": JSONValue(result.logFile)
        ];
        writeln(obj.toString());
    }
    else if (ok)
    {
        if (result.response.length)
            writeln(result.response);
        writeln(result.logFile);
    }
    else
        return fail(asJson, result.response.length ? result.response : "call failed", result.code, result.logFile);
    return ok ? 0 : 1;
}

private int reset(string session, bool asJson)
{
    auto path = ringPath(session);
    auto logFile = logPath(session);
    if (exists(path))
    {
        Ring ring;
        if (ring.open(path, tasksPath(session)) == DropinError.ok)
        {
            auto owner = loadUlong(&ring.header.ownerPid);
            ring.close();
            if (processAlive(owner))
                return fail(asJson, "engine is live; shutdown before reset", DropinError.busy, logFile);
        }
        try
            remove(path);
        catch (Exception e)
            return fail(asJson, e.msg, DropinError.io, logFile);
    }
    if (asJson)
    {
        JSONValue obj = ["ok": JSONValue(true), "log": JSONValue(logFile)];
        writeln(obj.toString());
    }
    else
    {
        writeln("ring reset");
        writeln(logFile);
    }
    return 0;
}

private string readStdin()
{
    import std.array : appender;
    auto buf = appender!string();
    char[4096] chunk;
    while (true)
    {
        auto part = stdin.rawRead(chunk);
        if (part.length == 0)
            break;
        buf.put(part);
    }
    return buf.data;
}

private int fail(bool asJson, string message, int code, string logFile)
{
    if (asJson)
    {
        JSONValue obj = ["ok": JSONValue(false), "code": JSONValue(code), "error": JSONValue(message), "log": JSONValue(logFile)];
        writeln(obj.toString());
    }
    else
    {
        stderr.writeln(message);
        if (logFile.length)
            writeln(logFile);
    }
    return code < 0 ? 1 : code;
}

private void help()
{
    stderr.writeln(
        "dropin 0.1.0\n"
        ~ "Resident engine, CLI, and MCP. The engine is the core. Each CLI or MCP\n"
        ~ "process only appends a request. A new engine binary takes over the same\n"
        ~ "session file without replacing the running executable in place.\n"
        ~ "\n"
        ~ "  dropin --session devcentr engine\n"
        ~ "  dropin --session devcentr call ping\n"
        ~ "  dropin --session devcentr call status\n"
        ~ "  dropin --session devcentr tasks write tasks.sdl\n"
        ~ "  dropin --session devcentr tasks read\n"
        ~ "  dropin --session devcentr tasks path\n"
        ~ "  dropin --session devcentr handoff C:\\path\\to\\new-dropin.exe\n"
        ~ "  dropin --session devcentr plugin reload C:\\path\\to\\plugin.dll\n"
        ~ "  dropin --session devcentr mcp\n"
        ~ "  dropin --session devcentr reset\n"
        ~ "\n"
        ~ "Flags: --json  --verbose  --no-spawn  --session NAME  --version\n"
        ~ "Call names: ping, status, shutdown, tasks-put, tasks-get, notify, reload, handoff\n"
        ~ "Task lists are SDL files. The DevCentr window reloads sessions/devcentr/tasks.sdl.");
}
