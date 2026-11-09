# Re-keys the user's login keyring: the old and new password arrive on stdin,
# one per line. Run as the keyring's owner, on their session bus.
import sys
import dbus

old, new = sys.stdin.read().split("\n")[:2]
bus = dbus.SessionBus()
svc = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
_, session = svc.OpenSession("plain", dbus.String("", variant_level=1),
                             dbus_interface="org.freedesktop.Secret.Service")


def secret(text):
    return dbus.Struct((session, dbus.ByteArray(b""),
                        dbus.ByteArray(text.encode()), "text/plain"))


svc.ChangeWithMasterPassword(
    dbus.ObjectPath("/org/freedesktop/secrets/collection/login"),
    secret(old), secret(new),
    dbus_interface="org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface")
