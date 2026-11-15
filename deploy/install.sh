#!/usr/bin/env bash
#
# new-api-orange 一键部署脚本
#
# 在线使用：
#   mkdir -p /path/to/new-api && cd /path/to/new-api
#   curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy/install.sh | bash -s -- install
#
# 本地使用：
#   ./install.sh install
#
# 数据全部落在当前目录，迁移时停容器、打包整个目录、拷到新机器再执行 migrate。

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ -z "${BASH_VERSION:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
  printf '错误：需要 Bash 4.0 或更高版本。\n' >&2
  exit 1
fi

readonly DEFAULT_IMAGE="ghcr.io/juziool/new-api-orange:latest"
readonly DEFAULT_RAW_BASE="https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy"
readonly DEFAULT_HEALTH_TIMEOUT=180
readonly ROLLBACK_PREFIX="new-api-orange:rollback-"

DEPLOY_DIR="${NEW_API_DEPLOY_DIR:-$(pwd -P)}"
RAW_BASE_URL="${NEW_API_RAW_BASE:-$DEFAULT_RAW_BASE}"
HEALTH_TIMEOUT="${NEW_API_HEALTH_TIMEOUT:-$DEFAULT_HEALTH_TIMEOUT}"
BACKUP_KEEP="${NEW_API_BACKUP_KEEP:-7}"

MODE=""
MODE_EXPLICIT=false
IMAGE_OVERRIDE=""
BIND_HOST=""
HTTP_PORT=""
NO_BACKUP=false
NO_PULL=false
ASSUME_YES=false
INSTALL_DOCKER=false
RESTORE_FROM=""
SOURCE_DIR=""
COMPOSE_MODE=""
BACKUP_ROOT=""
STATE_FILE=""
LOCK_FILE=""
LOCK_DIR=""
LOCK_MODE=""
LOCK_ACQUIRED=false
TEMP_FILES=()

