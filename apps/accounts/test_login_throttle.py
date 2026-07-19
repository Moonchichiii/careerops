from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from django.test import override_settings

from apps.accounts.models import LoginThrottleState
from apps.accounts.services import (
    clear_login_failures,
    login_is_blocked,
    record_login_failure,
)

pytestmark = pytest.mark.django_db

EMAIL = "Mats@Example.COM"
REMOTE_ADDRESS = "192.0.2.10"


@override_settings(
    LOGIN_THROTTLE_FAILURE_LIMIT=3,
    LOGIN_THROTTLE_WINDOW_SECONDS=300,
    LOGIN_THROTTLE_BLOCK_SECONDS=600,
)
def test_failure_limit_blocks_login_scope() -> None:
    current_time = datetime(2026, 7, 19, 12, 0, tzinfo=UTC)

    assert (
        record_login_failure(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=current_time,
        )
        is False
    )

    assert (
        record_login_failure(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=current_time + timedelta(seconds=1),
        )
        is False
    )

    assert (
        record_login_failure(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=current_time + timedelta(seconds=2),
        )
        is True
    )

    assert (
        login_is_blocked(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=current_time + timedelta(seconds=3),
        )
        is True
    )

    state = LoginThrottleState.objects.get()

    assert state.failure_count == 3
    assert state.blocked_until == current_time + timedelta(seconds=602)


@override_settings(
    LOGIN_THROTTLE_FAILURE_LIMIT=3,
    LOGIN_THROTTLE_WINDOW_SECONDS=300,
    LOGIN_THROTTLE_BLOCK_SECONDS=600,
)
def test_expired_block_starts_a_fresh_window() -> None:
    current_time = datetime(2026, 7, 19, 12, 0, tzinfo=UTC)

    for offset in range(3):
        record_login_failure(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=current_time + timedelta(seconds=offset),
        )

    after_block = current_time + timedelta(seconds=603)

    assert (
        login_is_blocked(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=after_block,
        )
        is False
    )

    assert (
        record_login_failure(
            email=EMAIL,
            remote_address=REMOTE_ADDRESS,
            at=after_block,
        )
        is False
    )

    state = LoginThrottleState.objects.get()

    assert state.failure_count == 1
    assert state.window_started_at == after_block
    assert state.blocked_until is None


def test_clear_login_failures_removes_state() -> None:
    record_login_failure(
        email=EMAIL,
        remote_address=REMOTE_ADDRESS,
    )

    clear_login_failures(
        email=EMAIL,
        remote_address=REMOTE_ADDRESS,
    )

    assert LoginThrottleState.objects.exists() is False


def test_throttle_state_does_not_store_raw_identifiers() -> None:
    record_login_failure(
        email=EMAIL,
        remote_address=REMOTE_ADDRESS,
    )

    state = LoginThrottleState.objects.get()

    assert len(state.scope_hash) == 64
    assert EMAIL.casefold() not in state.scope_hash
    assert REMOTE_ADDRESS not in state.scope_hash
