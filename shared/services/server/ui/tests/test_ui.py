import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import unittest

import site_ui

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = Path(os.environ["SITE_REFERENCE"])
ARTIFACTS = ROOT / "ui/artifacts"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class SharedUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pages = []
        for site, directory in (("build", "ci/hive-ui"), ("cache", "cache")):
            old = REFERENCE / "shared/services/server" / directory
            new = ROOT / directory
            sys.path.insert(0, str(old))
            os.environ["CACHE_LOGO"] = str(REFERENCE / "configs/assets/bresilla.svg")
            os.environ["CI_LOGO"] = str(old / "logo.svg")
            os.environ["CI_STYLE"] = str(old / "ui.css") if site == "build" else ""
            before = module("old_" + site, old / "ui.py")
            sys.path[0] = str(new)
            os.environ["CI_STYLE"] = str(new / "ui.css") if site == "build" else ""
            after = module("new_" + site, new / "ui.py")
            for role in ("anonymous", "viewer", "admin"):
                for selected in (("repos", "builders", "settings") if site == "build" else ("caches", "settings")):
                    for app in (before, after):
                        app.VIEW.name = None if role == "anonymous" else "alice <&>"
                        app.VIEW.path = "/test?x=<value>&y=two"
                    body = '<div class=pagehead><h1>Example</h1></div><section class=set><h3>controls</h3><div><form class=row><input value="value"><button>Save</button><button class=ghost>Check</button></form><table><tr><th>name</th><th>status</th></tr><tr><td>example</td><td><span class="pill ok">succeeded</span></td></tr></table></div></section>'
                    a = before.layout("title <&>", body, role == "admin", "notice <&>", selected)
                    b = after.layout("title <&>", body, role == "admin", "notice <&>", selected)
                    cls.pages.append({"name": f"{site}-{role}-{selected}", "before": a, "after": b})
            assert before.logo() == after.logo()
            for name, svg in before.ICONS.items():
                assert after.ICONS[name] == svg
            sys.path.pop(0)
        ARTIFACTS.mkdir(exist_ok=True)
        (ARTIFACTS / "pages.json").write_text(json.dumps(cls.pages))

    def test_original_markup_and_account_controls(self):
        for page in self.pages:
            with self.subTest(page=page["name"]):
                a, b = (re.sub(r"<(script|style)>[\s\S]*?</\1>", "", page[key]) for key in ("before", "after"))
                self.assertEqual(a, b)

    def test_shared_code_escapes_text_and_keeps_trusted_body(self):
        page = site_ui.page(site='<img onerror="x">', title="<&>", body="<b>body</b>",
                            links=[("x", '/"<', "<&>")], active="x", name="<&>", here='/?next="<', flash="<&>")
        self.assertIn("&lt;img onerror=&quot;x&quot;&gt;", page)
        self.assertIn("<b>body</b>", page)
        self.assertNotIn('<img onerror="x">', page)

    def test_native_handlers_are_unchanged(self):
        for directory in ("ci/hive-ui", "cache"):
            def handlers(path):
                tree = ast.parse(path.read_text())
                return {node.name: ast.dump(node) for node in tree.body
                        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name not in ("layout", "logo")}
            self.assertEqual(handlers(REFERENCE / "shared/services/server" / directory / "ui.py"),
                             handlers(ROOT / directory / "ui.py"))

    def test_logo_and_header_have_one_source(self):
        self.assertEqual((site_ui.ROOT / "logo.svg").read_bytes(), (ROOT.parents[2] / "configs/assets/bresilla.svg").read_bytes())
        self.assertEqual((site_ui.ROOT / "logo-black.svg").read_bytes(), (REFERENCE / "shared/services/server/gitea/public/assets/img/logo.svg").read_bytes())
        self.assertFalse((ROOT / "ci/hive-ui/logo.svg").exists())
        self.assertFalse((ROOT / "gitea/public/assets/img/logo.svg").exists())
        for service in ("cache", "ci/hive-ui"):
            self.assertIn("site_ui.page(", (ROOT / service / "ui.py").read_text())
        self.assertIn("BresillaUI.header(", (ROOT / "id/hue.js").read_text())


if __name__ == "__main__":
    unittest.main()
