#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE=${COMPOSE_FILE:-"$ROOT_DIR/docker-compose.prod.yml"}
ENV_FILE=${ENV_FILE:-"$ROOT_DIR/.env"}
# Версия самого обновлятеля: нужна для флага --version и для проверки замены
# файла после скачивания. Обновляется при публикации скриптов.
SCRIPT_VERSION=0.16.0

MANIFEST_URL=${UPDATE_MANIFEST_URL:-}
MANIFEST_TOKEN=${UPDATE_MANIFEST_TOKEN:-}
OFFLINE_BUNDLE=${UPDATE_OFFLINE_BUNDLE:-}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
ASSUME_YES=${ASSUME_YES:-0}
TARGET_VERSION=

log() { printf '%s [update] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { printf '%s [update] ОШИБКА: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Обновление Helpdesk Portal (Docker-развёртывание).

Использование:
  scripts/update.sh [версия] [флаги]

Аргументы:
  версия            целевая версия (по умолчанию — последняя из манифеста)

Флаги/переменные:
  -y, --yes         без подтверждения
      --manifest U  URL манифеста обновлений (или UPDATE_MANIFEST_URL)
      --token T     Bearer-токен для манифеста (или UPDATE_MANIFEST_TOKEN)
      --offline D   путь к оффлайн-бандлу новой версии (или UPDATE_OFFLINE_BUNDLE)
      --check       только показать, что доступно обновление
  -h, --help        эта справка
      --version     показать версию самого обновлятеля и выйти

Переменные окружения:
  COMPOSE_FILE, ENV_FILE, HEALTH_TIMEOUT, ASSUME_YES=1

Примеры:
  scripts/update.sh --check
  scripts/update.sh 0.15.0 --yes
EOF
}

CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --check) CHECK_ONLY=1 ;;
    --manifest) MANIFEST_URL=${2:-}; shift ;;
    --token) MANIFEST_TOKEN=${2:-}; shift ;;
    --offline) OFFLINE_BUNDLE=${2:-}; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "helpdesk-portal update.sh $SCRIPT_VERSION"; exit 0 ;;
    -*) die "неизвестный флаг: $1" ;;
    *) TARGET_VERSION=$1 ;;
  esac
  shift
done

[ -f "$COMPOSE_FILE" ] || die "нет файла композа: $COMPOSE_FILE"
[ -f "$ENV_FILE" ] || die "нет env-файла: $ENV_FILE"
command -v docker > /dev/null 2>&1 || die "docker не найден"
docker compose version > /dev/null 2>&1 || die "нужен docker compose v2"

current_version() {
  sed -n 's/^APP_VERSION=//p' "$ENV_FILE" | tail -n 1
}

CURRENT_VERSION=$(current_version)
[ -n "$CURRENT_VERSION" ] || die "APP_VERSION не найден в $ENV_FILE"

env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -n 1
}

