(() => {
  // The shared accent, kept as --brand: --accent is shadcn's hover surface here.
  const root = document.documentElement;
  const colour = BresillaUI.accent();
  root.style.removeProperty("--accent");
  root.style.setProperty("--brand", colour);
  const logo = @LOGO@;
  const tint = () => BresillaUI.icon(logo);
  if (document.readyState === "loading") addEventListener("DOMContentLoaded", tint);
  else tint();
  // The tab: the console never renames it, so the page's own heading names it, "page · s3".
  BresillaUI.title("s3", () => document.querySelector("main h1, .site-login-card h1")?.firstChild?.textContent || "", { page: true });
})();
