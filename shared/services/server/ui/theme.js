(() => {
  if (globalThis.BresillaUI) return;
  const tokens = @TOKENS@;
  const markup = @HEADER@;
  let colour;
  let iconURL;
  const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#x27;'}[c]));

  function accent() {
    if (colour) return colour;
    const reload = performance.getEntriesByType("navigation")[0]?.type === "reload";
    let hue = null;
    try {
      hue = reload ? null : localStorage.getItem("accent-hue");
      if (hue === null) {
        hue = String(Math.floor(Math.random() * 360));
        localStorage.setItem("accent-hue", hue);
      }
    } catch {
      hue = hue ?? String(Math.floor(Math.random() * 360));
    }
    colour = `hsl(${hue} ${tokens['accent-saturation']} ${tokens['accent-lightness']})`;
    document.documentElement.style.setProperty("--accent", colour);
    return colour;
  }

  function icon(svg, {append = false, blob = false} = {}) {
    const tinted = svg.replace(/<style>.*?<\/style>/s, "").replaceAll("currentColor", accent()).replaceAll("#1a1a1a", accent());
    const url = blob ? URL.createObjectURL(new Blob([tinted], {type: "image/svg+xml"}))
      : "data:image/svg+xml," + encodeURIComponent(tinted);
    const links = append ? [document.createElement("link")] : document.querySelectorAll('link[rel~="icon"]');
    for (const link of links) {
      if (append) { link.rel = "icon"; link.type = "image/svg+xml"; document.head.append(link); }
      link.href = url;
    }
    if (iconURL) URL.revokeObjectURL(iconURL);
    iconURL = blob ? url : null;
    return url;
  }

  function header({logo, name, home, className = ""}) {
    const values = {ATTRS: className ? ` class="${escape(className)}"` : "", LOGO: logo,
      HOME: escape(home), NAME: escape(name), NAV: "", ACCOUNT: ""};
    const fragment = document.createElement("template");
    fragment.innerHTML = markup.replace(/@(ATTRS|LOGO|HOME|NAME|NAV|ACCOUNT)@/g, (_, key) => values[key]);
    return fragment.content.firstElementChild;
  }

  globalThis.BresillaUI = Object.freeze({accent, icon, header});
})();
