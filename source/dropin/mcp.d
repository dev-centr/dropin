module dropin.mcp;

import dropin.client : callSession, defaultBudget, opcodeByName;
import dropin.session : tasksPath;
import dropin.tasksfile : writeFileAtomic;
import std.conv : to;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : stdin, stdout, stderr;

int runMcp(string session)
{
    version (Windows)
    {
        import core.stdc.stdio : _setmode;
        enum int binary = 0x8000;
        _setmode(stdin.fileno, binary);
        _setmode(stdout.fileno, binary);
    }

    while (true)
    {
        auto raw = readFrame();
        if (raw is null)
            return 0;
        JSONValue msg;
        try
            msg = parseJSON(raw);
        catch (Exception)
        {
            writeFrame(`{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}`);
            continue;
        }
        if (msg.type != JSONType.object || "method" !in msg)
            continue;
        auto method = msg["method"].str;
        if (method.length >= 13 && method[0 .. 13] == "notifications")
            continue;
        JSONValue id;
        if ("id" in msg)
            id = msg["id"];
        JSONValue result;
        string err;
        int errCode;
        if (!dispatch(session, method, msg, result, err, errCode))
        {
            JSONValue error = ["code": JSONValue(errCode), "message": JSONValue(err)];
            JSONValue reply = ["jsonrpc": JSONValue("2.0"), "id": id, "error": error];
            writeFrame(reply.toString());
            continue;
        }
        JSONValue reply = ["jsonrpc": JSONValue("2.0"), "id": id, "result": result];
        writeFrame(reply.toString());
    }
}

private bool dispatch(string session, string method, JSONValue msg, out JSONValue result, out string err, out int errCode)
{
    if (method == "initialize")
    {
        result = parseJSON(`{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"dropin","version":"0.1.0"}}`);
        return true;
    }
    if (method == "ping")
    {
        result = parseJSON(`{}`);
        return true;
    }
    if (method == "tools/list")
    {
        result = parseJSON(toolsJson);
        return true;
    }
    if (method == "tools/call")
    {
        if ("params" !in msg || msg["params"].type != JSONType.object || "name" !in msg["params"])
        {
            err = "missing tool name";
            errCode = -32602;
            return false;
        }
        auto name = msg["params"]["name"].str;
        JSONValue args;
        if ("arguments" in msg["params"] && msg["params"]["arguments"].type == JSONType.object)
            args = msg["params"]["arguments"];
        string text;
        bool ok = tool(session, name, args, text, err);
        if (!ok)
        {
            errCode = -32000;
            return false;
        }
        result = JSONValue([
            "content": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue(text)])]),
            "isError": JSONValue(false)
        ]);
        return true;
    }
    err = "method not found";
    errCode = -32601;
    return false;
}

private bool tool(string session, string name, JSONValue args, out string text, out string err)
{
    if (name == "dropin_tasks_read")
    {
        auto path = tasksPath(session);
        text = exists(path) ? readText(path) : "tasks {\n}\n";
        return true;
    }
    if (name == "dropin_tasks_write")
    {
        if ("content" !in args || args["content"].type != JSONType.string)
        {
            err = "content must be a string";
            return false;
        }
        auto path = tasksPath(session);
        if (!writeFileAtomic(path, args["content"].str))
        {
            err = "could not write " ~ path;
            return false;
        }
        auto noted = callSession(session, opcodeByName("notify"), "", true, defaultBudget(opcodeByName("notify")));
        text = path ~ (noted.code == 0 ? "\nengine notified" : "\nfile written; engine did not acknowledge");
        return true;
    }
    if (name == "dropin_status")
    {
        auto result = callSession(session, opcodeByName("status"), "", true, defaultBudget(opcodeByName("status")));
        if (result.code != 0)
        {
            err = result.response;
            return false;
        }
        text = result.response;
        return true;
    }
    if (name == "dropin_shutdown")
    {
        auto result = callSession(session, opcodeByName("shutdown"), "", false, defaultBudget(opcodeByName("shutdown")));
        if (result.code != 0)
        {
            err = result.response;
            return false;
        }
        text = result.response;
        return true;
    }
    if (name == "dropin_call")
    {
        if ("op" !in args || args["op"].type != JSONType.string)
        {
            err = "op must be a string";
            return false;
        }
        auto op = opcodeByName(args["op"].str);
        if (op == 0)
        {
            err = "unknown op";
            return false;
        }
        string body;
        if ("body" in args && args["body"].type == JSONType.string)
            body = args["body"].str;
        auto result = callSession(session, op, body, op != opcodeByName("shutdown"), defaultBudget(op));
        if (result.code != 0)
        {
            err = result.response.length ? result.response : "call failed";
            return false;
        }
        text = result.response;
        return true;
    }
    if (name == "dropin_plugin_reload")
    {
        if ("path" !in args || args["path"].type != JSONType.string)
        {
            err = "path must be a string";
            return false;
        }
        auto result = callSession(session, opcodeByName("reload"), args["path"].str, true, defaultBudget(opcodeByName("reload")));
        if (result.code != 0)
        {
            err = result.response;
            return false;
        }
        text = result.response;
        return true;
    }
    err = "unknown tool";
    return false;
}

private string readFrame()
{
    import std.regex : matchFirst;
    import std.string : strip;

    string headers;
    while (true)
    {
        auto line = stdin.readln();
        if (line is null)
            return null;
        auto trimmed = line.strip;
        if (trimmed.length == 0)
            break;
        headers ~= line;
    }
    auto found = matchFirst(headers, `Content-Length:\s*(\d+)`);
    if (found.empty)
        return "";
    auto n = to!size_t(found[1]);
    auto buf = new char[n];
    size_t got;
    while (got < n)
    {
        auto part = stdin.rawRead(buf[got .. n]);
        if (part.length == 0)
            return null;
        got += part.length;
    }
    return buf.idup;
}

private void writeFrame(string body)
{
    stdout.write("Content-Length: ", body.length, "\r\n\r\n", body);
    stdout.flush();
}

private immutable toolsJson = `{
  "tools": [
    {"name":"dropin_status","description":"Show the resident engine status. Starts the engine if it is not running.","inputSchema":{"type":"object","properties":{}}},
    {"name":"dropin_tasks_read","description":"Read the session task list SDL file.","inputSchema":{"type":"object","properties":{}}},
    {"name":"dropin_tasks_write","description":"Replace the session task list SDL file. The desktop UI reloads it when the file changes.","inputSchema":{"type":"object","properties":{"content":{"type":"string","description":"Full tasks { } SDL document"}},"required":["content"]}},
    {"name":"dropin_call","description":"Send one opcode to the resident engine.","inputSchema":{"type":"object","properties":{"op":{"type":"string"},"body":{"type":"string"}},"required":["op"]}},
    {"name":"dropin_plugin_reload","description":"Load a replacement plugin DLL or shared library into the resident engine.","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
    {"name":"dropin_shutdown","description":"Ask the resident engine to finish the current request and exit.","inputSchema":{"type":"object","properties":{}}}
  ]
}`;
