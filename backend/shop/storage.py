"""Cloudinary as Django's file storage — every photo and receipt PDF.

Used when CLOUDINARY_URL is set (see settings.STORAGES); local disk otherwise.
Code saves and reads files through Django's FileField API exactly as before.

* Photos (customers, pieces, cash-release and loan proofs, disposal
  settlements) are Cloudinary *image* assets; receipt PDFs are *raw* assets, so
  they are delivered as the file the shop issued (Cloudinary blocks PDF
  delivery as images on many accounts).
* Everything is uploaded as type **authenticated**: an asset can only be
  fetched through a URL signed with the account's secret, which the server
  hands out (photo_url, pdf links). Customer faces and counted cash are not
  public files anyone can enumerate.
* The name stored in the database stays Django's ("items/7H3M2Q-….jpg"); the
  Cloudinary public id is that name under CLOUDINARY_FOLDER.
"""

from pathlib import PurePosixPath
from urllib.parse import urlparse

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import Storage
from django.utils.deconstruct import deconstructible

IMAGE_EXTENSIONS = frozenset({"jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff"})
DELIVERY_TYPE = "authenticated"


def _configure() -> None:
    import cloudinary

    url = urlparse(settings.CLOUDINARY_URL)
    if url.scheme != "cloudinary" or not url.hostname or not url.username or not url.password:
        raise ValueError("CLOUDINARY_URL must look like cloudinary://<api_key>:<api_secret>@<cloud_name>")
    cloudinary.config(cloud_name=url.hostname, api_key=url.username, api_secret=url.password, secure=True)


@deconstructible
class CloudinaryStorage(Storage):
    def __init__(self, folder: str | None = None):
        self.folder = (folder if folder is not None else settings.CLOUDINARY_FOLDER).strip("/")
        _configure()

    # --- naming --------------------------------------------------------------
    @staticmethod
    def _ext(name: str) -> str:
        return PurePosixPath(name).suffix.lower().lstrip(".")

    def _is_image(self, name: str) -> bool:
        return self._ext(name) in IMAGE_EXTENSIONS

    def _resource_type(self, name: str) -> str:
        return "image" if self._is_image(name) else "raw"

    def _public_id(self, name: str) -> str:
        """Images drop their extension (Cloudinary keeps the format); raw files keep it."""
        path = str(PurePosixPath(name).with_suffix("")) if self._is_image(name) else name
        return f"{self.folder}/{path}" if self.folder else path

    # --- Storage API ---------------------------------------------------------
    def _save(self, name: str, content) -> str:
        import cloudinary.uploader

        if hasattr(content, "seek"):
            content.seek(0)
        data = content.read()
        cloudinary.uploader.upload(
            data, public_id=self._public_id(name), resource_type=self._resource_type(name), type=DELIVERY_TYPE,
            overwrite=True, invalidate=True, use_filename=False, unique_filename=False,
        )
        return name

    def url(self, name: str) -> str:
        from cloudinary.utils import cloudinary_url

        options = {"resource_type": self._resource_type(name), "type": DELIVERY_TYPE, "sign_url": True,
                   "secure": True}
        if self._is_image(name):
            options["format"] = self._ext(name)
        return cloudinary_url(self._public_id(name), **options)[0]

    def _open(self, name: str, mode: str = "rb"):
        """Downloads the asset — used when a snapshot sends a photo to the phone
        as base64, or a receipt PDF is streamed."""
        import requests

        response = requests.get(self.url(name), timeout=30)
        if response.status_code == 404:
            raise FileNotFoundError(name)
        response.raise_for_status()
        return ContentFile(response.content, name=name)

    def delete(self, name: str) -> None:
        import cloudinary.uploader

        if name:
            cloudinary.uploader.destroy(self._public_id(name), resource_type=self._resource_type(name),
                                        type=DELIVERY_TYPE, invalidate=True)

    def exists(self, name: str) -> bool:
        # Every upload path carries the record id and a microsecond timestamp,
        # so names never collide; asking Cloudinary would cost an Admin API call.
        return False

    def size(self, name: str) -> int:
        import cloudinary.api

        resource = cloudinary.api.resource(self._public_id(name), resource_type=self._resource_type(name),
                                           type=DELIVERY_TYPE)
        return int(resource.get("bytes", 0))
