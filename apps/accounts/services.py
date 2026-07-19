from __future__ import annotations

from datetime import datetime, timedelta

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import transaction
from django.utils import timezone
from django.utils.crypto import salted_hmac

from apps.accounts.models import LoginThrottleState


def _positive_setting(name: str) -> int:
    value = getattr(settings, name)

    if not isinstance(value, int) or value < 1:
        message = f"{name} must be a positive integer."
        raise ImproperlyConfigured(message)

    return value


def _scope_hash(
    *,
    email: str,
    remote_address: str,
) -> str:
    normalized_email = email.strip().casefold()
    normalized_address = remote_address.strip() or "unknown"
    material = f"{normalized_email}\x00{normalized_address}"

    return salted_hmac(
        "careerops.accounts.login-throttle",
        material,
        algorithm="sha256",
    ).hexdigest()


def login_is_blocked(
    *,
    email: str,
    remote_address: str,
    at: datetime | None = None,
) -> bool:
    current_time = at or timezone.now()
    scope_hash = _scope_hash(
        email=email,
        remote_address=remote_address,
    )

    state = LoginThrottleState.objects.filter(scope_hash=scope_hash).only("blocked_until").first()

    return (
        state is not None and state.blocked_until is not None and state.blocked_until > current_time
    )


def record_login_failure(
    *,
    email: str,
    remote_address: str,
    at: datetime | None = None,
) -> bool:
    current_time = at or timezone.now()
    scope_hash = _scope_hash(
        email=email,
        remote_address=remote_address,
    )

    failure_limit = _positive_setting("LOGIN_THROTTLE_FAILURE_LIMIT")
    window_duration = timedelta(seconds=_positive_setting("LOGIN_THROTTLE_WINDOW_SECONDS"))
    block_duration = timedelta(seconds=_positive_setting("LOGIN_THROTTLE_BLOCK_SECONDS"))

    with transaction.atomic():
        LoginThrottleState.objects.get_or_create(
            scope_hash=scope_hash,
            defaults={
                "window_started_at": current_time,
            },
        )

        state = LoginThrottleState.objects.select_for_update().get(scope_hash=scope_hash)

        if state.blocked_until is not None and state.blocked_until > current_time:
            return True

        block_expired = state.blocked_until is not None and state.blocked_until <= current_time
        window_expired = state.window_started_at + window_duration <= current_time

        if block_expired or window_expired:
            state.failure_count = 0
            state.window_started_at = current_time
            state.blocked_until = None

        state.failure_count += 1

        if state.failure_count >= failure_limit:
            state.blocked_until = current_time + block_duration

        state.save(
            update_fields=[
                "failure_count",
                "window_started_at",
                "blocked_until",
                "updated_at",
            ]
        )

        return state.blocked_until is not None and state.blocked_until > current_time


def clear_login_failures(
    *,
    email: str,
    remote_address: str,
) -> None:
    scope_hash = _scope_hash(
        email=email,
        remote_address=remote_address,
    )

    LoginThrottleState.objects.filter(
        scope_hash=scope_hash,
    ).delete()
