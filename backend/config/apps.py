from django.contrib.admin.apps import AdminConfig


class ShopAdminConfig(AdminConfig):
    """django.contrib.admin, using the shop's own site (config/admin_site.py).
    Kept apart from that module because an AppConfig is imported before any
    model is ready."""

    default_site = "config.admin_site.ShopAdminSite"
