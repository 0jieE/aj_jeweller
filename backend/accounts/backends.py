"""Django authentication for the admin site: the same name-or-id + PIN check,
lockout included, that the app's sign-in uses."""

from .models import User
from .services import SignInRefused, authenticate_pin


class PinBackend:
    def authenticate(self, request, username=None, password=None, **kwargs):
        if not username or password is None:
            return None
        username = username.strip()
        try:
            if User.objects.filter(pk=username).exists():
                return authenticate_pin(user_id=username, name=None, pin=password)
            return authenticate_pin(user_id=None, name=username, pin=password)
        except SignInRefused:
            return None

    def get_user(self, user_id):
        user = User.objects.filter(pk=user_id).first()
        return user if user is not None and user.active else None