log() { printf '[new-api] %s\n' "$*"; }
warn() { printf '[new-api] 警告：%s\n' "$*" >&2; }
die() { printf '[new-api] 错误：%s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "$LOCK_MODE" == mkdir && "$LOCK_ACQUIRED" == true ]]; then
    rm -rf -- "$LOCK_DIR" 2>/dev/null || true
  fi
  local file
  for file in "${TEMP_FILES[@]}"; do
    rm -f -- "$file" 2>/dev/null || true
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
new-api-orange 一键部署脚本

用法：
  install.sh install                 全新安装（默认）
  install.sh migrate                 迁移安装：目录里已有 .env 和 postgres_data
  install.sh update                  更新应用镜像
  install.sh backup                  备份数据库和配置
  install.sh restore --from <路径>   从备份恢复
  install.sh health                  健康检查

  不带参数且有终端时进入菜单，没有终端时默认 install。

选项：
  --dir <路径>             部署目录，默认当前目录
  --image <tag|digest>     指定镜像，默认 ghcr.io/juziool/new-api-orange:latest
  --bind <地址>            监听地址，默认 0.0.0.0
  --port <端口>            监听端口，默认 3000
  --health-timeout <秒>    健康检查超时，默认 180
  --keep <份数>            备份保留份数，默认 7
  --from <路径>            restore 使用的备份目录或 tar.gz
  --no-backup              update 前跳过备份
  --no-pull                使用本地已有镜像
  --install-docker         缺少 Docker 时自动安装（需要 root）
  --raw-base <URL>         运行时文件下载地址
  --yes                    跳过确认
  -h, --help               显示帮助

环境变量：
  NEW_API_DEPLOY_DIR       默认部署目录
  NEW_API_IMAGE            默认镜像
  NEW_API_RAW_BASE         默认下载地址
  NEW_API_HEALTH_TIMEOUT   健康检查超时
  NEW_API_BACKUP_KEEP      备份保留份数
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      install|migrate|update|backup|restore|health)
        [[ -z "$MODE" ]] || die "只能指定一个命令。"
        MODE="$1"
        MODE_EXPLICIT=true
        shift
        ;;
      --dir)
        (($# >= 2)) || die "--dir 需要路径。"
        DEPLOY_DIR="$2"
        shift 2
        ;;
      --dir=*) DEPLOY_DIR="${1#*=}"; shift ;;
      --image)
        (($# >= 2)) || die "--image 需要 tag 或 digest。"
        IMAGE_OVERRIDE="$2"
        shift 2
        ;;
      --image=*) IMAGE_OVERRIDE="${1#*=}"; shift ;;
      --bind)
        (($# >= 2)) || die "--bind 需要地址。"
        BIND_HOST="$2"
        shift 2
        ;;
      --bind=*) BIND_HOST="${1#*=}"; shift ;;
      --port)
        (($# >= 2)) || die "--port 需要端口。"
        HTTP_PORT="$2"
        shift 2
        ;;
      --port=*) HTTP_PORT="${1#*=}"; shift ;;
      --health-timeout)
        (($# >= 2)) || die "--health-timeout 需要秒数。"
        HEALTH_TIMEOUT="$2"
        shift 2
        ;;
      --health-timeout=*) HEALTH_TIMEOUT="${1#*=}"; shift ;;
      --keep)
        (($# >= 2)) || die "--keep 需要份数。"
        BACKUP_KEEP="$2"
        shift 2
        ;;
      --keep=*) BACKUP_KEEP="${1#*=}"; shift ;;
      --from)
        (($# >= 2)) || die "--from 需要备份路径。"
        RESTORE_FROM="$2"
        shift 2
        ;;
      --from=*) RESTORE_FROM="${1#*=}"; shift ;;
      --raw-base)
        (($# >= 2)) || die "--raw-base 需要 URL。"
        RAW_BASE_URL="$2"
        shift 2
        ;;
      --raw-base=*) RAW_BASE_URL="${1#*=}"; shift ;;
      --no-backup) NO_BACKUP=true; shift ;;
      --no-pull) NO_PULL=true; shift ;;
      --install-docker) INSTALL_DOCKER=true; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done

  [[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--health-timeout 必须是正整数。"
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || die "--keep 必须是非负整数。"
}

choose_mode() {
  if [[ "$MODE_EXPLICIT" == true ]]; then
    return 0
  fi

  local tty_fd=0 input
  if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      exec {tty_fd}<>/dev/tty || tty_fd=-1
    else
      tty_fd=-1
    fi
  fi

  if ((tty_fd < 0)); then
    MODE=install
    warn "没有交互式终端，默认执行全新安装。"
    return 0
  fi

  printf '\n请选择操作：\n'
  printf '  1) 全新安装\n'
  printf '  2) 迁移安装（目录里已有数据）\n'
  printf '  3) 更新镜像\n'
  printf '  4) 创建备份\n'
  printf '  5) 从备份恢复\n'
  printf '  6) 健康检查\n\n'

  while true; do
    if ! IFS= read -r -u "$tty_fd" -p '请输入 1-6 [1]: ' input; then
      if ((tty_fd > 0)); then
        eval "exec ${tty_fd}<&-"
      fi
      die "无法读取操作选择。"
    fi
    input="${input//[[:space:]]/}"
    case "${input:-1}" in
      1) MODE=install; break ;;
      2) MODE=migrate; break ;;
      3) MODE=update; break ;;
      4) MODE=backup; break ;;
      5) MODE=restore; break ;;
      6) MODE=health; break ;;
      *) warn "请输入 1 到 6 之间的数字。" ;;
    esac
  done

  if ((tty_fd > 0)); then
    eval "exec ${tty_fd}<&-"
  fi
  log "已选择：$MODE"
}

