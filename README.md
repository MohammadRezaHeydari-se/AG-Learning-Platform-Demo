# AG Learning Platform Demo

A small, self-contained Django portfolio project that demonstrates authentication,
role-based access control, course/lesson permissions and a passing test suite with
CI. It is intentionally minimal so it can be read, run and evaluated in a few
minutes.

> **Local development demo only.** This is **not** the production
> Automationsguiden application and is **not production-ready**. It contains no
> private production source code, customer data, real credentials or deployment
> secrets. Everything is fictional demo data.

---

## Purpose

Show a clean, readable example of:

- Django's built-in authentication (login/logout, sessions, password hashing).
- The three roles **Admin**, **Teacher** and **Student** using Django users and
  groups.
- Server-side permission checks: only authorized users can read course lessons.
- Idempotent, environment-driven demo seeding.
- A reproducible local setup with Docker Compose and a clear test/CI story.

---

## Architecture

```
config/                 Django project settings, root URLconf, WSGI
courses/
  models.py             Course, Enrollment, Lesson
  roles.py              Admin / Teacher / Student helpers over Django groups
  permissions.py        Course/lesson access rules (single source of truth)
  views.py              Public homepage, dashboards, lesson view, JSON API
  urls.py               URL routing
  admin.py              Django admin registration
  templates/            Server-rendered HTML
  management/commands/
    seed_demo.py        Idempotent fictional demo data
  migrations/           Database schema (0001, 0002)
  tests.py              Roles, auth, permissions, lessons, seeding
compose.yaml            Local PostgreSQL-free SQLite stack with named volume
Dockerfile              python:3.12-slim local image
requirements.txt        Django (only dependency)
.github/workflows/ci.yml GitHub Actions test pipeline
```

Stack: **Django 5.2**, **SQLite**, server-rendered templates. No JavaScript
build step and no frontend framework.

### Roles and capabilities

| Role | How it is defined | Can do |
| --- | --- | --- |
| **Admin** | Django superuser (`is_superuser`) | Full Django admin; sees and opens every course and all lessons, including unpublished. |
| **Teacher** | Member of the `Teacher` group | Dashboard lists courses assigned to them; can open those courses and see all their lessons (published and unpublished). |
| **Student** | Member of the `Student` group | Dashboard lists enrolled courses; can open them and see **published** lessons only. |
| Anonymous | Not signed in | Can view the public homepage and the read-only courses API. Everything else redirects to login. |

Access rules live in `courses/permissions.py:15` (`user_can_access_course`) and
`courses/permissions.py:23` (`visible_lessons`); the views enforce them and return
`403 Forbidden` for unauthorized access.

---

## Prerequisites

- **Python 3.12+** (for the local virtualenv workflow), or
- **Docker** with the Compose plugin (for the container workflow).
- No database server is required; the demo uses SQLite in a local file/volume.

---

## Getting started with Docker (recommended)

This is the fastest way for an evaluator to reproduce the environment.

```bash
git clone https://github.com/MohammadRezaHeydari-se/AG-Learning-Platform-Demo.git
cd AG-Learning-Platform-Demo
docker compose up --build -d
docker compose logs -f web      # follow startup; press Ctrl+C to stop following
```

On startup the container automatically runs:

```bash
python manage.py migrate        # create/update the schema
python manage.py seed_demo      # create fictional demo users/courses/lessons
python manage.py runserver 0.0.0.0:8000
```

Open **http://127.0.0.1:8000/**. The service is published only on
`127.0.0.1`, so it is not reachable from other machines.

To override the demo passwords or secret key, copy the example env file before
starting (Compose reads `.env` automatically):

```bash
cp .env.example .env
# edit .env, then:
docker compose up --build -d
```

### Stop / restart

```bash
docker compose stop            # stop the container, keep data
docker compose start           # start again with the same data
docker compose down            # remove the container, keep the named volume
docker compose down -v         # DANGER: also deletes demo data (fresh start)
```

Data lives in the named Docker volume `demo_data` (mounted at `/app/data`),
so `stop`, `start`, `restart` and `down` preserve it.

---

## Getting started without Docker

```bash
git clone https://github.com/MohammadRezaHeydari-se/AG-Learning-Platform-Demo.git
cd AG-Learning-Platform-Demo

python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env               # development-only values
python manage.py migrate
python manage.py seed_demo
python manage.py runserver
```

Open **http://127.0.0.1:8000/**.

---

## Local URLs

| URL | What it is | Access |
| --- | --- | --- |
| `/` | Public homepage listing published courses | Anyone |
| `/login/` | Login form | Anyone |
| `/logout/` | Logout (POST only) | Signed-in users |
| `/dashboard/` | Role-based dashboard | Signed-in users |
| `/courses/<id>/lessons/` | Lessons for a course | Admin, assigned teacher, or enrolled student |
| `/api/courses/` | JSON list of published courses | Anyone |
| `/admin/` | Django admin (manage courses, lessons, users) | Admins only |