set_env_value() {
  key=$1
  value=$2
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

GHCR_USER=${UPDATE_GHCR_USER:-$(env_value UPDATE_GHCR_USER)}
GHCR_USER=${GHCR_USER:-${USER:-$(id -un)}}
GHCR_TOKEN=${UPDATE_GHCR_TOKEN:-$(env_value UPDATE_GHCR_TOKEN)}

load_offline_images() {
  bundle=$1
  [ -d "$bundle/images" ] || die "в оффлайн-бандле нет каталога images: $bundle"
  [ -f "$bundle/VERSION" ] || die "в оффлайн-бандле нет файла VERSION: $bundle"
  log "загружаю образы из $bundle/images"
  for image_file in "$bundle"/images/*.tar; do
    [ -e "$image_file" ] || continue
    if docker load -i "$image_file" > /dev/null 2>&1; then
      log "  загружен $(basename "$image_file")"
    else
      die "не удалось загрузить образ $image_file"
    fi
  done
  API_IMAGE_LOCAL=1
}

version_gt() {
  [ "$1" != "$2" ] || return 1
  first=$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  [ "$first" = "$1" ]
}

fetch_manifest() {
  url=$MANIFEST_URL
  if [ -z "$url" ]; then
    url=$(sed -n 's/^UPDATE_MANIFEST_URL=//p' "$ENV_FILE" | tail -n 1)
  fi
  if [ -z "$url" ]; then
    cat >&2 <<EOF
[update] ОШИБКА: не задан адрес манифеста обновлений.

Включить сетевое обновление — одна строка в $ENV_FILE:
  UPDATE_MANIFEST_URL=https://raw.githubusercontent.com/matemfromrussia/helpdesk-portal-updates/main/update.json

Или разово, без правки .env:
  scripts/update.sh --check --manifest <url>
  scripts/update.sh <версия> --manifest <url>

Пока адрес не задан, обновление по сети невозможно; оффлайн-обновление
(скрипт обновления с бандлом) работает и без него.
EOF
    exit 1
  fi
  token=$MANIFEST_TOKEN
  if [ -z "$token" ]; then
    token=$(sed -n 's/^UPDATE_MANIFEST_TOKEN=//p' "$ENV_FILE" | tail -n 1)
  fi
  if command -v curl > /dev/null 2>&1; then
    if [ -n "$token" ]; then
      curl -fsSL -H "Authorization: Bearer $token" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    die "нужен curl для загрузки манифеста"
  fi
}

json_field() {
  node -e "
    let raw='';
    process.stdin.on('data',c=>raw+=c);
    process.stdin.on('end',()=>{
      const data=JSON.parse(raw);
      // Поддерживается вложенный путь: images.api
      const value='$1'.split('.').reduce((acc,key)=>acc&&acc[key],data);
      if (Array.isArray(value)) { console.log(value.join('\n')); }
      else if (value===undefined || value===null) { console.log(''); }
      else { console.log(value); }
    });
  " 2> /dev/null || true
}

AVAILABLE_VERSION=$TARGET_VERSION
CHANGELOG=""
if [ -n "$OFFLINE_BUNDLE" ]; then
  BUNDLE_VERSION=$(tr -d ' \n' < "$OFFLINE_BUNDLE/VERSION" 2>/dev/null || true)
  [ -n "$BUNDLE_VERSION" ] || die "не удалось прочитать версию из $OFFLINE_BUNDLE/VERSION"
  if [ -n "$TARGET_VERSION" ] && [ "$TARGET_VERSION" != "$BUNDLE_VERSION" ]; then
    die "версия в бандле ($BUNDLE_VERSION) не совпадает с запрошенной ($TARGET_VERSION)"
  fi
  AVAILABLE_VERSION=$BUNDLE_VERSION
  if [ -f "$OFFLINE_BUNDLE/SHA256SUMS" ]; then
    log "проверяю контрольные суммы бандла"
    (cd "$OFFLINE_BUNDLE" && sha256sum -c SHA256SUMS > /dev/null 2>&1) \
      || die "контрольные суммы бандла не совпали"
  fi
fi
# Манифест нужен всегда, а не только когда версия не указана аргументом: из
# него берутся ссылки на образы и список изменений. Раньше при запуске вида
# «update.sh 0.16.0» манифест не загружался вовсе, и обновлятор не знал, что
# качать.
MANIFEST=""
manifest_url_configured=$MANIFEST_URL
[ -n "$manifest_url_configured" ] || manifest_url_configured=$(sed -n 's/^UPDATE_MANIFEST_URL=//p' "$ENV_FILE" | tail -n 1)
if [ -n "$manifest_url_configured" ]; then
  log "загружаю манифест обновлений"
  if MANIFEST=$(fetch_manifest) && [ -n "$MANIFEST" ]; then
    [ -n "$AVAILABLE_VERSION" ] || AVAILABLE_VERSION=$(printf '%s' "$MANIFEST" | json_field version)
    CHANGELOG=$(printf '%s' "$MANIFEST" | json_field changelog)
  else
    MANIFEST=""
    [ -n "$AVAILABLE_VERSION" ] || die "не удалось загрузить манифест обновлений по адресу $manifest_url_configured"
    log "внимание: манифест недоступен — список изменений и ссылки на образы неизвестны"
  fi
fi
[ -n "$AVAILABLE_VERSION" ] || die "не задана версия: укажите её аргументом или почините загрузку манифеста"

log "текущая версия: $CURRENT_VERSION"
log "доступная версия: $AVAILABLE_VERSION"

if [ "$AVAILABLE_VERSION" = "$CURRENT_VERSION" ]; then
  log "установлена актуальная версия, обновление не требуется"
  exit 0
fi

if ! version_gt "$AVAILABLE_VERSION" "$CURRENT_VERSION"; then
  if [ -n "$TARGET_VERSION" ]; then
    die "даунгрейд не поддерживается: $AVAILABLE_VERSION старше установленной $CURRENT_VERSION"
  fi
  die "версия $AVAILABLE_VERSION не новее установленной $CURRENT_VERSION"
fi

if [ -n "$CHANGELOG" ]; then
  log "список изменений:"
  printf '%s\n' "$CHANGELOG" | while IFS= read -r line; do
    [ -n "$line" ] && printf '  - %s\n' "$line"
  done
fi

if [ "$CHECK_ONLY" = "1" ]; then
  log "режим проверки: обновление доступно ($CURRENT_VERSION -> $AVAILABLE_VERSION)"
  exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
  printf 'Обновить %s -> %s? [y/N] ' "$CURRENT_VERSION" "$AVAILABLE_VERSION"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) log "отменено пользователем"; exit 0 ;;
  esac
fi

ENV_BACKUP="$ENV_FILE.bak.$(date -u '+%Y%m%d%H%M%S')"
cp "$ENV_FILE" "$ENV_BACKUP"
log "резервная копия окружения: $ENV_BACKUP"

export APP_VERSION=$AVAILABLE_VERSION

# Список файлов compose должен совпадать с тем, который использовал установщик:
# оффлайн-override подменяет образы на локальные, а override файловых секретов
# монтирует /run/secrets. Без них пересоздание контейнеров на updater-e оставит
# API без DATABASE_URL и JWT_SECRET — то есть убьёт установку.
# Режимы читаем из .env, а для установок, сделанных установщиком до 0.15.2
# (там маркеров ещё не было), выводим их по файлам на диске: файловый режим
# секретов всегда создаёт secrets/database_url, оффлайн-установка тянет образы
# не из реестра.
secrets_mode() {
  local mode; mode=$(env_value SECRETS_MODE)
  if [ -z "$mode" ]; then
    if [ -s "$ROOT_DIR/secrets/database_url" ] || [ -s "$ROOT_DIR/secrets/jwt_secret" ]; then
      mode=files
    else
      mode=env
    fi
  fi
  printf '%s' "$mode"
}

image_source() {
  local src; src=$(env_value IMAGE_SOURCE)
  if [ -z "$src" ]; then
    case "$(env_value API_IMAGE)" in
      ghcr.io/*|"") src=registry ;;
      *) src=offline ;;
    esac
  fi
  printf '%s' "$src"
}

# Имя проекта compose — критично: в docker-compose.prod.yml зашито имя по
# умолчанию, поэтому без явного -p обновление применялось бы к ЧУЖОМУ проекту
# (и пересоздавало его контейнеры вместо наших). Порядок: .env → работающие
# контейнеры этой установки → имя по умолчанию.
project_name() {
  local name; name=$(env_value COMPOSE_PROJECT_NAME)
  if [ -z "$name" ]; then
    name=$(docker ps -a --filter "label=com.docker.compose.project" \
      --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null \
      | awk -F'|' -v f="$(basename "$COMPOSE_FILE")" 'index($2, f) {print $1; exit}')
  fi
  printf '%s' "${name:-helpdesk-portal-prod}"
}

# Обёртка compose.sh (её создаёт установщик) знает про режимы этой установки —
# пользуемся ею, чтобы не расходиться с тем, как ставили систему.
COMPOSE_WRAPPER="$ROOT_DIR/compose.sh"
if [ -x "$COMPOSE_WRAPPER" ]; then
  compose() { "$COMPOSE_WRAPPER" "$@"; }
else
  # Скрипт объявлен через /bin/sh и обязан работать в dash, поэтому здесь
  # никаких массивов bash (local -a ... =( ... )) — dash их не умеет и падает
  # с синтаксической ошибкой ещё до выполнения. Файлы compose подставляются
  # через $COMPOSE_FILES с разделением пробелами.
  compose() {
    files="-p $(project_name) -f $COMPOSE_FILE"
    if [ "$(image_source)" = "offline" ] && [ -f "$ROOT_DIR/deploy/offline/docker-compose.offline.yml" ]; then
      files="$files -f deploy/offline/docker-compose.offline.yml"
    fi
    if [ "$(secrets_mode)" = "files" ] && [ -f "$ROOT_DIR/deploy/docker-compose.secrets.yml" ]; then
      files="$files -f deploy/docker-compose.secrets.yml"
    fi
    # shellcheck disable=SC2086  # список файлов намеренно разбивается по словам
    docker compose $files --env-file "$ENV_FILE" "$@"
  }
fi


image_ref() {
  key=$1
  fallback=$2
  value=$(sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1)
  printf '%s' "${value:-$fallback}"
}

API_IMAGE=$(image_ref API_IMAGE helpdesk-portal-api)
WEB_IMAGE=$(image_ref WEB_IMAGE helpdesk-portal-web)

uses_registry() {
  case "$1" in
    */*) return 0 ;;
    *) return 1 ;;
  esac
}

