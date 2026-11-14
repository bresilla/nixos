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
})();
