"""The two branches, and database-level append-only guards.

The transaction log and the rate history are evidence; a log that can be
quietly corrected is not evidence of anything. These triggers refuse UPDATE
and DELETE on both tables for every client of the database, not just this
app. (TRUNCATE, used only by test teardown and a deliberate demo reset, is a
separate statement and is not blocked.)
"""

from django.db import migrations

APPEND_ONLY_SQL = """
CREATE OR REPLACE FUNCTION shop_refuse_change() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER shop_transactionlog_append_only
    BEFORE UPDATE OR DELETE ON shop_transactionlog
    FOR EACH ROW EXECUTE FUNCTION shop_refuse_change();

CREATE TRIGGER shop_ratechange_append_only
    BEFORE UPDATE OR DELETE ON shop_ratechange
    FOR EACH ROW EXECUTE FUNCTION shop_refuse_change();
"""

DROP_SQL = """
DROP TRIGGER IF EXISTS shop_transactionlog_append_only ON shop_transactionlog;
DROP TRIGGER IF EXISTS shop_ratechange_append_only ON shop_ratechange;
DROP FUNCTION IF EXISTS shop_refuse_change();
"""


def create_branches(apps, schema_editor):
    Branch = apps.get_model("shop", "Branch")
    for branch_id in ("kidapawan", "davao"):
        Branch.objects.get_or_create(pk=branch_id)


class Migration(migrations.Migration):
    dependencies = [("shop", "0001_initial")]

    operations = [
        migrations.RunPython(create_branches, migrations.RunPython.noop),
        migrations.RunSQL(APPEND_ONLY_SQL, DROP_SQL),
    ]
