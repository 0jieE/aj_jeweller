"""Input fields shared by the serializers."""

import base64
import binascii
import io
from decimal import ROUND_HALF_UP

from django.core.files.base import ContentFile
from django.core.files.uploadedfile import UploadedFile
from PIL import Image, UnidentifiedImageError
from rest_framework import serializers

_FORMAT_EXT = {"JPEG": "jpg", "PNG": "png", "WEBP": "webp", "HEIF": "heic", "GIF": "gif"}
MAX_PHOTO_BYTES = 10 * 1024 * 1024


def grams_field(**kwargs) -> serializers.DecimalField:
    """Grams to 3 decimals. A phone double such as 15.749999999 is rounded,
    not refused — the scale only ever read three decimals."""
    return serializers.DecimalField(max_digits=10, decimal_places=3, rounding=ROUND_HALF_UP, **kwargs)


def money_field(**kwargs) -> serializers.IntegerField:
    """Integer centavos. Never a float."""
    return serializers.IntegerField(**kwargs)


def decode_photo(raw: bytes, *, validate: bool = True) -> ContentFile:
    ext = "jpg"
    if validate:
        if len(raw) > MAX_PHOTO_BYTES:
            raise serializers.ValidationError("A photo can be at most 10 MB")
        try:
            with Image.open(io.BytesIO(raw)) as image:
                fmt = image.format
                image.verify()
        except (UnidentifiedImageError, OSError, SyntaxError):
            raise serializers.ValidationError("That file is not a photo") from None
        ext = _FORMAT_EXT.get(fmt or "", "jpg")
    return ContentFile(raw, name=f"photo.{ext}")


def decode_base64(value: str) -> bytes:
    if value.startswith("data:") and "," in value:
        value = value.split(",", 1)[1]
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise serializers.ValidationError("A photo must be a file upload or base64 text") from None


class PhotoField(serializers.Field):
    """A photo as a multipart file upload, or as base64 text in JSON — the
    latter is how a queued offline write carries its photo."""

    def to_internal_value(self, data):
        if isinstance(data, UploadedFile):
            return decode_photo(data.read())
        if isinstance(data, str) and data:
            return decode_photo(decode_base64(data))
        raise serializers.ValidationError("A photo must be a file upload or base64 text")

    def to_representation(self, value):  # pragma: no cover — output uses photo_url
        return None
