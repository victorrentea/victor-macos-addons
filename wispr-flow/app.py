#!/usr/bin/env python3
"""Wispr Addons — macOS menu bar app.

Wraps the clipboard cleanup daemon (CGEventTap) in a menu bar app using rumps.
The event tap runs on a background thread; the main thread runs the menu bar UI.
"""

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

VK_D = 0x02
VK_V = 0x09
VK_Z = 0x06
VK_ESCAPE = 0x35
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
        if str(objc.objc_object(c_void_p=ref)) == name:
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
        log(f"Dictation device: {DICTATION_MUTE_DEVICE} (ID {device_id})")
    else:
        log(f"WARNING: '{DICTATION_MUTE_DEVICE}' not found")

    log("Event tap active")
    CFRunLoopRun()
    log("Event tap stopped")


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
        self._whisper_runner = None
        self._transcribing = False

        self._transcribe_item = rumps.MenuItem("💬 Transcribing", callback=self.toggle_transcribing)
        self.menu = [
            self._transcribe_item,
            None,  # separator
            rumps.MenuItem("Emotional 🥹 Paste — ⌘⌃V", callback=self.on_clean),
            rumps.MenuItem("Toggle Dark Mode — ⌘⌃⌥D", callback=None),
            rumps.MenuItem("Mute 🎶 — Mouse 5", callback=None),
            rumps.MenuItem("Re-paste — Wheel x 2", callback=None),
            None,  # separator
            rumps.MenuItem("📋 IntelliJ Git → Clipboard", callback=self.copy_intellij_git),
            rumps.MenuItem("🎬 Show", callback=self.toggle_overlay_controls),
            rumps.MenuItem("☠️ Kill port"),
            rumps.MenuItem("Show Log", callback=self.show_log),
            None,
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]
        self.menu["Toggle Dark Mode — ⌘⌃⌥D"].enabled = False
        self.menu["Mute 🎶 — Mouse 5"].enabled = False
        self.menu["Re-paste — Wheel x 2"].enabled = False

        # Kill port submenu — build initial items inline
        self._kill_port_history: list[int] = [8080]
        kill_menu = self.menu["☠️ Kill port"]
        kill_menu.add(rumps.MenuItem("Port…", callback=self._kill_port_prompt))
        kill_menu.add(None)
        for port in self._kill_port_history:
            kill_menu.add(rumps.MenuItem(f":{port}", callback=self._make_kill_callback(port)))

    def _rebuild_kill_submenu(self):
        kill_menu = self.menu["☠️ Kill port"]
        # Remove all items after "Port…" and separator
        for key in list(kill_menu.keys()):
            if key.startswith(":"):
                del kill_menu[key]
        for port in self._kill_port_history:
            kill_menu.add(rumps.MenuItem(f":{port}", callback=self._make_kill_callback(port)))

    def _make_kill_callback(self, port: int):
        def cb(_):
            self._kill_port(port)
        return cb

    def _kill_port_prompt(self, _):
        from AppKit import (NSAlert, NSTextField, NSAlertFirstButtonReturn,
                            NSScreen, NSAlertStyleInformational)
        from Foundation import NSMakeRect

        alert = AppKit.NSAlert.alloc().init()
        alert.setAlertStyle_(NSAlertStyleInformational)
        alert.setMessageText_("Kill port")
        alert.setInformativeText_("")
        alert.addButtonWithTitle_("Kill")
        alert.addButtonWithTitle_("Cancel")
        alert.window().setTitle_("")

        field = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 0, 60, 22))
        field.setPlaceholderString_("8080")
        alert.setAccessoryView_(field)

        # Position near top-right (close to menu bar)
        window = alert.window()
        screen = NSScreen.mainScreen().frame()
        window.setFrameTopLeftPoint_((screen.size.width - 300, screen.size.height - 30))

        window.makeFirstResponder_(field)
        result = alert.runModal()
        if result != NSAlertFirstButtonReturn:
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
                return
            for pid in pids.splitlines():
                subprocess.run(["kill", "-9", pid.strip()], timeout=5)
            log(f"☠️ Killed :{port} (pid {pids.replace(chr(10), ', ')})")
        except Exception as e:
            log(f"☠️ Kill :{port} failed: {e}")
        # Update history: move to top, keep unique, max 5
        if port in self._kill_port_history:
            self._kill_port_history.remove(port)
        self._kill_port_history.insert(0, port)
        self._kill_port_history = self._kill_port_history[:5]
        self._rebuild_kill_submenu()

    def start_transcribing(self):
        from whisper_runner import WhisperTranscriptionRunner
        folder = Path(os.environ.get("TRANSCRIPTION_FOLDER",
                                     str(Path.home() / "Documents" / "transcriptions")))
        self._whisper_runner = WhisperTranscriptionRunner(folder)
        self._whisper_runner.start()
        self._transcribing = True
        self._transcribe_item.title = "💬 Transcribing"
        self.icon = self._icon_on
        log("🎙️ Whisper transcription started")

    def stop_transcribing(self):
        if self._whisper_runner:
            self._whisper_runner.stop()
            self._whisper_runner = None
        self._transcribing = False
        self._transcribe_item.title = "💬 Not Transcribing"
        self.icon = self._icon_off
        log("🎙️ Whisper transcription stopped")

    def toggle_transcribing(self, _):
        if self._transcribing:
            self.stop_transcribing()
        else:
            self.start_transcribing()

    def copy_intellij_git(self, _):
        try:
            # Get IntelliJ window title
            script = (
                'tell application "System Events" to tell process "idea" to '
                'return title of front window'
            )
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True, text=True, timeout=2,
            )
            title = result.stdout.strip()
            if not title:
                log("📋 IntelliJ not open or no window")
                return

            # Extract project name from title: "kafka – File.java [module]" → "kafka"
            project_name = title.split(" – ")[0].split("[")[0].strip()
            if not project_name:
                log(f"📋 Can't parse project from: {title}")
                return

            # Find project path via recentProjects.xml
            import glob
            import xml.etree.ElementTree as ET
            pattern = os.path.expanduser(
                "~/Library/Application Support/JetBrains/IntelliJIdea*/options/recentProjects.xml"
            )
            xml_files = sorted(glob.glob(pattern), reverse=True)
            project_path = None
            for xml_file in xml_files:
                try:
                    tree = ET.parse(xml_file)
                    for entry in tree.findall(".//entry"):
                        key = entry.get("key", "")
                        folder = Path(key.replace("$USER_HOME$", str(Path.home()))).name
                        if folder.lower() == project_name.lower():
                            project_path = key.replace("$USER_HOME$", str(Path.home()))
                            break
                except Exception:
                    continue
                if project_path:
                    break

            if not project_path:
                log(f"📋 Project '{project_name}' not found in recentProjects.xml")
                return

            # Get git remote URL and branch
            def _git(cmd):
                r = subprocess.run(
                    ["git", "-C", project_path] + cmd,
                    capture_output=True, text=True, timeout=2,
                )
                return r.stdout.strip() if r.returncode == 0 else ""

            remote_url = _git(["remote", "get-url", "origin"])
            branch = _git(["branch", "--show-current"])

            if not remote_url:
                log(f"📋 No git remote in {project_path}")
                return

            clipboard_text = f"{remote_url} ({branch})" if branch else remote_url
            set_clipboard(clipboard_text)
            log(f"📋 Copied: {clipboard_text}")

        except Exception as e:
            log(f"📋 IntelliJ git copy failed: {e}")

    def toggle_overlay_controls(self, sender):
        try:
            pid_str = Path("/tmp/desktop-overlay.pid").read_text().strip()
            pid = int(pid_str)
            os.kill(pid, signal.SIGUSR1)
            if sender.title == "🎬 Show":
                sender.title = "🎬 Hide"
            else:
                sender.title = "🎬 Show"
        except FileNotFoundError:
            log("Overlay not running (no PID file)")
        except ProcessLookupError:
            log("Overlay process not found")
        except Exception as e:
            log(f"Toggle overlay failed: {e}")

    def on_clean(self, _):
        threading.Thread(target=handle_clean_hotkey, daemon=True).start()

    def show_log(self, _):
        log_text = "\n".join(_log_buffer) if _log_buffer else "(no log entries yet)"
        rumps.alert(title="Wispr Addons Log", message=log_text)

    def quit_app(self, _):
        if self._transcribing:
            self.stop_transcribing()
        if _dictation_active:
            _restore_dictation_volume()
        if _tap_run_loop_ref:
            CFRunLoopStop(_tap_run_loop_ref)
        rumps.quit_application()


def main():
    global _client, _app_ref

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

    # Start event tap on background thread
    tap_thread = threading.Thread(target=_run_event_tap, daemon=True)
    tap_thread.start()

    log("Wispr Addons started")

    # Hide from Cmd+Tab (menu bar only, no dock icon)
    AppKit.NSApplication.sharedApplication().setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)

    # Run menu bar app on main thread
    _app_ref = WisprAddonsApp()
    _app_ref.start_transcribing()
    _app_ref.run()


if __name__ == "__main__":
    main()
