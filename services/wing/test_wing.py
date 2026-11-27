"""wing.py against a scratch database: storage, the pages, the forms and the CLI's API.

git and build are pointed at a closed port, so nothing here leaves the machine.
"""

import base64
import contextlib
import http.client
import io
import json
import os
import sqlite3
import sys
import tarfile
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

SCRATCH = tempfile.mkdtemp(prefix="wing-test-")
os.environ.update(WING_DATABASE=os.path.join(SCRATCH, "wing.db"), WING_GITEA="http://127.0.0.1:9",
                  WING_MUROS="http://127.0.0.1:9", WING_DOMAIN="wing.test")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wing  # noqa: E402

wing.initialize()
SERVER = ThreadingHTTPServer(("127.0.0.1", 0), wing.Handler)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
PORT = SERVER.server_address[1]


def call(method, path, body=None, headers=None, form=None):
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    headers = dict(headers or {})
    if form is not None:
        from urllib.parse import urlencode
        body = urlencode(form, doseq=True)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif isinstance(body, (dict, list)):
        body = json.dumps(body)
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data, dict(response.getheaders())


def token():
    return {"Authorization": "Bearer " + wing.make_token("test")}


class Storage(unittest.TestCase):
    def test_quick_text(self):
        self.assertEqual(wing.quick_text("fix it +v1 !high"), {"title": "fix it", "plan": "v1", "priority": 2})
        self.assertEqual(wing.quick_text("later !low")["priority"], 0)

    def test_numbers_are_per_project_and_go_with_it(self):
        wing.save_project({"name": "alpha"})
        wing.save_project({"name": "beta"})
        a1 = wing.save_task("alpha", {"title": "one"})
        a2 = wing.save_task("alpha", {"title": "two"})
        b1 = wing.save_task("beta", {"title": "uno"})
        self.assertEqual((a1["number"], a2["number"], b1["number"]), (1, 2, 1))
        wing.delete_project("beta")
        self.assertEqual([t["project_name"] for t in wing.tasks()].count("beta"), 0)

    def test_plan_by_number_or_title(self):
        wing.save_project({"name": "gamma"})
        plan = wing.save_plan("gamma", {"title": "release"})
        task = wing.save_task("gamma", wing.quick_text("ship +release"))
        self.assertEqual(task["plan_number"], plan["number"])
        task = wing.save_task("gamma", {"plan": str(plan["number"])}, task["number"])
        self.assertEqual(wing.plan("gamma", plan["number"])["total"], 1)
        with self.assertRaises(ValueError):
            wing.save_task("gamma", {"title": "x", "plan": "nope"})

    def test_done_keeps_its_time(self):
        wing.save_project({"name": "delta"})
        t = wing.save_task("delta", {"title": "x", "state": "done"})
        again = wing.save_task("delta", {"notes": "later"}, t["number"])
        self.assertEqual(again["done_at"], t["done_at"])
        self.assertEqual(wing.save_task("delta", {"state": "todo"}, t["number"])["done_at"], "")

    def test_checkouts_are_merged_per_machine(self):
        wing.save_project({"name": "eps", "checkout": {"machine": "core", "path": "/a"}})
        p = wing.save_project({"name": "eps", "checkout": {"machine": "tron", "path": "/b"}})
        self.assertEqual(sorted(p["checkouts"]), ["core", "tron"])
        self.assertEqual(wing.save_project({"name": "eps", "description": "d"})["checkouts"]["core"]["path"], "/a")

    def test_template_files(self):
        wing.create_template("tpl", "a test")
        self.assertIsNotNone(wing.template_file("tpl", "template.lua"))
        wing.save_template_file("tpl", "base/a.txt", b"hello")
        wing.save_template_file("tpl", "base/a.txt", b"hello", rename="base/b.txt")
        self.assertIsNone(wing.template_file("tpl", "base/a.txt"))
        for bad in ("../x", "/", "a/../../b"):
            with self.assertRaises(ValueError):
                wing.save_template_file("tpl", bad, b"")
        wing.delete_template_file("tpl", "base")
        self.assertEqual([f["path"] for f in wing.template_files("tpl")], ["template.lua"])

    def test_push_is_checked_before_anything_is_made(self):
        with self.assertRaises(ValueError):
            wing.replace_template("bad", [{"path": "../evil", "data": ""}])
        self.assertIsNone(wing.template_row("bad"))

    def test_hash_follows_content(self):
        files = [{"path": "a", "data": base64.b64encode(b"1").decode()}]
        first = wing.replace_template("h", files)["hash"]
        self.assertEqual(first, wing.replace_template("h", files)["hash"])
        files[0]["data"] = base64.b64encode(b"2").decode()
        self.assertNotEqual(first, wing.replace_template("h", files)["hash"])

    def test_description_comes_from_template_lua(self):
        lua = b'wing.template("d", { description = "from lua" })'
        wing.replace_template("desc", [{"path": "template.lua", "data": base64.b64encode(lua).decode()}])
        self.assertEqual(wing.template_row("desc")["description"], "from lua")

    def test_old_database_gains_checkouts(self):
        path = os.path.join(SCRATCH, "old.db")
        with contextlib.closing(sqlite3.connect(path)) as c, c:
            c.execute("CREATE TABLE projects (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, namespace TEXT NOT NULL DEFAULT '',"
                      " description TEXT NOT NULL DEFAULT '', language TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]',"
                      " remotes TEXT NOT NULL DEFAULT '[]', created TEXT NOT NULL, updated TEXT NOT NULL)")
        saved, wing.DATABASE = wing.DATABASE, path
        try:
            wing.initialize()
            self.assertEqual(wing.save_project({"name": "old"})["checkouts"], {})
        finally:
            wing.DATABASE = saved


