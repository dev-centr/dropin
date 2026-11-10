module dropin.tasksfile;

import std.algorithm : endsWith, startsWith;
import std.file : exists, remove, write;
import std.path : dirName;
import std.string : splitLines, strip;

struct TaskItem
{
    string id;
    string title;
    string status;
    string owner;
    string detail;
}

string quoteSdl(string s)
{
    char[] o;
    o ~= '"';
    foreach (c; s)
    {
        if (c == '\\' || c == '"')
            o ~= '\\';
        if (c == '\n')
        {
            o ~= '\\';
            o ~= 'n';
            continue;
        }
        if (c == '\r')
            continue;
        o ~= c;
    }
    o ~= '"';
    return o.idup;
}

string writeTasksSdl(const(TaskItem)[] tasks)
{
    auto o = "tasks {\n";
    foreach (task; tasks)
    {
        o ~= "  task " ~ quoteSdl(task.id) ~ " {\n";
        o ~= "    title " ~ quoteSdl(task.title) ~ "\n";
        o ~= "    status " ~ quoteSdl(task.status.length ? task.status : "open") ~ "\n";
        o ~= "    owner " ~ quoteSdl(task.owner) ~ "\n";
        o ~= "    detail " ~ quoteSdl(task.detail) ~ "\n";
        o ~= "  }\n";
    }
    o ~= "}\n";
    return o;
}

bool writeFileAtomic(string path, const(void)[] data)
{
    import std.file : mkdirRecurse;
    mkdirRecurse(dirName(path));
    auto tmp = path ~ ".tmp";
    try
    {
        write(tmp, data);
        version (Windows)
        {
            import core.sys.windows.winbase : MoveFileExW;
            import std.utf : toUTF16z;
            enum uint replaceExisting = 0x1;
            enum uint writeThrough = 0x8;
            if (MoveFileExW(toUTF16z(tmp), toUTF16z(path), replaceExisting | writeThrough))
                return true;
        }
        if (exists(path))
            remove(path);
        import std.file : rename;
        rename(tmp, path);
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

TaskItem[] parseTasksSdl(string text)
{
    TaskItem[] items;
    TaskItem current;
    bool inTask;
    foreach (raw; text.splitLines)
    {
        auto line = raw.strip;
        if (line.length == 0 || line.startsWith("//") || line.startsWith("#"))
            continue;
        if (!inTask && line.startsWith("task "))
        {
            current = TaskItem.init;
            current.id = unquote(afterWord(line, "task"));
            inTask = true;
            continue;
        }
        if (!inTask)
            continue;
        if (line == "}")
        {
            items ~= current;
            inTask = false;
            continue;
        }
        if (line.startsWith("title "))
            current.title = unquote(line[6 .. $]);
        else if (line.startsWith("status "))
            current.status = unquote(line[7 .. $]);
        else if (line.startsWith("owner "))
            current.owner = unquote(line[6 .. $]);
        else if (line.startsWith("detail "))
            current.detail = unquote(line[7 .. $]);
    }
    return items;
}

private string afterWord(string line, string word)
{
    auto rest = line[word.length .. $].strip;
    if (rest.endsWith("{"))
        rest = rest[0 .. $ - 1].strip;
    return rest;
}

private string unquote(string s)
{
    s = s.strip;
    if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
    {
        string o;
        bool esc;
        foreach (c; s[1 .. $ - 1])
        {
            if (esc)
            {
                o ~= c == 'n' ? '\n' : c;
                esc = false;
            }
            else if (c == '\\')
                esc = true;
            else
                o ~= c;
        }
        return o;
    }
    return s;
}

unittest
{
    TaskItem[] items;
    items ~= TaskItem("write-spec", "Write the spec", "open", "agent", "line\nnext");
    auto text = writeTasksSdl(items);
    auto back = parseTasksSdl(text);
    assert(back.length == 1);
    assert(back[0].id == "write-spec");
    assert(back[0].title == "Write the spec");
    assert(back[0].status == "open");
    assert(back[0].detail == "line\nnext");
}
