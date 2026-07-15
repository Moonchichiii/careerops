from __future__ import annotations

import pytest
from django.db import IntegrityError, transaction

from apps.accounts.models import User

pytestmark = pytest.mark.django_db


def test_user_manager_normalizes_email() -> None:
    user = User.objects.create_user(email="  Mats@EXAMPLE.COM  ", password="not-a-real-secret")

    assert user.email == "Mats@example.com"
    assert user.check_password("not-a-real-secret")


def test_natural_key_lookup_is_case_insensitive() -> None:
    user = User.objects.create_user(email="mats@example.com")

    found = User.objects.get_by_natural_key("MATS@EXAMPLE.COM")

    assert found == user


def test_email_is_unique_case_insensitively() -> None:
    User.objects.create_user(email="mats@example.com")

    with pytest.raises(IntegrityError), transaction.atomic():
        User.objects.create_user(email="MATS@example.com")


def test_superuser_has_required_flags() -> None:
    user = User.objects.create_superuser(
        email="admin@example.com",
        password="not-a-real-secret",
    )

    assert user.is_staff is True
    assert user.is_superuser is True
    assert user.is_active is True
