# AJ Jeweler — backend

The server for the AJ Jeweler app (two gold shops: Kidapawan and Davao).
It is Django 5 with Django REST Framework and PostgreSQL. In development,
photos and receipt PDFs are stored on local disk.

The specification is [BACKEND_SPEC.md](BACKEND_SPEC.md). Where the spec is
silent, the Flutter app is the source of truth, mainly
`mobile/lib/core/data/app_repository.dart` and its tests. The server enforces
the same rules and refuses with the same sentences.

## Quick start

You need Python 3.12+ and Docker (for Postgres). Commands are run from `backend/`.

```bash
docker compose up -d --wait               # Postgres 16 on localhost:5434 (user/pass/db: aj/aj/aj_jeweler)
python -m venv .venv
.venv/Scripts/activate                    # Windows; on macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env                      # optional — every setting has a dev default
python manage.py migrate
python manage.py seed_demo                # the app's demo shop; everyone's PIN is 1234
python manage.py runserver 0.0.0.0:8000   # the Android emulator reaches it at http://10.0.2.2:8000
```

To check that it works:

```bash
curl -s -X POST localhost:8000/api/v1/auth/login -H 'Content-Type: application/json' \
     -d '{"name": "Grace Ramos", "pin": "1234"}'
```

Run the tests (195 of them; Django creates and drops its own test database, and no test touches the network):

```bash
python manage.py test
```

### Starting from real phone data instead of the demo

```bash
python manage.py migrate
python manage.py bootstrap_admin --id USR-AJ01 --name "Arnel Javier" --pin 1234
# sign in as that Admin, then send the phone's saved file (aj_jeweler_data.json):
curl -X POST localhost:8000/api/v1/sync/import?dry_run=true -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' --data-binary @aj_jeweler_data.json   # report only, writes nothing
curl -X POST localhost:8000/api/v1/sync/import -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' --data-binary @aj_jeweler_data.json
```

Use the phone's own Admin id with `bootstrap_admin` (`USR-AJ01` in the app). The
import then recognises them instead of adding a second person. Staff who
arrive through the import have no PIN until an Admin sets one with
`POST /users/{id}/pin`. The import report lists who needs one.

## Decisions you made

**Sign-in: name + PIN.** Each person has a 4–6 digit PIN, hashed exactly like a
password. Only an Admin sets or resets one (`POST /users/{id}/pin`), and anyone
can change their own (`POST /me/pin`).

`POST /auth/login {name | user_id, pin}` returns a 30-minute access token, a
14-day refresh token, and the person. `GET /auth/staff` lists who can sign in,
for a PIN-pad picker.

- Five wrong PINs lock that sign-in for 15 minutes.
- A PIN change revokes the person's existing tokens.
- A deactivated person is refused on their very next request.

The actor is always taken from the token, never from the request body.

