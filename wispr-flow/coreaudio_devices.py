"""
CoreAudio device detection module using ctypes.
No external dependencies -- uses only CoreAudio and CoreFoundation frameworks.

Provides:
    list_input_devices()  -> list of dicts with name, alive, transport, channels, uid, device_id
    is_device_alive(device_id) -> bool
    register_device_change_callback(callback) -> unregister function
"""
import ctypes
from ctypes import c_uint32, c_void_p, byref, sizeof, CFUNCTYPE

# ---------------------------------------------------------------------------
# Framework bindings
# ---------------------------------------------------------------------------
_CoreAudio = ctypes.CDLL('/System/Library/Frameworks/CoreAudio.framework/CoreAudio')
_CF = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

# Types
AudioObjectID = c_uint32
UInt32 = c_uint32
OSStatus = ctypes.c_int32


class AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ('mSelector', c_uint32),
        ('mScope', c_uint32),
        ('mElement', c_uint32),
    ]


# Function prototypes
_GetPropertyDataSize = _CoreAudio.AudioObjectGetPropertyDataSize
_GetPropertyDataSize.restype = OSStatus
_GetPropertyDataSize.argtypes = [
    AudioObjectID, ctypes.POINTER(AudioObjectPropertyAddress),
    UInt32, c_void_p, ctypes.POINTER(UInt32),
]

_GetPropertyData = _CoreAudio.AudioObjectGetPropertyData
_GetPropertyData.restype = OSStatus
_GetPropertyData.argtypes = [
    AudioObjectID, ctypes.POINTER(AudioObjectPropertyAddress),
    UInt32, c_void_p, ctypes.POINTER(UInt32), c_void_p,
]

_AddPropertyListener = _CoreAudio.AudioObjectAddPropertyListener
_AddPropertyListener.restype = OSStatus
_RemovePropertyListener = _CoreAudio.AudioObjectRemovePropertyListener
_RemovePropertyListener.restype = OSStatus

