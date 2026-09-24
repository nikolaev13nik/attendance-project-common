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
| POST | `/attendance/addLeaveDays/tenant/{tenantId}/userId/{idUser}` | ADMINISTRATOR |
| GET | `/attendance/sessions/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/workdays/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/minutes/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/overtimeMinutes/tenant/{tenantId}` | ADMINISTRATOR |
| GET | `/attendance/check/tenant/{tenantId}/user/{idUser}` | ADMINISTRATOR |
| POST | `/attendance/statistic/tenant/{tenantId}` | ADMINISTRATOR |
| DELETE | `/attendance/sessionRemove/tenant/{tenantId}/session/{id}` | ADMINISTRATOR |

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
| 7 | Normal user, `GET /attendance/sessions` (admin-only) | **403** |

Two things to take from this:

- **400 means the token worked.** A rejected token stops at 401 and never
  reaches parameter binding. Case 4 is a *success* for the integration.
- **Admins bypass the tenant check.** `TenantInterceptor` short-circuits on
  `ROLE_ADMINISTRATOR`, so the admin token will *not* produce 403 on a foreign
  tenant. Use the normal user (case 6) to see tenant isolation working.
  Cases 6 and 7 are both 403 but from different layers — `TenantInterceptor`
  vs `@PreAuthorize`.

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
| `accounting` | `users`, `user_roles` |
| `timetracking` | `att_work_sessions`, `att_month_statistic`, `att_user_leave_days` |

The services themselves connect as `accounting_user` / `timetracking_user`,
which are granted rights **only on their own schema** — each service physically
cannot read the other's tables. Note that PostgreSQL cannot join across
*databases*, but these are schemas in one database, so cross-schema joins work
fine as `postgres`.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| 401 on everything, login included | check `docker compose ps`; Accounting not healthy |
| 401 on TimeTracking only, login works | the two containers have different `JWT_SECRET` values |
| 401 after it was working | token expired (3600s) — log in again |
| 400 with `MissingServletRequestParameter` | a required query param is absent |
| 403 | wrong role, or wrong tenant for a non-admin |
| Connection refused | stack not running — `docker compose up -d` |

```bash
docker compose logs -f accounting
docker compose logs -f timetracking

# confirm both containers share the same secret
docker compose exec accounting   printenv ATTENDANCE_ACCOUNTING_JWT_SECRET
docker compose exec timetracking printenv ATTENDANCE_ACCOUNTING_JWT_SECRET
```
