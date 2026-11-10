module dropin.os;

import dropin.protocol;

ulong currentPid() nothrow @nogc
{
    version (Windows)
    {
        import core.sys.windows.winbase : GetCurrentProcessId;
        return GetCurrentProcessId();
    }
    else
    {
        import core.sys.posix.unistd : getpid;
        return cast(ulong) getpid();
    }
}

bool processAlive(ulong pid) nothrow @nogc
{
    if (pid == 0)
        return false;
    version (Windows)
    {
        import core.sys.windows.winbase : OpenProcess, CloseHandle, GetLastError;
        enum uint processQueryLimited = 0x1000;
        auto handle = OpenProcess(processQueryLimited, 0, cast(uint) pid);
        if (handle !is null)
        {
            CloseHandle(handle);
            return true;
        }
        return GetLastError() == 5;
    }
    else
    {
        import core.stdc.errno : errno, EPERM;
        import core.sys.posix.signal : kill;
        if (kill(cast(int) pid, 0) == 0)
            return true;
        return errno == EPERM;
    }
}

struct Mapping
{
    void* view;
    size_t length;
    version (Windows)
    {
        import core.sys.windows.winnt : HANDLE;
        HANDLE file = null;
        HANDLE map = null;
    }
    else
        int fd = -1;

    bool open(const(char)[] path, size_t bytes)
    {
        close();
        length = bytes;
        version (Windows)
        {
            import core.sys.windows.winbase : CreateFileW, CreateFileMappingW,
                MapViewOfFile, CloseHandle, GetFileSize, SetFilePointer, SetEndOfFile,
                OPEN_ALWAYS, FILE_BEGIN, FILE_MAP_ALL_ACCESS, INVALID_HANDLE_VALUE;
            import core.sys.windows.winnt : PAGE_READWRITE, GENERIC_READ, GENERIC_WRITE,
                FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE, FILE_ATTRIBUTE_NORMAL;
            import std.utf : toUTF16z;

            auto wide = toUTF16z(path);
            file = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
            if (file is null || file == INVALID_HANDLE_VALUE)
            {
                file = null;
                return false;
            }
            auto size = GetFileSize(file, null);
            if (size == 0xFFFF_FFFF || size < bytes)
            {
                SetFilePointer(file, cast(int) bytes, null, FILE_BEGIN);
                if (!SetEndOfFile(file))
                {
                    close();
                    return false;
                }
            }
            map = CreateFileMappingW(file, null, PAGE_READWRITE, 0, cast(uint) bytes, null);
            if (map is null)
            {
                close();
                return false;
            }
            view = MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, bytes);
            if (view is null)
            {
                close();
                return false;
            }
            return true;
        }
        else
        {
            import core.sys.posix.fcntl : posixOpen = open, O_CREAT, O_RDWR;
            import core.sys.posix.sys.mman : mmap, MAP_SHARED, PROT_READ, PROT_WRITE, MAP_FAILED;
            import core.sys.posix.sys.stat : fstat, stat_t, S_IRUSR, S_IWUSR;
            import core.sys.posix.unistd : ftruncate;
            import std.string : toStringz;

            auto z = toStringz(path);
            fd = posixOpen(z, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
            if (fd < 0)
                return false;
            stat_t st;
            if (fstat(fd, &st) != 0)
            {
                close();
                return false;
            }
            if (st.st_size < bytes)
            {
                if (ftruncate(fd, cast(long) bytes) != 0)
                {
                    close();
                    return false;
                }
            }
            view = mmap(null, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (view is null || view == MAP_FAILED)
            {
                view = null;
                close();
                return false;
            }
            return true;
        }
    }

    void close() nothrow @nogc
    {
        version (Windows)
        {
            import core.sys.windows.winbase : UnmapViewOfFile, CloseHandle;
            if (view !is null)
            {
                UnmapViewOfFile(view);
                view = null;
            }
            if (map !is null)
            {
                CloseHandle(map);
                map = null;
            }
            if (file !is null)
            {
                CloseHandle(file);
                file = null;
            }
        }
        else
        {
            import core.sys.posix.sys.mman : munmap;
            import core.sys.posix.unistd : close;
            if (view !is null)
            {
                munmap(view, length);
                view = null;
            }
            if (fd >= 0)
            {
                .close(fd);
                fd = -1;
            }
        }
        length = 0;
    }
}
