"""Session and staff endpoints: /auth/*, /me, /users."""

from rest_framework import mixins, serializers, status, viewsets
from rest_framework.decorators import action
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.serializers import TokenRefreshSerializer
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenRefreshView

from shop.api.base import ShopView, filter_dates
from shop.enums import BranchId, Role

from . import services
from .models import User


class UserSerializer(serializers.ModelSerializer):
    role_label = serializers.CharField(read_only=True)
    has_pin = serializers.BooleanField(read_only=True)

    class Meta:
        model = User
        fields = ["id", "name", "role", "role_label", "home_branch", "contact_number", "active", "has_pin",
                  "created_at", "last_login"]


class UserCreateSerializer(serializers.Serializer):
    id = serializers.CharField(required=False, allow_blank=True)
    name = serializers.CharField(allow_blank=True)
    role = serializers.ChoiceField(choices=Role.choices)
    home_branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    contact_number = serializers.CharField(required=False, allow_null=True, allow_blank=True)
    pin = serializers.CharField()


class UserUpdateSerializer(serializers.Serializer):
    name = serializers.CharField(required=False, allow_blank=True)
    role = serializers.ChoiceField(choices=Role.choices, required=False)
    home_branch = serializers.ChoiceField(choices=BranchId.choices, required=False, allow_null=True)
    contact_number = serializers.CharField(required=False, allow_null=True, allow_blank=True)


class PinSerializer(serializers.Serializer):
    pin = serializers.CharField()


class OwnPinSerializer(serializers.Serializer):
    current_pin = serializers.CharField()
    new_pin = serializers.CharField()


class LoginSerializer(serializers.Serializer):
    user_id = serializers.CharField(required=False, allow_blank=True)
    name = serializers.CharField(required=False, allow_blank=True)
    pin = serializers.CharField()

    def validate(self, attrs):
        if not attrs.get("user_id") and not attrs.get("name"):
            raise serializers.ValidationError("Sign in with your name (or user id) and PIN")
        return attrs


def _tokens(user: User) -> dict:
    refresh = RefreshToken.for_user(user)
    return {"access": str(refresh.access_token), "refresh": str(refresh)}


class LoginView(APIView):
    """POST /auth/login {name | user_id, pin} -> {access, refresh, user}.

    Deliberately outside the write transaction: a wrong PIN must still count
    towards the lockout even though the request is refused.
    """

    permission_classes = [AllowAny]
    authentication_classes: list = []

    def post(self, request):
        data = LoginSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        try:
            user = services.authenticate_pin(
                user_id=data.validated_data.get("user_id") or None,
                name=data.validated_data.get("name") or None,
                pin=data.validated_data["pin"],
            )
        except services.SignInRefused as refused:
            return Response({"error": {"code": refused.code, "message": refused.message}}, status=refused.status)
        return Response({**_tokens(user), "user": UserSerializer(user).data})


class _ActiveRefreshSerializer(TokenRefreshSerializer):
    default_error_messages = {"no_active_account": "This account has been deactivated — ask an Admin"}


class RefreshView(TokenRefreshView):
    """POST /auth/refresh {refresh} -> {access}. Refused once deactivated."""

    serializer_class = _ActiveRefreshSerializer


class StaffDirectoryView(APIView):
    """GET /auth/staff — who can sign in, for the phone's PIN-pad picker."""

    permission_classes = [AllowAny]
    authentication_classes: list = []

    def get(self, request):
        people = User.objects.filter(active=True).order_by("name")
        return Response([
            {"id": u.id, "name": u.name, "role": u.role, "role_label": u.role_label,
             "home_branch": u.home_branch, "has_pin": u.has_pin}
            for u in people
        ])


class MeView(ShopView, APIView):
    def get(self, request):
        return Response(UserSerializer(request.user).data)


class MyPinView(ShopView, APIView):
    """POST /me/pin {current_pin, new_pin}."""

    def post(self, request):
        data = OwnPinSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        user = services.change_own_pin(self.ctx, data.validated_data["current_pin"], data.validated_data["new_pin"])
        # The old tokens die with the old PIN; hand back fresh ones.
        return Response({**_tokens(user), "user": UserSerializer(user).data})


class UserViewSet(ShopView, mixins.ListModelMixin, mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    """GET/POST /users, GET/PATCH/DELETE /users/{id}, deactivate, reactivate, pin."""

    serializer_class = UserSerializer
    queryset = User.objects.all().order_by("name")
    lookup_value_regex = "[^/]+"

    def get_queryset(self):
        queryset = super().get_queryset()
        params = self.request.query_params
        if params.get("active") in ("true", "1"):
            queryset = queryset.filter(active=True)
        elif params.get("active") in ("false", "0"):
            queryset = queryset.filter(active=False)
        if params.get("role"):
            queryset = queryset.filter(role=params["role"])
        if params.get("branch"):
            queryset = queryset.filter(home_branch=params["branch"])
        if params.get("q"):
            queryset = queryset.filter(name__icontains=params["q"])
        return filter_dates(queryset, self.request, "created_at")

    def create(self, request):
        data = UserCreateSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        v = data.validated_data
        user = services.add_user(
            self.ctx, user_id=v.get("id") or None, name=v["name"], role=v["role"],
            home_branch=v.get("home_branch"), contact_number=v.get("contact_number"), pin=v["pin"],
        )
        return Response(UserSerializer(user).data, status=status.HTTP_201_CREATED)

    def partial_update(self, request, pk=None):
        data = UserUpdateSerializer(data=request.data, partial=True)
        data.is_valid(raise_exception=True)
        changes = services.update_user(self.ctx, pk, **data.validated_data)
        return Response({"user": UserSerializer(services.get_user(pk)).data, "changes": changes})

    def destroy(self, request, pk=None):
        services.delete_user(self.ctx, pk)
        return Response(status=status.HTTP_204_NO_CONTENT)

    @action(detail=True, methods=["post"])
    def deactivate(self, request, pk=None):
        return Response(UserSerializer(services.set_active(self.ctx, pk, False)).data)

    @action(detail=True, methods=["post"])
    def reactivate(self, request, pk=None):
        return Response(UserSerializer(services.set_active(self.ctx, pk, True)).data)

    @action(detail=True, methods=["post"])
    def pin(self, request, pk=None):
        data = PinSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        return Response(UserSerializer(services.set_pin(self.ctx, pk, data.validated_data["pin"])).data)