**Sync: offline outbox.** The phone keeps working offline, choosing record ids
itself as it already does, and queues each write. Back online, it replays the
queue in order. The server applies each write exactly as if it had been sent
live, then the phone pulls what changed. See [The offline outbox](#the-offline-outbox).

## Non-negotiables, and where they are enforced

| Rule | How |
| --- | --- |
| Money is integer centavos | `BigIntegerField` everywhere. Weights are `Decimal(10,3)` and travel as strings such as `"15.750"`. |
| Balances are derived | No balance column exists. A balance is the opening figure plus the signed ledger, computed in SQL (`services/cash.py`). A loan's balance and status come from the disposals applied to it (`services/commitments.py`). |
| Three pots per branch | Purchase release → `purchase`. Sale cash → `sales`, sale bank → `bank`. Loan proceeds → `purchase`. Transfers are matched pairs. |
| Nothing silently deleted | The only hard deletes are a manual cash entry (both halves for a transfer), a partition, and a user with no records. Every deleted id stays in `RecordId`, so it is never reused and an old snapshot cannot bring the record back. |
| Every write names a person | Each mutating request writes exactly one `TransactionLog` row naming the actor. Corrections carry `{field, before, after}`. |
| Append-only log and rate history | Postgres triggers refuse `UPDATE` and `DELETE` on both tables (migration 0002). |
| One code, one record | `RecordId` registers every id across all record types. A clash is a 409. |
| Purity matches metal, plus other invariants | Database check constraints cover enums, purity per metal, positive amounts, gross ≥ net, linked vs manual entries, transfer pairs, the user's branch vs role, and partition remainders ≥ 0. The services check them first, so the refusal can say what is wrong. |
| Refusals are 422 with the app's sentence | `{"error": {"code": "...", "message": "..."}}`. Messages are the app's (`ArgumentError`/`StateError` texts and its form copy). |

Every write takes one shop-wide database lock for its transaction, so writes
run one at a time. Two branches and a handful of staff write rarely enough
that this costs nothing. In return, no rule can race another (two cashiers
releasing one purchase), and the sync feed's order is exactly commit order.

## API

All endpoints are under `/api/v1/`. Trailing slashes are optional. Every list
takes `?branch=`, `?from=`, `?to=`, `?q=`, `?page=` and `?page_size=`. Branch
staff always see only their own branch. Admin sees both, unless `?branch=`
narrows it.

| Area | Endpoints |
| --- | --- |
| Session | `POST auth/login`, `POST auth/refresh`, `GET auth/staff`, `GET me`, `POST me/pin` |
| Devices | `POST devices` `{token, platform}`, `DELETE devices/{token}` — see [Push notifications](#push-notifications) |
| Staff | `GET/POST users`, `GET/PATCH/DELETE users/{id}`, `POST users/{id}/deactivate`, `…/reactivate`, `…/pin` |
| Reference | `GET branches`, `GET branches/{id}`, `GET/POST rates`, `GET/PATCH rates/{karat}`, `GET rates/history`, `GET rates/on/{date}`, `POST rates/apply` |
| Customers | `GET/POST customers`, `GET/PATCH customers/{id}`, `PUT customers/{id}/photo` |
| Purchases | `GET/POST purchases`, `GET purchases/{id}`, `POST purchases/{id}/release`, `…/return`, `…/resubmit` |
| Items | `GET items`, `GET items/{id}`, `PATCH items/{id}` (admin correction), `PUT items/{id}/photo`, `POST items/{id}/partitions`, `POST items/{id}/resubmit`, `DELETE partitions/{id}` |
| Sales | `GET items/sellable`, `POST items/{id}/reserve`, `POST items/{id}/release-reservation`, `GET/POST sales`, `GET sales/{id}`, `POST sales/{id}/complete`, `…/return`, `…/resubmit` |
| Disposal & loans | `GET disposal/pool`, `GET/POST disposal`, `GET disposal/{id}`, `GET/POST commitments`, `GET commitments/{id}`, `POST commitments/{id}/receive` |
| Cash | `GET/POST cash/entries`, `GET/PATCH/DELETE cash/entries/{id}`, `POST cash/transfers`, `GET cash/balances` |
| Records | `GET/POST receipts`, `GET receipts/{id}`, `GET receipts/{id}/pdf`, `GET receipts/{id}/text`, `GET logs`, `GET logs/{id}`, `GET exports/{purchases\|sales\|expenses\|withdrawals}?format=csv\|xlsx\|pdf` |
| Sync | `POST sync/import`, `GET sync/snapshot`, `GET sync/changes?since=`, `POST sync/push` |

### Roles

| Role | Both branches | One branch | Django admin |
| --- | --- | --- | --- |
| `superuser` | yes | — | **yes** |
| `admin` | yes | — | no |
| `supervisor` | — | yes, their own | no |
| `cashier`, `assistantAppraiser`, `salesRep` | — | counter work at their branch | no |

The shop runs on two rules:

- **Counter work is everyone's.** Any role can encode a purchase, build an
  order, release the cash to a customer and receive payment, and return either
  for correction. That covers Cashier, Assistant Appraiser, Sales Rep,
  Supervisor, Admin and Superuser. When the Cashier is out, the Appraiser or
  the Sales Rep carries on.

  A role says what someone is normally responsible for, and who gets
  *notified*, not what they're allowed to do. Every record names whoever
  actually did the work, so covering for a colleague shows in the log.
- **Running a branch is not shared.** The cash ledger means recording an
  entry, an expense, a withdrawal or a transfer, and editing or deleting one.
  That is the shop's own money being moved and accounted for, so it belongs
  to the branch's Supervisor, and to an Admin or Superuser at both branches.
  So do corrections, partition returns, disposal, loans and staff.

  Releasing cash to a customer is counter work; moving the shop's float is
  not.

Branch scoping never changes: everyone works at their own branch, and an Admin
or Superuser at either.

- **Superuser** is an Admin everywhere in the shop, and the **only** role that
  may sign in to the Django admin site.
- **Admin** oversees both branches. It cannot sign in to the Django admin site,
  and cannot create, edit or deactivate a Superuser or make anyone one.
- **Supervisor** runs one branch without needing the Admin. Everything below is
  limited to their `home_branch`, which they must have:
  - the cash ledger: entries, expenses, withdrawals, corrections to manual
    entries, and transfers where their branch is one end;
  - item corrections and returning partitions;
  - disposal batches;
  - their branch's loans (adding and receiving them);
  - their branch's counter staff: adding a Cashier, Appraiser or Sales Rep
    there, editing them, setting their PIN, deactivating them.
- **What a Supervisor may not do:**
  - anything at the other branch;
  - a company-wide loan, including applying a disposal to one; that stays the
    Admin's;
  - the import;
  - touching an Admin, a Superuser or any Supervisor, themselves included, or
    making anyone one of those. Such an attempt is refused (403), not quietly
    filtered.
- **Gold and silver rates** are open to every role. The counter quotes from
  them all day, every change is logged under its author's name, and a change
  applies to both branches.
- **Permissions by task:**

  | Task | Who |
  | --- | --- |
  | Counter work: encode and resubmit purchases, draw partitions, build and hold orders, release cash, receive payment, return either for correction | everyone, at their own branch |
  | Gold and silver rates | everyone |
  | The cash ledger: entries, expenses, withdrawals, transfers, editing and deleting them | Supervisor (own branch), Admin |
  | Corrections, partition returns, disposal, branch loans, counter staff | Supervisor (own branch), Admin |
  | Company-wide loans, the import, any staff | Admin |
  | Read | everyone |

  A Superuser can do everything an Admin can.
- **Rules that hold at all times:** at least one active Admin or Superuser
  always exists, and the last active Superuser can't be demoted, deactivated
  or deleted.

A few request details:

- **Photos** can be a multipart file or base64 text in JSON. An outbox entry is
  JSON, so it uses base64. Release and loan receipt *require* a proof photo.
- **Ids** are optional on create. Send the phone's 6-character code
  (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`) and it becomes the primary key; leave it
  out and the server mints one. For the ledger rows that release, payment and
  loan receipt write, the client can also name the entry id (`cash_entry_id`,
  `bank_entry_id`), so the phone's local copy and the server agree.
- **Dates** without an offset are read as Manila time, which is what Dart's
  `toIso8601String()` sends. REST responses carry the `+08:00` offset.

Example — record a visit, then release it:

```http
POST /api/v1/purchases
{"id": "A7K2M9", "branch": "kidapawan",
 "customer": {"name": "Maria Santos", "contact_number": "0917 555 0142"},
 "lines": [{"id": "7H3M2Q", "description": "22K gold necklace", "gross_weight_grams": "16.400",
            "weight_grams": "15.750", "karat": 22, "type": "goods", "amount_centavos": 8200000}]}

POST /api/v1/purchases/A7K2M9/release          (multipart proof_photo, or {"proof_photo": "<base64>"})
→ 200, the batch plus "cash_entry": {"account": "purchase", "type": "expense", "amount_centavos": 8200000, ...}
```

## The offline outbox

1. **Start.** Sign in, then `GET /sync/snapshot` (add `?photos=false` to leave
   photos out). The response is in the phone's own file format
   (`SnapshotCodec`), plus a `cursor`. The app's own
   `AppRepository.restoreSnapshot` reads it as-is.
2. **Work offline.** Each write is queued as `{key, method, path, body,
   recorded_at}`. The `key` is a fresh UUID per write; `recorded_at` is when it
   happened on the phone.
3. **Push.** `POST /sync/push {"operations": [...], "stop_on_error": false}`.
   Each operation runs through the real endpoint, with the same rules, the same
   single log row, and `X-Recorded-At` as its date. The log keeps both times:
   `at` (on the phone) and `received_at` (on the server). The response gives a
   `status` and `body` per operation. A replayed key returns its first result
   with `"replayed": true`, so resending a whole queue after a dropped
   connection never acts twice.
4. **Handle refusals.** A 422 in the results is a real refusal, for example
   *"Payment for this order was already received"*. The phone must show it to
   the person and drop or fix that change. `stop_on_error: true` stops at the
   first one and marks the rest `skipped`.
5. **Pull.** `GET /sync/changes?since=<cursor>` returns changed records in the
   phone's format, the ids under `deleted`, the next `cursor`, and `has_more`.

Every write endpoint also honours `Idempotency-Key` directly, outside `push`.
Keys belong to the person who sent them. Reusing a key for a different
request is refused. A change dated more than 30 days back, or more than five
minutes ahead of the server's clock, is refused; both limits are in settings.

## Push notifications

The phone registers its FCM token after sign-in (`POST /devices`), re-sends it
when Firebase rotates it, and deletes it on sign-out (`DELETE /devices/{token}`).
The server then tells the right people when work lands on them:

| When | Who is told | `kind` | Title — body |
| --- | --- | --- | --- |
| A purchase is recorded, or resubmitted after a return | that branch's Cashiers | `purchase` | Cash to release — Rico Dela Cruz · 2 item(s) · ₱26,100.00 |
| A purchase is returned for correction | the Appraiser who encoded it | `purchase` | Purchase returned — {customer} · {note} |
| An order is sent to the Cashier, or resubmitted | that branch's Cashiers | `sale` | Payment to receive — {customer} · {amount} |
| An order is returned to the rep | the Sales Rep who built it | `sale` | Order returned — {customer} · {note} |
| A loan's cash is received | Admins | `commitment` | Loan received — {lender} · {amount} |
| A disposal clears a loan | Admins | `commitment` | Loan cleared — {lender} |

- **Who is told:** only active staff, and never the person who caused the event.
  A branch with no active Cashier has its Admins told instead, since an Admin
  then does the Cashier's work.
- **What is sent:** a tray `notification` plus a `data` block
  `{kind, record_id, branch}` (all strings), on Android channel `aj_jeweler`,
  at high priority.
- **Registering a handset:** one row per token. If that phone was registered
  to someone else, the token moves to the person now signed in. Deleting a
  token that isn't there is still `204`.
- **Dead tokens:** a token FCM reports as `UNREGISTERED` is deleted. So is one
  reported as `INVALID_ARGUMENT`, but only when FCM says the token itself is
  the problem; a malformed message must not wipe every phone.

**Setup.** Two environment variables, in `backend/.env`:

```
FIREBASE_CREDENTIALS_FILE=C:\secrets\aj-jeweler-notification-firebase-adminsdk.json
FIREBASE_PROJECT_ID=aj-jeweler-notification
```

The key is a service-account private key for the Firebase project
`aj-jeweler-notification`. Get it from the Firebase console: Project settings →
Service accounts → Generate new private key. Keep it outside the repository,
and never commit or paste it. The server calls the FCM HTTP v1 API with it,
through `google-auth` + `requests`.

**Check a phone.** Sign in on the phone as the person and allow notifications.
Then run:

```bash
python manage.py send_test_notification --user USR-K-CSH
```

It sends one test notification to every phone registered to that person and
prints what FCM said for each.

**How sending works.** The notification is written to an outbox table in the
same transaction as the shop change, so a refused or rolled-back write never
notifies anyone. After the commit, a background thread sends it, and the
response never waits on Google.

Anything left unsent (FCM unreachable, or the server restarted mid-send) stays
pending. Run `python manage.py send_notifications` every few minutes from Task
Scheduler or cron to retry it. Notifications older than 12 hours
(`PUSH_MAX_AGE_HOURS`) are dropped instead of arriving late.
`PUSH_DELIVERY=command` makes that command the only sender.

A `/sync/push` replay of a write already applied returns its stored first
response without running anything, so it never notifies twice. A phone back
from a day offline doesn't flood the shop with notifications it already got.

**If notifications are off** (no key file, wrong path, or an unreadable key):

- The server logs one warning at the first send and carries on. Every
  purchase, sale and release still works.
- Nobody's phone buzzes; staff see new work only when they open or refresh the
  app.
- The outbox marks those rows `off`, so turning notifications on later doesn't
  deliver a backlog.
- `send_test_notification` explains why notifications are off.

## Admin site

The admin site is at `/admin/` (for example http://localhost:8000/admin/). Sign in with
your name or user id and your PIN, the same as on the phone. **Only an
active Superuser gets in**; an Admin is refused like a Cashier. Wrong PINs
count toward the same lockout. "Change password"
in the top bar changes your PIN.

- **Staff** (Accounts → Users): add people, edit them, set a new PIN, and
  deactivate or reactivate them from the list's actions. Each of these runs
  through the same rules as the API, so a refusal shows on the form in the
  app's words (for example "Grace Ramos is already on file") and nothing is
  saved. Each change writes its log row under your name. The Delete button
  appears only for someone with no records.
- **Shop records** (purchases, items, sales, cash entries, loans, disposals,
  rates, receipts, the transaction log): view-only. You can browse, search,
  filter by branch and status, and open any record. Balances and loan status
  are computed live. Changes go through the app or the API, where the rules
  run and the log is written; editing rows here would skip both.
- **Phones and notifications**: see which phones are registered to whom,
  remove one (the same as that phone signing out), and see every notification
  with its delivery status. The "Send the selected pending notifications now"
  action retries pending ones.

When `DEBUG` is off, run `python manage.py collectstatic` and serve
`staticfiles/` for the admin's CSS. If the admin is reached through a domain
or proxy, list it in `DJANGO_CSRF_TRUSTED_ORIGINS`, for example
`https://admin.example.com`.

## Seed data and the phone's file format

- `python manage.py seed_demo [--reset] [--pin 1234]` loads the app's demo
  shop: the seven staff, 19 purchases, 23 items, 3 sales, 3 loans, 3 disposals,
  16 ledger entries, rates with history, and 74 log rows. It produces the
  Dashboard's ₱1,037,903.00 (Kidapawan) and ₱694,169.00 (Davao).
  `shop/demo.py` is a line-by-line port of `seed_data.dart`, and it loads
  through the same importer as real phone data.
- `shop/tests/fixtures/app_demo_snapshot.json` was written by the Flutter app
  itself, using [`tools/app_snapshot_dump`](tools/app_snapshot_dump/README.md),
  which depends on `mobile/` by path and changes nothing in it. Tests import
  that file and check the seed port against it field by field. Regenerate it
  whenever the app's seed or codec changes.
- `tools/app_snapshot_dump/test/restore_test.dart` feeds a server snapshot to
  the app's own parser. It was run against `GET /sync/snapshot` from a seeded
  server, and the app derived identical balances for all six accounts.

## Where this departs from the spec, and why

1. **Log action names follow the app.** The spec lists `itemCorrected`; the
   app writes `itemEdited` and also `photoAttached`. The phone's parser throws
   on any name it doesn't know, so the server uses the app's names.

   Rule 5 needs a row for writes the phone never logged, so there are six
   server-only actions: `itemReserved`, `reservationReleased`,
   `customerAdded`, `customerUpdated`, `receiptIssued` and
   `snapshotImported`. They appear in `GET /logs` but are left out of
   phone-format exports, which the v1 app could not parse.
2. **Sold and disposed items cannot be corrected.** This follows the spec. The
   app also blocks *reserved* items, which the server keeps. The app does allow
   correcting a *sold* item's figures; the server does not.
3. **Payment must equal the order total** at completion, as the spec says.
   The app's own tests don't check this.
4. **`POST /rates/apply` writes one log row for the whole table**, with one
   change per rate, so "one row per mutation" holds. The app writes one per
   rate. There is still one history row per changed rate.
5. **Branch `silverValue` is not stored.** The app's `Branch` carries it but
   nothing reads it, and the spec allows no stored money besides opening
   balances. Exports send `0`.
6. **Endpoints the spec implies but doesn't list:**
   - purchase resubmit (`purchases/{id}/resubmit`, plus the app's per-piece `items/{id}/resubmit`);
   - cart holds (`items/{id}/reserve`);
   - `auth/staff`, `me/pin` and `users/{id}/pin`, for PIN sign-in;
   - `receipts/{id}/pdf` and `…/text`.
7. **Rules the app enforces in its screens are enforced on the server too:**
   - a release or loan receipt needs its proof photo;
   - a partition needs a verified lot;
   - a disposal needs a received loan with a balance left, from the same branch
     or company-wide, and its capital must match the pieces;
   - a receipt is issued only once cash is released or payment received.
8. **Who receives loan cash, and who corrects manual cash entries, follows the
   app.** Receiving loan cash is Admin only. Editing and deleting manual cash
   entries is Cashier and Admin, the app's `canMoveCash`.
9. **Import releases abandoned cart holds.** A piece marked reserved that no
   open order holds goes back on sale, which is what the app does every time
   it loads its file. The import report lists each one.
10. **Purchase receipts show each lot's original figures** in both the PDF and
    the text. The app's PDF used the lot's current figures and its text used
    the original ones; the original is what was paid.

## Deploying

The shop runs this on one machine with Docker Compose: Postgres, the web
process behind nginx, and a sender that retries notifications. Photos,
receipt PDFs and the database live in named volumes, so updating the server
never touches the shop's records.

```bash
cp .env.production.example .env.production   # then fill it in — see below
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml logs -f web
```

The web container runs `migrate` and `collectstatic` on every start, so an
update is `git pull` and `up -d --build`.

**The first time only**, create the shop's first Admin, then sign in on a
phone as them:

```bash
docker compose -f docker-compose.prod.yml run --rm web     python manage.py bootstrap_admin --id USR-AJ01 --name "Arnel Javier" --pin 1234
```

Use `seed_demo` instead if this is a demo server; never on the shop's own.

### What goes in `.env.production`

Everything is in `.env.production.example`. The ones that matter:

| Variable | Why |
| --- | --- |
| `DJANGO_SECRET_KEY` | Signs the phones' tokens. Changing it signs everyone out. `python -c "import secrets; print(secrets.token_urlsafe(50))"` |
| `DJANGO_DEBUG=0` | Never 1 on a server: debug pages show the settings and the SQL. |
| `DJANGO_ALLOWED_HOSTS` | Every address a phone uses to reach this server — the domain, or the LAN IP. |
| `POSTGRES_PASSWORD` | Compose refuses to start without it. |
| `FIREBASE_CREDENTIALS_HOST_FILE` | The service-account key's path **on the host**. Compose mounts it read-only; it is never in the image or the repo. Leave empty and notifications are simply off. |

### On Render (or another platform that just runs the image)

The image needs no start command: it migrates, collects static and serves on
`$PORT` by itself. Set the service to **Docker**, branch `main`, root
directory `backend/`.

Create a **PostgreSQL** instance first and use its *internal* connection
string. Then set these environment variables on the web service:

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | the Postgres internal URL |
| `DJANGO_SECRET_KEY` | `python -c "import secrets; print(secrets.token_urlsafe(50))"` |
| `DJANGO_DEBUG` | `0` |
| `WEB_CONCURRENCY` | `2` on a small instance — three workers do not fit in 512 MB |
| `FIREBASE_CREDENTIALS_FILE` | path to a Secret File holding the service-account key, or leave unset for no notifications |
| `FIREBASE_PROJECT_ID` | `aj-jeweler-notification` |

`DJANGO_ALLOWED_HOSTS` and the CSRF origin are worked out from the hostname
the platform assigns, and HTTPS redirect and HSTS turn themselves on there.
Then put the staff on it; see [Adding staff to a running server](#adding-staff-to-a-running-server).

Two things to settle before the shop depends on it:

- **Photos and receipts must survive a deploy.** The container's filesystem
  does not: every deploy and every restart takes `media/` with it, and a
  released purchase loses the photo of the cash being handed over — which is
  the point of taking it. Set `CLOUDINARY_URL` (see [Photos and receipts on
  Cloudinary](#photos-and-receipts-on-cloudinary)); that also makes a free
  instance usable, since it needs no disk.
- **A free instance sleeps.** After about fifteen minutes idle the next
  request waits roughly a minute while it wakes. The app is offline-first, so
  the counter keeps working and the queue goes up when the server answers —
  but a notification waits that long too, and the phone will show "offline"
  in the meantime.

The notification retry loop is a second service (`PUSH_DELIVERY=command`
running `send_notifications` on a schedule). Without it, anything the web
process could not send stays pending. Compose runs it as the `notifier`
service; on a platform, make it a cron job or a background worker.

### Deploying the Supervisor and Superuser roles

**Do this in order.** Every phone reads a user's role by its exact name, and
the app release before this one does not know `supervisor` or `superuser`. A
phone that receives a person with either role fails to sign in or sync, and
the sign-in list (`/auth/staff`) and every snapshot carry everyone's role.

1. Deploy the server. As long as nobody holds a new role, it sends only the
   four old role names, so phones carry on working. Apply the migrations:
   they only widen the allowed role values. No data changes.
2. From this moment **an Admin cannot sign in to the Django admin site.**
   Nobody can until someone is a Superuser. If you need it before the app is
   out, set `DJANGO_ADMIN_SITE_ROLES=superuser,admin` on the server for that
   window, and remove it afterwards.
3. Install the app release that knows the new roles on every phone.
4. Then, and only then, run the one command this change requires, or nobody
   can reach the admin site:

   ```bash
   DATABASE_URL="<external database url>" python manage.py set_role --id USR-AJ01 --role superuser
   ```

   It is idempotent and logged, and refuses an unknown id or role. Create
   Supervisors the same way (`set_role --id … --role supervisor --branch
   kidapawan`), or with `create_staff`, or from the app.

### Adding staff to a running server

The first setup and every later hire use the same command, run from a machine
that can reach the database:

```bash
cp staff.example.json staff.json        # fill in names, roles, branches, optional PINs
DATABASE_URL="<external database url>" python manage.py create_staff --file staff.json           # dry run
DATABASE_URL="<external database url>" python manage.py create_staff --file staff.json --apply
curl -s https://<your-server>/api/v1/auth/staff   # every new person should appear, with has_pin: true
```

- **The file.** `staff.json` is a list of `{id, name, role, home_branch,
  contact_number, pin}`. `home_branch` is left out for an Admin and required
  for everyone else; `contact_number` and `pin` are optional, and the PIN
  defaults to `1234`. The file is git-ignored because it holds PINs. Delete it
  once the PINs are handed over.
- **Dry run by default.** It does the whole job and rolls it back, so it shows
  exactly what `--apply` would do.
- **Never changes anyone already there.** Someone already on the server is
  reported "already there" and left alone, with no rename and no new PIN.
  Running it twice is the check that it worked. Reset a PIN from the admin site
  or `POST /users/{id}/pin`.
- **Bad rows are skipped, not fatal.** An unknown role, an Admin with a
  branch, branch staff without one, a short PIN or a name already taken is
  reported for that row. The rest are created, and the command exits non-zero.
- **Every creation is logged.** People are created through the same service
  as the API, one log row each. On an empty server the owner (`USR-AJ01`,
  role `admin`) is created first, naming themself; everyone else is then
  added by them. Keep `USR-AJ01` for the owner, so a later `/sync/import`
  recognises them.
- **PINs on screen once.** It prints who is on the server now, then each new
  person's PIN once. Hand those over in person and have everyone change theirs
  on the phone. The server does not force that change.

### Desktop app (the Flutter web build)

The server also serves the back-office desktop app, the Flutter web build that
installs from the browser onto the shop's PC, from the **same origin** as the
API:

```
/                       the app (index.html)
/main.dart.js, /assets/…  its files
/cash, /purchases/…     index.html again: the app owns its routes, so a reload on any page works
/api/v1/  /admin/  /media/  /static/     never the app
```

On the same origin the app calls `/api/v1/` on its own host, so there is no
CORS to configure and no server address baked into the build.

**`WEB_APP_ROOT`** is the folder holding the build's `index.html`. The Docker
image sets it to `/app/webapp`, which is `backend/webapp/` in the repository.
When it is unset or holds no `index.html`, `/` says no desktop app is deployed
and the API works exactly as before. A missing file (`/assets/…`,
`/canvaskit/…`, anything with an extension) is a 404, never the app.

**Deploying a new build.** The build is committed to `backend/webapp/`. Render
builds the image from the repository, where `mobile/build/` is git-ignored and
Flutter is never installed (it would add a 1 GB SDK to the image), so a
committed copy is the simplest way to get the files there:

```bash
cd mobile && flutter build web --release
cd ../backend && python manage.py publish_webapp      # copies ../mobile/build/web into webapp/
git add webapp && git commit -m "Desktop app: <what changed>" && git push
```

- **What `publish_webapp` copies.** It leaves out debug `.symbols` files.
  It also leaves out `canvaskit/` (37 MB of the 44 MB build) unless the build
  loads CanvasKit from its own host. By default Flutter loads it from Google's
  CDN, pinned to the engine version, and never reads the local copy. So a
  release is about 7 MB in git.
- **What the image build does.** It gzips the files once; `main.dart.js` goes
  from 4.7 MB to 1.4 MB over the wire.
- **What a new build doesn't need.** No migration, no restart beyond the
  normal deploy, and no change to the shop's data. If git history ever grows
  too large, the next step is a CI job that builds the app and publishes it;
  nothing on the server side would change.

**Caching, and why it matters.** Flutter's web build does not put content
hashes in its file names: `main.dart.js`, `assets/AssetManifest.bin` and
`canvaskit.wasm` keep their names from one build to the next. Caching them
"hard" would let a shop PC run last week's app against this week's API. So:

- `index.html`, `flutter_bootstrap.js`, `flutter_service_worker.js`,
  `version.json` and `manifest.json` are `Cache-Control: no-store`. They decide
  which version runs, and a stale service worker would stop the installed app
  from ever updating.
- Every other file is `no-cache`: the browser keeps it but checks each time,
  and gets a 304 Not Modified unless a new build changed it.

### Backups

The records are in the `pgdata` volume and the photos in `media`. Both need
backing up — a dump alone loses the photos:

```bash
docker compose -f docker-compose.prod.yml exec -T db     pg_dump -U aj aj_jeweler | gzip > aj-$(date +%F).sql.gz
docker run --rm -v aj_media:/m -v "$PWD:/out" alpine     tar czf /out/aj-media-$(date +%F).tar.gz -C /m .
```

### Over the open internet

As configured, nginx serves plain HTTP and `/media/` is readable by anyone
who can reach it — fine on the shop's own network, not on the public
internet. Before exposing it: put TLS in front (Caddy or nginx with Let's
Encrypt), set `DJANGO_CSRF_TRUSTED_ORIGINS`, and turn on
`SECURE_SSL_REDIRECT` and `SECURE_HSTS_SECONDS`. `python manage.py check
--deploy` lists what is still missing.

### Photos and receipts on Cloudinary

With `CLOUDINARY_URL` set, every photo (customers, pieces, cash-release and
loan proofs, disposal settlements) and every receipt PDF is stored on
Cloudinary instead of local disk. Without it, files stay in `MEDIA_ROOT`.
Tests always use local disk.

```
CLOUDINARY_URL=cloudinary://<api_key>:<api_secret>@<cloud_name>   # Cloudinary console > Settings > API Keys
CLOUDINARY_FOLDER=aj-jeweler        # production; use aj-jeweler-dev on a development machine
```

- **Private assets.** Assets are uploaded as *authenticated*: they can be
  fetched only through a URL signed with the account's secret. The API hands
  those out as `photo_url` and in receipt links, so customer faces and counted
  cash are never public files.
- **Where they live.** Photos are image assets. Receipt PDFs are raw assets,
  so they arrive exactly as issued; Cloudinary blocks PDF delivery as images
  on many accounts.
- **Names.** The database keeps Django's file name. The Cloudinary public id
  is that name under `CLOUDINARY_FOLDER` (see the folder layout below).
- **Nothing else changes.** Snapshots that carry photos as base64, the receipt
  PDF download and the admin's thumbnails all read through Django's storage
  API.
- **Backups.** Assets live on Cloudinary, so the `media` volume is no longer
  part of the backup.
- **Replaced photos.** When a photo is replaced, the old asset stays on
  Cloudinary (nothing deletes evidence automatically).

### Folder layout

Files are organised by **kind, then branch, then year and month**. Someone can
then browse "the Kidapawan release proofs from October" in the Cloudinary
Media Library without reading through thousands of ids:

```
aj-jeweler/                                   CLOUDINARY_FOLDER (MEDIA_ROOT on local disk: same layout)
  customers/shop/2026/09/CUS005-20260912110000000003.jpg
  items/davao/2026/10/L2M8XK-20261018090501000001.jpg
  release-proofs/kidapawan/2026/10/A3T8QD-20261018143022123456.jpg
  loan-proofs/shop/2026/10/P2N9KM-20261008102527000004.jpg
  disposals/kidapawan/2026/10/F6H3ZN-20261003102527000005.jpg
  receipts/kidapawan/2026/10/S4M2HQ-20261016103527000006.pdf
```

- **Branch:** `kidapawan` or `davao`. A record with no branch (a customer, a
  company-wide loan), or an unexpected one, goes under `shop`. Working out the
  folder never fails an upload.
- **Month:** the record's own date. That is the purchase date for pieces
  (a photo added later still files with the piece), the release time for
  release proofs, the receipt time for loan proofs, the settlement date for
  disposals, and the issue time for receipts. Customer photos use the time of
  upload, because a person's photo is retaken whenever.
  `shop/media_paths.py` holds the rules.
- **File names:** `<record-id>-<timestamp>.<ext>`, with ids only. A path
  travels in URLs and shows in the Media Library, so it never carries a name,
  number or address.

**Old files stay where they were.** Rows saved before this layout keep their
flat paths (`items/A3T8QD-….jpg`) and still open, download and delete. Only
new uploads use the folders. To move the old ones:

```bash
python manage.py reorganise_media                    # dry run (default): what would move, per kind
python manage.py reorganise_media --kind items       # one kind at a time
python manage.py reorganise_media --apply            # really move
```

It works one record at a time: it copies the file to the new path, points the
row at the copy, and deletes the old asset only after that is saved. It skips
anything already in place, so it can be stopped and run again. A file it
cannot read is reported and left alone. Phones notice nothing, because
snapshots still carry the same bytes as base64.

### Other notes

- Without Cloudinary, `/media/` is served by Django only when `DEBUG` is on;
  in production nginx serves it.

## Layout

```
config/            settings, root urls
accounts/          the staff model, PIN sign-in, staff rules (services.py) and endpoints (api.py)
notifications/     devices, the push outbox, the FCM client, who-is-told rules (events.py), commands
config/admin_site.py   the admin site: PIN sign-in, PIN change;  */admin.py  what each model shows
shop/
  models.py        the schema
  enums.py         the app's enum names and labels
  ids.py           6-character ids and the shared registry
  services/        every rule and state change, one function per mutation
  api/             serializers, inputs, viewsets, urls
  snapshot.py      the phone's file format (writing)
  services/importer.py   the phone's file format (reading) — /sync/import
  services/sync.py       snapshot and changes feed;  api/views_sync.py  push
  demo.py          the app's seed data, ported
  signals.py       the sync change feed
  migrations/      0001 schema, 0002 branches + append-only triggers
  tests/           test_a … test_f, one file per build stage
tools/app_snapshot_dump/   Dart harness: dump the app's snapshot / restore the server's
```

The spec's nine acceptance checks:

| # | Test |
| --- | --- |
| 1 | `test_b_purchases_items.py` — `test_a_purchase_moves_no_cash_until_release_then_exactly_one_entry_against_purchase_cash` |
| 2 | `test_c_sales_cash.py` — `test_a_split_payment_puts_cash_in_sales_and_the_transfer_in_bank_and_leaves_purchase_alone` |
| 3 | `test_c_sales_cash.py` — `test_each_branch_balance_is_always_opening_plus_its_own_entries` |
| 4 | `test_b_purchases_items.py` — `test_a_partition_never_draws_more_than_the_lot_has_left`, `test_deleting_a_partition_restores_the_lot_exactly` |
| 5 | `test_d_commitments_disposal.py` — `test_disposal_marks_items_disposed_moves_no_cash_and_draws_down_the_commitment` |
| 6 | `test_b_purchases_items.py` — `test_silver_with_a_gold_karat_or_gold_with_a_silver_purity_is_refused` (plus a database-level test) |
| 7 | `test_c_sales_cash.py` — `test_a_linked_entry_cannot_be_edited_or_deleted_but_a_manual_one_can`, `test_both_halves_of_a_transfer_move_together` |
| 8 | `test_a_auth_users_branches.py` — `test_the_last_active_admin_cannot_be_demoted_deactivated_or_deleted` |
| 9 | `test_e_rates_receipts_logs.py` — `test_every_mutating_endpoint`: 37 calls, one per mutating endpoint (the import's single log row is checked in `test_f_import_sync.py`) |
