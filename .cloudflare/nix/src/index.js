export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed\n", {
        status: 405,
        headers: {
          allow: "GET, HEAD",
          "content-type": "text/plain; charset=utf-8",
        },
      });
    }

    if (url.hostname !== "nix.bresilla.dev") {
      return new Response("not found\n", {
        status: 404,
        headers: {
          "content-type": "text/plain; charset=utf-8",
        },
      });
    }

    const upstream = await fetch(env.INSTALLER_URL, {
      headers: {
        "user-agent": "bresilla-nix-worker",
      },
      cf: {
        cacheTtl: 60,
        cacheEverything: true,
      },
    });

    if (!upstream.ok) {
      return new Response("installer unavailable\n", {
        status: 502,
        headers: {
          "content-type": "text/plain; charset=utf-8",
        },
      });
    }

    return new Response(request.method === "HEAD" ? null : upstream.body, {
      status: 200,
      headers: {
        "cache-control": "public, max-age=60",
        "content-type": "text/x-shellscript; charset=utf-8",
      },
    });
  },
};
