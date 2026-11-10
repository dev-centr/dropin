module dropin.plugin;

import dropin.protocol;
import std.conv : to;
import std.file : copy, exists, mkdirRecurse;
import std.path : buildPath, extension;

alias CallFn = extern (C) int function(uint opcode, const(char)* req, uint reqLen,
    char* resp, uint respCap, uint* respLen) nothrow;
alias AttachFn = extern (C) int function() nothrow;
alias DetachFn = extern (C) void function() nothrow;
alias AbiFn = extern (C) int function() nothrow;

struct Plugin
{
    version (Windows)
    {
        import core.sys.windows.winnt : HANDLE;
        HANDLE library = null;
    }
    else
        void* library = null;

    CallFn callFn;
    DetachFn detachFn;
    string loadedFrom;

    bool loaded() const nothrow
    {
        version (Windows)
            return library !is null;
        else
            return library !is null;
    }

    int reload(string source, string directory, ulong* generation)
    {
        if (!exists(source))
            return DropinError.plugin;
        unload();
        mkdirRecurse(directory);
        auto next = *generation + 1;
        auto dest = buildPath(directory, "plugin-" ~ to!string(next) ~ extension(source));
        try
            copy(source, dest);
        catch (Exception)
            return DropinError.io;
        version (Windows)
        {
            import core.sys.windows.winbase : LoadLibraryW, GetProcAddress;
            import std.utf : toUTF16z;
            library = LoadLibraryW(toUTF16z(dest));
            if (library is null)
                return DropinError.plugin;
            auto abi = cast(AbiFn) GetProcAddress(library, "dropin_plugin_abi");
            if (abi is null || abi() != dropinAbi)
            {
                unload();
                return DropinError.badVersion;
            }
            auto attach = cast(AttachFn) GetProcAddress(library, "dropin_plugin_attach");
            if (attach !is null && attach() != 0)
            {
                unload();
                return DropinError.plugin;
            }
            callFn = cast(CallFn) GetProcAddress(library, "dropin_plugin_call");
            detachFn = cast(DetachFn) GetProcAddress(library, "dropin_plugin_detach");
            if (callFn is null)
            {
                unload();
                return DropinError.plugin;
            }
        }
        else
        {
            import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;
            import std.string : toStringz;
            library = dlopen(toStringz(dest), RTLD_NOW);
            if (library is null)
                return DropinError.plugin;
            auto abi = cast(AbiFn) dlsym(library, "dropin_plugin_abi");
            if (abi is null || abi() != dropinAbi)
            {
                unload();
                return DropinError.badVersion;
            }
            auto attach = cast(AttachFn) dlsym(library, "dropin_plugin_attach");
            if (attach !is null && attach() != 0)
            {
                unload();
                return DropinError.plugin;
            }
            callFn = cast(CallFn) dlsym(library, "dropin_plugin_call");
            detachFn = cast(DetachFn) dlsym(library, "dropin_plugin_detach");
            if (callFn is null)
            {
                unload();
                return DropinError.plugin;
            }
        }
        loadedFrom = dest;
        *generation = next;
        return DropinError.ok;
    }

    void unload()
    {
        if (!loaded)
            return;
        if (detachFn !is null)
            detachFn();
        version (Windows)
        {
            import core.sys.windows.winbase : FreeLibrary;
            FreeLibrary(library);
            library = null;
        }
        else
        {
            import core.sys.posix.dlfcn : dlclose;
            dlclose(library);
            library = null;
        }
        callFn = null;
        detachFn = null;
        loadedFrom = null;
    }

    int call(uint opcode, const(char)[] req, char[] resp, uint* respLen) nothrow
    {
        if (!loaded || callFn is null)
            return 0;
        return callFn(opcode, req.ptr, cast(uint) req.length, resp.ptr, cast(uint) resp.length, respLen);
    }
}
