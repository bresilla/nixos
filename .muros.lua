local muros = require("muros")

muros.flake_dir = "packages"
muros.cache = {
    default = "packages",
    pin = true,
    pin_name = "{name}-{system}",
}

muros.recipe { name = "packages", attribute = "checks" }
