from __future__ import annotations

from typing import TYPE_CHECKING

from django.db import DatabaseError, connection
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render

if TYPE_CHECKING:
    from django.http import HttpRequest


def asset_smoke(request: HttpRequest) -> HttpResponse:
    response = render(request, "platform/asset_smoke.html")
    response.headers["Cache-Control"] = "no-store"
    return response


def liveness(_request: HttpRequest) -> JsonResponse:
    response = JsonResponse({"status": "ok"})
    response.headers["Cache-Control"] = "no-store"
    return response


def readiness(_request: HttpRequest) -> JsonResponse:
    try:
        connection.ensure_connection()
    except DatabaseError:
        response = JsonResponse({"status": "unavailable"}, status=503)
    else:
        response = JsonResponse({"status": "ready"})

    response.headers["Cache-Control"] = "no-store"
    return response
