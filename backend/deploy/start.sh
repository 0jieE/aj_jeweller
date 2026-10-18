#!/bin/sh
# What the container does on its own: bring the database up to date, collect
# the admin's static files, then serve.
#
# Safe to run on every start. `migrate` does nothing when there is nothing to
# apply, and two containers starting at once take a lock rather than fighting.
set -e

python manage.py migrate --noinput
python manage.py collectstatic --noinput

# Render and most platforms assign the port; nginx in front of compose does not.
exec gunicorn config.wsgi:application \
    --bind "0.0.0.0:${PORT:-8000}" \
    --workers "${WEB_CONCURRENCY:-3}" \
    --timeout 120 \
    --access-logfile - \
    --error-logfile -
