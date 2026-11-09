# The user's keyrings, run as their owner on their session bus.
#   patty-keyring list         the login and default keyrings: path, tab, label
#   patty-keyring change PATH  old and new password on stdin, one per line
#   patty-keyring reset PATH   erase it and make it anew; new password on stdin
import sys
import dbus

bus = dbus.SessionBus()
svc = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
SERVICE = "org.freedesktop.Secret.Service"
GUILTY = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"
LABEL = "org.freedesktop.Secret.Collection.Label"

if sys.argv[1] == "list":
    paths = ["/org/freedesktop/secrets/collection/login",
             str(svc.ReadAlias("default", dbus_interface=SERVICE))]
    for path in dict.fromkeys(p for p in paths if p != "/"):
        label = bus.get_object("org.freedesktop.secrets", path).Get(
            "org.freedesktop.Secret.Collection", "Label",
            dbus_interface="org.freedesktop.DBus.Properties")
        print(f"{path}\t{label}")
    sys.exit(0)

lines = sys.stdin.read().split("\n")
_, session = svc.OpenSession("plain", dbus.String("", variant_level=1),
                             dbus_interface=SERVICE)


def secret(text):
    return dbus.Struct((session, dbus.ByteArray(b""),
                        dbus.ByteArray(text.encode()), "text/plain"))


path = dbus.ObjectPath(sys.argv[2])
if sys.argv[1] == "change":
    svc.ChangeWithMasterPassword(path, secret(lines[0]), secret(lines[1]),
                                 dbus_interface=GUILTY)
    sys.exit(0)

# Reset: remember its label and whether it was the default, then remake it.
col = bus.get_object("org.freedesktop.secrets", path)
label = col.Get("org.freedesktop.Secret.Collection", "Label",
                dbus_interface="org.freedesktop.DBus.Properties")
was_default = str(svc.ReadAlias("default", dbus_interface=SERVICE)) == path
col.Delete(dbus_interface="org.freedesktop.Secret.Collection")
new = svc.CreateWithMasterPassword({LABEL: label}, secret(lines[0]),
                                   dbus_interface=GUILTY)
if was_default:
    svc.SetAlias("default", new, dbus_interface=SERVICE)
