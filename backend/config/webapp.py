"""The desktop app (the Flutter web build) served from this same origin.

    /                       the app's index.html
    /assets/…, main.dart.js the app's files (WhiteNoise, from WEB_APP_ROOT)
    /cash, /purchases/…     index.html again — the app owns its own routes
    /api/v1/…  /admin/…  /media/…  /static/…   never the app

Same origin means the app calls /api/v1/ on its own host: no CORS, no server
address baked into the build.

Caching. Flutter's web build does not put content hashes in its file names —
main.dart.js, assets/AssetManifest.bin and canvaskit/canvaskit.wasm keep their
names from one build to the next. So nothing here is cached "hard":

* the entry points (index.html, flutter_bootstrap.js, flutter_service_worker.js,
  version.json, manifest.json) are `no-store` — a shop PC must never keep
  running last week's app against this week's API, and a stale service worker
  would keep the PWA from ever updating;
* every other file is `no-cache`: the browser keeps it but asks each time, and
  WhiteNoise answers 304 Not Modified (ETag / Last-Modified) unless a new build
  changed it. Cheap when nothing changed, correct when something did.
"""

from pathlib import Path, PurePosixPath

from django.conf import settings
from django.http import HttpResponse, HttpResponseNotAllowed

NO_STORE = "no-store"
REVALIDATE = "no-cache"
# Files that decide which version of the app runs.
ENTRY_POINTS = frozenset({"index.html", "flutter_bootstrap.js", "flutter_service_worker.js", "version.json",
                          "manifest.json"})
# Folders that only ever hold files; a miss there is a 404, never the app.
FILE_FOLDERS = ("assets/", "canvaskit/", "icons/")

NOT_DEPLOYED = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>AJ Jeweler server</title>
<meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family: system-ui, sans-serif; max-width: 36rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5">
<h1 style="font-size: 1.4rem">AJ Jeweler server</h1>
<p>No desktop app has been deployed on this server, so there is nothing to show here.</p>
<p>The API is running at <code>/api/v1/</code>, and the administration site is at
<a href="/admin/">/admin/</a>. To serve the desktop app, see "Desktop app" in the backend README.</p>
</body></html>
"""


def web_root(root=None) -> Path | None:
    """The deployed build — a directory holding index.html — or None."""
    raw = settings.WEB_APP_ROOT if root is None else root
    if not raw:
        return None
    path = Path(raw)
    return path if (path / "index.html").is_file() else None


def add_headers(headers, path, url) -> None:
    """WHITENOISE_ADD_HEADERS_FUNCTION: cache rules for the app's files.
    Django's own static files (/static/, hashed by the manifest) are left alone."""
    if url.startswith("/" + settings.STATIC_URL.strip("/") + "/"):
        return
    name = PurePosixPath(url).name
    headers["Cache-Control"] = NO_STORE if name in ENTRY_POINTS or url == "/" else REVALIDATE


def _looks_like_a_file(path: str) -> bool:
    return path.startswith(FILE_FOLDERS) or "." in PurePosixPath(path).name


def spa(request, path: str = ""):
    """Every route that is not the API, the admin, media, static or a real file:
    the app's index.html, so a reload on any inner page works."""
    if request.method not in ("GET", "HEAD"):
        return HttpResponseNotAllowed(["GET", "HEAD"])
    root = web_root()
    if root is None:
        response = HttpResponse(NOT_DEPLOYED, status=200 if path == "" else 404, content_type="text/html")
    elif _looks_like_a_file(path):
        # A real file would have been served by WhiteNoise before reaching here.
        response = HttpResponse("Not found", status=404, content_type="text/plain")
    else:
        response = HttpResponse((root / "index.html").read_bytes(), content_type="text/html; charset=utf-8")
    response["Cache-Control"] = NO_STORE
    return response
