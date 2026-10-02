// The data symbols listed by `dyld_info -fixups` as non-lazy binds of the two Python
// extension modules (plan: M08-M13 §3.1): webrtcvad needs ValueError, None, True and False;
// espeakbridge needed RuntimeError, None, True and False. espeakbridge is no longer vendored
// (D-54), but the set stays the plan's five. The modules only take these addresses inside
// Py* functions, which are never called, so zeroed storage is enough. Lazy binds (the Py*
// functions) are left unresolved on purpose.
#include "pystubs.h"

typedef struct { void *words[8]; } jarvis_pyobject_stub;

__attribute__((visibility("default"), used)) void *PyExc_ValueError = 0;
__attribute__((visibility("default"), used)) void *PyExc_RuntimeError = 0;
__attribute__((visibility("default"), used)) jarvis_pyobject_stub _Py_NoneStruct = {{0}};
__attribute__((visibility("default"), used)) jarvis_pyobject_stub _Py_TrueStruct = {{0}};
__attribute__((visibility("default"), used)) jarvis_pyobject_stub _Py_FalseStruct = {{0}};

__attribute__((visibility("default"))) int jarvis_pystubs_loaded(void) { return 1; }
