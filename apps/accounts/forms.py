from __future__ import annotations

from typing import TYPE_CHECKING, Any, ClassVar

from django import forms
from django.contrib.auth.forms import AdminUserCreationForm as DjangoAdminUserCreationForm
from django.contrib.auth.forms import AuthenticationForm
from django.contrib.auth.forms import UserChangeForm as DjangoUserChangeForm
from django.core.exceptions import ValidationError

from apps.accounts.models import User
from apps.accounts.services import (
    clear_login_failures,
    login_is_blocked,
    record_login_failure,
)

if TYPE_CHECKING:
    from django.http import HttpRequest


def _remote_address(request: HttpRequest | None) -> str:
    if request is None:
        return "unknown"

    value = request.META.get("REMOTE_ADDR")

    if isinstance(value, str) and value:
        return value

    return "unknown"


class EmailAuthenticationForm(AuthenticationForm):
    username = forms.EmailField(
        label="Email",
        max_length=254,
        widget=forms.EmailInput(
            attrs={
                "autocomplete": "email",
                "autofocus": True,
                "class": "auth-input",
            }
        ),
    )
    password = forms.CharField(
        label="Password",
        strip=False,
        widget=forms.PasswordInput(
            attrs={
                "autocomplete": "current-password",
                "class": "auth-input",
            }
        ),
    )

    def clean(self) -> dict[str, Any]:
        username = self.cleaned_data.get("username")
        password = self.cleaned_data.get("password")

        if not isinstance(username, str) or not password:
            return super().clean()

        remote_address = _remote_address(self.request)

        if login_is_blocked(
            email=username,
            remote_address=remote_address,
        ):
            raise self.get_invalid_login_error()

        try:
            cleaned_data = super().clean()
        except ValidationError:
            record_login_failure(
                email=username,
                remote_address=remote_address,
            )
            raise

        clear_login_failures(
            email=username,
            remote_address=remote_address,
        )

        return cleaned_data


# django-stubs models these forms as generic, but Django's runtime classes are not
# subscriptable. Keep the incompatibility isolated to the inheritance boundary.
class UserCreationForm(DjangoAdminUserCreationForm):
    class Meta(DjangoAdminUserCreationForm.Meta):
        model = User
        fields: ClassVar[tuple[str, ...]] = ("email",)


class UserChangeForm(DjangoUserChangeForm):  # type: ignore[type-arg]
    class Meta(DjangoUserChangeForm.Meta):
        model = User
        fields = "__all__"
