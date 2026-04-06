#!/usr/bin/env python3
"""Wispr Addons — macOS menu bar app.

Wraps the clipboard cleanup daemon (CGEventTap) in a menu bar app using rumps.
The event tap runs on a background thread; the main thread runs the menu bar UI.
"""

BUILD_TIME = "Apr 6, 19:58"

import ctypes
import ctypes.util
import os
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

# Add sibling module to path so we can import whisper-transcribe
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "whisper-transcribe"))

import anthropic
import objc
import AppKit
import rumps
import Quartz
from Quartz import (
    CGEventCreateKeyboardEvent,
    CGEventSetFlags,
    CGEventGetFlags,
    CGEventGetIntegerValueField,
    CGEventMaskBit,
    CGEventPost,
    CGEventTapCreate,
    CGEventTapEnable,
    CFMachPortCreateRunLoopSource,
    CFRunLoopAddSource,
    CFRunLoopGetCurrent,
    CFRunLoopRun,
    CFRunLoopStop,
    kCGEventKeyDown,
    kCGEventKeyUp,
    kCGEventOtherMouseDown,
    kCGEventTapDisabledByTimeout,
    kCGHeadInsertEventTap,
    kCGHIDEventTap,
    kCGKeyboardEventKeycode,
    kCGSessionEventTap,
    kCFRunLoopCommonModes,
    kCGEventFlagMaskCommand,
    kCGEventFlagMaskControl,
    kCGEventFlagMaskAlternate,
    kCGMouseEventButtonNumber,
)
from AppKit import NSEvent

# --- Configuration ---
MODEL = "claude-haiku-4-5-20251001"
TIMEOUT_BASE = 2
TIMEOUT_PER_1K = 1.5
TIMEOUT_MAX = 15
MAX_INPUT_CHARS = 5000

CLEANUP_PROMPT = (
    "Fix grammar, punctuation, and spelling errors.\n"
    "Remove filler words and false starts from speech-to-text output.\n"
    "Synthesize verbose text into concise form while preserving all meaning.\n"
    "Add at least 1 emoji to the output, placed where it naturally fits.\n"
    "Use at most 1 emoji per 2 sentences.\n"
    "Detect the input language and respond in the same language.\n"
    "Return ONLY the cleaned text, nothing else."
)

VK_P = 0x23
VK_D = 0x02
VK_V = 0x09
VK_Z = 0x06
VK_ESCAPE = 0x35
SCREENSHOT_DIR = Path.home() / "Documents" / "screenshots"
MOUSE_BUTTON_5 = 4
MOUSE_BUTTON_3 = 2
DICTATION_MUTE_DEVICE = "\U0001f50aOS Output"
DICTATION_VOLUME_LOW = 0.01
DICTATION_MUTE_DELAY = 0.05
MOUSE_WHEEL_DOUBLE_CLICK_WINDOW = 0.35

# --- CoreAudio helpers ---
_ca = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreAudio"))


class _AudioPropAddr(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


_kScopeGlobal = 1735159650
_kScopeOutput = 1869968496
_kElementMain = 0
_kDevices = 1684370979
_kName = 1819173229
_kVolume = 1986885219
_NX_KEYTYPE_PLAY = 16


_cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFRelease.argtypes = [ctypes.c_void_p]
_cf.CFRelease.restype = None


def _cfstring_to_str(cfstr: ctypes.c_void_p) -> str | None:
    buf = ctypes.create_string_buffer(256)
    if _cf.CFStringGetCString(cfstr, buf, 256, 0x08000100):  # kCFStringEncodingUTF8
        return buf.value.decode("utf-8")
    return None


def _find_audio_device_id(name: str) -> int | None:
    addr = _AudioPropAddr(_kDevices, _kScopeGlobal, _kElementMain)
    size = ctypes.c_uint32(0)
    _ca.AudioObjectGetPropertyDataSize(1, ctypes.byref(addr), 0, None, ctypes.byref(size))
    n = size.value // 4
    ids = (ctypes.c_uint32 * n)()
    _ca.AudioObjectGetPropertyData(1, ctypes.byref(addr), 0, None, ctypes.byref(size), ids)
    for i in range(n):
        dev_id = ids[i]
        na = _AudioPropAddr(_kName, _kScopeGlobal, _kElementMain)
        ref = ctypes.c_void_p()
        ns = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
        if _ca.AudioObjectGetPropertyData(dev_id, ctypes.byref(na), 0, None, ctypes.byref(ns), ctypes.byref(ref)) != 0:
            continue
        dev_name = _cfstring_to_str(ref.value)
        _cf.CFRelease(ref.value)
        if dev_name == name:
            return dev_id
    return None


def _get_device_volume(device_id: int) -> float:
    addr = _AudioPropAddr(_kVolume, _kScopeOutput, _kElementMain)
    val = ctypes.c_float(0)
    size = ctypes.c_uint32(4)
    if _ca.AudioObjectGetPropertyData(device_id, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(val)) == 0:
        return val.value
    return 1.0


def _set_device_volume(device_id: int, volume: float) -> bool:
    addr = _AudioPropAddr(_kVolume, _kScopeOutput, _kElementMain)
    val = ctypes.c_float(volume)
    return _ca.AudioObjectSetPropertyData(device_id, ctypes.byref(addr), 0, None, 4, ctypes.byref(val)) == 0


# --- Shared state ---
_client: anthropic.Anthropic | None = None
_clean_lock = threading.Lock()
_last_paste_text: str | None = None
_last_paste_lock = threading.Lock()
_mute_device_original_volume: float = 1.0
_dictation_active: bool = False
_tap_ref = None
_tap_run_loop_ref = None
_log_buffer: deque[str] = deque(maxlen=50)
_app_ref: "WisprAddonsApp | None" = None
_mouse_wheel_click_lock = threading.Lock()
_mouse_wheel_pending_timer: threading.Timer | None = None


def log(message: str) -> None:
    timestamp = datetime.now().strftime("%H:%M:%S")
    line = f"[{timestamp}] {message}"
    print(line)
    _log_buffer.append(line)


# --- Clipboard & keystroke helpers ---
def get_clipboard() -> str:
    try:
        return subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=1).stdout
    except Exception:
        return ""


