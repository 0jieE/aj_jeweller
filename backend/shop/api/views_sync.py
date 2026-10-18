"""/sync/*: the one-time import, and the offline outbox (snapshot, changes, push).

The outbox, end to end:

1. The phone signs in and takes GET /sync/snapshot (or /sync/changes?since=).
2. Offline, it keeps working on its own copy and queues every write it makes
   — method, path, JSON body, an Idempotency-Key, and when it happened —
   choosing record ids itself, as it already does.
3. Back online it sends the queue, in order, to POST /sync/push. Each
   operation runs exactly as if it had been sent live: same rules, same
   refusals, same one log row, dated when it happened on the phone. A replayed
   key returns its first result, so resending a queue never acts twice.
4. It reads each result. A 422 is a refusal the person must see ("Payment for
   this order was already received") — the phone shows it and drops or fixes
   that change. Then it pulls /sync/changes to take the server's version.
"""

import json

from django.db import transaction
from django.test import RequestFactory
from django.urls import Resolver404, resolve
from rest_framework import exceptions, serializers
from rest_framework.response import Response
from rest_framework.views import APIView

from ..services import importer
from ..services import sync as sync_service
from .base import ShopView, query_bool, read_branch

API_PREFIX = "/api/v1/"
MAX_OPERATIONS = 500


class ImportView(ShopView, APIView):
    """POST /sync/import — the phone's JSON snapshot as the body (or a
    multipart `snapshot` file). `?dry_run=true` reports without writing."""

    def post(self, request):
        data = request.data
        upload = data.get("snapshot") if hasattr(data, "get") else None
        if upload is not None and hasattr(upload, "read"):
            try:
                data = json.loads(upload.read().decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise exceptions.ValidationError({"snapshot": ["That file is not a JSON snapshot"]}) from None
        elif isinstance(data, dict) and isinstance(data.get("snapshot"), dict):
            data = data["snapshot"]
        dry_run = bool(query_bool(request, "dry_run"))
        report = importer.import_snapshot(self.ctx, data, dry_run=dry_run, write_files=not dry_run)
        if dry_run:
            transaction.set_rollback(True)
        return Response(report)


class SnapshotView(ShopView, APIView):
    """GET /sync/snapshot?photos=false — everything in scope, in the phone's format."""

    def get(self, request):
        photos = query_bool(request, "photos")
        return Response(sync_service.full_snapshot(read_branch(request), photos=photos is not False))


class ChangesView(ShopView, APIView):
    """GET /sync/changes?since=<cursor>&photos=false"""

    def get(self, request):
        try:
            since = int(request.query_params.get("since", "0"))
        except ValueError:
            raise exceptions.ValidationError({"since": ["The cursor is a whole number"]}) from None
        photos = query_bool(request, "photos")
        return Response(sync_service.changes_since(since, read_branch(request), photos=photos is not False))


class OperationInput(serializers.Serializer):
    key = serializers.CharField(max_length=128)
    method = serializers.ChoiceField(choices=["POST", "PUT", "PATCH", "DELETE"])
    path = serializers.CharField(max_length=255)
    body = serializers.JSONField(required=False, default=dict)
    recorded_at = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class PushInput(serializers.Serializer):
    operations = OperationInput(many=True, allow_empty=True)
    stop_on_error = serializers.BooleanField(default=False)


class PushView(APIView):
    """POST /sync/push — replays a phone's queued writes, in order.

    Not wrapped in one transaction: each operation commits (or is refused) on
    its own, exactly as if it had been sent live, and is reported one by one.
    """

    def post(self, request):
        data = PushInput(data=request.data)
        data.is_valid(raise_exception=True)
        operations = data.validated_data["operations"]
        if len(operations) > MAX_OPERATIONS:
            raise exceptions.ValidationError({"operations": [f"Send at most {MAX_OPERATIONS} operations at a time"]})
        factory = RequestFactory()
        results = []
        stopped = False
        for op in operations:
            if stopped:
                results.append({"key": op["key"], "status": None, "skipped": True})
                continue
            result = self._run(factory, request, op)
            results.append(result)
            if result["status"] >= 400 and data.validated_data["stop_on_error"]:
                stopped = True
        applied = sum(1 for r in results if r.get("status") and r["status"] < 400)
        return Response({"results": results, "applied": applied,
                         "refused": sum(1 for r in results if r.get("status") and r["status"] >= 400),
                         "cursor": sync_service.cursor()})

    @staticmethod
    def _error(op, status, code, message):
        return {"key": op["key"], "status": status, "body": {"error": {"code": code, "message": message}}}

    def _run(self, factory, outer, op) -> dict:
        path = op["path"]
        if not path.startswith("/"):
            path = API_PREFIX + path
        if not path.startswith(API_PREFIX) or path.rstrip("/").endswith("/sync/push") or "/auth/" in path:
            return self._error(op, 400, "bad_path", f"{op['path']} cannot be replayed")
        try:
            match = resolve(path)
        except Resolver404:
            return self._error(op, 404, "not_found", f"{op['path']} is not an endpoint")
        headers = {
            "HTTP_AUTHORIZATION": outer.META.get("HTTP_AUTHORIZATION", ""),
            "HTTP_IDEMPOTENCY_KEY": op["key"],
            "HTTP_HOST": outer.get_host(),
        }
        if op.get("recorded_at"):
            headers["HTTP_X_RECORDED_AT"] = op["recorded_at"]
        inner = factory.generic(op["method"], path, data=json.dumps(op.get("body") or {}),
                                content_type="application/json", secure=outer.is_secure(), **headers)
        response = match.func(inner, *match.args, **match.kwargs)
        body = getattr(response, "data", None)
        result = {"key": op["key"], "status": response.status_code, "body": body}
        if response.get("Idempotent-Replayed"):
            result["replayed"] = True
        return result
