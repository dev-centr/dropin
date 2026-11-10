module dropin.session;

import std.path : buildPath;
import std.process : environment;
import std.file : mkdirRecurse;

string dropinHome()
{
    auto home = environment.get("DROPIN_HOME");
    if (home.length)
        return home;
    home = environment.get("USERPROFILE");
    if (home.length == 0)
        home = environment.get("HOME");
    if (home.length == 0)
        home = ".";
    return buildPath(home, ".dropin");
}

string sanitizeSession(string name)
{
    if (name.length == 0)
        return "";
    if (name == "." || name == "..")
        return "";
    foreach (c; name)
    {
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok)
            return "";
    }
    return name;
}

string sessionDir(string session)
{
    auto dir = buildPath(dropinHome(), "sessions", session);
    mkdirRecurse(dir);
    return dir;
}

string ringPath(string session)
{
    return buildPath(sessionDir(session), "ring.bin");
}

string tasksPath(string session)
{
    return buildPath(sessionDir(session), "tasks.sdl");
}

string logPath(string session)
{
    return buildPath(sessionDir(session), "engine.log");
}

string pluginDir(string session)
{
    auto dir = buildPath(sessionDir(session), "plugins");
    mkdirRecurse(dir);
    return dir;
}
