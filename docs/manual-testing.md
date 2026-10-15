# Manual API testing with Postman

Reference for driving the Attendance system by hand once the Docker Compose
stack is up. Every status code below was verified against the running stack.

## Before you start

```bash
cd attendance-project-common
docker compose up -d
docker compose ps          # all four must show Up (healthy)
```

| Service | From your Mac |
| --- | --- |
| Accounting | `http://localhost:8081` |
| TimeTracking | `http://localhost:8082` |
| Postgres | `localhost:5432` (user `postgres`, db `attendance`) |
| Kafka | `localhost:9094` |

Quick sanity check before blaming Postman:

```
GET http://localhost:8081/actuator/health   ->  {"status":"UP"}
GET http://localhost:8082/actuator/health   ->  {"status":"UP"}
```

## Two test users

Which user you log in as changes what you are allowed to do. Keep both handy.

| | Super admin | Normal user |
| --- | --- | --- |
| idUser | `123456789` | `555000111` |
| password | `admin` | `pass1234` |
| tenantId | `0` | `1` |
| roles | ADMINISTRATOR, MODERATOR, USER | USER |
| created by | seeded at startup by `AttendanceAccountingApplication` | registered manually (see below) |

The admin is seeded automatically on first boot. The normal user must be
registered once — `POST /account/user`, see the Accounting table.

---

## Step 1 — Log in and capture the token

**`POST http://localhost:8081/account/login`**
Header: `Content-Type: application/json`

```json
{ "idUser": 123456789, "password": "admin", "tenantId": 0 }
```

Response:

```json
{
  "token": "eyJhbGciOiJIUzI1NiJ9...",
  "tokenType": "Bearer",
  "expiresIn": 3600,
  "profile": { "idUser": 123456789, "firstName": "Super", "lastName": "Admin", "roles": [...] }
}
```

### Postman setup (do this once)

1. On the **collection** (not the request): *Authorization → Type: Bearer Token →
   Token: `{{token}}`*. Every request then inherits it.
2. On the login request: *Scripts → Post-response*, paste:

```js
pm.collectionVariables.set("token", pm.response.json().token);
```

Now re-running login refreshes the token everywhere. It expires after **3600s**
(`expiresIn`), so if working requests suddenly return 401, log in again.

---

## Step 2 — Accounting endpoints

Base `http://localhost:8081`. All need the bearer token except where noted.

| Method | Path | Notes |
| --- | --- | --- |
| POST | `/account/login` | **public** |
| POST | `/account/user` | **public**, returns **201** |
| GET | `/account/users?tenantId=0` | any authenticated user |
| GET | `/account/tenant/{tenantId}/userId/{idUser}` | any authenticated user |
| DELETE | `/account/user/{idUser}` | ADMINISTRATOR |
| POST | `/account/user/{idUser}/role/{role}` | ADMINISTRATOR |
| DELETE | `/account/user/{idUser}/role/{role}` | ADMINISTRATOR |
| PUT | `/account/user/password/{idUser}` | self, or ADMINISTRATOR |

Registration body (`POST /account/user`):

```json
{
  "idUser": 555000111,
  "password": "pass1234",
  "firstName": "Test",
  "lastName": "User",
  "email": "test@example.com",
  "tenantId": 1
}
```

---

## Step 3 — TimeTracking endpoints

Base `http://localhost:8082`. **Every** endpoint needs a token.

This is the integration proof: the token was minted by Accounting on port 8081
and is accepted here on 8082, because both containers were given the same
`JWT_SECRET` from `.env`.

| Method | Path | Role |
| --- | --- | --- |
| PUT | `/attendance/openSession/tenant/{tenantId}/userId/{idUser}` | ADMIN **or self** |
| PUT | `/attendance/closeSession/tenant/{tenantId}/userId/{idUser}` | ADMIN **or self** |
| POST | `/attendance/sessionChange/tenant/{tenantId}` | ADMINISTRATOR |
| DELETE | `/attendance/sessionRemove/tenant/{tenantId}/session/{id}` | ADMINISTRATOR |
| GET | `/attendance/sessions/tenant/{tenantId}` | ADMIN **or self** |
| GET | `/attendance/check/tenant/{tenantId}/user/{idUser}` | ADMIN **or self** |
| POST | `/attendance/addLeaveDays/tenant/{tenantId}/userId/{idUser}` | ADMIN **or self** |
| GET | `/attendance/leaveDays/tenant/{tenantId}/userId/{idUser}` | ADMIN **or self** |
| POST | `/attendance/leaveDayChange/tenant/{tenantId}` | ADMINISTRATOR |
| DELETE | `/attendance/leaveDayRemove/tenant/{tenantId}/leaveDay/{id}` | ADMINISTRATOR |
| GET | `/attendance/workdays/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/minutes/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/overtimeMinutes/tenant/{tenantId}` | ADMINISTRATOR |
| POST | `/attendance/statistic/tenant/{tenantId}` | ADMINISTRATOR |

