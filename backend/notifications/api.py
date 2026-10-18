"""POST /devices and DELETE /devices/{token} — which handset gets whose
notifications.

The owner is always the signed-in person, never a field in the body. Like
signing in, registering a handset changes no shop record, so it writes no
TransactionLog row.
"""

from django.utils import timezone
from rest_framework import serializers, status
from rest_framework.response import Response
from rest_framework.views import APIView

from shop.api.base import ShopView

from .models import Device


class DeviceInput(serializers.Serializer):
    token = serializers.CharField(max_length=4096, trim_whitespace=True)
    platform = serializers.ChoiceField(choices=Device.Platform.choices, required=False,
                                       default=Device.Platform.ANDROID)


def _present(device: Device) -> dict:
    return {"token": device.token, "platform": device.platform, "user_id": device.user_id,
            "created_at": serializers.DateTimeField().to_representation(device.created_at),
            "last_seen_at": serializers.DateTimeField().to_representation(device.last_seen_at)}


class DeviceListView(ShopView, APIView):
    def post(self, request):
        """Registers this handset for the signed-in person. One row per token:
        a token already on file — even under someone else, because the same
        phone is now in another person's hands — moves to them (200)."""
        data = DeviceInput(data=request.data)
        data.is_valid(raise_exception=True)
        token, platform = data.validated_data["token"], data.validated_data["platform"]
        now = timezone.now()
        device = Device.objects.select_for_update().filter(token=token).first()
        if device is None:
            device = Device.objects.create(token=token, user=request.user, platform=platform, created_at=now,
                                           last_seen_at=now)
            return Response(_present(device), status=status.HTTP_201_CREATED)
        device.user = request.user
        device.platform = platform
        device.last_seen_at = now
        device.save()
        return Response(_present(device), status=status.HTTP_200_OK)


class DeviceDetailView(ShopView, APIView):
    def delete(self, request, token):
        """Signing out: this handset stops receiving the person's notifications.
        Removing a token that isn't there — or isn't yours — is still 204."""
        Device.objects.filter(token=token, user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)
