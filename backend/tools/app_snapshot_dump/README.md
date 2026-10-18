# app_snapshot_dump

Writes the Flutter app's own demo data, exactly as `AppRepository.toSnapshot()`
produces it, to a JSON file. The backend's import tests and seed-fidelity test
read the result from `shop/tests/fixtures/app_demo_snapshot.json`.

It depends on `mobile/` by path and changes nothing inside it.

```bash
cd backend/tools/app_snapshot_dump
flutter pub get
SNAPSHOT_OUT=../../shop/tests/fixtures/app_demo_snapshot.json flutter test test/dump_test.dart
```

Regenerate it whenever the app's seed data or `SnapshotCodec` changes.
