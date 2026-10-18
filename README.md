# AJ Jeweler

The system two AJ Jewellers branches run on — Kidapawan and Davao. Purchases
over the counter, sales, scrap disposal, loans repaid in gold, cash, and a log
that names whoever did each thing.

| Folder | What's in it |
| --- | --- |
| `mobile/` | The Flutter app the counter uses, on Android. |
| `backend/` | The Django server: PostgreSQL, the REST API, the sync endpoints, and push notifications. |

## How it fits together

The server holds the shop's records. Each phone keeps its own copy, so the
counter keeps working when the connection does not: every write lands locally
first and is queued, and the server has the last word on every rule. A phone
that has been offline all day replays its queue in order when it comes back,
and anything the server refuses is shown to the person rather than silently
dropped.

Staff sign in with a 4–6 digit PIN. A role decides what someone is normally
responsible for and who gets notified — not what they may do. Cashier,
Assistant Appraiser and Sales Rep can all do the counter's work, so an absence
never leaves a customer waiting; the cash ledger, corrections, disposal,
rates, loans and staff stay with an Admin.

## Running it

**The server** — Docker Compose on one machine; `backend/README.md` has the
whole thing, including backups and what to do before putting it on the open
internet.

```bash
cd backend
cp .env.production.example .env.production   # fill it in
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml run --rm web \
    python manage.py bootstrap_admin --id USR-AJ01 --name "Your Admin" --pin 1234
```

For development instead, `backend/README.md`'s quick start runs Postgres in
Docker and Django on the host, with demo data.

**The app** — point it at the server at build time:

```bash
cd mobile
flutter pub get
flutter test
flutter build apk --release --dart-define=API_BASE_URL=http://<server>:8000/api/v1
```

The APK lands in `mobile/build/app/outputs/flutter-apk/app-release.apk`.
`mobile/README.md` covers the server URL, signing in, syncing, and
notifications.

## What is not in this repository, on purpose

Four things are needed to build and run this, and none of them are here —
they would let anyone sign the app, read the shop's records, or send
notifications to its phones:

| What | Where it belongs | Stand-in in the repo |
| --- | --- | --- |
| The Android signing keystore and its passwords | outside the repo; `mobile/android/key.properties` points at it | `mobile/android/key.properties.example` |
| `google-services.json` (Firebase, for notifications) | `mobile/android/app/` | — download it from the Firebase console |
| The Firebase service-account key (the server sends with it) | on the server's host disk, mounted read-only | `backend/deploy/no-firebase.json` |
| `.env` / `.env.production` | on the machine that runs the server | `backend/.env.example`, `backend/.env.production.example` |

Without them everything still builds: the app falls back to debug signing and
runs without notifications, and the server runs with notifications off.

## Tests

```bash
cd mobile   && flutter test          # 207, no server needed
cd backend  && python manage.py test # 183, Django makes its own database
```
