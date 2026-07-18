#!/bin/sh

set -eu

manifest="frontend/web-assets/static/careerops/.vite/manifest.json"

echo "Waiting for the frontend asset manifest..."

until [ -f "${manifest}" ]; do
    sleep 1
done

echo "Applying database migrations..."
python manage.py migrate --noinput

echo "Starting the Django development server..."
exec python manage.py runserver 0.0.0.0:8000