"""Moves photos and receipts saved under the old flat layout
("items/A3T8QD-….jpg") into kind/branch/YYYY/MM/ ("items/kidapawan/2026/10/…").

    python manage.py reorganise_media                  # dry run: what would move
    python manage.py reorganise_media --kind items     # one kind at a time
    python manage.py reorganise_media --apply          # really move

Safe to stop and run again:

* one record at a time — copy to the new path, then (in its own transaction)
  point the row at the copy, and only after that commits delete the old asset.
  A crash at any point leaves the row pointing at a file that exists; the
  worst case is a stray copy.
* anything already in the new layout is skipped.
* an asset that cannot be read is reported and left exactly where it is.

Only the stored path changes. The bytes are the same, so phones (which get
photos as base64) see nothing different, and no log row is written: no shop
record changes meaning.
"""

from django.apps import apps
from django.core.files.base import ContentFile
from django.core.management.base import BaseCommand
from django.db import transaction

from shop.media_paths import KINDS, in_new_layout, relocated
from shop.services.base import acquire_write_lock

EXAMPLES_PER_KIND = 5


class Command(BaseCommand):
    help = "Move existing photos and receipts into the kind/branch/YYYY/MM layout (dry run unless --apply)."

    def add_arguments(self, parser):
        parser.add_argument("--apply", action="store_true", help="Really move files (default is a dry run).")
        parser.add_argument("--dry-run", action="store_true", help="Only report (the default).")
        parser.add_argument("--kind", choices=sorted(KINDS), help="Only this kind.")

    def handle(self, *args, **options):
        apply = options["apply"] and not options["dry_run"]
        chosen = [options["kind"]] if options["kind"] else list(KINDS)
        verbose = options["verbosity"] >= 2
        self.stdout.write("Moving files." if apply else "Dry run: nothing will move. Add --apply to move.")
        totals = {"in place": 0, "to move": 0, "moved": 0, "unreadable": 0, "skipped": 0, "old copy kept": 0}
        for kind_name in chosen:
            counts = self._kind(kind_name, apply, verbose)
            for key, value in counts.items():
                totals[key] += value
            self.stdout.write(f"{kind_name}: " + ", ".join(f"{v} {k}" for k, v in counts.items() if v)
                              if any(counts.values()) else f"{kind_name}: no files")
        self.stdout.write("Total: " + ", ".join(f"{v} {k}" for k, v in totals.items() if v or k == "to move"))

    def _kind(self, kind_name: str, apply: bool, verbose: bool) -> dict:
        kind = KINDS[kind_name]
        model = apps.get_model(kind.model)
        counts = {"in place": 0, "to move": 0, "moved": 0, "unreadable": 0, "skipped": 0, "old copy kept": 0}
        rows = (model.objects.exclude(**{f"{kind.field}__isnull": True}).exclude(**{kind.field: ""})
                .order_by("pk").iterator())
        shown = 0
        for row in rows:
            field = getattr(row, kind.field)
            old = field.name
            if in_new_layout(old, kind_name):
                counts["in place"] += 1
                continue
            target = relocated(old, kind_name, row)
            counts["to move"] += 1
            if not apply:
                if verbose or shown < EXAMPLES_PER_KIND:
                    self.stdout.write(f"  would move {old} -> {target}")
                    shown += 1
                continue

            storage = field.storage
            try:
                with storage.open(old, "rb") as handle:
                    data = handle.read()
            except Exception as error:  # never touch what cannot be read
                counts["unreadable"] += 1
                self.stderr.write(f"  cannot read {old} ({type(error).__name__}) - left where it is")
                continue

            new = storage.save(target, ContentFile(data, name=target.rsplit("/", 1)[-1]))
            with transaction.atomic():
                acquire_write_lock()
                # Only if the row still points at the old file — it may have
                # been given a new photo while this ran.
                updated = model.objects.filter(pk=row.pk, **{kind.field: old}).update(**{kind.field: new})
            if not updated:
                counts["skipped"] += 1
                storage.delete(new)
                self.stderr.write(f"  {kind_name} {row.pk} changed while moving - left as it is")
                continue
            counts["moved"] += 1
            if verbose:
                self.stdout.write(f"  moved {old} -> {new}")
            try:
                storage.delete(old)  # only now: the row already points at the copy
            except Exception as error:
                counts["old copy kept"] += 1
                self.stderr.write(f"  moved {old}, but the old copy could not be deleted ({type(error).__name__})")
        return counts
