module dropin.log;

void logLine(string path, string line)
{
    import std.datetime.systime : Clock;
    import std.file : append, exists, getSize, mkdirRecurse, remove, rename;
    import std.path : dirName;

    try
    {
        mkdirRecurse(dirName(path));
        if (exists(path) && getSize(path) > 1_048_576)
        {
            auto old = path ~ ".1";
            if (exists(old))
                remove(old);
            rename(path, old);
        }
        append(path, Clock.currTime.toISOExtString() ~ " " ~ line ~ "\n");
    }
    catch (Exception)
    {
    }
}