def set_clipboard(text: str) -> None:
    try:
        subprocess.run(["pbcopy"], input=text, text=True, timeout=1)
    except Exception as e:
        log(f"pbcopy failed: {e}")


def simulate_keystroke(keycode: int, flags: int = 0) -> None:
    for key_down in (True, False):
        event = CGEventCreateKeyboardEvent(None, keycode, key_down)
        if flags:
            CGEventSetFlags(event, flags)
        CGEventPost(kCGHIDEventTap, event)


def compute_timeout(text: str) -> float:
    return min(TIMEOUT_BASE + (len(text) / 1000) * TIMEOUT_PER_1K, TIMEOUT_MAX)


def play_sound() -> None:
    subprocess.Popen(["afplay", "/System/Library/Sounds/Tink.aiff"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --- Core handlers ---
COST_PER_INPUT_TOKEN  = 0.80 / 1_000_000   # claude-haiku-4-5
COST_PER_OUTPUT_TOKEN = 4.00 / 1_000_000


def clean_text(text: str) -> tuple[str, float] | tuple[None, None]:
    timeout = compute_timeout(text)
    try:
        response = _client.messages.create(
            model=MODEL, max_tokens=4096,
            messages=[{"role": "user", "content": text}],
            system=CLEANUP_PROMPT, timeout=timeout,
        )
        cost = (response.usage.input_tokens * COST_PER_INPUT_TOKEN
                + response.usage.output_tokens * COST_PER_OUTPUT_TOKEN)
        return response.content[0].text, cost
    except Exception as e:
        log(f"API error: {e}")
        return None, None


def handle_clean_hotkey() -> None:
    global _last_paste_text
    if not _clean_lock.acquire(blocking=False):
        return
    try:
        play_sound()
        with _last_paste_lock:
            text = _last_paste_text
        if not text or not text.strip():
            log("Skipped: no captured paste text")
            return
        if len(text) > MAX_INPUT_CHARS:
            log(f"Skipped: text too long ({len(text)} chars > {MAX_INPUT_CHARS})")
            return

        start = time.time()
        log(f"Cleaning {len(text)} chars...")
        cleaned, cost = clean_text(text)
        if cleaned is None:
            log("Failed: no response from API")
            return

        simulate_keystroke(VK_Z, kCGEventFlagMaskCommand)
        time.sleep(0.15)
        set_clipboard(cleaned)
        time.sleep(0.05)
        simulate_keystroke(VK_V, kCGEventFlagMaskCommand)

        elapsed_ms = int((time.time() - start) * 1000)
        log(f"Done ({len(text)}\u2192{len(cleaned)} chars, {elapsed_ms}ms, ${cost:.4f}):\n  {cleaned[:200]}")
    except Exception as e:
        log(f"Failed: {e}")
    finally:
        _clean_lock.release()


def _paste_last_intercepted_text() -> None:
    with _last_paste_lock:
        text = _last_paste_text
    if not text or not text.strip():
        log("Skipped: no captured paste text to repaste")
        return

    previous_clipboard = get_clipboard()
    set_clipboard(text)
    time.sleep(0.05)
    simulate_keystroke(VK_V, kCGEventFlagMaskCommand)
    time.sleep(0.05)
    set_clipboard(previous_clipboard)
    log(f"Repasted last captured text ({len(text)} chars)")


def _on_mouse_wheel_timeout() -> None:
    global _mouse_wheel_pending_timer
    with _mouse_wheel_click_lock:
        _mouse_wheel_pending_timer = None


def _on_mouse_wheel_click() -> None:
    global _mouse_wheel_pending_timer
    with _mouse_wheel_click_lock:
        if _mouse_wheel_pending_timer is not None:
            _mouse_wheel_pending_timer.cancel()
            _mouse_wheel_pending_timer = None
            is_double_click = True
        else:
            timer = threading.Timer(MOUSE_WHEEL_DOUBLE_CLICK_WINDOW, _on_mouse_wheel_timeout)
            timer.daemon = True
            _mouse_wheel_pending_timer = timer
            timer.start()
            is_double_click = False

    if is_double_click:
        threading.Thread(target=_paste_last_intercepted_text, daemon=True).start()


def _is_dark_mode() -> bool:
    try:
        result = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to tell appearance preferences to get dark mode'],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip().lower() == "true"
    except Exception:
        return False


def toggle_dark_mode() -> None:
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'],
            timeout=5,
        )
        log("🌗 Toggled dark mode")
    except Exception as e:
        log(f"🌗 Dark mode toggle failed: {e}")


def handle_dictation_toggle() -> None:
    global _mute_device_original_volume, _dictation_active
    if _dictation_active:
        _restore_dictation_volume()
    else:
        device_id = _find_audio_device_id(DICTATION_MUTE_DEVICE)
        if device_id is None:
            log(f"WARNING: Device '{DICTATION_MUTE_DEVICE}' not found")
            return
        current_vol = _get_device_volume(device_id)
        _mute_device_original_volume = current_vol
        time.sleep(DICTATION_MUTE_DELAY)
        _set_device_volume(device_id, DICTATION_VOLUME_LOW)
        _dictation_active = True
        log(f"\U0001f7e2 Dictation: \U0001f507 OS Output ({current_vol:.0%}\u2192{DICTATION_VOLUME_LOW:.0%})")


def _restore_dictation_volume() -> None:
    global _dictation_active
    if not _dictation_active:
        return
    device_id = _find_audio_device_id(DICTATION_MUTE_DEVICE)
    if device_id is None:
        log(f"WARNING: Device '{DICTATION_MUTE_DEVICE}' not found")
        _dictation_active = False
        return
    _set_device_volume(device_id, _mute_device_original_volume)
    _dictation_active = False
    log(f"\U0001f534 Dictation: \U0001f50a OS Output ({_mute_device_original_volume:.0%})")


# --- Screenshot ---
def _active_display_number() -> int:
    """Return the screencapture -D display number for the screen with the frontmost window."""
    try:
        front_screen = AppKit.NSScreen.mainScreen()  # screen with key window / menu bar focus
        screens = AppKit.NSScreen.screens()
        for i, scr in enumerate(screens):
            if scr == front_screen:
                return i + 1  # screencapture -D is 1-indexed
    except Exception:
        pass
    return 1


def take_screenshot():
    from datetime import datetime
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    filepath = SCREENSHOT_DIR / f"screenshot_{ts}.png"
    display = _active_display_number()
    subprocess.run(["screencapture", "-x", "-D", str(display), str(filepath)], timeout=5)
    log(f"📷 Screenshot saved: {filepath.name} (display {display})")
    # Flash camera icon
    if _app_ref:
        _app_ref._flash_screenshot_icon()


# --- Event tap callback ---
def event_tap_callback(proxy, event_type, event, refcon):
    global _last_paste_text

    if event_type == kCGEventTapDisabledByTimeout:
        log("\u26a0\ufe0f Event tap re-enabled after timeout")
        if _tap_ref is not None:
            CGEventTapEnable(_tap_ref, True)
        return event

    if event_type == kCGEventOtherMouseDown:
        button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber)
        if button == MOUSE_BUTTON_5:
            threading.Thread(target=handle_dictation_toggle, daemon=True).start()
        elif button == MOUSE_BUTTON_3:
            _on_mouse_wheel_click()
        return event

    keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)
    flags = CGEventGetFlags(event)

    if keycode == VK_ESCAPE and _dictation_active:
        threading.Thread(target=_restore_dictation_volume, daemon=True).start()
        return event

    has_cmd = bool(flags & kCGEventFlagMaskCommand)
    has_ctrl = bool(flags & kCGEventFlagMaskControl)
    has_opt = bool(flags & kCGEventFlagMaskAlternate)

    # Ctrl+P → screenshot
    if keycode == VK_P and has_ctrl and not has_cmd and not has_opt:
        threading.Thread(target=take_screenshot, daemon=True).start()
        return None

    # Cmd+Opt+Ctrl+D → toggle dark mode
    if keycode == VK_D and has_cmd and has_ctrl and has_opt:
        threading.Thread(target=toggle_dark_mode, daemon=True).start()
        return None

    if keycode != VK_V:
        return event

    if has_cmd and has_ctrl:
        threading.Thread(target=handle_clean_hotkey, daemon=True).start()
        return None

    if has_cmd and not has_ctrl:
        clipboard = get_clipboard()
        if clipboard:
            with _last_paste_lock:
                _last_paste_text = clipboard

    return event


