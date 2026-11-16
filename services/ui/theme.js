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

  // Every tab reads "page · site". Apps rename their tab as they navigate, so each new
  // title is passed through clean (raw title in, page name or "" out) and written back.
  // With {page: true} the page itself is followed too, for apps whose tab never changes.
  function title(site, clean = (raw) => raw, {page: follow = false} = {}) {
    let own = "";
    let raw = document.title;
    const apply = () => {
      if (document.title !== own) raw = document.title;
      const page = String(clean(raw) || "").trim();
      const next = page && page !== site ? `${page} · ${site}` : site;
      if (next !== document.title) document.title = next;
      own = next;
    };
    apply();
    if (follow) {
      let queued = false;
      new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; apply(); }); } })
        .observe(document.documentElement, {childList: true, subtree: true});
    }
    const watch = () => {
      const node = document.querySelector("head > title");
      if (node) new MutationObserver(apply).observe(node, {childList: true, characterData: true, subtree: true});
    };
    if (document.querySelector("head > title")) watch();
    else new MutationObserver((_, observer) => { if (document.querySelector("head > title")) { observer.disconnect(); watch(); apply(); } })
      .observe(document.documentElement, {childList: true, subtree: true});
  }

  // Each single-choice <select> as a button and a menu like gitea's; the select stays,
  // hidden, holding the value that forms send. Only for pages whose markup is ours.
  function selects(root = document) {
    const chevron = '<svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden="true"><path d="M4.4 6.2 8 9.8l3.6-3.6"/></svg>';
    let open = null;
    const close = (focus) => {
      if (!open) return;
      const pick = open; open = null;
      pick.classList.remove("open");
      pick.querySelector(".pick-menu").hidden = true;
      pick.querySelector(".pick-button").setAttribute("aria-expanded", "false");
      if (focus) pick.querySelector(".pick-button").focus();
    };
    document.addEventListener("click", (event) => { if (open && !open.contains(event.target)) close(false); });
    for (const select of root.querySelectorAll("select:not([multiple]):not([data-native])")) {
      if (select.closest(".pick")) continue;
      const pick = document.createElement("div");
      pick.className = "pick " + select.className;
      const button = Object.assign(document.createElement("button"), {type: "button", className: "pick-button"});
      button.setAttribute("aria-haspopup", "listbox");
      button.setAttribute("aria-expanded", "false");
      const label = document.createElement("span");
      button.append(label);
      button.insertAdjacentHTML("beforeend", chevron);
      const menu = Object.assign(document.createElement("div"), {className: "pick-menu", hidden: true});
      menu.setAttribute("role", "listbox");
      const items = [...select.options].map((option) => {
        const item = Object.assign(document.createElement("div"), {className: "pick-item", tabIndex: -1, textContent: option.textContent});
        item.setAttribute("role", "option");
        if (option.disabled) item.setAttribute("aria-disabled", "true");
        item.addEventListener("click", () => choose(option));
        menu.append(item);
        return item;
      });
      const show = () => {
        label.textContent = select.selectedOptions[0]?.textContent ?? "";
        items.forEach((item, i) => item.setAttribute("aria-selected", String(i === select.selectedIndex)));
      };
      const choose = (option) => {
        if (option.disabled) return;
        select.value = option.value;
        select.dispatchEvent(new Event("change", {bubbles: true}));
        show();
        close(true);
      };
      const usable = () => items.filter((item) => item.getAttribute("aria-disabled") !== "true");
      const reveal = () => {
        if (open && open !== pick) close(false);
        open = pick;
        pick.classList.add("open");
        menu.hidden = false;
        button.setAttribute("aria-expanded", "true");
        (items[select.selectedIndex] || usable()[0])?.focus();
      };
      button.addEventListener("click", () => (open === pick ? close(true) : reveal()));
      button.addEventListener("keydown", (event) => {
        if (["ArrowDown", "ArrowUp", "Enter", " "].includes(event.key)) { event.preventDefault(); reveal(); }
      });
      menu.addEventListener("keydown", (event) => {
        const list = usable(), at = list.indexOf(document.activeElement);
        if (event.key === "ArrowDown") list[Math.min(at + 1, list.length - 1)]?.focus();
        else if (event.key === "ArrowUp") list[Math.max(at - 1, 0)]?.focus();
        else if (event.key === "Home") list[0]?.focus();
        else if (event.key === "End") list[list.length - 1]?.focus();
        else if (event.key === "Enter" || event.key === " ") choose(select.options[items.indexOf(document.activeElement)]);
        else if (event.key === "Escape") close(true);
        else if (event.key === "Tab") { close(false); return; }
        else return;
        event.preventDefault();
      });
      select.addEventListener("change", show);
      select.before(pick);
      pick.append(button, menu, select);
      select.hidden = true;
      select.tabIndex = -1;
      show();
    }
  }

  globalThis.BresillaUI = Object.freeze({accent, icon, header, title, selects});
})();
