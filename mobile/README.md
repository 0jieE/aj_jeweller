# AJ Jeweler — mobile app

The Flutter app for the two branches (Kidapawan and Davao). Android is the
real target; the web build is only used for quick previews.

```
flutter pub get
flutter test                 # 204 tests, no server needed
flutter run
flutter build apk --release  # build/app/outputs/flutter-apk/app-release.apk
```

A release build is signed with the shop's own key when
`android/key.properties` points at the keystore (see
`android/key.properties.example`); without it, it falls back to Flutter's
debug keys and says so in the build log. **The keystore and that file live
outside the repository.** Losing either means this app can never be updated
again — Android treats a differently signed build as a different app, which
can only be installed by uninstalling the old one first, taking anything not
yet synced with it.

## Pointing the app at a server

[lib/core/api/api_config.dart](lib/core/api/api_config.dart) holds the shop's
server, and a build with no arguments uses it:

```
https://aj-jeweller.onrender.com/api/v1/
```

That is what the counter should be running. To point a build somewhere else —
a laptop on the shop's Wi-Fi, a staging server — pass the URL in:

```
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000/api/v1
flutter build apk --release --dart-define=API_BASE_URL=https://aj.example.com/api/v1
```

A trailing slash is optional. The URL in use is printed at the bottom of the
Sync page and on the sign-in screen when the server cannot be reached, so a
phone in the shop can be checked without a cable.

The shop's server is on Render's free plan while it is being tried out, which
sleeps after about fifteen minutes idle: the first request of the morning
wakes it and can take a minute, so the sign-in screen may say it cannot reach
the server and work on the second try.

The server must be reachable over plain HTTP only for local work; Android
release builds allow cleartext to the LAN, so a production deployment should
be HTTPS.

## Signing in

There is no user picker any more. The app asks the server who can sign in
(`GET /auth/staff`), the person taps their name and types their 4–6 digit PIN
(`POST /auth/login`), and every record from then on names them because the
server reads the actor from the token — the app never sends one.

- Tokens live in Android's Keystore-backed storage
  ([token_store.dart](lib/core/api/token_store.dart)), not in a plain file, so
  a backed-up or stolen phone does not hand over the shop's ledger.
- A request that comes back `401` triggers one refresh and one retry, so an
  expired token never surfaces as an error anyone has to understand. Several
  requests expiring at once share the single refresh.
- **More → Change PIN** changes your own; the server hands back fresh tokens,
  which ends every other session that person had.
- An Admin sets or resets someone else's from **Users → _person_ → Set PIN**.
- **More → Sign Out** keeps anything still queued — it belongs to the shop,
  not to the session — and sends it the next time someone signs in here.

## How syncing works

The phone is the one that has to work. Every write lands locally first, so the
counter keeps running with no signal at all, and the server is told afterwards.

1. **Sign-in** pulls the whole picture once: `GET /sync/snapshot` replaces the
   phone's records and stores the server's cursor.
2. **Every write** goes through
   [app_repository.dart](lib/core/data/app_repository.dart), which applies it
   locally and hands one operation to the outbox — `{key, method, path, body,
   recorded_at}`. The phone generates the record's 6-character id (and the
   `cash_entry_id` / `bank_entry_id` for anything that moves money), so the
   same write replayed cannot create a second record.
3. **The queue is pushed in order** to `POST /sync/push`, in batches, and is
   written to disk after every change
   ([app_storage.dart](lib/core/data/app_storage.dart)) so a day's work
   offline survives a dead battery.
   - `2xx` — done, dropped from the queue.
   - `422` / `409` and other 4xx — a rule, not a glitch. The operation is
     dropped and kept as a **refusal** for the person to read.
   - `5xx` or no connection — it stays queued, **with the same key**, and goes
     up again on the next attempt. The key is what stops a dropped connection
     releasing cash twice.
4. **Then the changes come down**: `GET /sync/changes?since=<cursor>` is
   applied page by page — upserts from `changes`, removals from `deleted` —
   until `has_more` is false. The server's version always wins, because it is
   the one that applied the shop's rules. Nothing applied this way is queued
   back up.

The app bar's cloud icon shows where this stands — a count of what is waiting,
a cloud-off when there is no signal, a red badge when something was refused —
and opens the **Sync** page: what is queued, what was refused and why, and
when the phone and the server last agreed.

