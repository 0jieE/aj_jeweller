"""Django settings for the AJ Jeweler backend.

Every value can be overridden from the environment (or a `.env` file next to
manage.py); the defaults are for local development against the Postgres in
docker-compose.yml.
"""

import os
import sys
from datetime import timedelta
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

BASE_DIR = Path(__file__).resolve().parent.parent


def _load_dotenv(path: Path) -> None:
    """Minimal `.env` reader so development needs no extra dependency."""
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


_load_dotenv(BASE_DIR / ".env")


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool) -> bool:
    return env(name, "1" if default else "0").lower() in {"1", "true", "yes", "on"}


SECRET_KEY = env("DJANGO_SECRET_KEY", "dev-only-insecure-key-change-me")
DEBUG = env_bool("DJANGO_DEBUG", True)
ALLOWED_HOSTS = [h.strip() for h in env("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1,10.0.2.2").split(",") if h.strip()]

# A platform that assigns the hostname (Render) tells the container what it
# ended up being called, so the first deploy does not 400 on its own URL.
_PLATFORM_HOST = env("RENDER_EXTERNAL_HOSTNAME", "")
if _PLATFORM_HOST and _PLATFORM_HOST not in ALLOWED_HOSTS:
    ALLOWED_HOSTS.append(_PLATFORM_HOST)

# TLS is terminated by the platform's load balancer, which tells us what the
# browser actually asked for. Without this Django thinks every request is
# plain HTTP and refuses the admin's secure cookies.
if env_bool("TRUST_PROXY_TLS", bool(_PLATFORM_HOST)):
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    # Such a platform serves HTTPS and nothing else, so say so. On the shop's
    # own network this stays off: there is no certificate for a LAN address,
    # and redirecting would lock every phone out.
    SECURE_SSL_REDIRECT = env_bool("SECURE_SSL_REDIRECT", True)
    SECURE_HSTS_SECONDS = int(env("SECURE_HSTS_SECONDS", "31536000"))
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True

INSTALLED_APPS = [
    "config.apps.ShopAdminConfig",  # django.contrib.admin, with the shop's sign-in
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "accounts",
    "shop",
    "notifications",
    "office",  # the back office at /administrator/
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    # Serves the admin's own CSS and JS. Behind nginx these come off disk and
    # this never runs; on a platform with nothing in front, it is the only
    # thing that does.
    "whitenoise.middleware.WhiteNoiseMiddleware",
    # Sessions, CSRF and messages serve the admin site only; the API signs in
    # with JWT and its views are CSRF-exempt.
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"
# API paths work with or without a trailing slash; never redirect a POST.
APPEND_SLASH = False

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "config" / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"


def _database_from_url(url: str) -> dict:
    """postgres://user:pass@host:port/name?sslmode=require — query parameters
    (sslmode, connect_timeout, ...) are passed to the driver."""
    parsed = urlparse(url)
    options = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
    host = parsed.hostname or "localhost"
    # A hosted database reached from outside its network (Render's external
    # URL) only accepts SSL; ask for it unless the URL says otherwise.
    if "sslmode" not in options and host not in ("localhost", "127.0.0.1") and "." in host:
        options["sslmode"] = "require"
    return {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": unquote(parsed.path.lstrip("/")),
        "USER": unquote(parsed.username or ""),
        "PASSWORD": unquote(parsed.password or ""),
        "HOST": host,
        "PORT": str(parsed.port or 5432),
        "CONN_MAX_AGE": int(env("DB_CONN_MAX_AGE", "60")),
        "OPTIONS": options,
    }


DATABASES = {"default": _database_from_url(env("DATABASE_URL", "postgres://aj:aj@localhost:5434/aj_jeweler"))}

AUTH_USER_MODEL = "accounts.User"
# The admin site signs in like the app: name (or user id) and PIN, with the
# same lockout. Only active Admins get in.
AUTHENTICATION_BACKENDS = ["accounts.backends.PinBackend"]
# Roles that may sign in to the Django admin site: the Superuser, and nobody
# else. DJANGO_ADMIN_SITE_ROLES=superuser,admin lets an Admin back in while the
# phones still cannot parse "superuser" (see README, "Roles"); set it back
# afterwards. Never put branch roles here.
ADMIN_SITE_ROLES = frozenset(
    r.strip() for r in env("DJANGO_ADMIN_SITE_ROLES", "superuser").split(",") if r.strip() in ("superuser", "admin")
) or frozenset({"superuser"})
LOGIN_URL = "admin:login"
# An admin session ends when the browser closes, or after 8 hours.
SESSION_EXPIRE_AT_BROWSER_CLOSE = True
SESSION_COOKIE_AGE = 8 * 60 * 60
SESSION_COOKIE_SECURE = not DEBUG
CSRF_COOKIE_SECURE = not DEBUG
CSRF_TRUSTED_ORIGINS = [o.strip() for o in env("DJANGO_CSRF_TRUSTED_ORIGINS", "").split(",") if o.strip()]
if _PLATFORM_HOST:
    CSRF_TRUSTED_ORIGINS.append(f"https://{_PLATFORM_HOST}")

# The test suite creates staff in every test; a fast hasher keeps it quick.
RUNNING_TESTS = "test" in sys.argv[1:2]
if RUNNING_TESTS:
    PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]

# PINs are hashed exactly like passwords. Django's password validators are
# for passwords, not 4–6 digit PINs, so PIN rules live in accounts.pins.
AUTH_PASSWORD_VALIDATORS: list = []

LANGUAGE_CODE = "en-us"
# The shop is in the Philippines. Times the phone sends without an offset are
# Manila wall-clock time, and "today" means today in Manila.
TIME_ZONE = "Asia/Manila"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"

