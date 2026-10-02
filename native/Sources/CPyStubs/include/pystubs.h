// libpystubs.dylib (plan: M08-M13 §3.1, T0.1). The Python data symbols that webrtcvad's
// extension module binds non-lazily, so dyld can load the module without a Python runtime.
// JarvisVoice dlopens this library with RTLD_GLOBAL before the module, and never calls a
// Py* function: only WebRtcVad_* entry points are used.
#ifndef JARVIS_PYSTUBS_H
#define JARVIS_PYSTUBS_H

/// Returns 1. Lets a caller check, with dlsym, that it loaded this library and not another.
int jarvis_pystubs_loaded(void);

#endif
