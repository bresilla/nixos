{ lib, pkgs, ... }:

let
  # Rule files as on the Arch install, by file name. Tool paths that do not
  # exist on NixOS point at the store; /bin/sh is valid on NixOS.
  rules = {
    "00-teensy.rules" = ''
      # UDEV Rules for Teensy boards, http://www.pjrc.com/teensy/
      #
      # The latest version of this file may be found at:
      #   http://www.pjrc.com/teensy/00-teensy.rules
      #
      # This file must be placed at:
      #
      # /etc/udev/rules.d/00-teensy.rules    (preferred location)
      #   or
      # /lib/udev/rules.d/00-teensy.rules    (req'd on some broken systems)
      #
      # To install, type this command in a terminal:
      #   sudo cp 00-teensy.rules /etc/udev/rules.d/00-teensy.rules
      #
      # After this file is installed, physically unplug and reconnect Teensy.
      #
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789a]*", ENV{MTP_NO_PROBE}="1"
      KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666", RUN:="/bin/stty -F /dev/%k raw -echo"
      KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04*", MODE:="0666"
      KERNEL=="hidraw*", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="013*", MODE:="0666"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="1fc9", ATTRS{idProduct}=="013*", MODE:="0666"

      #
      # If you share your linux system with other users, or just don't like the
      # idea of write permission for everybody, you can replace MODE:="0666" with
      # OWNER:="yourusername" to create the device owned by you, or with
      # GROUP:="somegroupname" and mange access using standard unix groups.
      #
      # ModemManager tends to interfere with USB Serial devices like Teensy.
      # Problems manifest as the Arduino Serial Monitor missing some incoming
      # data, and "Unable to open /dev/ttyACM0 for reboot request" when
      # uploading.  If you experience these problems, disable or remove
      # ModemManager from your system.  If you must use a modem, perhaps
      # try disabling the "MM_FILTER_RULE_TTY_ACM_INTERFACE" ModemManager
      # rule.  Changing ModemManager's filter policy from "strict" to "default"
      # may also help.  But if you don't use a modem, completely removing
      # the troublesome ModemManager is the most effective solution.
    '';
    "02-backlight.rules" = ''
      ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video $sys$devpath/brightness", RUN+="/bin/chmod g+w $sys$devpath/brightness"
    '';
    "05-network-names.rules" = ''
      SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="3c:e1:a1:b7:86:8f", NAME="wire0"
      SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="00:e0:4c:68:08:03", NAME="wire1"
    '';
    "10-ubports.rules" = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="03f0", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="03fc", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0408", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0409", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0414", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0451", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0471", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0482", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0489", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="04b7", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="04c5", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="04da", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="04dd", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0502", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0531", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="054c", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="067e", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="091e", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0930", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0955", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0b05", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0bb4", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0c2e", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0db0", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0e79", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0e8d", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0f1c", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0fce", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1004", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="109b", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="10a9", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1219", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1662", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="16d5", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="17ef", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1949", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="19a5", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="19d2", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1bbb", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d09", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d45", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d4d", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d91", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1e85", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1ebf", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1f53", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2006", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="201e", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2080", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2116", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2237", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2257", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="22d9", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2314", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2340", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2420", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="24e3", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="25e3", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="271d", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2836", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2916", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="297f", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="29a9", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="29e4", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2a45", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2a47", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2a49", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2a70", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="2ae5", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="413c", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="8087", MODE="0666"
      SUBSYSTEM=="usb", ATTR{idVendor}=="e040", MODE="0666"
    '';
    "50-uinput.rules" = ''
      KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
    '';
    "51-openterface.rules" = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="534d", ATTRS{idProduct}=="2109", TAG+="uaccess"
    '';
    "52-uinput.rules" = ''
      KERNEL=="event*", NAME="input/%k", MODE="660", GROUP="input"
    '';
    "60-weylus.rules" = ''
      KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
    '';
    "70-dualsensectl.rules" = ''
      # PS5 DualSense controller over USB hidraw
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"

      # PS5 DualSense controller over bluetooth hidraw
      KERNEL=="hidraw*", KERNELS=="*054C:0CE6*", MODE="0660", TAG+="uaccess"

      # PS5 DualSense Edge controller over USB hidraw
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"

      # PS5 DualSense Edge controller over bluetooth hidraw
      KERNEL=="hidraw*", KERNELS=="*054C:0DF2*", MODE="0660", TAG+="uaccess"
    '';
    "70-wifi-powersave.rules" = ''
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
    '';
    "80-nvidia-pm.rules" = ''
      # Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind
      ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
      ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"

      # Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind
      ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
    '';
    "90-wluma-backlight.rules" = ''
      ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
      ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
      ACTION=="add", SUBSYSTEM=="leds", RUN+="/bin/chgrp video /sys/class/leds/%k/brightness"
      ACTION=="add", SUBSYSTEM=="leds", RUN+="/bin/chmod g+w /sys/class/leds/%k/brightness"
    '';
    "97-logitech-controller.rules" = ''
      SUBSYSTEM=="input", \
      ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c21f", \
      KERNEL=="event*", \
      MODE="0666", \
      SYMLINK+="input/event-logi"
    '';
    "98-ps4-controller.rules" = ''
      KERNEL=="event*" , SUBSYSTEM=="input", MODE="0666"
      KERNEL=="event*", ATTRS{name}=="Wireless Controller", SYMLINK+="input/event-ps4"
      KERNEL=="event*", ATTRS{name}=="Wireless Controller Motion Sensors", SYMLINK+="input/event-ps4-ms"
      KERNEL=="event*", ATTRS{name}=="Wireless Controller Touchpad", SYMLINK+="input/event-ps4-tp"
    '';
    "98-ps5-controller.rules" = ''
        KERNEL=="event*", SUBSYSTEM=="input", MODE="0666"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller", SYMLINK+="input/event-ps5"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Motion Sensors", SYMLINK+="input/event-ps5-ms"
        KERNEL=="event*", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", SYMLINK+="input/event-ps5-tp"
    '';
    "99-mcp2221.rules" = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="04d8", ATTR{idProduct}=="00dd", MODE="0666"
    '';
    "99-openterface.rules" = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="1a40", ATTR{idProduct}=="0101", SYMLINK+="openterface"

      KERNEL== "hidraw*", SUBSYSTEM=="hidraw", MODE="0666"
    '';
    "99-platformio-udev.rules" = ''
      # Copyright (c) 2014-present PlatformIO <contact@platformio.org>
      #
      # Licensed under the Apache License, Version 2.0 (the "License");
      # you may not use this file except in compliance with the License.
      # You may obtain a copy of the License at
      #
      #    http://www.apache.org/licenses/LICENSE-2.0
      #
      # Unless required by applicable law or agreed to in writing, software
      # distributed under the License is distributed on an "AS IS" BASIS,
      # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
      # See the License for the specific language governing permissions and
      # limitations under the License.

      #####################################################################################
      #
      # INSTALLATION
      #
      # Please visit > https://docs.platformio.org/en/latest/core/installation/udev-rules.html
      #
      #####################################################################################

      #
      # Boards
      #

      # CP210X USB UART
      ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea[67][013]", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="80a9", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # FT231XS USB UART
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Prolific Technology, Inc. PL2303 Serial Port
      ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # QinHeng Electronics HL-340 USB-Serial adapter
      ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      # QinHeng Electronics CH343 USB-Serial adapter
      ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d3", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      # QinHeng Electronics CH9102 USB-Serial adapter
      ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Arduino boards
      ATTRS{idVendor}=="2341", ATTRS{idProduct}=="[08][023]*", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      ATTRS{idVendor}=="2a03", ATTRS{idProduct}=="[08][02]*", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Arduino SAM-BA
      ATTRS{idVendor}=="03eb", ATTRS{idProduct}=="6124", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{MTP_NO_PROBE}="1"

      # Digistump boards
      ATTRS{idVendor}=="16d0", ATTRS{idProduct}=="0753", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Maple with DFU
      ATTRS{idVendor}=="1eaf", ATTRS{idProduct}=="000[34]", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # USBtiny
      ATTRS{idProduct}=="0c9f", ATTRS{idVendor}=="1781", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # USBasp V2.0
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="05dc", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Teensy boards
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
      KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", MODE:="0666"

      # TI Stellaris Launchpad
      ATTRS{idVendor}=="1cbe", ATTRS{idProduct}=="00fd", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # TI MSP430 Launchpad
      ATTRS{idVendor}=="0451", ATTRS{idProduct}=="f432", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # GD32V DFU Bootloader
      ATTRS{idVendor}=="28e9", ATTRS{idProduct}=="0189", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # FireBeetle-ESP32
      ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7522", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Wio Terminal
      ATTRS{idVendor}=="2886", ATTRS{idProduct}=="[08]02d", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Raspberry Pi Pico
      ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="[01]*", MODE:="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # AIR32F103
      ATTRS{idVendor}=="0d28", ATTRS{idProduct}=="0204", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # STM32 virtual COM port
      ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      #
      # Debuggers
      #

      # Black Magic Probe
      SUBSYSTEM=="tty", ATTRS{interface}=="Black Magic GDB Server", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
      SUBSYSTEM=="tty", ATTRS{interface}=="Black Magic UART Port", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # opendous and estick
      ATTRS{idVendor}=="03eb", ATTRS{idProduct}=="204f", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Original FT232/FT245/FT2232/FT232H/FT4232
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="60[01][104]", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # DISTORTEC JTAG-lock-pick Tiny 2
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="8220", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # TUMPA, TUMPA Lite
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="8a9[89]", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # XDS100v2
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="a6d0", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Xverve Signalyzer Tool (DT-USB-ST), Signalyzer LITE (DT-USB-SLITE)
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="bca[01]", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # TI/Luminary Stellaris Evaluation Board FTDI (several)
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="bcd[9a]", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # egnite Turtelizer 2
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="bdc8", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Section5 ICEbear
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="c14[01]", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Amontec JTAGkey and JTAGkey-tiny
      ATTRS{idVendor}=="0403", ATTRS{idProduct}=="cff8", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # TI ICDI
      ATTRS{idVendor}=="0451", ATTRS{idProduct}=="c32a", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # STLink probes
      ATTRS{idVendor}=="0483", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Hilscher NXHX Boards
      ATTRS{idVendor}=="0640", ATTRS{idProduct}=="0028", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Hitex probes
      ATTRS{idVendor}=="0640", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Altera USB Blaster
      ATTRS{idVendor}=="09fb", ATTRS{idProduct}=="6001", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Amontec JTAGkey-HiSpeed
      ATTRS{idVendor}=="0fbb", ATTRS{idProduct}=="1000", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # SEGGER J-Link
      ATTRS{idVendor}=="1366", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Raisonance RLink
      ATTRS{idVendor}=="138e", ATTRS{idProduct}=="9000", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Debug Board for Neo1973
      ATTRS{idVendor}=="1457", ATTRS{idProduct}=="5118", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Olimex probes
      ATTRS{idVendor}=="15ba", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # USBprog with OpenOCD firmware
      ATTRS{idVendor}=="1781", ATTRS{idProduct}=="0c63", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # TI/Luminary Stellaris In-Circuit Debug Interface (ICDI) Board
      ATTRS{idVendor}=="1cbe", ATTRS{idProduct}=="00fd", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Marvell Sheevaplug
      ATTRS{idVendor}=="9e88", ATTRS{idProduct}=="9e8f", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Keil Software, Inc. ULink
      ATTRS{idVendor}=="c251", ATTRS{idProduct}=="2710", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # CMSIS-DAP compatible adapters
      ATTRS{product}=="*CMSIS-DAP*", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Atmel AVR Dragon
      ATTRS{idVendor}=="03eb", ATTRS{idProduct}=="2107", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Espressif USB JTAG/serial debug unit
      ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"

      # Zephyr framework USB CDC-ACM
      ATTRS{idVendor}=="2fe3", ATTRS{idProduct}=="0100", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
    '';
    "99-realsense-libusb.rules" = ''
      ##Version=1.1##
      # Device rules for Intel RealSense devices (R200, F200, SR300 LR200, ZR300, D400, L500, T200)
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0a66", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aa3", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aa2", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aa5", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0abf", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0acb", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad0", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="04b4", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad1", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad2", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad3", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad4", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad5", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad6", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0af2", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0af6", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0afe", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aff", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b00", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b01", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b03", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b07", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b0c", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b0d", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3a", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3d", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b48", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b49", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4b", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4d", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b52", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5b", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b64", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b68", MODE:="0666", GROUP:="plugdev"

      # Intel RealSense recovery devices (DFU)
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ab3", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0adb", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0adc", MODE:="0666", GROUP:="plugdev"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b55", MODE:="0666", GROUP:="plugdev"

      # Intel RealSense devices (Movidius, T265)
      SUBSYSTEMS=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="8087", ATTRS{idProduct}=="0af3", MODE="0666", GROUP="plugdev"
      SUBSYSTEMS=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="8087", ATTRS{idProduct}=="0b37", MODE="0666", GROUP="plugdev"
      SUBSYSTEMS=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="03e7", ATTRS{idProduct}=="2150", MODE="0666", GROUP="plugdev"

      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad5", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor_custom", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0ad5", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0af2", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0af2", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0afe", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor_custom", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0afe", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aff", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor_custom", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0aff", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b00", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor_custom", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b00", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b01", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor_custom", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b01", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3a", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3a", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3d", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3d", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4b", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4b", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4d", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b4d", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5b", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5b", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b5c", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b64", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b64", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"
      KERNEL=="iio*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b68", MODE:="0777", GROUP:="plugdev", RUN+="/bin/sh -c 'chmod -R 0777 /sys/%p'"
      DRIVER=="hid_sensor*", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b68", RUN+="/bin/sh -c ' chmod -R 0777 /sys/%p && chmod 0777 /dev/%k'"

      # For products with motion_module, if (kernels is 4.15 and up) and (device name is "accel_3d") wait, in another process, until (enable flag is set to 1 or 200 mSec passed) and then set it to 0.
    '';
    "61-intel-igpu.rules" = ''
      SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="0000:00:02.0", SYMLINK+="dri/intel-igpu"
    '';
    "99-xbox-controller.rules" = ''
      #SUBSYSTEM=="input", ATTRS{name}=="Xbox Wireless Controller", ATTRS{uniq}=="A8:8C:3E:24:5C:3F", SYMLINK+="input/event27"
      KERNEL=="event*" , SUBSYSTEM=="input", MODE="0666"
      KERNEL=="event*", ATTRS{name}=="Xbox Wireless Controller", SYMLINK+="input/event-xbox"
    '';
  };
  patch = builtins.replaceStrings
    [ "/usr/sbin/iw" "/bin/chgrp" "/bin/chmod" "/bin/stty" ]
    [ "${pkgs.iw}/bin/iw" "${pkgs.coreutils}/bin/chgrp" "${pkgs.coreutils}/bin/chmod" "${pkgs.coreutils}/bin/stty" ];
in
{
  services.udev.packages = lib.mapAttrsToList
    (name: text: pkgs.writeTextDir "lib/udev/rules.d/${name}" (patch text))
    rules
  ++ (with pkgs; [
    dfu-util
    openocd
    probe-rs-tools
    stlink
    usb-blaster-udev-rules
    zsa-udev-rules
  ]);
}