# CFString helpers
_CF.CFStringGetCStringPtr.restype = ctypes.c_char_p
_CF.CFStringGetCStringPtr.argtypes = [c_void_p, ctypes.c_uint32]
_CF.CFStringGetCString.restype = ctypes.c_bool
_CF.CFStringGetCString.argtypes = [c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_CF.CFStringGetLength.restype = ctypes.c_long
_CF.CFStringGetLength.argtypes = [c_void_p]
_CF.CFRelease.argtypes = [c_void_p]

_kCFStringEncodingUTF8 = 0x08000100

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_kAudioObjectSystemObject = 1
_PTR_SIZE = sizeof(c_void_p)

# Callback C type
_ListenerProc = CFUNCTYPE(
    OSStatus, AudioObjectID, UInt32,
    ctypes.POINTER(AudioObjectPropertyAddress), c_void_p,
)
_AddPropertyListener.argtypes = [
    AudioObjectID, ctypes.POINTER(AudioObjectPropertyAddress),
    _ListenerProc, c_void_p,
]
_RemovePropertyListener.argtypes = [
    AudioObjectID, ctypes.POINTER(AudioObjectPropertyAddress),
    _ListenerProc, c_void_p,
]

# Transport type lookup
TRANSPORT_NAMES = {
    'bltn': 'Built-in',
    'usb ': 'USB',
    'blue': 'Bluetooth',
    'virt': 'Virtual',
    'pci ': 'PCI',
    'hdmi': 'HDMI',
    'dprt': 'DisplayPort',
    'airp': 'AirPlay',
    'fire': 'FireWire',
    'thng': 'Thunderbolt',
}


def _fourcc(s: str) -> int:
    """Convert 4-char code string to UInt32."""
    return ord(s[0]) << 24 | ord(s[1]) << 16 | ord(s[2]) << 8 | ord(s[3])


def _uint_to_fourcc(val: int) -> str:
    return bytes([
        (val >> 24) & 0xFF, (val >> 16) & 0xFF,
        (val >> 8) & 0xFF, val & 0xFF,
    ]).decode('ascii', errors='replace')


def _cfstring_to_str(cf_str) -> str:
    """Convert a CFStringRef to Python str and release it."""
    cstr = _CF.CFStringGetCStringPtr(cf_str, _kCFStringEncodingUTF8)
    if cstr:
        result = cstr.decode('utf-8')
    else:
        length = _CF.CFStringGetLength(cf_str)
        buf = ctypes.create_string_buffer(length * 4 + 1)
        _CF.CFStringGetCString(cf_str, buf, len(buf), _kCFStringEncodingUTF8)
        result = buf.value.decode('utf-8')
    _CF.CFRelease(cf_str)
    return result


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

def _get_device_ids() -> list[int]:
    prop = AudioObjectPropertyAddress(_fourcc('dev#'), _fourcc('glob'), 0)
    size = UInt32(0)
    status = _GetPropertyDataSize(_kAudioObjectSystemObject, byref(prop), 0, None, byref(size))
    if status != 0:
        return []
    count = size.value // sizeof(AudioObjectID)
    devs = (AudioObjectID * count)()
    status = _GetPropertyData(_kAudioObjectSystemObject, byref(prop), 0, None, byref(size), byref(devs))
    if status != 0:
        return []
    return list(devs)


def _get_string_property(device_id: int, selector: int) -> str | None:
    prop = AudioObjectPropertyAddress(selector, _fourcc('glob'), 0)
    cf_str = c_void_p(0)
    size = UInt32(sizeof(c_void_p))
    status = _GetPropertyData(device_id, byref(prop), 0, None, byref(size), byref(cf_str))
    if status != 0 or not cf_str.value:
        return None
    return _cfstring_to_str(cf_str)


def _get_uint_property(device_id: int, selector: int, scope: str = 'glob') -> int | None:
    prop = AudioObjectPropertyAddress(selector, _fourcc(scope), 0)
    val = UInt32(0)
    size = UInt32(sizeof(UInt32))
    status = _GetPropertyData(device_id, byref(prop), 0, None, byref(size), byref(val))
    if status != 0:
        return None
    return val.value


def _get_input_channel_count(device_id: int) -> int:
    prop = AudioObjectPropertyAddress(_fourcc('slay'), _fourcc('inpt'), 0)
    size = UInt32(0)
    status = _GetPropertyDataSize(device_id, byref(prop), 0, None, byref(size))
    if status != 0 or size.value == 0:
        return 0
    buf = (ctypes.c_byte * size.value)()
    status = _GetPropertyData(device_id, byref(prop), 0, None, byref(size), byref(buf))
    if status != 0:
        return 0
    num_buffers = UInt32.from_buffer_copy(buf, 0).value
    total = 0
    # On 64-bit: 8 bytes offset (padding after mNumberBuffers for pointer alignment)
    # Each AudioBuffer: UInt32 mNumberChannels + UInt32 mDataByteSize + void* mData
    buffer_start = 8 if _PTR_SIZE == 8 else 4
    buffer_stride = 4 + 4 + _PTR_SIZE
    for i in range(num_buffers):
        offset = buffer_start + i * buffer_stride
        if offset + 4 > len(buf):
            break
        total += UInt32.from_buffer_copy(buf, offset).value
    return total


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def list_input_devices() -> list[dict]:
    """
    Return a list of dicts for every audio device that has input channels.

    Each dict contains:
        device_id  (int)       -- CoreAudio AudioObjectID
        name       (str)       -- human-readable device name
        alive      (bool)      -- True if device is currently alive
        transport  (str)       -- 4-char transport code, e.g. 'usb ', 'bltn'
        transport_name (str)   -- human-readable transport, e.g. 'USB', 'Built-in'
        channels   (int)       -- number of input channels
        uid        (str)       -- stable unique identifier (persists across reconnects)
    """
    results = []
    for dev_id in _get_device_ids():
        channels = _get_input_channel_count(dev_id)
        if channels == 0:
            continue
        transport_raw = _get_uint_property(dev_id, _fourcc('tran'))
        transport_code = _uint_to_fourcc(transport_raw) if transport_raw is not None else '????'
        alive_raw = _get_uint_property(dev_id, _fourcc('livn'))
        results.append({
            'device_id': dev_id,
            'name': _get_string_property(dev_id, _fourcc('lnam')) or '<unknown>',
            'alive': bool(alive_raw) if alive_raw is not None else False,
            'transport': transport_code,
            'transport_name': TRANSPORT_NAMES.get(transport_code, transport_code),
            'channels': channels,
            'uid': _get_string_property(dev_id, _fourcc('uid ')) or '<unknown>',
        })
    return results


def is_device_alive(device_id: int) -> bool:
    """Check if a specific CoreAudio device is currently alive."""
    val = _get_uint_property(device_id, _fourcc('livn'))
    return bool(val) if val is not None else False


def get_device_by_uid(uid: str) -> dict | None:
    """Find an input device by its stable UID. Returns None if not found."""
    for dev in list_input_devices():
        if dev['uid'] == uid:
            return dev
    return None


# Keep references to prevent garbage collection of C callbacks
_active_listeners: list[tuple] = []


def register_device_change_callback(callback) -> callable:
    """
    Register a Python callable to be notified when the audio device list changes.

    The callback receives no arguments: callback()
    It fires when devices are added, removed, or their properties change.

    Returns an unregister function. Call it to stop listening:
        unregister = register_device_change_callback(my_func)
        # ... later ...
        unregister()

    IMPORTANT: In a rumps app, the NSApplication run loop handles dispatch
    automatically. In a plain script, you need a CFRunLoop running.
    """
    def _c_callback(obj_id, num_addresses, addresses, client_data):
        try:
            callback()
        except Exception as e:
            import traceback
            traceback.print_exc()
        return 0  # noErr

    c_ref = _ListenerProc(_c_callback)
    prop = AudioObjectPropertyAddress(_fourcc('dev#'), _fourcc('glob'), 0)

    status = _AddPropertyListener(_kAudioObjectSystemObject, byref(prop), c_ref, None)
    if status != 0:
        raise RuntimeError(f"AudioObjectAddPropertyListener failed with status {status}")

    entry = (prop, c_ref)
    _active_listeners.append(entry)

    def unregister():
        s = _RemovePropertyListener(_kAudioObjectSystemObject, byref(entry[0]), entry[1], None)
        if entry in _active_listeners:
            _active_listeners.remove(entry)
        return s == 0

    return unregister


# ---------------------------------------------------------------------------
# Self-test when run directly
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    print("=" * 100)
    print("coreaudio_devices module -- self-test")
    print("=" * 100)

    print("\n--- list_input_devices() ---")
    devices = list_input_devices()
    print(f"Found {len(devices)} input device(s):\n")
    print(f"  {'ID':>5} | {'Name':35s} | {'Alive':5s} | {'Transport':10s} | {'Ch':>2s} | UID")
    print("  " + "-" * 95)
    for d in devices:
        print(f"  {d['device_id']:5d} | {d['name']:35s} | {'YES' if d['alive'] else 'NO':5s} "
              f"| {d['transport_name']:10s} | {d['channels']:2d} | {d['uid']}")

    print("\n--- is_device_alive() ---")
    for d in devices:
        alive = is_device_alive(d['device_id'])
        print(f"  Device {d['device_id']} ({d['name'][:30]}): alive={alive}")

    print("\n--- get_device_by_uid() ---")
    test_uid = devices[0]['uid'] if devices else None
    if test_uid:
        found = get_device_by_uid(test_uid)
        print(f"  Searched for UID: {test_uid}")
        print(f"  Found: {found['name'] if found else 'NOT FOUND'}")

    print("\n--- register_device_change_callback() ---")
    def on_change():
        print("  [CALLBACK] Device list changed!")

    unregister = register_device_change_callback(on_change)
    print("  Callback registered successfully.")
    unregister()
    print("  Callback unregistered successfully.")

    print("\n--- ALL TESTS PASSED ---")
