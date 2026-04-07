# Project Template: Python FastAPI Service

Drop this into your repo as `CLAUDE.md` and customize the placeholders.

## Architecture

- **FastAPI backend** (`app/`) — async, Pydantic models, SQLAlchemy
- **PostgreSQL** via Docker Compose
- **Alembic** for migrations
- **Poetry** or **uv** for dependency management

## Deployment

| Service | URL | Platform |
|---|---|---|
| API | `<API_URL>` | GCP Cloud Run / Vercel |

## Conventions

### Python
- Python 3.12+, strict type hints everywhere
- Pydantic v2 for request/response models
- SQLAlchemy 2.0 async style
- `ruff` for linting and formatting
- `pytest` for tests, `pytest-asyncio` for async tests
- Dependency injection via FastAPI `Depends()`
- Structured logging via `structlog`
- Never `print()` in production code

### API
- snake_case for all JSON fields (Python default)
- Versioned routes: `/api/v1/`
- Response model on every endpoint
- OpenAPI auto-generated from Pydantic models

### Database
- Alembic migrations (auto-generate, then review)
- UUID primary keys
- Timestamps on every table
- Async session management

### Testing
- `pytest` with fixtures
- Factory pattern for test data
- Test database per test run (Docker)
- Minimum: happy path + validation + auth per endpoint