# --- Event tap thread ---
def _run_event_tap():
    global _tap_ref, _tap_run_loop_ref

    tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        0,
        CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventOtherMouseDown),
        event_tap_callback,
        None,
    )

    _tap_ref = tap
    if tap is None:
        log("ERROR: Could not create event tap — check Accessibility permissions")
        return

    source = CFMachPortCreateRunLoopSource(None, tap, 0)
    _tap_run_loop_ref = CFRunLoopGetCurrent()
    CFRunLoopAddSource(_tap_run_loop_ref, source, kCFRunLoopCommonModes)

    device_id = _find_audio_device_id(DICTATION_MUTE_DEVICE)
    if device_id:
        log(f"🔇 Mute device (Mouse 5): {DICTATION_MUTE_DEVICE}")
    else:
        log(f"WARNING: '{DICTATION_MUTE_DEVICE}' not found")

    log("Event tap active")
    CFRunLoopRun()
    log("Event tap stopped")


# --- Port history persistence ---
_PORTS_FILE = Path.home() / ".victor-macos-addons-ports.json"


def _load_port_history() -> list[int]:
    try:
        import json
        return json.loads(_PORTS_FILE.read_text())
    except Exception:
        return [8080]


def _save_port_history(ports: list[int]) -> None:
    import json
    _PORTS_FILE.write_text(json.dumps(ports))


