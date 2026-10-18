# The server, as it runs for the shop.
#
# One image serves three roles, chosen by the command: the web process, the
# notification sender, and one-off jobs like `migrate` or `seed_demo`.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DJANGO_SETTINGS_MODULE=config.settings

# psycopg needs libpq; Pillow and reportlab need the image and font libraries.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        libjpeg62-turbo \
        zlib1g \
        libfreetype6 \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first, so a code change does not reinstall them.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# The desktop app, if a build has been committed to webapp/ (manage.py
# publish_webapp). WhiteNoise serves pre-compressed copies but does not
# compress on the fly, so compress here; with no app committed this does
# nothing and "/" says no app is deployed.
ENV WEB_APP_ROOT=/app/webapp
RUN if [ -f webapp/index.html ]; then python -m whitenoise.compress -q webapp; fi

# Never run as root: a photo upload should not be able to write anywhere.
RUN useradd --create-home --uid 10001 aj \
    && mkdir -p /app/media /app/staticfiles \
    && chown -R aj:aj /app
USER aj

EXPOSE 8000

# Migrates, collects static, then serves on $PORT — so a platform that only
# runs the image (Render and the like) needs no start command of its own.
# Compose overrides this for the notification sender and one-off jobs.
CMD ["sh", "deploy/start.sh"]