Reading and recording your **own** data is self-service; correcting or deleting
a record is always ADMINISTRATOR. That asymmetry is deliberate: people report
their own time, only an administrator rewrites history.

### Query parameters are required

`idUser`, `startDate` and `endDate` are **required** on the GET endpoints.
Omitting `idUser` returns **400**, not 200 with everything:

```
GET /attendance/sessions/tenant/0?startDate=2026-09-01&endDate=2026-09-30&idUser=123456789
```

Date format is ISO: `2026-09-01`. Date-times use `2026-09-22T09:00:00Z`.

### Open / close a session

**`PUT /attendance/openSession/tenant/1/userId/555000111`**

```json
{ "openSessionDate": "2026-09-22T09:00:00Z", "workDate": "2026-09-22" }
```

Returns the created record:

```json
{ "id": 1, "userId": 555000111, "tenantId": 1,
  "openSessionDate": "2026-09-22T09:00:00Z", "closeSessionDate": null,
  "workDate": "2026-09-22" }
```

Then close it with the same shape plus `closeSessionDate`.

Opening a session again on the same date does **not** overwrite the first one —
it records a second period, which is how a break is logged. A date can therefore
hold several session rows.

### Leave days

A leave day is **one row per date**, carrying a vacation portion, a sick
portion, or both. Half sick plus half vacation on the same date is a single
record, not two. Portions are `1.0` for a full day and `0.5` for half, and the
two together may never exceed `1.0`.

**`POST /attendance/addLeaveDays/tenant/1/userId/555000111`**

```json
{ "days": [ { "date": "2026-09-22", "vacationAmount": 0.5, "sickAmount": 0.5 } ] }
```

Returns `200` with no body. Reporting the **same date again updates** that
record rather than adding a second one, and a portion you leave out keeps its
stored value:

```json
{ "days": [ { "date": "2026-09-22", "sickAmount": 1.0 } ] }
```

That one is refused with **400** — the stored vacation of `0.5` plus the
requested sick `1.0` exceeds a full day. The rule is applied to the *resulting*
record, not just to what you sent.

**`GET /attendance/leaveDays/tenant/1/userId/555000111?startDate=2026-09-01&endDate=2026-09-30`**

```json
[ { "id": 1, "userId": 555000111, "tenantId": 1, "date": "2026-09-22",
    "vacationAmount": 0.5, "sickAmount": 0.5 } ]
```

The `id` is what the edit and remove endpoints address.

**`POST /attendance/leaveDayChange/tenant/1`** — administrator only. Only the
properties you send are changed; `0` clears a portion:

```json
{ "id": 1, "vacationAmount": 1.0, "sickAmount": 0 }
```

Returns the updated record. Clearing *both* portions is **400** — an empty
record is a removal, so use `leaveDayRemove`. Moving a record onto a date that
already has one is **400** as well.

**`DELETE /attendance/leaveDayRemove/tenant/1/leaveDay/1`** — administrator
only. Returns the removed record, so you can report what went.

---

## Step 4 — Verified authorization behaviour

Worth reproducing by hand; these are the cases that explain the security model.

| # | Request | Result |
| --- | --- | --- |
| 1 | Any TimeTracking call **without** `Authorization` header | **401** |
| 2 | Any TimeTracking call with a **malformed** token | **401** |
| 3 | Admin token, valid params | **200** |
| 4 | Admin token, missing `idUser` | **400** (auth passed, validation failed) |
| 5 | Normal user, `openSession` for **self** in **own** tenant | **200** |
| 6 | Normal user, `openSession` in **another** tenant | **403** |
| 7 | Normal user, `GET /attendance/sessions` with **own** `idUser` | **200** |
| 8 | Normal user, `GET /attendance/sessions` with a **colleague's** `idUser` | **403** |
| 9 | Normal user, `GET /attendance/workdays` (admin-only) | **403** |
| 10 | Normal user, `addLeaveDays` for **self** | **200** |
| 11 | Normal user, `leaveDayChange` or `leaveDayRemove` | **403** |