def _check_port_alive(port: int) -> bool:
    """Check if any process is listening on the given port."""
    try:
        result = subprocess.run(["lsof", "-ti", f":{port}"], capture_output=True, text=True, timeout=2)
        return bool(result.stdout.strip())
    except Exception:
        return False


def _get_port_process_name(port: int) -> str | None:
    """Get the executable name bound to a port, or None."""
    try:
        result = subprocess.run(["lsof", "-ti", f":{port}"], capture_output=True, text=True, timeout=2)
        pid = result.stdout.strip().splitlines()[0] if result.stdout.strip() else None
        if pid:
            return _get_process_info(pid)
    except Exception:
        pass
    return None


def _get_process_info(pid: str) -> str:
    """Get process name/command for a PID."""
    try:
        result = subprocess.run(["ps", "-p", pid.strip(), "-o", "comm="], capture_output=True, text=True, timeout=2)
        comm = result.stdout.strip()
        return os.path.basename(comm) if comm else "unknown"
    except Exception:
        return "unknown"


def _send_notification(title: str, message: str) -> None:
    """Send a macOS notification."""
    subprocess.Popen([
        "osascript", "-e",
        f'display notification "{message}" with title "{title}"'
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --- Menu bar app ---
class WisprAddonsApp(rumps.App):
    def __init__(self):
        icon_path = str(Path(__file__).parent / "icon_chat.png")
        super().__init__(
            "",
            icon=icon_path,
            template=False,
            quit_button=None,
        )
        self._icon_on = icon_path
        self._icon_off = str(Path(__file__).parent / "icon_chat_off.png")
        self._icon_camera = str(Path(__file__).parent / "icon_camera.png")
        self._whisper_runner = None
        self._transcribing = False
        self._ppt_monitor = None
        self._tracking_ppt = False
        self._ij_monitor = None
        self._ws_status_item = rumps.MenuItem("WS 🔴", callback=None)
        self._ws_status_item.enabled = False
        from ws_server import WsServer
        self._ws_server = WsServer(on_clients_changed=self._on_ws_clients_changed)
        self._ws_server.start()
        log(f"WS server started on ws://127.0.0.1:{WsServer.PORT}")

        self._transcribe_item = rumps.MenuItem("Stop Transcribing", callback=self.toggle_transcribing)
        self._kill_8080_item = rumps.MenuItem("Kill :8080", callback=lambda _: self._kill_port(8080))
        _dark_label = "Exit Dark Mode" if _is_dark_mode() else "Enter Dark Mode"
        self._dark_mode_item = rumps.MenuItem(_dark_label + " — ⌘⌃⌥D", callback=self._toggle_dark_mode)

        self.menu = [
            self._kill_8080_item,
            rumps.MenuItem("Kill…"),
            None,  # separator
            self._transcribe_item,
            rumps.MenuItem("Monitor", callback=self.monitor_transcription),
            None,  # separator
            rumps.MenuItem("Copy Git", callback=self.copy_intellij_git),
            rumps.MenuItem("Log", callback=self.show_log),
            None,  # separator
            rumps.MenuItem("Paste Emotions — ⌘⌃V", callback=None),
            self._dark_mode_item,

            rumps.MenuItem("Re-paste — Wheel x 2", callback=None),
            rumps.MenuItem("Screenshot — ⌃P", callback=None),
            self._ws_status_item,
            None,  # separator
            rumps.MenuItem(BUILD_TIME, callback=None),
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]
        self.menu["Paste Emotions — ⌘⌃V"].enabled = False

        self.menu["Re-paste — Wheel x 2"].enabled = False
        self.menu["Screenshot — ⌃P"].enabled = False
        self.menu[BUILD_TIME].enabled = False

        # Kill port submenu — persisted across sessions
        self._kill_port_history: list[int] = _load_port_history()
        self._kill_submenu_items: dict = {}  # port -> MenuItem, rebuilt on each menu open
        kill_menu = self.menu["Kill…"]
        kill_menu.add(rumps.MenuItem("Port…", callback=self._kill_port_prompt))
        kill_menu.add(None)

        # Refresh port status when kill submenu opens (NSMenu delegate)
        self._setup_menu_delegate()

    def _setup_menu_delegate(self):
        """Set up NSMenu delegate to refresh port status on menu open."""
        try:
            from Foundation import NSObject
            from objc import python_method

            parent = self

            class MenuDelegate(NSObject):
                def menuNeedsUpdate_(self, menu):
                    parent._refresh_port_status()

            class MainThreadCaller(NSObject):
                def call_(self, fn):
                    fn()

            self._menu_delegate = MenuDelegate.alloc().init()
            self._main_thread_caller = MainThreadCaller.alloc().init()
            # Set delegate on the status bar menu
            ns_menu = self._nsapp_statusbar_button_menu()
            if ns_menu:
                ns_menu.setDelegate_(self._menu_delegate)
                ns_menu.setAutoenablesItems_(False)
                # rumps item.enabled=False only sets a Python attribute, not the NSMenuItem.
                # With autoenablesItems=False we must set isEnabled directly.
                for title in ["Paste Emotions — ⌘⌃V", "Re-paste — Wheel x 2", "Screenshot — ⌃P", BUILD_TIME]:
                    self.menu[title]._menuitem.setEnabled_(False)
                self._ws_status_item._menuitem.setEnabled_(False)
                # Also disable autoenablesItems on the Kill… submenu so Port… isn't grayed out
                kill_ns_menu = self.menu["Kill…"]._menuitem.submenu()
                if kill_ns_menu:
                    kill_ns_menu.setAutoenablesItems_(False)
        except Exception:
            pass  # fallback: ports refresh only after kill

    def _nsapp_statusbar_button_menu(self):
        """Get the underlying NSMenu from the rumps status bar."""
        try:
            return self._status_item._nsObject.menu()
        except Exception:
            try:
                return self.menu._menu
            except Exception:
                return None

    def _toggle_dark_mode(self, _):
        threading.Thread(target=self._toggle_dark_mode_bg, daemon=True).start()

    def _toggle_dark_mode_bg(self):
        toggle_dark_mode()
        self._refresh_dark_mode_label()

    def _refresh_dark_mode_label(self, dark=None):
        if dark is None:
            dark = _is_dark_mode()
        label = "Exit Dark Mode" if dark else "Enter Dark Mode"
        self._dark_mode_item.title = label + " — ⌘⌃⌥D"

    def _dispatch_main(self, fn):
        """Run fn on the main thread (safe to call from any thread)."""
        try:
            self._main_thread_caller.performSelectorOnMainThread_withObject_waitUntilDone_('call:', fn, False)
        except Exception:
            fn()

    def _refresh_port_status(self):
        """Show '?' placeholders immediately, then update each port in background."""
        all_ports = [8080] + [p for p in self._kill_port_history if p != 8080]

        # Immediately show placeholders so the menu opens fast
        self._kill_8080_item.title = "Kill :8080 ?"
        self._kill_8080_item._menuitem.setEnabled_(False)
        self._kill_8080_item.set_callback(None)
        self._rebuild_kill_submenu_placeholders([p for p in all_ports if p != 8080])

        # Dark mode refresh in background
        def bg_dark():
            dark = _is_dark_mode()
            self._dispatch_main(lambda: self._refresh_dark_mode_label(dark))
        threading.Thread(target=bg_dark, daemon=True).start()

        # Check each port in background and update when done
        def check_port(port):
            proc = _get_port_process_name(port)
            if port == 8080:
                def update():
                    if proc:
                        self._kill_8080_item.title = f"Kill :8080 {proc}"
                        self._kill_8080_item._menuitem.setEnabled_(True)
                        self._kill_8080_item.set_callback(self._make_kill_callback(8080))
                    else:
                        self._kill_8080_item.title = "Kill :8080"
                        self._kill_8080_item._menuitem.setEnabled_(False)
                self._dispatch_main(update)
            else:
                def update():
                    item = self._kill_submenu_items.get(port)
                    if item is None:
                        return
                    if proc:
                        item.title = f":{port} {proc}"
                        item._menuitem.setEnabled_(True)
                        item.set_callback(self._make_kill_callback(port))
                    else:
                        item.title = f":{port}"
                        item._menuitem.setEnabled_(False)
                self._dispatch_main(update)

        for port in all_ports:
            threading.Thread(target=check_port, args=(port,), daemon=True).start()

    def _rebuild_kill_submenu_placeholders(self, ports: list[int]):
        """Replace submenu port items with '?' placeholders; track items for async update."""
        kill_menu = self.menu["Kill…"]
        for key in list(kill_menu.keys()):
            if key.startswith(":"):
                del kill_menu[key]
        self._kill_submenu_items = {}
        for port in ports:
            item = rumps.MenuItem(f":{port} ?")
            item._menuitem.setEnabled_(False)
            kill_menu.add(item)
            self._kill_submenu_items[port] = item

    def _make_kill_callback(self, port: int):
        def cb(_):
            self._kill_port(port)
        return cb

    def _kill_port_prompt(self, _):
        from AppKit import (NSPanel, NSTextField, NSButton, NSScreen,
                            NSBezelStyleRounded, NSBackingStoreBuffered,
                            NSWindowStyleMaskTitled, NSWindowStyleMaskClosable,
                            NSApplication, NSFont, NSModalResponseOK)
        from Foundation import NSMakeRect, NSNumberFormatter, NSNumberFormatterNoStyle

        W, H = 200, 36
        screen = NSScreen.mainScreen()
        visible = screen.visibleFrame()
        x = 1100
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, 0, W, H),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
            NSBackingStoreBuffered, False)
        panel.setTitle_("")
        panel.setLevel_(25)  # floating
        # Pin top of window frame to bottom of menu bar
        top_y = visible.origin.y + visible.size.height
        panel.setFrameTopLeftPoint_((x, top_y))

        field = NSTextField.alloc().initWithFrame_(NSMakeRect(4, 4, 152, 28))
        field.setPlaceholderString_("8080")
        field.setFont_(NSFont.systemFontOfSize_(16))
        fmt = NSNumberFormatter.alloc().init()
        fmt.setNumberStyle_(NSNumberFormatterNoStyle)  # integers only, no separators
        fmt.setAllowsFloats_(False)
        fmt.setMinimum_(1)
        fmt.setMaximum_(65535)
        field.setFormatter_(fmt)
        panel.contentView().addSubview_(field)

        btn = NSButton.alloc().initWithFrame_(NSMakeRect(160, 4, 36, 28))
        btn.setTitle_("☠️")
        btn.setBezelStyle_(NSBezelStyleRounded)
        btn.setFont_(NSFont.systemFontOfSize_(16))
        btn.setKeyEquivalent_("\r")  # Enter triggers kill
        btn.setTarget_(NSApplication.sharedApplication())
        btn.setAction_("stopModalWithCode:")
        btn.setTag_(NSModalResponseOK)
        panel.contentView().addSubview_(btn)

        panel.makeFirstResponder_(field)
        result = NSApplication.sharedApplication().runModalForWindow_(panel)
        panel.orderOut_(None)
        if result != NSModalResponseOK:
            return
        text = str(field.stringValue()).strip()
        if not text.isdigit():
            log(f"☠️ Invalid port: {text}")
            return
        self._kill_port(int(text))

    def _kill_port(self, port: int):
        try:
            result = subprocess.run(["lsof", "-ti", f":{port}"], capture_output=True, text=True, timeout=5)
            pids = result.stdout.strip()
            if not pids:
                log(f"☠️ No process on :{port}")
                _send_notification("Kill port", f"No process on :{port}")
                return
            killed_procs = []
            for pid in pids.splitlines():
                proc_name = _get_process_info(pid)
                subprocess.run(["kill", "-9", pid.strip()], timeout=5)
                killed_procs.append(f"{proc_name} (pid {pid.strip()})")
            summary = ", ".join(killed_procs)
            log(f"☠️ Killed :{port} — {summary}")
            _send_notification(f"Killed :{port}", summary)
        except Exception as e:
            log(f"☠️ Kill :{port} failed: {e}")
        # Update history: move to top, keep unique, max 5
        if port in self._kill_port_history:
            self._kill_port_history.remove(port)
        self._kill_port_history.insert(0, port)
        self._kill_port_history = self._kill_port_history[:5]
        _save_port_history(self._kill_port_history)
        self._refresh_port_status()

    # ── Transcribing ──

    def _get_victor_source_emoji(self):
        """Get the short device emoji for Victor's current capture device."""
        from whisper_runner import _short_device_name, _ME_SPEAKER
        if not self._whisper_runner:
            return ""
        for ch in self._whisper_runner._channels:
            if ch.label == _ME_SPEAKER:
                return _short_device_name(ch.device_name)
        return ""

    def _update_transcribe_title(self):
        emoji = self._get_victor_source_emoji()
        suffix = f" {emoji}" if emoji else ""
        if self._transcribing:
            self._transcribe_item.title = f"Stop Transcribing{suffix}"
        else:
            self._transcribe_item.title = "Start Transcribing"

    def start_transcribing(self):
        import whisper_runner as _wr
        from whisper_runner import WhisperTranscriptionRunner
        _wr.set_error_callback(log)
        folder = Path(os.environ.get("TRANSCRIPTION_FOLDER",
                                     str(Path.home() / "Documents" / "transcriptions")))
        self._whisper_runner = WhisperTranscriptionRunner(folder, on_device_change=self._update_transcribe_title)
        self._whisper_runner.start()
        self._transcribing = True
        self._update_transcribe_title()
        self.icon = self._icon_on
        devices = [f"{ch.label}: {ch.device_name}" for ch in self._whisper_runner._channels]
        log(f"🎙️ Whisper transcription started — {', '.join(devices)}")

    def stop_transcribing(self):
        if self._whisper_runner:
            self._whisper_runner.stop()
            self._whisper_runner = None
        self._transcribing = False
        self._update_transcribe_title()
        self.icon = self._icon_off
        log("🎙️ Whisper transcription stopped")

    def monitor_transcription(self, _):
        from datetime import date
        folder = Path(os.environ.get("TRANSCRIPTION_FOLDER",
                                     str(Path.home() / "Documents" / "transcriptions")))
        today_file = folder / f"{date.today()} transcription.txt"
        today_file.touch()
        subprocess.Popen([
            "osascript",
            "-e", 'tell application "Terminal"',
            "-e", f"do script \"tput setaf 8 && python3 -u '{Path(__file__).parent / 'tail_rolling.py'}' '{today_file}'\"",
            "-e", "activate",
            "-e", "end tell",
        ])

    # ── PowerPoint tracking ──

    def start_ppt_tracking(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "powerpoint-monitor"))
        from ppt_probe import PowerPointMonitor
        folder = Path(os.environ.get("TRANSCRIPTION_FOLDER",
                                     str(Path.home() / "Documents" / "transcriptions")))
        self._ppt_monitor = PowerPointMonitor(folder, slide_callback=self._ws_server.push_slide)
        self._ppt_monitor.start()
        self._tracking_ppt = True
        log("📊 PowerPoint tracking started")

    # ── IntelliJ tracking ──

    def start_ij_tracking(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "intellij-monitor"))
        from ij_probe import IntelliJMonitor
        folder = Path(os.environ.get("TRANSCRIPTION_FOLDER",
                                     str(Path.home() / "Documents" / "transcriptions")))
        self._ij_monitor = IntelliJMonitor(folder)
        self._ij_monitor.start()
        log("📋 IntelliJ tracking started")

    def toggle_transcribing(self, _):
        if self._transcribing:
            self.stop_transcribing()
        else:
            self.start_transcribing()

    def _flash_screenshot_icon(self):
        current = self._icon_on if self._transcribing else self._icon_off
        self.icon = self._icon_camera
        threading.Timer(1.0, lambda: setattr(self, 'icon', current)).start()

    def copy_intellij_git(self, _):
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "intellij-monitor"))
            from ij_probe import probe_intellij, get_last_used_intellij_project
            state = probe_intellij()
            if not state or not state.get("url"):
                state = get_last_used_intellij_project()
            if not state or not state.get("url"):
                log("📋 No IntelliJ project with git remote found")
                return
            url = state["url"]
            branch = state.get("branch", "")
            clipboard_text = f"{url} ({branch})" if branch else url
            set_clipboard(clipboard_text)
            log(f"📋 Copied: {clipboard_text}")
        except Exception as e:
            log(f"📋 IntelliJ git copy failed: {e}")

    def on_clean(self, _):
        threading.Thread(target=handle_clean_hotkey, daemon=True).start()

    def show_log(self, _):
        from AppKit import (NSPanel, NSScrollView, NSTextView, NSScreen, NSFont,
                            NSBackingStoreBuffered, NSWindowStyleMaskTitled,
                            NSWindowStyleMaskClosable, NSWindowStyleMaskResizable,
                            NSBezelBorder, NSApplication, NSPasteboard, NSStringPboardType)
        from Foundation import NSMakeRect
        import objc

        log_text = "\n".join(_log_buffer) if _log_buffer else "(no log entries yet)"

        screen = NSScreen.mainScreen().frame()
        w = int(screen.size.width * 0.7)
        h = int(screen.size.height * 0.7)
        x = int((screen.size.width - w) / 2)
        y = int((screen.size.height - h) / 2)

        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, y, w, h),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
            NSBackingStoreBuffered, False)
        panel.setTitle_("Log")
        panel.setLevel_(25)  # floating above other windows

        scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
        scroll.setHasVerticalScroller_(True)
        scroll.setHasHorizontalScroller_(True)
        scroll.setBorderType_(NSBezelBorder)
        scroll.setAutoresizingMask_(0x12)  # flexible width + height

        class _ClickToCopyTextView(NSTextView):
            def mouseDown_(self, event):
                text = self.string()
                pb = NSPasteboard.generalPasteboard()
                pb.declareTypes_owner_([NSStringPboardType], None)
                pb.setString_forType_(text, NSStringPboardType)

        text_view = _ClickToCopyTextView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
        text_view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(12, 0))
        text_view.setEditable_(False)
        text_view.setString_(log_text)
        text_view.setAutoresizingMask_(0x12)

        scroll.setDocumentView_(text_view)
        panel.contentView().addSubview_(scroll)
        self._log_panel = panel  # prevent garbage collection
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        panel.makeKeyAndOrderFront_(None)

    def _on_ws_clients_changed(self, count: int) -> None:
        self._ws_status_item.title = f"WS {'🟢' if count > 0 else '🔴'}"

    def quit_app(self, _):
        if self._whisper_runner:
            self._whisper_runner.stop()
        if self._ppt_monitor:
            self._ppt_monitor.stop()
        if self._ij_monitor:
            self._ij_monitor.stop()
        if _dictation_active:
            _restore_dictation_volume()
        if _tap_run_loop_ref:
            CFRunLoopStop(_tap_run_loop_ref)
        self._ws_server.stop()
        log(f"WS server stopped")
        # Kill desktop-overlay (launched by start.sh as a sibling process)
        subprocess.run(["pkill", "-f", "DesktopOverlay"], stderr=subprocess.DEVNULL)
        rumps.quit_application()
        os._exit(0)


