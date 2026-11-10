import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

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
            sys.modules.pop("backend", None)
            os.environ["CI_STYLE"] = str(new / "ui.css") if site == "build" else ""
            after = module("new_" + site, new / "ui.py")
            if site == "build":
                cls.ci = after
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
            sys.modules.pop("backend", None)
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
            def handlers(path, original=False):
                source = path.read_text()
                if original and directory == "ci/hive-ui":
                    source = source.replace("nixbot_state", "muros_state").replace("nixbot(", "service_api(").replace("nixbot", "Muros")
                if not original and directory == "ci/hive-ui":
                    source = source.replace('    if user:\n        actions += f\'<a class="btn ghost small" href="{base}/settings">Rules</a>\'\n', '')
                    source = source.replace('                if rest == ["settings"]:\n                    if not user:\n                        return self.need_admin()\n                    return self.reply(200, repo_rules.page(sys.modules[__name__], user, forge, owner, name, flash))\n', '')
                    source = source.replace('            if rest == ["settings"]:\n                service_api("PUT", repo_path(forge, owner, name) + "/settings", user, body=repo_rules.parse(form))\n                return self.redirect(back + "/settings", "rules saved; .muros.lua takes precedence when present")\n', '')
                    source = source.replace('actions = ((post_button(f"{base}/trigger", "Build now", "small") if r["enabled"] else "")\n                       + post_button(', 'actions = (post_button(')
                    source = source.replace('    actions = post_button(f"{base}/trigger", "Build now", "small") if user and page.get("enabled") else ""\n', '')
                    source = source.replace('{e(owner)}/{e(name)}</h1>{actions}</div>', '{e(owner)}/{e(name)}</h1></div>')
                    source = source.replace('            if rest == ["trigger"]:\n                result = service_api("POST", repo_path(forge, owner, name) + "/trigger", user)\n                action = "already active" if result["action"] == "active" else result["action"]\n                return self.redirect(f\'{back}/{result["number"]}\', f\'build #{result["number"]}: {action}\')\n', '')
                tree = ast.parse(source)
                return {node.name: ast.dump(node) for node in tree.body
                        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name not in ("layout", "logo")}
            self.assertEqual(handlers(REFERENCE / "shared/services/server" / directory / "ui.py", original=True),
                             handlers(ROOT / directory / "ui.py"))

    def test_manual_trigger_controls_and_dispatch(self):
        for enabled in (True, False):
            repo = {"forge": "pull_based", "owner": "team", "name": "project", "enabled": enabled,
                    "url": "https://example.test/team/project", "default_branch": "main", "private": False}
            def service(method, path, user=None):
                return [repo] if path == "/api/repos" else {"items": [], "enabled": enabled}
            with patch.object(self.ci, "service_api", service):
                for user in (None, "alice"):
                    for html in (self.ci.repos_page(user, ""), self.ci.repo_page(user, "pull_based", "team", "project", "")):
                        self.assertEqual('action="/-/repo/pull_based/team/project/trigger"' in html, bool(user and enabled))
        handler = object.__new__(self.ci.Handler)
        handler.redirect = lambda path, message: (path, message)
        with patch.object(self.ci, "service_api", return_value={"number": 17, "action": "queued"}) as service:
            result = handler.manage("/-/repo/pull_based/team/project/trigger", {}, "alice")
            service.assert_called_once_with("POST", "/api/repos/pull_based/team/project/trigger", "alice")
            self.assertEqual(result, ("/-/repo/pull_based/team/project/17", "build #17: queued"))

    def test_logo_and_header_have_one_source(self):
        self.assertEqual((site_ui.ROOT / "logo.svg").read_bytes(), (ROOT.parents[2] / "configs/assets/bresilla.svg").read_bytes())
        self.assertEqual((site_ui.ROOT / "logo-black.svg").read_bytes(), (REFERENCE / "shared/services/server/gitea/public/assets/img/logo.svg").read_bytes())
        self.assertFalse((ROOT / "ci/hive-ui/logo.svg").exists())
        self.assertFalse((ROOT / "gitea/public/assets/img/logo.svg").exists())
        for service in ("cache", "ci/hive-ui"):
            self.assertIn("site_ui.page(", (ROOT / service / "ui.py").read_text())
        self.assertIn("BresillaUI.header(", (ROOT / "id/hue.js").read_text())

    def test_repository_rule_fields_and_file_precedence(self):
        data = {"config": {"trigger": {"mode": "tag", "branches": ["main"], "tags": ["v*"]},
                           "cache": {"pin": True, "pin_name": "{name}-{system}"}},
                "source": ".muros.lua", "effective": {"trigger": {"mode": "manual"}},
                "default_branch": "main", "decision": "file policy"}
        with patch.object(self.ci, "service_api", return_value=data):
            html = self.ci.repo_rules.page(self.ci, "alice", "pull_based", "team", "project", "")
        self.assertIn("effective configuration: .muros.lua", html)
        self.assertIn("overrides these fallback settings", html)
        self.assertIn('value="tag" selected', html)
        self.assertIn('name=pin value=yes checked', html)
        parsed = self.ci.repo_rules.parse({"mode": "tag", "branches": "main\nrelease/*", "tags": "v*",
            "pin": "yes", "manual": "yes", "cache_rules": "morf*=packages"})
        self.assertEqual(parsed["trigger"]["branches"], ["main", "release/*"])
        self.assertEqual(parsed["cache"]["rules"], [["morf*", "packages"]])
        self.assertTrue(parsed["cache"]["pin"])


if __name__ == "__main__":
    unittest.main()