class Web(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wing.save_project({"name": "web", "remotes": [{"name": "origin", "url": "https://example.com/x/web.git"}]})
        wing.save_task("web", {"title": "a task", "due": "2000-01-01"})
        wing.save_plan("web", {"title": "a plan"})
        wing.create_template("webtpl")
        wing.save_template_file("webtpl", "bin.dat", b"\0\1\2")

    def test_every_page_draws(self):
        for path in ["/", "/?q=web", "/new", "/import", "/tasks", "/tasks?show=done", "/tasks?project=web", "/settings",
                     "/p/web", "/p/web?show=done", "/p/web?v=builds", "/p/web?v=git", "/p/web?v=edit", "/p/web/plans",
                     "/p/web/plans/1", "/p/web/plans/1?v=edit", "/p/web/t/1", "/templates", "/templates/new",
                     "/templates/webtpl", "/templates/webtpl?v=settings", "/templates/webtpl/f/template.lua",
                     "/templates/webtpl/f/bin.dat"]:
            status, body, _ = call("GET", path)
            self.assertEqual(status, 200, path)
            self.assertIn(b"<main>", body, path)
        self.assertEqual(call("GET", "/p/nope")[0], 404)

    def test_overdue_is_flagged(self):
        self.assertIn(b"overdue", call("GET", "/p/web")[1])

    def test_forms(self):
        status, _, head = call("POST", "/p/web/tasks", form={"quick": "from the form !high"})
        self.assertEqual(status, 303)
        self.assertTrue(any(t["title"] == "from the form" and t["priority"] == 2 for t in wing.tasks("web")))
        self.assertEqual(call("POST", "/p/web/tasks", form={"quick": "x"}, headers={"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(call("POST", "/tasks", form={"quick": "no project"})[0], 400)

    def test_upload_and_archive(self):
        boundary = "XyZ"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"dir\"\r\n\r\nbase\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"up.txt\"\r\n"
                f"Content-Type: text/plain\r\n\r\nuploaded\r\n--{boundary}--\r\n").encode()
        status, _, _ = call("POST", "/templates/webtpl/upload", body=body,
                            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        self.assertEqual(status, 303)
        self.assertEqual(wing.template_file("webtpl", "base/up.txt")["data"], b"uploaded")
        status, data, _ = call("GET", "/templates/webtpl.tar.gz")
        self.assertEqual(status, 200)
        names = tarfile.open(fileobj=io.BytesIO(data)).getnames()
        self.assertIn("webtpl/base/up.txt", names)

    def test_editor_saves_and_renames(self):
        status, _, head = call("POST", "/templates/webtpl/f/template.lua", form={"content": "-- edited\r\n", "rename": "template.lua", "exec": "1"})
        self.assertEqual(status, 303)
        f = wing.template_file("webtpl", "template.lua")
        self.assertEqual(f["data"], b"-- edited\n")
        self.assertTrue(f["mode"] & 0o111)

    def test_gitea_token_setting(self):
        call("POST", "/settings", form={"gitea": "1", "gitea_token": "secret1234"})
        self.assertEqual(wing.setting("gitea_token"), "secret1234")
        self.assertNotIn(b"secret1234", call("GET", "/settings")[1])
        call("POST", "/settings", form={"gitea": "1", "gitea_token": ""})
        self.assertEqual(wing.setting("gitea_token"), "")


class Api(unittest.TestCase):
    def test_needs_a_token(self):
        self.assertEqual(call("GET", "/api/projects")[0], 401)
        self.assertEqual(call("GET", "/api/projects", headers={"Authorization": "Bearer wing_nope"})[0], 401)

    def test_tasks_round_trip(self):
        auth = token()
        self.assertEqual(call("POST", "/api/projects", {"name": "api", "checkout": {"machine": "core", "path": "/p"}}, auth)[0], 200)
        status, data, _ = call("POST", "/api/projects/api/tasks", {"quick": "do it !high"}, auth)
        self.assertEqual(status, 201)
        number = json.loads(data)["number"]
        status, data, _ = call("PATCH", f"/api/projects/api/tasks/{number}", {"state": "done"}, auth)
        self.assertEqual(json.loads(data)["state"], "done")
        self.assertEqual(call("GET", "/api/projects/nope/tasks", headers=auth)[0], 404)
        self.assertEqual(call("POST", "/api/projects/api/tasks", [1], auth)[0], 400)

    def test_templates_round_trip(self):
        auth = token()
        files = [{"path": "template.lua", "data": base64.b64encode(b"x").decode(), "mode": 0o755}]
        self.assertEqual(call("PUT", "/api/templates/apitpl", {"files": files}, auth)[0], 200)
        listing = json.loads(call("GET", "/api/templates", headers=auth)[1])
        self.assertIn("apitpl", [t["name"] for t in listing])
        full = json.loads(call("GET", "/api/templates/apitpl", headers=auth)[1])
        self.assertEqual(full["files"][0]["mode"], 0o755)
        self.assertEqual(call("PUT", "/api/templates/new", {"files": []}, auth)[0], 400)
        self.assertEqual(call("DELETE", "/api/templates/apitpl", headers=auth)[0], 200)
        self.assertEqual(call("GET", "/api/templates/apitpl", headers=auth)[0], 404)


if __name__ == "__main__":
    unittest.main(verbosity=1)