# Photos and receipt PDFs go to Cloudinary when CLOUDINARY_URL is set
# (cloudinary://<api_key>:<api_secret>@<cloud_name>), local disk otherwise.
# Tests always use local disk, whatever .env says.
CLOUDINARY_URL = "" if RUNNING_TESTS else env("CLOUDINARY_URL", "").strip()
# Every asset lives under this folder; give development and production different ones.
CLOUDINARY_FOLDER = env("CLOUDINARY_FOLDER", "aj-jeweler")

STORAGES = {
    "default": {"BACKEND": "shop.storage.CloudinaryStorage" if CLOUDINARY_URL
                else "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage"
        if not DEBUG
        else "django.contrib.staticfiles.storage.StaticFilesStorage"
    },
}
STATIC_ROOT = BASE_DIR / "staticfiles"

# The desktop app: the Flutter web build, served at the site root from this
# same origin (config/webapp.py). WEB_APP_ROOT is the directory holding its
# index.html; unset, empty or without an index.html, "/" says no app is
# deployed and the API carries on exactly as before.
_web_root = env("WEB_APP_ROOT", "").strip()
WEB_APP_ROOT = str((BASE_DIR / _web_root) if _web_root and not Path(_web_root).is_absolute() else _web_root)
WHITENOISE_ROOT = WEB_APP_ROOT if WEB_APP_ROOT and (Path(WEB_APP_ROOT) / "index.html").is_file() else None


def WHITENOISE_ADD_HEADERS_FUNCTION(headers, path, url):  # noqa: N802 — a setting, named as WhiteNoise reads it
    from config.webapp import add_headers

    add_headers(headers, path, url)

# Local-disk media (used only when Cloudinary is not configured).
MEDIA_URL = "/media/"
MEDIA_ROOT = Path(env("MEDIA_ROOT", str(BASE_DIR / "media")))
if not MEDIA_ROOT.is_absolute():
    MEDIA_ROOT = BASE_DIR / MEDIA_ROOT
if RUNNING_TESTS:
    # Tests write photos and PDFs; keep them out of the development media folder.
    import tempfile

    MEDIA_ROOT = Path(tempfile.mkdtemp(prefix="aj-test-media-"))

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# A full phone snapshot carries every photo as base64, so it can be large.
DATA_UPLOAD_MAX_MEMORY_SIZE = int(env("DATA_UPLOAD_MAX_MEMORY_SIZE", str(100 * 1024 * 1024)))
FILE_UPLOAD_MAX_MEMORY_SIZE = 10 * 1024 * 1024

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["rest_framework_simplejwt.authentication.JWTAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_PARSER_CLASSES": [
        "rest_framework.parsers.JSONParser",
        "rest_framework.parsers.MultiPartParser",
        "rest_framework.parsers.FormParser",
    ],
    "DEFAULT_PAGINATION_CLASS": "shop.api.pagination.Pagination",
    "PAGE_SIZE": 50,
    "EXCEPTION_HANDLER": "shop.errors.exception_handler",
    "UNAUTHENTICATED_USER": None,
    "DATETIME_FORMAT": "iso-8601",
    "COERCE_DECIMAL_TO_STRING": True,
    # `?format=` is the export format (csv/xlsx/pdf), not a DRF renderer pick.
    "URL_FORMAT_OVERRIDE": None,
}

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=int(env("JWT_ACCESS_MINUTES", "30"))),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=int(env("JWT_REFRESH_DAYS", "14"))),
    "ROTATE_REFRESH_TOKENS": False,
    # Tokens carry a hash of the PIN hash, so resetting a PIN signs that
    # person out everywhere; deactivated staff are refused on every request.
    "CHECK_REVOKE_TOKEN": True,
    "REVOKE_TOKEN_CLAIM": "hash_password",
    "CHECK_USER_IS_ACTIVE": True,
    "USER_ID_FIELD": "id",
    "USER_ID_CLAIM": "user_id",
    "SIGNING_KEY": SECRET_KEY,
    "AUTH_HEADER_TYPES": ("Bearer",),
}

# How far back an offline change may be dated by X-Recorded-At, and how far
# ahead of the server clock a phone clock may run.
SYNC_MAX_BACKDATE_DAYS = int(env("SYNC_MAX_BACKDATE_DAYS", "30"))
SYNC_MAX_CLOCK_SKEW_SECONDS = int(env("SYNC_MAX_CLOCK_SKEW_SECONDS", "300"))

# Push notifications (Firebase Cloud Messaging, HTTP v1). With no credential
# file, notifications are simply off and every shop action still works.
FIREBASE_CREDENTIALS_FILE = env("FIREBASE_CREDENTIALS_FILE", "")
FIREBASE_PROJECT_ID = env("FIREBASE_PROJECT_ID", "aj-jeweler-notification")
# How a notification is sent once its write commits: "thread" (background
# thread, the default), "inline" (in the request thread), or "command" (only
# `manage.py send_notifications` sends — run it on a schedule).
PUSH_DELIVERY = env("PUSH_DELIVERY", "thread")
# A notification still unsent after this long is dropped rather than delivered late.
PUSH_MAX_AGE_HOURS = int(env("PUSH_MAX_AGE_HOURS", "12"))
if RUNNING_TESTS:
    # No test may touch the network, whatever .env says.
    FIREBASE_CREDENTIALS_FILE = ""
    PUSH_DELIVERY = "inline"

# Wrong PINs before a sign-in is locked, and for how long.
PIN_MAX_ATTEMPTS = int(env("PIN_MAX_ATTEMPTS", "5"))
PIN_LOCKOUT_MINUTES = int(env("PIN_LOCKOUT_MINUTES", "15"))

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": "WARNING"},
    "loggers": {"notifications": {"handlers": ["console"], "level": "INFO", "propagate": False}},
}