registry_host() {
  printf '%s' "${1%%/*}"
}

if [ -n "$OFFLINE_BUNDLE" ]; then
  log "офлайн-обновление: бандл $OFFLINE_BUNDLE (Registry не используется)"
  load_offline_images "$OFFLINE_BUNDLE"
  if [ -n "${API_IMAGE:-}" ] || [ -n "${WEB_IMAGE:-}" ]; then
    log "в .env задан явный образ — приведу его к локальному имени из бандла"
    set_env_value API_IMAGE "helpdesk-portal-api"
    set_env_value WEB_IMAGE "helpdesk-portal-web"
  fi
else
  # Манифест — источник истины для выпущенной версии: в нём полные ссылки на
  # образы. Локальное имя в .env (установка из оффлайн-бандла) НЕ означает
  # «собирать из исходников»: в комплекте исходников нет, и сборка падала с
  # «lstat <каталог>/apps: no such file or directory».
  # В манифесте образы с тегом (ghcr.io/owner/api:0.16.0), а compose ждёт имя
  # без тега и дописывает версию сам (${API_IMAGE}:${APP_VERSION}). Тег снимаем
  # только в последнем сегменте пути, иначе сломается реестр с портом (host:443).
  strip_tag() {
    case "$1" in
      */*) last=${1##*/}; head=${1%/*}
           case "$last" in *:*) printf '%s/%s' "$head" "${last%%:*}" ;; *) printf '%s' "$1" ;; esac ;;
      *)   printf '%s' "$1" ;;
    esac
  }
  manifest_api=""
  manifest_web=""
  if [ -n "$MANIFEST" ]; then
    manifest_api=$(printf '%s' "$MANIFEST" | json_field images.api)
    manifest_web=$(printf '%s' "$MANIFEST" | json_field images.web)
  fi
  manifest_api=$(strip_tag "$manifest_api")
  manifest_web=$(strip_tag "$manifest_web")
  has_sources=0
  [ -d "$ROOT_DIR/apps" ] && has_sources=1

  target_api=$API_IMAGE
  target_web=$WEB_IMAGE
  if uses_registry "$manifest_api"; then
    target_api=$manifest_api
    target_web=${manifest_web:-$WEB_IMAGE}
    if [ "$API_IMAGE" != "$target_api" ]; then
      log "в .env образ указан локально ($API_IMAGE) — беру из манифеста: $target_api"
      set_env_value API_IMAGE "$target_api"
      API_IMAGE=$target_api
      if [ -n "$manifest_web" ] && [ "$WEB_IMAGE" != "$manifest_web" ]; then
        set_env_value WEB_IMAGE "$manifest_web"
        WEB_IMAGE=$manifest_web
      fi
    fi
  fi

  if uses_registry "$target_api" || uses_registry "$target_web"; then
    if [ -n "$GHCR_TOKEN" ]; then
      registry=$(printf '%s\n%s\n' "$target_api" "$target_web" \
        | while IFS= read -r ref; do
            case "$ref" in
              */*) printf '%s\n' "${ref%%/*}" ;;
            esac
          done | sort -u | head -n 1)
      [ -n "$registry" ] || registry=ghcr.io
      log "логин в реестр $registry (пользователь $GHCR_USER)"
      if ! printf '%s' "$GHCR_TOKEN" | docker login "$registry" --username "$GHCR_USER" --password-stdin > /dev/null; then
        die "не удалось войти в реестр $registry"
      fi
    else
      log "UPDATE_GHCR_TOKEN не задан — использую существующий docker login"
    fi
    # Предпроверка до перекачки: без неё compose pull повторяет одну и ту же
    # ошибку десятки раз и падает без объяснения (в логе стенда так и вышло).
    # docker manifest inspect отвечает за ~2 секунды и говорит прямо.
    probe_ref=$target_api
    case "$target_api" in
      *:*) probe_ref=$target_api ;;
      *)   probe_ref="$target_api:$AVAILABLE_VERSION" ;;
    esac
    if ! docker manifest inspect "$probe_ref" > /dev/null 2> /tmp/update-probe.txt; then
      probe_err=$(head -n 1 /tmp/update-probe.txt 2> /dev/null || echo "")
      rm -f /tmp/update-probe.txt
      cat >&2 <<EOF
