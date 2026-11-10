module echo;

import core.runtime;
import core.stdc.string : memcpy;

extern (C) export int dropin_plugin_abi() nothrow
{
    return 1;
}

extern (C) export int dropin_plugin_attach() nothrow
{
    try
    {
        Runtime.initialize();
        return 0;
    }
    catch (Throwable)
    {
        return 1;
    }
}

extern (C) export void dropin_plugin_detach() nothrow
{
    try
        Runtime.terminate();
    catch (Throwable)
    {
    }
}

extern (C) export int dropin_plugin_call(uint opcode, const(char)* req, uint reqLen,
    char* resp, uint respCap, uint* respLen) nothrow
{
    if (opcode != 100 || respLen is null)
        return 0;
    auto n = reqLen;
    if (n > respCap)
        n = respCap;
    if (n && resp !is null && req !is null)
        memcpy(resp, req, n);
    *respLen = n;
    return 1;
}
