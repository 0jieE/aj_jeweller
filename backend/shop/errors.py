"""How the API says no.

Every refusal has the same envelope:

    {"error": {"code": "purity_mismatch", "message": "A silver piece needs ..."}}

* 422 — a business rule refused the request (`Refusal`). The message is the
  plain-English sentence the app shows for the same situation.
* 409 — a client-chosen id is already used by another record (`Conflict`).
* 400 — the request is malformed (wrong types, missing fields).
* 401 / 403 / 404 — not signed in / not allowed / no such record.
"""

from django.core.exceptions import PermissionDenied as DjangoPermissionDenied
from django.http import Http404
from rest_framework import exceptions, status
from rest_framework.response import Response
from rest_framework.views import set_rollback


class ShopError(Exception):
    status_code = status.HTTP_422_UNPROCESSABLE_ENTITY
    default_code = "rule"

    def __init__(self, message: str, code: str | None = None, **extra):
        super().__init__(message)
        self.message = message
        self.code = code or self.default_code
        self.extra = extra

    def payload(self) -> dict:
        return {"error": {"code": self.code, "message": self.message, **self.extra}}


class Refusal(ShopError):
    """A business rule said no. Maps to 422."""


class Conflict(ShopError):
    status_code = status.HTTP_409_CONFLICT
    default_code = "duplicate_id"


class NotFound(ShopError):
    status_code = status.HTTP_404_NOT_FOUND
    default_code = "not_found"


class Forbidden(ShopError):
    status_code = status.HTTP_403_FORBIDDEN
    default_code = "forbidden"


def _first_message(detail) -> str:
    """The first human sentence inside a DRF error detail, however nested."""
    if isinstance(detail, dict):
        for key, value in detail.items():
            inner = _first_message(value)
            if inner:
                return inner if key in ("non_field_errors", "detail") else f"{key}: {inner}"
        return ""
    if isinstance(detail, list):
        for value in detail:
            inner = _first_message(value)
            if inner:
                return inner
        return ""
    return str(detail)


def exception_handler(exc, context):
    if isinstance(exc, ShopError):
        set_rollback()
        return Response(exc.payload(), status=exc.status_code)

    if isinstance(exc, Http404):
        exc = exceptions.NotFound("That record does not exist")
    elif isinstance(exc, DjangoPermissionDenied):
        exc = exceptions.PermissionDenied()

    if not isinstance(exc, exceptions.APIException):
        return None  # a bug: let Django return a 500 and log it

    set_rollback()
    headers = {}
    if getattr(exc, "auth_header", None):
        headers["WWW-Authenticate"] = exc.auth_header
    if getattr(exc, "wait", None):
        headers["Retry-After"] = str(int(exc.wait))

    if isinstance(exc, exceptions.ValidationError):
        body = {"error": {"code": "invalid", "message": _first_message(exc.detail) or "Invalid request",
                          "fields": exc.detail}}
    else:
        detail = exc.detail
        code = getattr(detail, "code", None) or exc.default_code
        body = {"error": {"code": str(code), "message": _first_message(detail)}}
    return Response(body, status=exc.status_code, headers=headers)