[update] ОШИБКА: нет доступа к образу $probe_ref

Ответ реестра: ${probe_err:-нет ответа}

Образы лежат в приватном GHCR, поэтому до загрузки нужен вход:

  # вариант 1 — разовый вход (без записи токена в файлы проекта)
  read -rsp 'GHCR токен (scope read:packages): ' TOKEN; echo
  printf '%s' "\$TOKEN" | docker login ghcr.io -u <ваш-логин> --password-stdin

  # вариант 2 — вписать в .env установки, обновлятор войдёт сам
  #   UPDATE_GHCR_USER=<ваш-логин>
  #   UPDATE_GHCR_TOKEN=<токен>

Либо обновиться оффлайн-бандлом, для которого реестр не нужен:
  scripts/update.sh $AVAILABLE_VERSION --offline /путь/к/bандл
EOF
      exit 1
    fi
    rm -f /tmp/update-probe.txt
    log "подтягиваю образы $target_api:$AVAILABLE_VERSION и $target_web:$AVAILABLE_VERSION"
    if ! compose pull; then
      die "не удалось получить образы (проверьте docker login и права на репозиторий)"
    fi
  else
    if [ "$has_sources" != "1" ]; then
      cat >&2 <<EOF
[update] ОШИБКА: в $ROOT_DIR нет исходников, а в манифесте нет ссылок на образы
в реестре — собрать $AVAILABLE_VERSION не из чего и скачать нечего.

