
(() => {
  const sheet = document.createElement("link");
  sheet.rel = "stylesheet";
  sheet.href = "/pkg/override.css?v=@VERSION@";
  document.head.append(sheet);
  BresillaUI.accent();

  const logo = @LOGO@;
  const header = BresillaUI.header({logo, name: "id", home: "/ui/apps", className: "site"});
  const old = document.querySelector("nav.navbar");
  if (old) {
    for (const link of old.querySelectorAll(".navbar-nav:not(.ms-md-auto) a.nav-link")) {
      link.className = new URL(link.href, location).pathname === location.pathname ? "on" : "";
      link.querySelector("[data-feather]")?.remove();
      header.querySelector("nav").append(link);
    }
    for (const link of old.querySelectorAll(".navbar-nav.ms-md-auto a.nav-link")) {
      link.className = "item";
      header.querySelector(".who").append(link);
    }
    old.remove();
    fetch("/v1/self", { credentials: "same-origin" }).then((r) => r.ok ? r.json() : null).then((self) => {
      const name = self?.youare?.attrs?.name?.[0];
      if (!name) return;
      const who = document.createElement("span");
      who.className = "mute";
      who.textContent = name;
      header.querySelector(".who").prepend(who);
    });
  }
  document.body.prepend(header);

  const url = BresillaUI.icon(logo);
  const tint = () => {
    for (const img of document.querySelectorAll('img[src*="logo-square.svg"], img.oauth2-img')) {
      if (img.src !== url) img.src = url;
    }
  };
  tint();
  document.body.addEventListener("htmx:afterSettle", tint);
})();
