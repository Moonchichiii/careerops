from __future__ import annotations

from django.contrib.auth.views import LoginView, LogoutView
from django.utils.decorators import method_decorator
from django.views.decorators.cache import never_cache

from apps.accounts.forms import EmailAuthenticationForm


@method_decorator(never_cache, name="dispatch")
class SessionLoginView(LoginView):
    authentication_form = EmailAuthenticationForm
    redirect_authenticated_user = True
    template_name = "accounts/login.html"


@method_decorator(never_cache, name="dispatch")
class SessionLogoutView(LogoutView):
    next_page = "shell"
