from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path
from django.views.generic import RedirectView

urlpatterns = [
    path("api/v1/", include("shop.api.urls")),
    path("admin/", admin.site.urls),
    path("admin", RedirectView.as_view(url="/admin/")),  # APPEND_SLASH is off for the API
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
