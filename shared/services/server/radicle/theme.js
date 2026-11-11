BresillaUI.accent();
fetch("/bresilla/logo.svg")
  .then(response => {
    if (!response.ok) throw new Error("Could not load the site logo");
    return response.text();
  })
  .then(svg => BresillaUI.icon(svg, { blob: true }))
  .catch(() => {
    // Keep the static favicon if the tinted version is unavailable.
  });
