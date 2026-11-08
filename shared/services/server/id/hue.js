
// As on git, cache and build: a new hue on a refresh, the saved one while clicking
// around, and the favicon drawn from the header logo in that colour.
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
  document.documentElement.style.setProperty("--accent", `hsl(${hue} 65% 50%)`);
  fetch("/pkg/img/logo-square.svg").then((r) => r.text()).then((svg) => {
    const tinted = svg.replace(/fill="#[0-9a-fA-F]+"/g, `fill="hsl(${hue} 65% 50%)"`);
    const url = URL.createObjectURL(new Blob([tinted], { type: "image/svg+xml" }));
    for (const link of document.querySelectorAll('link[rel~="icon"]')) link.href = url;
  });
})();
