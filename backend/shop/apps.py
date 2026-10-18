from django.apps import AppConfig


class ShopConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "shop"
    verbose_name = "AJ Jeweler"

    def ready(self):
        from . import signals

        signals.connect()
