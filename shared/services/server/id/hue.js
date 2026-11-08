
// As on git, cache and build: a new hue on a refresh, the saved one while clicking
// around, the same header, and the favicon drawn from its logo in that colour.
(() => {
  // The theme by its own version, so a cached copy of an older one never wins.
  const sheet = document.createElement("link");
  sheet.rel = "stylesheet";
  sheet.href = "/pkg/override.css?v=@VERSION@";
  document.head.append(sheet);
  let hue = null;
  try {
    const reload = performance.getEntriesByType("navigation")[0]?.type === "reload";
    hue = reload ? null : localStorage.getItem("accent-hue");
    if (hue === null) {
      hue = String(Math.floor(Math.random() * 360));
      localStorage.setItem("accent-hue", hue);
    }
  } catch {
    hue = hue ?? String(Math.floor(Math.random() * 360));
  }
  const accent = `hsl(${hue} 65% 50%)`;
  document.documentElement.style.setProperty("--accent", accent);

  // The other sites' header: logo, site name, the pages, and sign-out on the right.
  // Kanidm's own navbar gives up its links to it.
  const logo = @LOGO@;
  const header = document.createElement("header");
  header.className = "site";
  header.innerHTML = `${logo}<a href="/ui/apps">id</a><nav></nav><div class="who"></div>`;
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
  }
  document.body.prepend(header);

  // A data: URL, the one kind of generated image Kanidm's policy allows.
  const url = "data:image/svg+xml," + encodeURIComponent(logo.replaceAll("currentColor", accent));
  for (const link of document.querySelectorAll('link[rel~="icon"]')) link.href = url;
  // The big logo on the sign-in pages in the same colour.
  for (const img of document.querySelectorAll('img[src*="logo-square.svg"]')) img.src = url;
})();
