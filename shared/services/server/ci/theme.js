// A new hue only on a refresh; clicking around keeps the saved one, as on gitea.
(() => {
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
  document.documentElement.style.setProperty("--hue", hue);
  document.title = document.title.replace(/nixbot/g, "build");

  // The favicon is the logo, redrawn in the same colour.
  fetch("/_bresilla/logo.svg").then((r) => r.text()).then((svg) => {
    const tinted = svg.replace(/<style>.*?<\/style>/s, "").replaceAll("#1a1a1a", `hsl(${hue} 65% 50%)`);
    const url = URL.createObjectURL(new Blob([tinted], { type: "image/svg+xml" }));
    for (const link of document.querySelectorAll('link[rel~="icon"]')) link.href = url;
  });
})();