### Refusals

A refused change has already been applied on this phone, so the two now
disagree. The Sync page says so plainly and the phone's copy is corrected the
next time the server's version of that record arrives. Tapping **Got it**
marks a refusal seen; **Clear all** empties the inbox.

### Moving a shop that has been running offline

A shop that has been using the app with no server keeps its history:
**More → Send Data to Server** (Admin only) sends this phone's saved file to
`POST /sync/import`. It is sent with `?dry_run=true` first and the server's
report is shown — what would be created, skipped, and any warnings — before
anything is written. The real send is followed by a fresh snapshot.

## Notifications

The app registers for Firebase Cloud Messaging once someone signs in, so the
counter is told when a purchase is waiting on a Cashier or an order needs
payment instead of having to watch the Dashboard.

- The Firebase project is `aj-jeweler-notification`; its config lives at
  `android/app/google-services.json`. **That file is not in version control
  and should not be** — it names the project this app's notifications come
  from. A build without it still runs; there are simply no notifications.
- Android 13 and up asks the person before anything may appear in the tray.
  **More → Notifications** says whether this phone is registered and asks
  again if it is not.
- The phone's token goes to `POST /devices` after sign-in and is deleted on
  sign-out, so the next person at that counter does not get the last
  person's notifications.
- A notification carries `kind` (`purchase`, `sale`, `commitment`, `item`)
  and `record_id` in its data. Tapping it opens that record, syncing first if
  this phone has not seen it yet — see
  [lib/core/notifications/](lib/core/notifications/).
- Everything lands in the tray, on the `aj_jeweler` channel, at high
  importance — so it pops up over whatever is on screen and makes a sound.
  Firebase never puts a message in the tray while the app is open and in
  front, so in that case the app posts it itself
  ([notification_channel.dart](lib/core/notifications/notification_channel.dart)).
  The counter sees the same thing either way.
- Two notifications about one record replace each other rather than stacking
  up in the shade.

## What a role means

A role says what someone is normally responsible for and who the server
notifies — **not** what they are allowed to do. Cashier, Assistant Appraiser
and Sales Rep can all do the same counter work, so when the Cashier is out the
Appraiser or the Sales Rep releases the cash and the shop does not stop. Every
record names whoever actually did it, so covering for someone is visible in
the log rather than hidden.

What stays an Admin's: the cash ledger (entries, expenses, withdrawals,
transfers between branches), corrections to a record, deleting a partition,
disposal batches, commitments and rates, staff, the data import, and seeing
both branches at once. Releasing a purchase and receiving payment are counter
work and stay open to everyone — what an Admin keeps is moving and accounting
for the shop's own money. See [lib/core/models/user_role.dart](lib/core/models/user_role.dart).

The Dashboard follows the same rule — everyone at a branch sees the counter's
queue, and their own submissions underneath it when they have any.

## The rules, in both places

The app refuses the same things the server does, in the same words, so nothing
has to travel to be told no:

- a payment must equal the order total;
- a sold, disposed or reserved item can no longer be edited;
- releasing a purchase, and receiving loan cash, each need a photo of the cash
  changing hands;
- only a verified lot can be partitioned;
- a disposal needs a received loan with a balance left to pay;
- a receipt is issued once the cash is released, or the payment is received.

A rule that only the server can know — a record someone else already changed,
a staff account that has been deactivated — still comes back as a refusal, and
that is what the inbox is for.

## Where the code sits

| Path | What's in it |
| --- | --- |
| `lib/core/data/app_repository.dart` | Every record and every rule. Screens read and write through this and nothing else. |
| `lib/core/data/snapshot_codec.dart` | The one JSON shape shared by the save file, `/sync/snapshot` and `/sync/changes`. |
| `lib/core/data/app_storage.dart` | The device's own copy, and the queue beside it. |
| `lib/core/api/` | The HTTP client, the base URL, and where tokens are kept. |
| `lib/core/sync/` | The outbox and the push/pull service. |
| `lib/core/state/` | Session, selected branch, and the counter's staged cart and purchase basket. |
| `lib/features/` | One folder per screen area. |
| `test/support/fake_server.dart` | The stand-in server the sync and sign-in tests run against. |

Money is whole centavos everywhere (`int`), weight is grams to three decimals,
and no balance is ever stored — every total is derived, so the ledger cannot
drift from the entries that make it up.
