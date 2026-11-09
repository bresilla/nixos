# The user's keyrings, run as their owner on their session bus.
#   patty-keyring list         the login and default keyrings: path, tab, label
#   patty-keyring change PATH  old and new password on stdin, one per line
#   patty-keyring unlock       open both with the password on stdin, once the
#                              keyring daemon of a new login is up
import sys
import time
import dbus

NAME = "org.freedesktop.secrets"
SERVICE = "org.freedesktop.Secret.Service"
COLLECTION = "org.freedesktop.Secret.Collection"
PROPS = "org.freedesktop.DBus.Properties"
GUILTY = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"

bus = dbus.SessionBus()
# Wait for the login's own daemon instead of starting a second one.
if sys.argv[1] == "unlock":
    for _ in range(60):
        if bus.name_has_owner(NAME):
            break
        time.sleep(0.5)
    else:
        sys.exit(1)
svc = bus.get_object(NAME, "/org/freedesktop/secrets")


def keyrings():
    login = "/org/freedesktop/secrets/collection/login"
    # No default keyring: apps would make a new one with its own password.
    if str(svc.ReadAlias("default", dbus_interface=SERVICE)) == "/":
        svc.SetAlias("default", dbus.ObjectPath(login),
                     dbus_interface=SERVICE)
    paths = [login, str(svc.ReadAlias("default", dbus_interface=SERVICE))]
    return [p for p in dict.fromkeys(paths) if p != "/"]


if sys.argv[1] == "list":
    for path in keyrings():
        label = bus.get_object(NAME, path).Get(COLLECTION, "Label",
                                               dbus_interface=PROPS)
        print(f"{path}\t{label}")
    sys.exit(0)

lines = sys.stdin.read().split("\n")
_, session = svc.OpenSession("plain", dbus.String("", variant_level=1),
                             dbus_interface=SERVICE)


def secret(text):
    return dbus.Struct((session, dbus.ByteArray(b""),
                        dbus.ByteArray(text.encode()), "text/plain"))


if sys.argv[1] == "unlock":
    failed = False
    for path in keyrings():
        try:
            svc.UnlockWithMasterPassword(dbus.ObjectPath(path),
                                         secret(lines[0]),
                                         dbus_interface=GUILTY)
        except dbus.DBusException:
            failed = True
    sys.exit(1 if failed else 0)

path = dbus.ObjectPath(sys.argv[2])
if sys.argv[1] == "change":
    svc.ChangeWithMasterPassword(path, secret(lines[0]), secret(lines[1]),
                                 dbus_interface=GUILTY)
    sys.exit(0)