Варианты:
  1) войти в приватный реестр и обновить по сети — в .env нужны
     UPDATE_GHCR_USER и UPDATE_GHCR_TOKEN (токен со scope read:packages);
  2) обновиться оффлайн-бандлом:
     scripts/update.sh $AVAILABLE_VERSION --offline /путь/к/bundle
EOF
      exit 1
    fi
    log "образы заданы локально ($API_IMAGE) — собираю из исходников"
    if ! compose build api web; then
      die "не удалось собрать образы локально"
    fi
  fi
fi

log "запускаю сервисы"
compose up -d --remove-orphans

rollback() {
  log "откат на $CURRENT_VERSION"
  cp "$ENV_BACKUP" "$ENV_FILE"
  export APP_VERSION=$CURRENT_VERSION
  compose up -d --remove-orphans || true
  wait_healthy || true
}

# Проверяем, что контейнеры поднялись именно с новым образом.
#
# Одного «healthy» мало: если образ не скачался, compose может оставить прежние
# контейнеры, они останутся healthy, и обновление рапортовало бы об успехе при
# старой версии. Именно так вышло на стенде: .env записали 0.16.1, а контейнеры
# остались 0.14.7. Смотрим на .Config.Image каждого контейнера, а не на статус.
verify_running_images() {
  [ "$(image_source)" = "offline" ] && return 0
  for svc in api web; do
    cid=$(compose ps -q "$svc" 2> /dev/null | head -n 1)
    if [ -z "$cid" ]; then
      printf '  %s: контейнер не найден\n' "$svc" >&2
      return 1
    fi
    actual=$(docker inspect --format '{{.Config.Image}}' "$cid" 2> /dev/null)
    expected=$(image_ref "API_IMAGE" "helpdesk-portal-api:$AVAILABLE_VERSION")
    [ "$svc" = "web" ] && expected=$(image_ref "WEB_IMAGE" "helpdesk-portal-web:$AVAILABLE_VERSION")
    case "$expected" in
      *:*) ;;
      *) expected="$expected:$AVAILABLE_VERSION" ;;
    esac
    if [ "$actual" != "$expected" ]; then
      printf '  %s: запущен %s, а ожидался %s\n' "$svc" "$actual" "$expected" >&2
      return 1
    fi
  done
  return 0
}

