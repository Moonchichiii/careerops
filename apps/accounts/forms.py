from __future__ import annotations

from typing import ClassVar

from django import forms
from django.contrib.auth.forms import AdminUserCreationForm as DjangoAdminUserCreationForm
from django.contrib.auth.forms import AuthenticationForm
from django.contrib.auth.forms import UserChangeForm as DjangoUserChangeForm

from apps.accounts.models import User


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
