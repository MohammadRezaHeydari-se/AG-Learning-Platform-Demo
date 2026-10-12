# AG Learning Platform Demo

A small, independently built Django portfolio project with readable code, automated tests and CI.

> **Portfolio demo only.** This is not the production Automationsguiden application. It contains no private production source code, customer data or deployment credentials.

## Features
- Manage sample courses in Django admin
- List published courses via `GET /api/courses/`
- Automated test confirming unpublished courses remain hidden
- GitHub Actions CI and a local-development Dockerfile

## Run locally
Requires Python 3.12+.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver
```

Open `http://127.0.0.1:8000/admin/` to add courses and `http://127.0.0.1:8000/api/courses/` to view published courses.

## Run tests
```bash
python manage.py check
python manage.py test
```

## Docker (local development only)
```bash
docker build -t ag-learning-demo .
docker run --rm -p 8000:8000 -e DJANGO_SECRET_KEY=demo-only -e DJANGO_DEBUG=true ag-learning-demo
```

This uses Django's development server and is **not production-ready**.

## Roadmap
- Role-based access
- Lessons and enrollments
- API validation and more tests
- Production-style deployment example

No reuse license is granted at this stage.
