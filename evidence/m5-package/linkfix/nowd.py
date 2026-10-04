import lldb
def setup(debugger, cmd, result, d):
    t = debugger.GetSelectedTarget()
    m = None
    for mod in t.module_iter():
        if mod.GetFileSpec().GetFilename() == '.ui-host-wrapped': m = mod
    exitpath = m.ResolveFileAddress(0x100006bf4).GetLoadAddress(t)
    loop = m.ResolveFileAddress(0x100006be4).GetLoadAddress(t)
    bp = t.BreakpointCreateByAddress(exitpath)
    bp.SetScriptCallbackBody("frame.GetThread().GetFrameAtIndex(0).SetPC(%d)\nreturn False" % loop)
    print("watchdog neutralised: bp@%x -> %x" % (exitpath, loop))
def __lldb_init_module(debugger, d):
    debugger.HandleCommand('command script add -f nowd.setup nowd')
