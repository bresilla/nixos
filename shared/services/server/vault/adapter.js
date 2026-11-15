(() => {
  BresillaUI.accent();
  const logo = @LOGO@;
  const root = document.documentElement;

  // A colour as the "R G B" triplet the vault's older tokens take.
  const probe = document.createElement("i");
  probe.style.display = "none";
  const triplet = (colour) => {
    probe.style.color = colour;
    const value = getComputedStyle(probe).color;
    const n = (value.match(/[\d.]+/g) || []).map(Number);
    if (value.startsWith("color(")) return n.slice(0, 3).map((v) => Math.round(v * 255)).join(" ");
    return n.slice(0, 3).map(Math.round).join(" ");
  };

  // Those tokens per theme, from the same page, panel and accent as the rest.
  const legacy = {
    "--color-primary-100": "var(--hover)",
    "--color-primary-300": "color-mix(in srgb, var(--accent) 60%, var(--bg))",
    "--color-primary-600": "var(--accent)",
    "--color-primary-700": "color-mix(in srgb, var(--accent) 85%, black)",
    "--color-background": "var(--page)",
    "--color-background-alt": "var(--panel)",
    "--color-background-alt2": "var(--accent)",
    "--color-background-alt3": "var(--panel)",
    "--color-background-alt4": "var(--page)",
    "--color-secondary-100": "var(--panel)",
    "--color-secondary-300": "color-mix(in srgb, var(--accent) 35%, var(--bg))",
    "--color-secondary-600": "var(--mute)",
    "--color-secondary-700": "var(--fg)",
    "--color-text-main": "var(--fg)",
    "--color-text-contrast": "var(--on-accent)",
    "--color-text-muted": "var(--mute)",
    "--color-illustration-outline": "var(--accent)",
    "--color-illustration-bg-primary": "color-mix(in srgb, var(--accent) 20%, var(--bg))",
    "--color-illustration-bg-secondary": "color-mix(in srgb, var(--accent) 45%, var(--bg))",
    "--color-illustration-bg-tertiary": "var(--page)",
    "--color-illustration-tertiary": "var(--accent)",
    "--color-illustration-logo": "var(--accent)",
  };
  const paint = () => {
    for (const name of Object.keys(legacy)) root.style.removeProperty(name);
    for (const [name, colour] of Object.entries(legacy)) {
      const value = triplet(colour);
      if (value) root.style.setProperty(name, value);
    }
  };
  document.body.append(probe);
  paint();
  new MutationObserver(paint).observe(root, { attributes: true, attributeFilter: ["class"] });

  document.body.prepend(BresillaUI.header({ logo, name: "vault", home: "/", className: "site" }));
  BresillaUI.icon(logo);
  // The tab: the web vault's "Page | Vaultwarden Web" as "page · vault".
  BresillaUI.title("vault", (raw) => raw.split("|")[0].replace(/vaultwarden web|bitwarden/gi, "").trim()
    || document.querySelector("bit-landing-hero h1, main h1")?.textContent?.trim() || "", { page: true });
})();
