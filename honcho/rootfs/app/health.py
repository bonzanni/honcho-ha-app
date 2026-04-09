"""Health check endpoint injected into the Honcho FastAPI app.

This module is NOT part of Honcho's source code. It is loaded by the HA add-on's
S6 startup script to provide a /health endpoint for the HA Supervisor watchdog.
"""

from fastapi import Response
from sqlalchemy import text

from src.db import engine
from src.main import app


@app.get("/health", include_in_schema=False)
async def health() -> Response:
    """Verify the API is up and PostgreSQL is reachable."""
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return Response(status_code=200, content="ok")
    except Exception:
        return Response(status_code=503, content="database unavailable")
