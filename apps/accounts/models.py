from __future__ import annotations

from typing import TYPE_CHECKING
from uuid import uuid4

from django.contrib.auth.models import AbstractUser
from django.db import models
from django.db.models.functions import Lower

from apps.accounts.managers import UserManager

if TYPE_CHECKING:
    from typing import ClassVar


class User(AbstractUser):
    id = models.UUIDField(primary_key=True, default=uuid4, editable=False)
    username = None
    email = models.EmailField(unique=True)

    USERNAME_FIELD: ClassVar[str] = "email"
    REQUIRED_FIELDS: ClassVar[list[str]] = []

    objects: ClassVar[UserManager] = UserManager()

    class Meta:
        constraints: ClassVar[list[models.UniqueConstraint]] = [
            models.UniqueConstraint(
                Lower("email"),
                name="accounts_user_email_ci_unique",
            ),
        ]

    def __str__(self) -> str:
        return self.email
