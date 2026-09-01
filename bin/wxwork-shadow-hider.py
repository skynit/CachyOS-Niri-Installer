#!/usr/bin/env python3

import ctypes
import ctypes.util
import sys
import time


DISPLAY = ctypes.c_void_p
WINDOW = ctypes.c_ulong
ATOM = ctypes.c_ulong
IS_VIEWABLE = 2


class WindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("border_width", ctypes.c_int),
        ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p),
        ("root", WINDOW),
        ("class", ctypes.c_int),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int),
        ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long),
        ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
        ("screen", ctypes.c_void_p),
    ]


class ClassHint(ctypes.Structure):
    _fields_ = [("res_name", ctypes.c_void_p), ("res_class", ctypes.c_void_p)]


library_path = ctypes.util.find_library("X11")
if not library_path:
    raise SystemExit("libX11 is unavailable")

x11 = ctypes.CDLL(library_path)
x11.XOpenDisplay.restype = DISPLAY
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XDefaultRootWindow.restype = WINDOW
x11.XDefaultRootWindow.argtypes = [DISPLAY]
x11.XQueryTree.restype = ctypes.c_int
x11.XQueryTree.argtypes = [
    DISPLAY,
    WINDOW,
    ctypes.POINTER(WINDOW),
    ctypes.POINTER(WINDOW),
    ctypes.POINTER(ctypes.POINTER(WINDOW)),
    ctypes.POINTER(ctypes.c_uint),
]
x11.XFree.restype = ctypes.c_int
x11.XFree.argtypes = [ctypes.c_void_p]
x11.XGetWindowAttributes.restype = ctypes.c_int
x11.XGetWindowAttributes.argtypes = [DISPLAY, WINDOW, ctypes.c_void_p]
x11.XUnmapWindow.restype = ctypes.c_int
x11.XUnmapWindow.argtypes = [DISPLAY, WINDOW]
x11.XFlush.restype = ctypes.c_int
x11.XFlush.argtypes = [DISPLAY]
x11.XGetClassHint.restype = ctypes.c_int
x11.XGetClassHint.argtypes = [DISPLAY, WINDOW, ctypes.c_void_p]
x11.XGetWindowProperty.restype = ctypes.c_int
x11.XGetWindowProperty.argtypes = [
    DISPLAY,
    WINDOW,
    ATOM,
    ctypes.c_long,
    ctypes.c_long,
    ctypes.c_int,
    ATOM,
    ctypes.POINTER(ATOM),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_void_p),
]
x11.XInternAtom.restype = ATOM
x11.XInternAtom.argtypes = [DISPLAY, ctypes.c_char_p, ctypes.c_int]
x11.XSetErrorHandler.restype = ctypes.c_void_p
x11.XSetErrorHandler.argtypes = [ctypes.c_void_p]


@ctypes.CFUNCTYPE(ctypes.c_int, DISPLAY, ctypes.c_void_p)
def ignore_x_error(_display, _event):
    return 0


x11.XSetErrorHandler(ignore_x_error)
display = x11.XOpenDisplay(None)
if not display:
    raise SystemExit("cannot open X11 display")

root = x11.XDefaultRootWindow(display)
net_wm_name = x11.XInternAtom(display, b"_NET_WM_NAME", 0)
utf8_string = x11.XInternAtom(display, b"UTF8_STRING", 0)


def get_property(window, property_atom, requested_type):
    actual_type = ATOM()
    actual_format = ctypes.c_int()
    item_count = ctypes.c_ulong()
    bytes_after = ctypes.c_ulong()
    data = ctypes.c_void_p()
    result = x11.XGetWindowProperty(
        display,
        window,
        property_atom,
        0,
        128,
        0,
        requested_type,
        ctypes.byref(actual_type),
        ctypes.byref(actual_format),
        ctypes.byref(item_count),
        ctypes.byref(bytes_after),
        ctypes.byref(data),
    )
    if result != 0 or not data.value:
        return None

    byte_count = item_count.value * (
        8 if actual_format.value == 32 else actual_format.value // 8
    )
    value = ctypes.string_at(data.value, byte_count)
    x11.XFree(data)
    return value


def get_title(window):
    value = get_property(window, net_wm_name, utf8_string)
    return value.decode("utf-8", "replace") if value else ""


def get_class(window):
    hint = ClassHint()
    if not x11.XGetClassHint(display, window, ctypes.byref(hint)):
        return None

    names = []
    for pointer in (hint.res_name, hint.res_class):
        names.append(
            ctypes.string_at(pointer).decode("utf-8", "replace") if pointer else ""
        )
        if pointer:
            x11.XFree(pointer)
    return tuple(names)


def get_attributes(window):
    attributes = WindowAttributes()
    if not x11.XGetWindowAttributes(display, window, ctypes.byref(attributes)):
        return None
    return attributes


def collect_windows(parent, windows):
    root_return = WINDOW()
    parent_return = WINDOW()
    children = ctypes.POINTER(WINDOW)()
    child_count = ctypes.c_uint()
    if not x11.XQueryTree(
        display,
        parent,
        ctypes.byref(root_return),
        ctypes.byref(parent_return),
        ctypes.byref(children),
        ctypes.byref(child_count),
    ):
        return

    try:
        for index in range(child_count.value):
            child = children[index]
            windows.append(child)
            collect_windows(child, windows)
    finally:
        if children:
            x11.XFree(ctypes.cast(children, ctypes.c_void_p))


def is_fullscreenish(attributes, root_attributes):
    return (
        attributes.width >= root_attributes.width * 0.5
        and attributes.height >= root_attributes.height * 0.8
    ) or (
        attributes.width >= root_attributes.width * 0.8
        and attributes.height >= root_attributes.height * 0.5
    )


def frames_main_window(attributes, main_geometry):
    main_x, main_y, main_width, main_height = main_geometry
    if main_width < 200 or main_height < 200:
        return False
    return (
        attributes.x <= main_x
        and attributes.y <= main_y
        and attributes.x + attributes.width >= main_x + main_width
        and attributes.y + attributes.height >= main_y + main_height
        and attributes.width > main_width
        and attributes.height > main_height
    )


def scan_and_hide():
    windows = []
    collect_windows(root, windows)

    main_geometry = None
    largest_area = 0
    for window in windows:
        window_class = get_class(window)
        if not window_class or window_class[0] != "wxwork.exe" or not get_title(window):
            continue
        attributes = get_attributes(window)
        if attributes and attributes.width * attributes.height > largest_area:
            largest_area = attributes.width * attributes.height
            main_geometry = (
                attributes.x,
                attributes.y,
                attributes.width,
                attributes.height,
            )

    root_attributes = get_attributes(root)
    for window in windows:
        window_class = get_class(window)
        if not window_class or window_class[0] != "wxwork.exe" or get_title(window):
            continue
        attributes = get_attributes(window)
        if not attributes or attributes.map_state != IS_VIEWABLE:
            continue
        if (
            root_attributes and is_fullscreenish(attributes, root_attributes)
        ) or (main_geometry and frames_main_window(attributes, main_geometry)):
            print(f"hide wxwork shadow: 0x{window:08x}", flush=True)
            x11.XUnmapWindow(display, window)
    x11.XFlush(display)


def watch():
    print("wxwork-shadow-hider: watching", flush=True)
    while True:
        scan_and_hide()
        time.sleep(2)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "watch":
        watch()
    else:
        scan_and_hide()
        print("done")
