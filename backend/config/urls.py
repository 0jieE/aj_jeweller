from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path, re_path
from django.views.generic import RedirectView

from config import webapp

urlpatterns = [
    path("api/v1/", include("shop.api.urls")),
    path("admin/", admin.site.urls),
    path("admin", RedirectView.as_view(url="/admin/")),  # APPEND_SLASH is off for the API
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)

# Last: everything else belongs to the desktop app (its routes return index.html;
# its files are served by WhiteNoise before reaching Django). The API, the admin,
# media and static files are never the app's.
urlpatterns += [
    re_path(r"^(?!api(?:/|$)|admin(?:/|$)|media/|static/)(?P<path>.*)$", webapp.spa, name="webapp"),
]
