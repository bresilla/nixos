"""Apply the shared presentation to the pinned Radicle Explorer sources."""

import sys
from pathlib import Path


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected one occurrence of {old!r}")
    return text.replace(old, new, 1)


if sys.argv[1] == "header":
    template = Path(sys.argv[2]).read_text()
    header = Path("src/components/Header.svelte")
    source = header.read_text()
    scripts = source[:source.index("<style>")]
    for component in ("Logo", "Button", "Icon", "IconButton", "MobileNav"):
        directory = "marketing" if component == "MobileNav" else "components"
        scripts = replace_once(
            scripts, f'  import {component} from "@app/{directory}/{component}.svelte";\n', ""
        )
    scripts = replace_once(scripts, '  const isNodeHomepage = config.nodes.homepage === "node";\n', "")
    scripts = replace_once(scripts, '  const isLandingDeployment = config.nodes.homepage === "landing";\n', "")
    scripts = replace_once(
        scripts,
        '  $: hideLogo =\n    isNodeHomepage && $activeRouteStore.resource.startsWith("repo.");\n',
        "",
    )
    scripts = replace_once(scripts, '  import config from "@app/lib/config";\n', "")
    controls = source.split('    <div class="right-section">', 1)[1]
    controls = controls.split("    </div>\n  </div>\n</div>", 1)[0]
    onboarding_start = controls.index("      {#if isMarketingRoute}")
    onboarding_end = controls.index("      <Popover", onboarding_start)
    controls = controls[:onboarding_start] + controls[onboarding_end:]
    controls = replace_once(
        controls,
        """      <IconButton
          slot="toggle"
          let:toggle
          on:click={toggle}
          inline
          ariaLabel="Settings">
          <span class="header-settings"><Icon name="settings" /></span>
        </IconButton>""",
        """      <button slot="toggle" let:toggle on:click={toggle}
        type="button" class="site-settings" aria-label="Settings">settings</button>""",
    )
    controls = replace_once(
        controls, "      {#if isMarketingRoute}\n        <MobileNav />\n      {/if}\n", ""
    )
    header.write_text(scripts + replace_once(template, "@CONTROLS@", controls))

    appearance = Path("src/lib/appearance.ts")
    appearance.write_text(
        appearance.read_text()
        .replace('"JetBrains Mono, monospace"', '"var(--site-code-font)"')
        .replace('displayName: "JetBrains Mono"', 'displayName: "Site font"')
    )
    node_view = Path("src/views/nodes/View.svelte")
    source = node_view.read_text()
    footer = source.index('      <div class="footer">')
    footer_end = source.index("      </div>", footer) + len("      </div>")
    node_view.write_text(source[:footer] + source[footer_end:])

elif sys.argv[1] == "styles":
    # Vite adds component styles at the end of <head>. Load the adapter after them.
    index = Path("build/index.html")
    source = index.read_text()
    link = sys.argv[2]
    source = replace_once(source, link, "")
    index.write_text(replace_once(source, "</head>", link + "\n</head>"))
else:
    raise ValueError("Expected header or styles")
