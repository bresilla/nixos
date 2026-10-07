{ config, lib, ... }:
let
  user = config.bresilla.user.name;
  directory = "/var/lib/morf/ui-scale/${user}";
in {
  options.bresilla.services.morf.uiScale = lib.mkOption {
    type = lib.types.addCheck lib.types.number (value: value >= 0.5 && value <= 2);
    default = 1.0;
    description = "Initial Morf scale shared by desktop, lock and greet. The user's scale slider persists its override.";
  };
  options.bresilla.services.morf.uiScaleFile = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "${directory}/scale.json";
    description = "Shared, user-writable UI scale preference readable by the greeter.";
  };
  config = lib.mkIf config.bresilla.features.desktop.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/morf 0755 root root -"
      "d /var/lib/morf/ui-scale 0755 root root -"
      "d ${directory} 0755 ${user} ${config.users.users.${user}.group} -"
    ];
  };
}
