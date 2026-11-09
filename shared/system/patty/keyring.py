# The user's keyrings, run as their owner on their session bus.
#   patty-keyring list         the login and default keyrings: path, tab, label
#   patty-keyring change PATH  old and new password on stdin, one per line
import sys
import dbus

bus = dbus.SessionBus()
svc = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
SERVICE = "org.freedesktop.Secret.Service"

if sys.argv[1] == "list":
    paths = ["/org/freedesktop/secrets/collection/login",
             str(svc.ReadAlias("default", dbus_interface=SERVICE))]
    for path in dict.fromkeys(p for p in paths if p != "/"):
        label = bus.get_object("org.freedesktop.secrets", path).Get(
            "org.freedesktop.Secret.Collection", "Label",
            dbus_interface="org.freedesktop.DBus.Properties")
        print(f"{path}\t{label}")
    sys.exit(0)

old, new = sys.stdin.read().split("\n")[:2]
_, session = svc.OpenSession("plain", dbus.String("", variant_level=1),
                             dbus_interface=SERVICE)


def secret(text):
    return dbus.Struct((session, dbus.ByteArray(b""),
                        dbus.ByteArray(text.encode()), "text/plain"))


svc.ChangeWithMasterPassword(
    dbus.ObjectPath(sys.argv[2]), secret(old), secret(new),
    dbus_interface="org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface")