PID_FILE = Path.home() / ".wispr-addons.pid"


def _kill_previous_instance():
    if PID_FILE.exists():
        try:
            old_pid = int(PID_FILE.read_text().strip())
            os.kill(old_pid, signal.SIGTERM)
            log(f"Killed previous instance (PID {old_pid})")
            time.sleep(0.5)
        except (ValueError, ProcessLookupError):
            pass
    PID_FILE.write_text(str(os.getpid()))


def main():
    global _client, _app_ref

    _kill_previous_instance()

    import atexit
    atexit.register(lambda: PID_FILE.unlink(missing_ok=True))

    # Load API key
    secrets_path = Path.home() / ".training-assistants-secrets.env"
    if secrets_path.exists():
        for line in secrets_path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                os.environ[key.strip()] = value.strip()
    api_key = os.environ.get("WISPR_CLEANUP_ANTHROPIC_API_KEY")
    if not api_key:
        rumps.alert("Wispr Addons", f"WISPR_CLEANUP_ANTHROPIC_API_KEY not set.\nAdd it to:\n{secrets_path}")
        sys.exit(1)
    os.environ["ANTHROPIC_API_KEY"] = api_key

    _client = anthropic.Anthropic(max_retries=0)

    log("Wispr Addons started")

    # Warm up Whisper model BEFORE event tap or GUI (Metal needs clean main thread)
    import numpy as np
    import mlx_whisper
    _whisper_model = os.environ.get("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
    log("🎙️ Warming up Whisper model...")
    mlx_whisper.transcribe(
        np.zeros(16000, dtype=np.float32),
        path_or_hf_repo=_whisper_model, verbose=False,
    )
    log("🎙️ Whisper model ready")

    # Start event tap on background thread
    tap_thread = threading.Thread(target=_run_event_tap, daemon=True)
    tap_thread.start()

    # Hide from Cmd+Tab (menu bar only, no dock icon)
    AppKit.NSApplication.sharedApplication().setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)

    # Run menu bar app on main thread
    _app_ref = WisprAddonsApp()
    _app_ref.start_transcribing()
    _app_ref.start_ppt_tracking()
    _app_ref.start_ij_tracking()
    _app_ref.run()


if __name__ == "__main__":
    main()
