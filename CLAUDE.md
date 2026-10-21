# Working in this repository

Two agents work here, each owning one folder, and both push to `main`.

| Folder | Owner | Deploys |
| --- | --- | --- |
| `backend/` | the backend agent | Render redeploys on any change under `backend/` |
| `mobile/` | the app agent | nothing — the app reaches the server only when published (see below) |

Stay in your folder. If something you need lives in the other one, say so and
stop rather than reaching across.

## Pushing

Push your own work when it is done and your tests pass. A push under
`backend/` **deploys to the live shop**, so run the suite first — a red test
that reaches `main` is on the server a few minutes later.

Before pushing, always:

```bash
git pull --rebase origin main
```

The other agent may have pushed since you started. Rebase, re-run your
tests, then push.

## Three things nobody may do

1. **`backend/webapp/` belongs to the app agent.** It is the built Flutter
   app, written by `manage.py publish_webapp`. Never edit, rebuild or commit
   it from the backend side; a stale copy there silently serves the shop an
   old app.
2. **No secrets, ever.** `.env`, `.env.production`, `staff.json`, the
   Firebase key, the Android keystore, PINs, database URLs — none of it goes
   in a commit, a file in the repo, or a summary. `.gitignore` covers the
   known ones; think before adding a new kind.
3. **Every write goes through `shop/services`.** The API, the back office at
   `/administrator/`, and any management command all call the same
   functions, so one set of rules holds: the same refusals, the same log
   entry naming whoever acted, and the same sync row that tells the phones
   something moved. Never write through the ORM directly.

## What the shop runs

- **Android app** — the counter. Offline-first; the APK is installed by hand.
- **PWA at `/`** — the same Flutter code, for iPhone staff (there is no iOS
  build) and for anyone working at a desktop. Served from `backend/webapp/`.
- **`/administrator/`** — the back office, Django pages. **Superuser only**;
  the owner's Admin account is refused on purpose.
- **`/admin/`** — Django's own admin, Superuser only, raw and ruleless. For
  emergencies, not for running the shop.

## Facts worth not rediscovering

- A role says who is **notified**, not who may act. Counter work — encoding a
  purchase, building an order, releasing cash, taking payment — is open to
  every role, because when the Cashier is out the shop still has to serve the
  customer. What is restricted is running a branch: the cash ledger,
  corrections, disposal, loans, staff.
- Money is whole centavos (`int`), weight is grams to three decimals, and no
  balance is ever stored — every total is derived.
- The phones read `/sync/snapshot` and `/sync/changes`, which carry photos as
  **base64**. Do not switch them to URLs without changing the app first; the
  app reads nothing else.
- Phones parse roles by exact string but fall back to the most limited role,
  so adding a role no longer breaks an un-updated phone. Adding an enum value
  anywhere else is not automatically safe.