if ! verify_running_images; then
  log "контейнеры поднялись не с новым образом"
  rollback
  die "образ не применился, выполнен откат на $CURRENT_VERSION"
fi

wait_healthy() {
  elapsed=0
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    unhealthy=$(compose ps \
      --format '{{.Service}} {{.Health}}' 2> /dev/null \
      | awk '$2 == "unhealthy" || $2 == "starting" {print $1}' | tr '\n' ' ')
    if [ -z "$unhealthy" ]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

log "жду healthy-статус контейнеров (до ${HEALTH_TIMEOUT}s)"
if ! wait_healthy; then
  log "health-check не пройден, выполняю откат на $CURRENT_VERSION"
  cp "$ENV_BACKUP" "$ENV_FILE"
  export APP_VERSION=$CURRENT_VERSION
  compose up -d --remove-orphans || true
  wait_healthy || true
  die "обновление не удалось, выполнен откат на $CURRENT_VERSION"
fi

# Версию фиксируем в .env только после успешного health-check: иначе следующий
# запуск update.sh считал бы установленной старую версию и compose поднимал бы
# старый тег образа.
set_env_value APP_VERSION "$AVAILABLE_VERSION"
log "версия $AVAILABLE_VERSION записана в $ENV_FILE"

if command -v curl > /dev/null 2>&1; then
  api_url=$(sed -n 's/^API_PUBLIC_URL=//p' "$ENV_FILE" | tail -n 1)
  if [ -n "$api_url" ]; then
    reported=$(curl -fsSL --max-time 10 "${api_url%/}/api/health" 2> /dev/null \
      | node -e "let r='';process.stdin.on('data',c=>r+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(r).version||'')}catch{console.log('')}})" || true)
    if [ -n "$reported" ] && [ "$reported" != "$AVAILABLE_VERSION" ]; then
      # Раньше здесь было предупреждение, и обновление завершалось «успехом»:
      # на стенде .env записали 0.16.1, а /api/health отвечал 0.14.7, и это
      # просто проходило мимо. Несовпадение версии — это несовпадение версии.
      rollback
      die "система отвечает версией $reported вместо $AVAILABLE_VERSION, выполнен откат на $CURRENT_VERSION"
    fi
  fi
fi

log "готово: версия $AVAILABLE_VERSION установлена и контейнеры healthy"
