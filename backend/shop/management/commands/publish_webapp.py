"""Copies a Flutter web build into backend/webapp/, ready to commit and deploy.

    cd mobile && flutter build web --release
    cd ../backend && python manage.py publish_webapp            # from ../mobile/build/web
    git add webapp && git commit -m "Desktop app build …" && git push

Render builds the image from the repository, where mobile/build/ is
git-ignored and Flutter is never installed — so the build travels as a
committed copy here, and the image serves it (WEB_APP_ROOT=/app/webapp).

What it leaves out, to keep each release small in git:
* `*.symbols` — debug symbols, never fetched by a browser;
* `.last_build_id` — Flutter's own bookkeeping;
* `canvaskit/` — unless the build loads CanvasKit from its own host. By default
  Flutter loads it from Google's CDN, pinned to the engine version, and never
  reads the local copy (37 MB of the 44 MB build). A build made with
  `--no-web-resources-cdn` does read it, and then it is kept.

The copy is assembled beside the old one and swapped in at the end, so an
interrupted run never leaves a half-copied app.
"""

import shutil
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

SKIP_NAMES = {".last_build_id"}
SKIP_SUFFIXES = (".symbols",)


def uses_local_canvaskit(build: Path) -> bool:
    bootstrap = build / "flutter_bootstrap.js"
    text = bootstrap.read_text(encoding="utf-8", errors="ignore") if bootstrap.is_file() else ""
    compact = text.replace(" ", "")
    return '"useLocalCanvasKit":true' in compact or '"engineRevision"' not in compact


class Command(BaseCommand):
    help = "Copy a Flutter web build (mobile/build/web) into backend/webapp for deployment."

    def add_arguments(self, parser):
        parser.add_argument("--from", dest="source", default=str(settings.BASE_DIR.parent / "mobile" / "build" / "web"),
                            help="The Flutter web build (default: ../mobile/build/web)")
        parser.add_argument("--to", dest="target", default=str(settings.BASE_DIR / "webapp"),
                            help="Where the server serves it from (default: backend/webapp)")

    def handle(self, *args, **options):
        source, target = Path(options["source"]).resolve(), Path(options["target"]).resolve()
        if not (source / "index.html").is_file():
            raise CommandError(f"No web build at {source} — run `flutter build web --release` in mobile/ first")
        keep_canvaskit = uses_local_canvaskit(source)

        staging = target.with_name(target.name + ".incoming")
        if staging.exists():
            shutil.rmtree(staging)
        copied, skipped, size = 0, 0, 0
        for file in sorted(source.rglob("*")):
            if not file.is_file():
                continue
            relative = file.relative_to(source)
            if (file.name in SKIP_NAMES or file.name.endswith(SKIP_SUFFIXES)
                    or (relative.parts[0] == "canvaskit" and not keep_canvaskit)):
                skipped += 1
                continue
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
            copied += 1
            size += file.stat().st_size

        retired = target.with_name(target.name + ".previous")
        if retired.exists():
            shutil.rmtree(retired)
        if target.exists():
            target.rename(retired)
        staging.rename(target)
        if retired.exists():
            shutil.rmtree(retired)

        self.stdout.write(self.style.SUCCESS(
            f"Published {copied} file(s), {size / 1_048_576:.1f} MB, to {target} "
            f"({skipped} left out{'' if keep_canvaskit else ', CanvasKit comes from the CDN'})."))
        self.stdout.write("Next: commit backend/webapp and push. The server picks it up on its next deploy; "
                          "no migration, and the shop's data is not touched.")
