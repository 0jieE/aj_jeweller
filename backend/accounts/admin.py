"""Staff in the admin site. Adding, editing, PIN resets, deactivating and
deleting all go through accounts.services, so the rules are the app's — unique
names, a branch for branch staff, the last active Admin protected, deactivate
anyone with records — and each change writes its TransactionLog row."""

from django import forms
from django.contrib import admin, messages
from django.contrib.auth.models import Group
from django.forms.models import construct_instance

from shop.admin_tools import ctx_for, run, trial
from shop.enums import Role
from shop.errors import ShopError

from . import services
from .models import User

admin.site.unregister(Group)  # roles, not Django groups, decide what staff may do


class _ServiceForm(forms.ModelForm):
    """A ModelForm whose saving is done by a service. Its `clean()` tries the
    service and rolls it back, so a refusal shows on the form in the service's
    own words; the model's own validation is left to the service too."""

    request = None  # set by the ModelAdmin

    def _post_clean(self):
        self.instance = construct_instance(self, self.instance, self._meta.fields, self._meta.exclude)

    def refuse_unless_ok(self, fn):
        problem = trial(fn)
        if problem:
            raise forms.ValidationError(problem)


class UserAddForm(_ServiceForm):
    user_id = forms.CharField(label="User id", required=False,
                              help_text="Optional — leave blank and one is made (USR-XXXXXX).")
    pin = forms.CharField(label="PIN", widget=forms.PasswordInput, help_text="4 to 6 digits.")

    class Meta:
        model = User
        fields = ["name", "role", "home_branch", "contact_number"]

    def call(self, ctx):
        d = self.cleaned_data
        return services.add_user(ctx, user_id=d.get("user_id") or None, name=d["name"], role=d["role"],
                                 home_branch=d.get("home_branch") or None,
                                 contact_number=d.get("contact_number"), pin=d["pin"])

    def clean(self):
        data = super().clean()
        if not self.errors:
            self.refuse_unless_ok(lambda: self.call(ctx_for(self.request)))
        return data


class UserChangeForm(_ServiceForm):
    new_pin = forms.CharField(label="Set a new PIN", required=False, widget=forms.PasswordInput,
                              help_text="Leave blank to keep the current PIN. Setting one signs them out of every phone.")

    class Meta:
        model = User
        fields = ["name", "role", "home_branch", "contact_number"]

    def call(self, ctx):
        d = self.cleaned_data
        user = self.instance
        services.update_user(ctx, user.pk, name=d["name"], role=d["role"], home_branch=d.get("home_branch") or None,
                             contact_number=d.get("contact_number") or "")
        if d.get("new_pin"):
            services.set_pin(ctx, user.pk, d["new_pin"])

    def clean(self):
        data = super().clean()
        if not self.errors:
            self.refuse_unless_ok(lambda: self.call(ctx_for(self.request)))
        return data


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ["name", "id", "role_label", "home_branch", "active", "has_pin", "last_login"]
    list_filter = ["role", "home_branch", "active"]
    search_fields = ["name", "id", "contact_number"]
    ordering = ["name"]
    readonly_fields = ["id", "active", "has_pin", "created_at", "last_login", "record_count"]
    actions = ["deactivate", "reactivate"]

    def get_actions(self, request):
        actions = super().get_actions(request)
        actions.pop("delete_selected", None)  # one at a time, through the delete rules
        return actions

    def get_form(self, request, obj=None, change=False, **kwargs):
        kwargs["form"] = UserChangeForm if obj is not None else UserAddForm
        form = super().get_form(request, obj, change=change, **kwargs)
        form.request = request
        return form

    def get_fieldsets(self, request, obj=None):
        if obj is None:
            return [(None, {"fields": ["user_id", "name", "role", "home_branch", "contact_number", "pin"]})]
        return [
            (None, {"fields": ["id", "name", "role", "home_branch", "contact_number"]}),
            ("Sign-in", {"fields": ["new_pin", "has_pin", "last_login"]}),
            ("On file", {"fields": ["active", "created_at", "record_count"],
                         "description": "Use the Deactivate / Reactivate actions on the staff list to change "
                                        "whether someone can sign in."}),
        ]

    def get_readonly_fields(self, request, obj=None):
        return [] if obj is None else self.readonly_fields

    @admin.display(description="Records naming them")
    def record_count(self, obj):
        return services.activity_count(obj.pk)

    @admin.display(boolean=True, description="PIN set")
    def has_pin(self, obj):
        return obj.has_pin

    @admin.display(description="Role", ordering="role")
    def role_label(self, obj):
        return Role(obj.role).label

    def save_model(self, request, obj, form, change):
        ctx = ctx_for(request)
        if change:
            run(lambda: form.call(ctx))
            obj.refresh_from_db()
        else:
            created = run(lambda: form.call(ctx))
            obj.pk, obj.name_key = created.pk, created.name_key
            obj._state.adding = False

    def save_related(self, request, form, formsets, change):
        pass  # nothing related to save, and the service already saved the person

    def has_delete_permission(self, request, obj=None):
        # Only someone added by mistake who never did anything can be deleted.
        if obj is None:
            return False
        return services.delete_problem(ctx_for(request), obj) is None

    def delete_model(self, request, obj):
        run(lambda: services.delete_user(ctx_for(request), obj.pk))

    def _set_active(self, request, queryset, active: bool):
        done = 0
        for user in queryset:
            try:
                run(lambda: services.set_active(ctx_for(request), user.pk, active))
                done += 1
            except ShopError as error:
                self.message_user(request, error.message, messages.ERROR)
        if done:
            self.message_user(request, f"{'Reactivated' if active else 'Deactivated'} {done} person(s).")

    @admin.action(description="Deactivate — they can no longer sign in; their records keep their name")
    def deactivate(self, request, queryset):
        self._set_active(request, queryset, False)

    @admin.action(description="Reactivate")
    def reactivate(self, request, queryset):
        self._set_active(request, queryset, True)
