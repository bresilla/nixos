{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = [ pkgs.python3 pkgs.nodejs pkgs.gnumake ];
  SITE_PLAYWRIGHT = "${pkgs.playwright-driver}";
  PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers-chromium}";
  PYTHONDONTWRITEBYTECODE = "1";
}