---

## Demo accounts and password setup

`seed_demo` creates three fictional accounts. Passwords are **only** set when an
account is first created, so restarting the stack never resets a password you
changed. Defaults (used when the environment variable is unset) are
development-only:

| Username | Role | Password env var | Fallback (dev only) |
| --- | --- | --- | --- |
| `demo_admin` | Admin | `DEMO_ADMIN_PASSWORD` | `demo-admin-pass` |
| `demo_teacher` | Teacher | `DEMO_TEACHER_PASSWORD` | `demo-teacher-pass` |
| `demo_student` | Student | `DEMO_STUDENT_PASSWORD` | `demo-student-pass` |

To choose your own passwords, set the variables in `.env` (see
`.env.example`) **before the first start**. If the demo users already exist,
`seed_demo` will keep their current passwords; delete the demo data
(`docker compose down -v`, or remove `db.sqlite3`) to re-seed from scratch.

Seeded data: 6 courses (5 published), 18 lessons, 2 enrollments, and the three
accounts above. Running `seed_demo` again is safe and creates no duplicates.

---

## API example

```bash
curl -s http://127.0.0.1:8000/api/courses/
```

```json
{
  "courses": [
    {"id": 3, "title": "CI/CD with GitHub Actions", "description": "Automated testing, builds and deployment pipelines."},
    {"id": 2, "title": "Docker Essentials", "description": "Images, containers, volumes and Docker networking."},
    {"id": 1, "title": "Linux Fundamentals", "description": "Linux commands, users, permissions and system administration."}
  ]
}
```

The endpoint lists **published** courses only, ordered by title, and requires no
authentication.

---

## Running the tests

```bash
python manage.py check
python manage.py test
python manage.py makemigrations --check --dry-run
```

The suite covers roles, authentication, login/logout, per-role dashboards,
lesson permissions, lesson visibility, the public homepage, the API and
idempotent seeding (including that passwords are not reset).

---

## Configuration reference

| Environment variable | Default | Notes |
| --- | --- | --- |
| `DJANGO_SECRET_KEY` | `development-only-change-me` | Placeholder. Set a random value locally. |
| `DJANGO_DEBUG` | `false` | Compose sets `true` for local development. |
| `DJANGO_ALLOWED_HOSTS` | `localhost,127.0.0.1,testserver` | Comma-separated. |
| `DATABASE_PATH` | `<project>/db.sqlite3` | Compose uses `/app/data/db.sqlite3`. |
| `DEMO_ADMIN_PASSWORD` | `demo-admin-pass` | Dev-only; used only at first user creation. |
| `DEMO_TEACHER_PASSWORD` | `demo-teacher-pass` | Dev-only; used only at first user creation. |
| `DEMO_STUDENT_PASSWORD` | `demo-student-pass` | Dev-only; used only at first user creation. |

`.env` is git-ignored; only `.env.example` is committed.

---

## Persistence

- **Docker:** the `demo_data` named volume holds `/app/data/db.sqlite3`.
  Restarting or rebuilding the container keeps your data.
- **Local:** data is stored in `db.sqlite3` in the project root (git-ignored).
- Re-running `migrate` or `seed_demo` is safe: migrations are idempotent and
  seeding uses `update_or_create`/`get_or_create`.

---

## CI overview

`.github/workflows/ci.yml` runs on every push and pull request:

1. Checkout and install Python 3.12 with pip caching.
2. `pip install -r requirements.txt`.
3. `python manage.py check`.
4. `python manage.py test`.
5. `python manage.py makemigrations --check --dry-run` (fails if model changes
   lack a migration).

---

## Troubleshooting

- **`Address already in use` / port 8000 busy:** stop the other process, or
  change the published port in `compose.yaml` (for example `127.0.0.1:8001:8000`).
- **Can't log in with the documented password:** the account may already exist
  with a different password. Reset the demo data (local: delete `db.sqlite3`;
  Docker: `docker compose down -v`) and start again, or change the password in
  `/admin/`.
- **`permission denied` with Docker on Linux:** ensure your user can run Docker,
  or use the local virtualenv workflow.
- **Changes to `DEMO_*_PASSWORD` seem ignored:** passwords are only applied when
  an account is first created; existing accounts keep their password by design.
- **`makemigrations --check` fails locally:** you changed a model without
  creating a migration; run `python manage.py makemigrations`.
- **Container exits immediately:** check `docker compose logs web`; the most
  common cause is a port conflict or a failed migration.

---

## Limitations

- Uses Django's development server; **not** suitable for production.
- SQLite only; no production database or migrations to Postgres.
- No HTTPS, no production secret management, no static-file/CDN setup.
- A course has at most one assigned teacher.
- No self-service signup or password-reset email flow; accounts are created via
  `seed_demo` or the Django admin.
- Minimal templates and no frontend build tooling, by design.

---

## Roadmap

- API validation and additional tests
- A production-style deployment example (separate from this demo)

No reuse license is granted at this stage.
