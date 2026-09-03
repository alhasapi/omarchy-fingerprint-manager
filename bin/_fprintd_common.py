"""Shared net.reactivated.Fprint D-Bus glue for the omarchy-fingerprint plugin.

Method/signal signatures confirmed live against this machine's open-fprintd
service (busctl introspect) and against openfprintd's own source
(/usr/lib/python3.14/site-packages/openfprintd/device.py) and
python-validity's backend (/usr/lib/python-validity/dbus-service).
"""

import contextlib
import json
import sys

import dbus

MANAGER_INTERFACE = "net.reactivated.Fprint.Manager"
DEVICE_INTERFACE = "net.reactivated.Fprint.Device"
PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties"

# The ten canonical fprintd/libfprint finger names, confirmed from
# python-validity's finger_ids table (validitysensor/fingerprint_constants.py),
# which itself cites https://fprint.freedesktop.org/fprintd-dev/Device.html#fingerprint-names.
FINGER_NAMES = (
    "left-thumb", "left-index-finger", "left-middle-finger",
    "left-ring-finger", "left-little-finger",
    "right-thumb", "right-index-finger", "right-middle-finger",
    "right-ring-finger", "right-little-finger",
)


def emit(event, **fields):
    fields["event"] = event
    print(json.dumps(fields), flush=True)


def emit_error(code, message):
    emit("error", code=code, message=message)


def get_default_device(bus):
    manager = bus.get_object("net.reactivated.Fprint", "/net/reactivated/Fprint/Manager")
    manager_iface = dbus.Interface(manager, MANAGER_INTERFACE)
    device_path = manager_iface.GetDefaultDevice()
    device_obj = bus.get_object("net.reactivated.Fprint", device_path)
    return device_path, device_obj


@contextlib.contextmanager
def claimed(device_obj, username=""):
    """Claim the device for the duration of the block, always releasing after."""
    device_iface = dbus.Interface(device_obj, DEVICE_INTERFACE)
    device_iface.Claim(username)
    try:
        yield device_iface
    finally:
        try:
            device_iface.Release()
        except dbus.DBusException:
            pass


def dbus_error_code(exc):
    name = exc.get_dbus_name() or ""
    return name.rsplit(".", 1)[-1] or "DBusError"


def system_bus():
    return dbus.SystemBus()


def fail_and_exit(exc):
    emit_error(dbus_error_code(exc), str(exc))
    sys.exit(1)
