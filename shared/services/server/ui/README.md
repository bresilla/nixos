# Shared site presentation

Build, cache, Gitea, Kanidm and RustFS consume this Nix package. It does not replace their
backends, authentication, navigation, permissions or page-specific controls.

## Sources

- `tokens.json`: fonts, palette, accent and header dimensions.
- `configs/assets/bresilla.svg` at the repository root: the single brand mark.
  The package derives Gitea's black variant from it.
- `header.html` and `header.css`: the build/cache/identity header shell.
- `theme.js`: accent persistence/reload behavior and tinted favicon generation.
- `site_ui.py`, `base.css`, `icons.json`: the shared build/cache presentation.

Build/cache import `site_ui` through their service `PYTHONPATH`. Their handlers
still supply the page content, navigation and authenticated account name.
Kanidm keeps its native UI; `id/hue.js` moves its original account/navigation
links into the shared header. Gitea keeps its native navbar, dropdowns and Go
templates; `gitea/theme.css` maps shared tokens to its native selectors. Its
custom template retains the native CSP nonce. Gitea's customization mechanism
is documented at <https://docs.gitea.com/administration/customizing-gitea/>.
RustFS's console is rebuilt (`s3/console.nix`): its `themes/<id>` hook takes the
header components, `s3/console.patch` puts the header over its pages, and
`s3/theme/console.css` maps shared tokens to its shadcn variables.

Native body styles and layout differences remain in the service adapters.
This package adds no Node service or frontend framework.
Substitute adapter placeholders before concatenating scripts: the shared header
contains its own runtime `@LOGO@` placeholder, which must remain intact.

## Verification

Run from this directory:

```sh
make check
make capture
make hive-build
make hive-assets
make public-check
make hive-template-check
make live-check
```

`check` compares the Python page shells against the pinned pre-extraction Git
revision, including anonymous/viewer/admin controls, SVG icons, escaping,
light/dark schemes, desktop/narrow widths, hover/focus and favicon behavior.
Node/Playwright run only inside the development test shell.

`capture` records the **currently deployed** anonymous pages and their resource
responses. Run it before deploying changes; retain its artifacts for comparison.
`hive-assets` copies the built identity/Gitea assets and syntax-checks the final
identity JavaScript. `public-check` replays native pages and CSP headers with
those exact generated assets and the Python candidate page shell,
then compares exact full-page pixels in normal/hover states. Gitea's expanded
mobile navigation and Kanidm's checkbox are compared at the visible viewport;
the expanded Gitea page also has identical computed styles and element bounds.
This is not a live deployment check or a completed human SSO roundtrip.
Never capture live cache-admin settings: they contain a token.
Artifacts are ignored by Git and excluded from the Nix package.

`hive-template-check` runs the candidate template through Hive's actual Gitea
binary with a disposable loopback-only database. `live-check` runs after
activation: it compares deployed headers with the retained originals, follows
native sign-in redirects and checks rejection of spoofed admin headers. It does
not submit credentials or complete human SSO.

`make hive-build` synchronizes only these service sources into an already prepared
Hive candidate with its existing pinned lock file, then builds the host closure.
It does not activate or restart services. `HIVE` and `HIVE_ROOT` are overridable.
Activation, rollback, persistence and post-deployment verification are separate.
