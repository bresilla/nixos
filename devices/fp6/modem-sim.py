"""Initialize an unselected Qualcomm USIM session, leaving active SIMs alone."""

import re
import subprocess
import sys
import time


def select_application(status):
    if not re.search(r"Primary GW:\s+session doesn't exist", status):
        return None
    cards = re.split(r"Card \[(\d+)\]:", status)
    for number, card in zip(cards[1::2], cards[2::2]):
        if "Card state: 'present'" not in card:
            continue
        for app in re.split(r"Application \[\d+\]:", card)[1:]:
            if not re.search(r"Application type:\s+'usim \(2\)'", app):
                continue
            aid = re.search(r"Application ID:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})+)", app)
            if aid:
                return int(number), aid[1]
    return None


def initialize(qmicli):
    def query(option):
        return subprocess.run([qmicli, "--device=qrtr://0", option],
                              capture_output=True, text=True, timeout=8)

    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            result = query("--uim-get-card-status")
        except subprocess.TimeoutExpired:
            continue
        if result.returncode == 0:
            selected = select_application(result.stdout)
            if selected:
                slot, aid = selected
                result = query("--uim-change-provisioning-session="
                               f"slot={slot},activate=yes,session-type=primary-gw-provisioning,aid={aid}")
                if result.returncode:
                    raise RuntimeError("Could not initialize the SIM application")
                print(f"Initialized the SIM application in slot {slot}")
                return
            if "Primary GW:   session doesn't exist" not in result.stdout:
                print("SIM session already selected")
                return
        time.sleep(1)
    # An empty SIM slot must not prevent ModemManager from exposing the modem.
    print("No selectable SIM application; continuing modem discovery")


if __name__ == "__main__":
    initialize(sys.argv[1])
