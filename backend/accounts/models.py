"""Staff — named people, not bare roles.

Roles decide what someone may do; the user is who did it. Every record and
every log row names one of these.

A member of staff signs in with their name and a 4–6 digit PIN. The PIN is
hashed into Django's `password` column exactly like a password, so it is never
stored or logged in the clear.
"""

import re

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.db import models
from django.db.models import Q
from django.utils import timezone

from shop.enums import BranchId, Role, choices_check


def name_key(name: str) -> str:
    """Matching key for "is this the same name?": trimmed, collapsed, lowercased."""
    return re.sub(r"\s+", " ", name.strip()).lower()


class UserManager(BaseUserManager):
    use_in_migrations = True

    def create_user(self, id, name, role, home_branch=None, pin=None, **extra):
        user = self.model(id=id, name=name, role=role, home_branch=home_branch, **extra)
        if pin:
            user.set_password(pin)
        else:
            user.set_unusable_password()
        user.save()
        return user


class User(AbstractBaseUser):
    id = models.CharField(primary_key=True, max_length=32)
    name = models.CharField(max_length=120)
    # Two staff with one name would make every record naming them ambiguous,
    # so uniqueness ignores case and spacing.
    name_key = models.CharField(max_length=120, unique=True, editable=False)
    role = models.CharField(max_length=24, choices=Role.choices)
    # Null only for Admin, who oversees both branches.
    home_branch = models.CharField(max_length=16, choices=BranchId.choices, null=True, blank=True)
    contact_number = models.CharField(max_length=40, null=True, blank=True)
    active = models.BooleanField(default=True)
    created_at = models.DateTimeField(default=timezone.now)

    # Sign-in throttling — wrong PINs in a row, and when a lockout ends.
    failed_pin_attempts = models.PositiveSmallIntegerField(default=0)
    locked_until = models.DateTimeField(null=True, blank=True)

    objects = UserManager()

    USERNAME_FIELD = "id"
    REQUIRED_FIELDS: list[str] = []

    class Meta:
        ordering = ["name"]
        constraints = [
            models.CheckConstraint(condition=choices_check("role", Role), name="user_role_valid"),
            models.CheckConstraint(
                condition=Q(home_branch__isnull=True) | choices_check("home_branch", BranchId),
                name="user_home_branch_valid",
            ),
            # Admin works across both branches; everyone else works from one.
            models.CheckConstraint(
                condition=(Q(role=Role.ADMIN, home_branch__isnull=True)
                           | (~Q(role=Role.ADMIN) & Q(home_branch__isnull=False))),
                name="user_branch_matches_role",
            ),
        ]

    def save(self, *args, **kwargs):
        self.name = self.name.strip()
        self.name_key = name_key(self.name)
        super().save(*args, **kwargs)

    # Django and simplejwt read `is_active`; the shop's word is `active`.
    @property
    def is_active(self) -> bool:
        return self.active

    @property
    def is_admin(self) -> bool:
        return self.role == Role.ADMIN

    # --- what Django's admin site asks of a user ------------------------------
    # Only an active Admin may use it; what they may do there is decided by
    # each ModelAdmin (shop records are view-only), not by these flags.
    @property
    def is_staff(self) -> bool:
        return self.active and self.role == Role.ADMIN

    @property
    def is_superuser(self) -> bool:
        return False

    def has_perm(self, perm, obj=None) -> bool:
        return self.is_staff

    def has_perms(self, perm_list, obj=None) -> bool:
        return self.is_staff

    def has_module_perms(self, app_label) -> bool:
        return self.is_staff

    def get_full_name(self) -> str:
        return self.name

    def get_short_name(self) -> str:
        return self.name.split(" ")[0]

    @property
    def has_pin(self) -> bool:
        return self.has_usable_password()

    @property
    def role_label(self) -> str:
        return Role(self.role).label

    @property
    def attribution(self) -> str:
        """'Grace Ramos (Cashier)' — how a person is named on a record."""
        return f"{self.name} ({self.role_label})"

    def __str__(self) -> str:
        return self.attribution
