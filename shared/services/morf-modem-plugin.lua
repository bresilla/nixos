-- Retain the live ModemManager observer in existing Caelestia checkouts.
-- This hook runs only for the desktop service, before constructing its scene.
package.loaded.services = require("modem_repair.services")
package.loaded.settings_model = require("modem_repair.settings_model")
package.loaded.bar_model = require("modem_repair.bar_model")
