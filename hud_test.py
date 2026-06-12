import webview, time, os
HERE = os.path.dirname(os.path.abspath(__file__))

def setup(window):
    time.sleep(1.5)
    try:
        from AppKit import (NSApp, NSScreenSaverWindowLevel,
                            NSWindowCollectionBehaviorCanJoinAllSpaces,
                            NSWindowCollectionBehaviorStationary)
        for w in NSApp.windows():
            w.setIgnoresMouseEvents_(True)
            w.setLevel_(NSScreenSaverWindowLevel)
            w.setOpaque_(False)
            w.setHasShadow_(False)
            w.setCollectionBehavior_(
                NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorStationary)
        print("nswindow tweaks applied")
    except Exception as e:
        print("nswindow tweak failed:", e)
    window.evaluate_js("window.jarvisState('listening','Listening')")
    window.evaluate_js("window.jarvisLevel(0.7)")
    window.evaluate_js("window.jarvisCaption('Good evening, sir.')")
    time.sleep(4)

try:
    from AppKit import NSScreen
    fr = NSScreen.mainScreen().frame()
    SW, SH = int(fr.size.width), int(fr.size.height)
except Exception:
    SW, SH = 1440, 900

W, H = 560, 640
X = (SW - W) // 2
Y = (SH - H) - 70   # near bottom-center

win = webview.create_window(
    "JARVIS", os.path.join(HERE, "hud.html"),
    width=W, height=H, x=X, y=Y,
    frameless=True, easy_drag=False, transparent=True,
    on_top=True, resizable=False)
webview.start(setup, win)
