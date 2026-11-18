#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=rakazo-native-test-$(openssl rand -hex 6)
image=ghcr.io/elie222/rakazo/app:v0.12.0@sha256:0ede140417319081bf646c97768976aaf0643e07b8ca2970d43da789ecff3b82
cleanup() { docker rm -fv "$prefix-worker" "$prefix-api" "$prefix-db" >/dev/null 2>&1 || true; docker volume rm "$prefix-data" >/dev/null 2>&1 || true; docker network rm "$prefix" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create "$prefix" >/dev/null
docker volume create "$prefix-data" >/dev/null
owner=$(openssl rand -hex 24); runtime=$(openssl rand -hex 24)
docker run -d --name "$prefix-db" --network "$prefix" --network-alias db -e POSTGRES_PASSWORD="$owner" -e POSTGRES_DB=rakazo postgres:16-alpine >/dev/null
for attempt in $(seq 1 45); do docker exec "$prefix-db" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
export DATABASE_URL="postgres://rakazo_app:$runtime@db:5432/rakazo"
docker run --rm --network "$prefix" -w /app/apps/api -e DATABASE_URL -e DATABASE_MIGRATION_URL="postgres://postgres:$owner@db:5432/rakazo" "$image" node dist/cli/migrate-database.js >/dev/null
port=${RAKAZO_TEST_PORT:-43191}; origin="http://127.0.0.1:$port"
shared=(--network "$prefix" -e DATABASE_URL -e BETTER_AUTH_URL="$origin" -e WEB_ORIGIN="$origin" -e API_URL="$origin"
  -e BETTER_AUTH_SECRET="$(openssl rand -hex 32)" -e ENCRYPTION_KEY="$(openssl rand -hex 32)" -e SCREEN_PROXY_SECRET="$(openssl rand -hex 32)"
  -e AGENT_RUNTIME=scripted -e SANDBOX_PROVIDER=fake -e RAKAZO_LIVE_MODEL_CATALOG=off -e PI_DEFAULT_PROVIDER=local -e PI_DEFAULT_MODEL=native-fixture
  -e PI_DEFAULT_CREDENTIALS=host -e RAKAZO_LOCAL_MODELS=native-fixture -e RAKAZO_LOCAL_MODELS_URL=http://127.0.0.1:9/v1 -e DATA_DIR=/data -v "$prefix-data:/data")
docker run -d --name "$prefix-api" "${shared[@]}" -p "127.0.0.1:$port:3100" -w /app/apps/api -e API_HOST=0.0.0.0 -e API_PORT=3100 -e SIGNUPS_ENABLED=true -e AUTH_PASSWORD_ENABLED=true "$image" node dist/index.js >/dev/null
docker run -d --name "$prefix-worker" "${shared[@]}" --cap-drop=ALL --security-opt=no-new-privileges -w /app/apps/worker "$image" node dist/index.js >/dev/null
for attempt in $(seq 1 45); do
  if [[ $(docker inspect -f '{{.State.Running}}' "$prefix-api") != true ]]; then docker logs --tail 12 "$prefix-api" >&2; exit 1; fi
  curl -fsS -H 'Content-Type: application/json' -d '{"json":{}}' "$origin/rpc/health" >/dev/null 2>&1 && break; sleep 1
done
curl -fsS -H 'Content-Type: application/json' -d '{"json":{}}' "$origin/rpc/health" | jq -e '.json.ok == true' >/dev/null
export TEST_RUNNER_RAKAZO_TEST_ORIGIN="$origin" TEST_RUNNER_RAKAZO_TEST_PASSWORD="$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')"
body=$(jq -nc --arg password "$TEST_RUNNER_RAKAZO_TEST_PASSWORD" '{name:"Native QA",email:"native@example.test",password:$password}')
curl -fsS -H 'Content-Type: application/json' -H 'Origin: rakazo://' -d "$body" "$origin/api/auth/sign-up/email" >/dev/null
cd "$root"; "$@"
