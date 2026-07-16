from __future__ import annotations

from typing import TYPE_CHECKING, Literal, TypedDict

from django.db import DatabaseError, connection
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.vary import vary_on_headers

if TYPE_CHECKING:
    from django.http import HttpRequest


class ShellStatus(TypedDict):
    state: Literal["ready", "confirmed"]
    label: str
    title: str
    detail: str


def _shell_status(*, refreshed: bool) -> ShellStatus:
    if refreshed:
        return {
            "state": "confirmed",
            "label": "Confirmed",
            "title": "Django returned the native partial.",
            "detail": (
                "HTMX requested the same route with HX-Request and replaced only this status panel."
            ),
        }

    return {
        "state": "ready",
        "label": "Ready",
        "title": "The application shell is online.",
        "detail": (
            "The complete page was rendered by Django and enhanced by the self-hosted HTMX bundle."
        ),
    }


@vary_on_headers("HX-Request")
def shell(request: HttpRequest) -> HttpResponse:
    refreshed = request.GET.get("status") == "refreshed"
    context: dict[str, object] = {
        "active_navigation": "shell",
        "shell_status": _shell_status(refreshed=refreshed),
    }

    template_name = (
        "platform/shell.html#shell-status"
        if request.headers.get("HX-Request") == "true"
        else "platform/shell.html"
    )

    response = render(request, template_name, context)
    response.headers["Cache-Control"] = "no-store"
    return response


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