resolve_deploy_dir() {
  if [[ "$DEPLOY_DIR" != /* ]]; then
    DEPLOY_DIR="$(pwd -P)/$DEPLOY_DIR"
  fi
  mkdir -p -- "$DEPLOY_DIR"
  DEPLOY_DIR="$(cd -- "$DEPLOY_DIR" && pwd -P)"
  BACKUP_ROOT="$DEPLOY_DIR/backups"
  STATE_FILE="$DEPLOY_DIR/.deploy-state.json"
  LOCK_FILE="$DEPLOY_DIR/.install.lock"
}

resolve_source_dir() {
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" ]]; then
    SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  elif [[ -f "$DEPLOY_DIR/install.sh" ]]; then
    SOURCE_DIR="$DEPLOY_DIR"
  else
    SOURCE_DIR=""
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

is_source_root() {
  [[ -f "$DEPLOY_DIR/go.mod" && -f "$DEPLOY_DIR/main.go" ]]
}

package_manager() {
  if command -v apt-get >/dev/null 2>&1; then printf 'apt-get'
  elif command -v apk >/dev/null 2>&1; then printf 'apk'
  elif command -v dnf >/dev/null 2>&1; then printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then printf 'yum'
  fi
}

install_docker_packages() {
  local manager
  manager="$(package_manager)"
  [[ -n "$manager" ]] || return 1
  case "$manager" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-plugin >/dev/null 2>&1 ||
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose >/dev/null 2>&1 || true
      ;;
    apk)
      apk add --no-cache docker docker-cli-compose >/dev/null 2>&1 || true
      ;;
    dnf|yum)
      "$manager" install -y docker docker-compose-plugin >/dev/null 2>&1 || true
      ;;
  esac
  command -v docker >/dev/null 2>&1
}

detect_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_MODE=plugin
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE_MODE=standalone
  else
    return 1
  fi
}

start_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi
  docker info >/dev/null 2>&1
}

ensure_docker() {
  require_cmd curl
  require_cmd openssl

  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$INSTALL_DOCKER" == true ]]; then
      [[ "$EUID" -eq 0 ]] || die "自动安装 Docker 需要 root 权限。"
      log "正在安装 Docker..."
      install_docker_packages || die "Docker 安装失败，请手动安装后重试。"
    else
      die "未检测到 Docker。请先安装 Docker Engine 和 Compose v2，或加 --install-docker 让脚本尝试安装。"
    fi
  fi

  if ! detect_compose; then
    if [[ "$INSTALL_DOCKER" == true ]]; then
      [[ "$EUID" -eq 0 ]] || die "自动安装 Docker Compose 需要 root 权限。"
      install_docker_packages || true
      detect_compose || die "未检测到 Docker Compose，请手动安装 Compose v2。"
    else
      die "未检测到 Docker Compose。请安装 Compose v2，或加 --install-docker。"
    fi
  fi

  start_docker || die "Docker 服务未运行，或当前用户没有访问 Docker 的权限。"
}

compose() {
  (
    cd -- "$DEPLOY_DIR"
    if [[ "$COMPOSE_MODE" == plugin ]]; then
      docker compose --env-file .env -f docker-compose.yml "$@"
    else
      docker-compose --env-file .env -f docker-compose.yml "$@"
    fi
  )
}

read_env_value() {
  local key="$1" fallback="$2" value
  [[ -f "$DEPLOY_DIR/.env" ]] || { printf '%s' "$fallback"; return 0; }
  value="$(sed -n "s/^${key}=//p" "$DEPLOY_DIR/.env" | tail -n 1 | tr -d '\r')"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "${value:-$fallback}"
}

update_env_value() {
  local key="$1" value="$2" tmp
  [[ -f "$DEPLOY_DIR/.env" ]] || die ".env 不存在。"
  tmp="$(mktemp "$DEPLOY_DIR/.env.XXXXXX")"
  TEMP_FILES+=("$tmp")
  awk -v prefix="${key}=" -v line="${key}=${value}" 'index($0, prefix) == 1 { print line; next } { print }' \
    "$DEPLOY_DIR/.env" > "$tmp"
  if ! grep -q "^${key}=" "$tmp"; then
    printf '%s\n' "${key}=${value}" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$DEPLOY_DIR/.env"
}

generate_hex() { openssl rand -hex "$1"; }

sanitize_project_name() {
  local raw
  raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
  [[ -n "$raw" ]] || raw="new-api-orange"
  printf '%s' "$raw"
}

prepare_file() {
  local name="$1" mode="$2" target="$DEPLOY_DIR/$1" tmp
  if [[ -f "$target" ]]; then
    return 0
  fi
  tmp="$(mktemp "$DEPLOY_DIR/.${name}.XXXXXX")"
  TEMP_FILES+=("$tmp")
  if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/$name" ]]; then
    cp -- "$SOURCE_DIR/$name" "$tmp"
  else
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 \
      -o "$tmp" "$RAW_BASE_URL/$name" || die "无法下载 $name，请检查网络或使用 --raw-base 指定地址。"
  fi
  chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$target"
}

prepare_runtime_files() {
  mkdir -p -- "$DEPLOY_DIR" "$DEPLOY_DIR/data" "$DEPLOY_DIR/postgres_data" "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  prepare_file install.sh 755
  prepare_file docker-compose.yml 644
  prepare_file .env.example 644
}

has_persistent_data() {
  if [[ -f "$DEPLOY_DIR/.env" ]]; then
    return 0
  fi
  if [[ -n "$(find "$DEPLOY_DIR/postgres_data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

prompt_fresh_values() {
  BIND_HOST="${BIND_HOST:-0.0.0.0}"
  HTTP_PORT="${HTTP_PORT:-3000}"
  if [[ "${NEW_API_NO_PROMPT:-0}" != "1" ]] && { : </dev/tty; } 2>/dev/null; then
    local value
    read -r -p "监听端口 [3000]: " value </dev/tty
    if [[ -n "$value" ]]; then
      HTTP_PORT="$value"
    fi
    read -r -p "监听地址 [0.0.0.0]: " value </dev/tty
    if [[ -n "$value" ]]; then
      BIND_HOST="$value"
    fi
  fi
  [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && ((HTTP_PORT >= 1 && HTTP_PORT <= 65535)) ||
    die "端口必须是 1 到 65535 之间的数字。"
  [[ -n "$BIND_HOST" ]] || die "监听地址不能为空。"
}

write_fresh_env() {
  local tmp line project_name
  project_name="$(sanitize_project_name "$(basename "$DEPLOY_DIR")")"
  tmp="$(mktemp "$DEPLOY_DIR/.env.XXXXXX")"
  TEMP_FILES+=("$tmp")

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      COMPOSE_PROJECT_NAME=*) printf 'COMPOSE_PROJECT_NAME=%s\n' "$project_name" ;;
      NEW_API_IMAGE=*) printf 'NEW_API_IMAGE=%s\n' "${IMAGE_OVERRIDE:-$DEFAULT_IMAGE}" ;;
      BIND_HOST=*) printf 'BIND_HOST=%s\n' "$BIND_HOST" ;;
      HTTP_PORT=*) printf 'HTTP_PORT=%s\n' "$HTTP_PORT" ;;
      POSTGRES_PASSWORD=*) printf 'POSTGRES_PASSWORD=%s\n' "$(generate_hex 24)" ;;
      REDIS_PASSWORD=*) printf 'REDIS_PASSWORD=%s\n' "$(generate_hex 24)" ;;
      SESSION_SECRET=*) printf 'SESSION_SECRET=%s\n' "$(generate_hex 32)" ;;
      BACKUP_KEEP=*) printf 'BACKUP_KEEP=%s\n' "$BACKUP_KEEP" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$DEPLOY_DIR/.env.example" > "$tmp"

  if ! grep -q '^NEW_API_IMAGE=' "$tmp"; then
    printf 'NEW_API_IMAGE=%s\n' "${IMAGE_OVERRIDE:-$DEFAULT_IMAGE}" >> "$tmp"
  fi
  if ! grep -q '^COMPOSE_PROJECT_NAME=' "$tmp"; then
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$project_name" >> "$tmp"
  fi
  if ! grep -q '^BACKUP_KEEP=' "$tmp"; then
    printf 'BACKUP_KEEP=%s\n' "$BACKUP_KEEP" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$DEPLOY_DIR/.env"
}

set_image() {
  local configured
  configured="$(read_env_value NEW_API_IMAGE "$DEFAULT_IMAGE")"
  if [[ -n "$IMAGE_OVERRIDE" ]]; then
    update_env_value NEW_API_IMAGE "$IMAGE_OVERRIDE"
    configured="$IMAGE_OVERRIDE"
  fi
  [[ -n "$configured" ]] || die "NEW_API_IMAGE 不能为空。"
  export NEW_API_IMAGE="$configured"
}

pull_image() {
  if [[ "$NO_PULL" == true ]]; then
    docker image inspect "$NEW_API_IMAGE" >/dev/null 2>&1 || die "本地不存在镜像：$NEW_API_IMAGE"
    log "使用本地镜像：$NEW_API_IMAGE"
  else
    log "拉取镜像：$NEW_API_IMAGE"
    compose pull new-api || return 1
  fi
}

health_url() {
  local host port
  host="$(read_env_value BIND_HOST 0.0.0.0)"
  port="$(read_env_value HTTP_PORT 3000)"
  if [[ "$host" == 0.0.0.0 || -z "$host" ]]; then
    host=127.0.0.1
  fi
  printf 'http://%s:%s/api/status' "$host" "$port"
}

wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) status id url body service
  url="$(health_url)"
  log "等待服务健康检查：$url"
  while ((SECONDS < deadline)); do
    status=healthy
    for service in postgres redis new-api; do
      id="$(compose ps -q "$service" 2>/dev/null || true)"
      if [[ -z "$id" ]]; then
        status=starting
        break
      fi
      case "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)" in
        healthy) ;;
        unhealthy|exited|dead) status=failed; break ;;
        *) status=starting; break ;;
      esac
    done
    if [[ "$status" == healthy ]]; then
      body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
      if [[ "$body" =~ \"success\"[[:space:]]*:[[:space:]]*true ]]; then
        return 0
      fi
    fi
    if [[ "$status" == failed ]]; then
      break
    fi
    sleep 3
  done
  compose ps >&2 || true
  compose logs --tail=200 new-api postgres redis >&2 || true
  return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

write_state() {
  local status="$1" image="$2" image_id="$3" rollback_tag="$4" previous_image="$5" backup="$6" error="${7:-}" tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")"
  TEMP_FILES+=("$tmp")
  {
    printf '{\n'
    printf '  "status": "%s",\n' "$(json_escape "$status")"
    printf '  "image": "%s",\n' "$(json_escape "$image")"
    printf '  "imageId": "%s",\n' "$(json_escape "$image_id")"
    printf '  "rollbackTag": "%s",\n' "$(json_escape "$rollback_tag")"
    printf '  "previousImage": "%s",\n' "$(json_escape "$previous_image")"
    printf '  "backup": "%s",\n' "$(json_escape "$backup")"
    printf '  "recordedAt": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "error": "%s"\n' "$(json_escape "$error")"
    printf '}\n'
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

confirm() {
  local prompt="$1" answer
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -p "$prompt [y/N]: " answer
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    read -r -p "$prompt [y/N]: " answer </dev/tty
  else
    return 1
  fi
  [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

prune_backups() {
  local keep="$BACKUP_KEEP" dirs=() i
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=7
  mapfile -t dirs < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  for ((i = keep; i < ${#dirs[@]}; i++)); do
    rm -rf -- "${dirs[i]}"
  done
}

backup_command() {
  local stamp tmp image image_id pg_version
  [[ -f "$DEPLOY_DIR/.env" ]] || die "备份要求当前目录已有 .env。"
  compose config --quiet
  wait_for_health || die "备份前健康检查失败，未创建备份。"

  stamp="$(date +%Y%m%d-%H%M%S)"
  tmp="$BACKUP_ROOT/.$stamp.tmp"
  rm -rf -- "$tmp"
  mkdir -p -- "$tmp"
  chmod 700 "$tmp"

  cp -- "$DEPLOY_DIR/.env" "$tmp/env"
  cp -- "$DEPLOY_DIR/docker-compose.yml" "$tmp/docker-compose.yml"

  log "导出 PostgreSQL..."
  compose exec -T postgres sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z9 --no-owner --no-privileges -f /tmp/new-api-backup.dump'
  compose cp postgres:/tmp/new-api-backup.dump "$tmp/postgres.dump"
  compose exec -T postgres rm -f /tmp/new-api-backup.dump

  tar -czf "$tmp/data.tar.gz" -C "$DEPLOY_DIR" --exclude='data/logs' data

  image="$(compose images --format '{{.Repository}}:{{.Tag}}' new-api 2>/dev/null | head -n 1 || true)"
  image_id="$(compose images -q new-api 2>/dev/null | head -n 1 || true)"
  pg_version="$(tr -d '[:space:]' < "$DEPLOY_DIR/postgres_data/PG_VERSION" 2>/dev/null || true)"

  {
    printf 'created_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'image=%s\n' "$image"
    printf 'image_id=%s\n' "$image_id"
    printf 'postgres_version=%s\n' "$pg_version"
    printf 'database=%s/%s\n' \
      "$(read_env_value POSTGRES_USER newapi)" "$(read_env_value POSTGRES_DB newapi)"
  } > "$tmp/metadata.txt"

  chmod 600 "$tmp/env" "$tmp/docker-compose.yml" "$tmp/postgres.dump" "$tmp/data.tar.gz" "$tmp/metadata.txt"
  mv -f -- "$tmp" "$BACKUP_ROOT/$stamp"
  prune_backups
  log "备份完成：$BACKUP_ROOT/$stamp"
}

wait_for_postgres() {
  local deadline=$((SECONDS + 120)) user db
  user="$(read_env_value POSTGRES_USER newapi)"
  db="$(read_env_value POSTGRES_DB newapi)"
  while ((SECONDS < deadline)); do
    if compose exec -T postgres pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

restore_command() {
  local source_dir="" temp_extract="" old_session old_crypto user db
  [[ -n "$RESTORE_FROM" ]] || die "restore 需要 --from <备份目录或 tar.gz>。"
  [[ -e "$RESTORE_FROM" ]] || die "备份路径不存在：$RESTORE_FROM"

  if [[ -d "$RESTORE_FROM" ]]; then
    source_dir="$(cd -- "$RESTORE_FROM" && pwd -P)"
  else
    temp_extract="$(mktemp -d)"
    TEMP_FILES+=("$temp_extract")
    tar -xzf "$RESTORE_FROM" -C "$temp_extract" || die "解压备份失败。"
    if [[ -f "$temp_extract/postgres.dump" ]]; then
      source_dir="$temp_extract"
    else
      source_dir="$(find "$temp_extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    fi
  fi
  [[ -n "$source_dir" && -f "$source_dir/postgres.dump" ]] || die "备份里没有找到 postgres.dump。"

  prepare_runtime_files
  if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
    BIND_HOST="${BIND_HOST:-0.0.0.0}"
    HTTP_PORT="${HTTP_PORT:-3000}"
    write_fresh_env
  fi

  if [[ -f "$source_dir/env" ]]; then
    old_session="$(sed -n 's/^SESSION_SECRET=//p' "$source_dir/env" | tail -n 1 | tr -d '\r')"
    old_crypto="$(sed -n 's/^CRYPTO_SECRET=//p' "$source_dir/env" | tail -n 1 | tr -d '\r')"
    if [[ -n "$old_session" ]]; then
      update_env_value SESSION_SECRET "$old_session"
    fi
    if [[ -n "$old_crypto" ]]; then
      update_env_value CRYPTO_SECRET "$old_crypto"
    fi
  else
    warn "备份里没有 env 文件，将使用当前会话密钥。"
  fi

  set_image
  compose config --quiet
  log "启动 PostgreSQL 和 Redis..."
  compose up -d postgres redis
  wait_for_postgres || die "PostgreSQL 未就绪。"

  confirm "将清空当前数据库并导入备份，继续？" ||
    die "已取消。非交互模式请加 --yes。"

  compose stop new-api >/dev/null 2>&1 || true
  user="$(read_env_value POSTGRES_USER newapi)"
  db="$(read_env_value POSTGRES_DB newapi)"

  log "清空并重建 public schema..."
  compose exec -T postgres psql -U "$user" -d "$db" -v ON_ERROR_STOP=1 \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

  log "导入备份..."
  compose cp "$source_dir/postgres.dump" postgres:/tmp/new-api-restore.dump
  compose exec -T postgres pg_restore -U "$user" -d "$db" \
    --no-owner --no-privileges /tmp/new-api-restore.dump
  compose exec -T postgres rm -f /tmp/new-api-restore.dump

  compose up -d
  wait_for_health || die "恢复完成，但服务未通过健康检查，请查看日志。"
  log "恢复完成。"
}

fresh_install() {
  if is_source_root; then
    die "当前目录是源码仓库，请换一个空目录部署。"
  fi
  [[ ! -e "$DEPLOY_DIR/.env" ]] || die "当前目录已有 .env，请使用 migrate 或 update。"
  if has_persistent_data; then
    die "当前目录已有持久化数据，全新安装已拒绝。"
  fi

  prepare_runtime_files
  prompt_fresh_values
  write_fresh_env
  set_image
  compose config --quiet
  pull_image || die "镜像拉取失败，请检查网络或使用 --image 指定可用镜像。"
  compose up -d
  wait_for_health || die "安装未通过健康检查。"

  local url
  url="$(health_url)"
  log "安装完成。"
  log "访问地址：${url%/api/status}"
  log "数据目录：$DEPLOY_DIR/data"
  log "备份目录：$BACKUP_ROOT"
  log "首次打开网页完成初始化，创建管理员账号。"
  log "常用命令：./install.sh update | ./install.sh backup | ./install.sh health"
}

migrate_install() {
  if is_source_root; then
    die "当前目录是源码仓库，请换一个目录部署。"
  fi
  [[ -f "$DEPLOY_DIR/.env" ]] || die "迁移安装要求目录里已有 .env。"
  [[ -f "$DEPLOY_DIR/postgres_data/PG_VERSION" ]] || die "迁移安装要求目录里已有 postgres_data/PG_VERSION。"

  local data_version image_tag image_major
  data_version="$(tr -d '[:space:]' < "$DEPLOY_DIR/postgres_data/PG_VERSION")"
  image_tag="$(read_env_value POSTGRES_IMAGE_TAG 15-alpine)"
  image_major="${image_tag%%-*}"
  [[ "$data_version" == "$image_major" ]] ||
    die "PostgreSQL 数据目录是 $data_version，但镜像标签是 $image_tag。请把 POSTGRES_IMAGE_TAG 改成 $data_version-* 再试。"

  prepare_runtime_files
  set_image
  compose config --quiet
  pull_image || die "镜像拉取失败。"
  compose up -d
  wait_for_health || die "迁移安装未通过健康检查。"

  log "迁移安装完成，原有配置和数据未重新生成。"
  log "访问地址：$(health_url | sed 's#/api/status$##')"
}

update_command() {
  local old_id old_image rollback_tag backup_dir new_id
  [[ -f "$DEPLOY_DIR/.env" ]] || die "更新要求当前目录已有 .env。"
  [[ -f "$DEPLOY_DIR/docker-compose.yml" ]] || die "缺少 docker-compose.yml，请先执行 install。"

  set_image
  compose config --quiet

  old_id="$(compose images -q new-api 2>/dev/null | head -n 1 || true)"
  old_image="$(compose images --format '{{.Repository}}:{{.Tag}}' new-api 2>/dev/null | head -n 1 || true)"
  rollback_tag=""
  if [[ -n "$old_id" ]]; then
    rollback_tag="${ROLLBACK_PREFIX}$(date +%Y%m%d%H%M%S)"
    docker tag "$old_id" "$rollback_tag" || rollback_tag=""
  fi

  backup_dir=""
  if [[ "$NO_BACKUP" == false ]]; then
    backup_command
    backup_dir="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  fi

  if ! pull_image; then
    write_state failed "$NEW_API_IMAGE" "" "$rollback_tag" "$old_image" "$backup_dir" "镜像拉取失败"
    die "镜像拉取失败，现有容器未改动。"
  fi

  if compose up -d --no-deps --force-recreate new-api && wait_for_health; then
    new_id="$(docker image inspect --format '{{.Id}}' "$NEW_API_IMAGE" 2>/dev/null || true)"
    write_state success "$NEW_API_IMAGE" "$new_id" "$rollback_tag" "$old_image" "$backup_dir"
    log "更新完成。"
    return 0
  fi

  warn "新镜像未通过健康检查，尝试恢复旧镜像。"
  if [[ -n "$rollback_tag" ]]; then
    export NEW_API_IMAGE="$rollback_tag"
    if compose up -d --no-deps --force-recreate new-api && wait_for_health; then
      write_state failed-recovered "$old_image" "$old_id" "" "$old_image" "$backup_dir" "新镜像未通过健康检查，已恢复旧镜像"
      die "更新失败，已恢复旧镜像。数据库结构不会自动回滚。"
    fi
  fi
  write_state failed "$NEW_API_IMAGE" "" "$rollback_tag" "$old_image" "$backup_dir" "更新失败且旧镜像恢复失败"
  die "更新失败，旧镜像也无法恢复，请检查日志和备份。"
}

health_command() {
  [[ -f "$DEPLOY_DIR/.env" ]] || die "健康检查要求当前目录已有 .env。"
  compose config --quiet
  wait_for_health || die "服务未在 ${HEALTH_TIMEOUT} 秒内通过健康检查。"
  log "健康检查通过。"
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "另一个安装、更新或备份任务正在运行。"
    LOCK_MODE=flock
    LOCK_ACQUIRED=true
    return 0
  fi

  LOCK_DIR="${LOCK_FILE}.d"
  if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
    die "另一个安装、更新或备份任务正在运行。"
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCK_MODE=mkdir
  LOCK_ACQUIRED=true
}

main() {
  parse_args "$@"
  choose_mode
  resolve_deploy_dir
  resolve_source_dir
  if is_source_root && [[ "$MODE" != install ]]; then
    die "当前目录是源码仓库，请换一个目录部署。"
  fi

  if [[ "$MODE" == restore && -z "$RESTORE_FROM" ]]; then
    die "restore 需要 --from <备份目录或 tar.gz>。"
  fi

  acquire_lock

  case "$MODE" in
    install) ensure_docker; fresh_install ;;
    migrate) ensure_docker; migrate_install ;;
    update) ensure_docker; update_command ;;
    backup) ensure_docker; backup_command ;;
    restore) ensure_docker; restore_command ;;
    health) ensure_docker; health_command ;;
    *) die "未知命令：$MODE" ;;
  esac
}

main "$@"