Two things to take from this:

- **400 means the token worked.** A rejected token stops at 401 and never
  reaches parameter binding. Case 4 is a *success* for the integration.
- **Admins bypass the tenant check.** `TenantInterceptor` short-circuits on
  `ROLE_ADMINISTRATOR`, so the admin token will *not* produce 403 on a foreign
  tenant. Use the normal user (case 6) to see tenant isolation working.
  Cases 6 and 9 are both 403 but from different layers — `TenantInterceptor`
  vs `@PreAuthorize`.
- **"Admin-only" is per endpoint, not per service.** Cases 7 and 8 are the same
  endpoint and the same token, differing only in the `idUser` asked for: reading
  your own row is self-service, reading a colleague's is not. Case 11 is the
  other half of the rule — a person may record their own leave (case 10) but
  only an administrator may correct or delete it.

---

## Step 5 — Watch the Kafka event

`POST /attendance/statistic/tenant/{tenantId}` computes monthly statistics and,
when `report=true`, publishes to `att.month-statistic`.

Open a consumer in a terminal first:

```bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic att.month-statistic --from-beginning
```

Then fire the request from Postman and watch the event appear. Ctrl+C to stop.

Useful Kafka commands:

```bash
# list topics
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# describe partitions
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --describe --topic att.month-statistic

# anything that failed validation lands here
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic att.month-statistic.dlq --from-beginning
```

`att.user-statistic-ai-analysis` only appears **after** the first publish —
producer bindings are created lazily by `StreamBridge` on first send.

---

## Inspecting the database

One database `attendance`, one schema per service. Connect DBeaver as the
**superuser** to see across both:

```
Host: localhost   Port: 5432   Database: attendance
User: postgres    Password: from .env (POSTGRES_PASSWORD)
```

In the connection settings, PostgreSQL tab, tick **"Show all databases"**.

| Schema | Tables |
| --- | --- |
| `accounting` | `users`, `user_roles`, `att_ac_tenant_mapping` |
| `timetracking` | `att_work_sessions`, `att_month_statistic`, `att_user_leave_days` |

`att_user_leave_days` holds **one row per date** — `id` (identity primary key),
`tenant_id`, `user_id`, `leave_date`, `vacation_amount`, `sick_amount`, with a
unique constraint on `(tenant_id, user_id, leave_date)`. A `NULL` amount means
that kind of leave was not taken. If you still see `leave_type` and `amount`
columns, the database predates that change: Hibernate's `ddl-auto=update` adds
columns but cannot replace a primary key, so the table has to be dropped and
left to be recreated on the next start.

The services themselves connect as `accounting_user` / `timetracking_user`,
which are granted rights **only on their own schema** — each service physically
cannot read the other's tables. Note that PostgreSQL cannot join across
*databases*, but these are schemas in one database, so cross-schema joins work
fine as `postgres`.

To put known attendance rows into `timetracking` so the statistic endpoints have
something to compute, see **`seeding-test-data.md`** — plain inserts plus a
reusable generator function, with the `kubectl` / `docker compose` commands for
applying them.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| 401 on everything, login included | check `docker compose ps`; Accounting not healthy |
| 401 on TimeTracking only, login works | the two containers have different `JWT_SECRET` values |
| 401 after it was working | token expired (3600s) — log in again |
| 400 with `MissingServletRequestParameter` | a required query param is absent |
| 403 | wrong role, or wrong tenant for a non-admin |
| 400 on `addLeaveDays` / `leaveDayChange` | the date's vacation + sick would exceed one day, both portions are zero, or the date is listed twice |
| 500 on any leave-day call, `leave_type` in the error | the database still has the old leave-day table — see **Inspecting the database** |
| Connection refused | stack not running — `docker compose up -d` |

```bash
docker compose logs -f accounting
docker compose logs -f timetracking

# confirm both containers share the same secret
docker compose exec accounting   printenv ATTENDANCE_ACCOUNTING_JWT_SECRET
docker compose exec timetracking printenv ATTENDANCE_ACCOUNTING_JWT_SECRET
```
