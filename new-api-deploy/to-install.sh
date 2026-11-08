#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_RAW_BASE_URL="https://raw.githubusercontent.com/JuZiool/new-api-orange/main/new-api-deploy"
readonly DEFAULT_IMAGE_REPOSITORY="ghcr.io/juziool/new-api-orange"
readonly HEALTH_TIMEOUT_DEFAULT=180
readonly SERVICES=(new-api postgres redis)
readonly SECRET_KEYS=(POSTGRES_PASSWORD REDIS_PASSWORD SESSION_SECRET CRYPTO_SECRET)

DEPLOY_DIR="${NEW_API_DEPLOY_DIR:-$(pwd -P)}"
RAW_BASE_URL="${NEW_API_RAW_BASE_URL:-$DEFAULT_RAW_BASE_URL}"
BACKUP_DIR=""
MODE=""
MODE_EXPLICIT=false
IMAGE_OVERRIDE=""
VERSION_OVERRIDE=""
ASSUME_YES=false
NO_PULL=false
ORIGIN_OVERRIDE=""
PROXIES_OVERRIDE=""
PORT_OVERRIDE=""
HEALTH_TIMEOUT="${NEW_API_HEALTH_TIMEOUT:-$HEALTH_TIMEOUT_DEFAULT}"
SOURCE_DIR=""
DOCKER_ENDPOINT=""
LOCK_DIR=""
LOCK_MODE=""
STOPPED_BY_SCRIPT=false
ORIGINAL_RUNNING_SERVICES=()
ORIGINAL_RUNNING_IDS=()
TEMP_FILES=()
TEMP_DIRS=()
TTY_FD=""
BACKUP_ARCHIVE=""

if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi

log() { printf '[New API] %s\n' "$*"; }
warn() { printf '[New API] 警告：%s\n' "$*" >&2; }
die() { printf '[New API] 错误：%s\n' "$*" >&2; exit 1; }

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    rm -f -- "$file" 2>/dev/null || true
  done
  for file in "${TEMP_DIRS[@]}"; do
    rmdir -- "$file" 2>/dev/null || true
  done
  if [[ "$LOCK_MODE" == mkdir && -n "$LOCK_DIR" ]]; then
    rmdir -- "$LOCK_DIR" 2>/dev/null || true
  fi
}

restore_original_services() {
  [[ "$STOPPED_BY_SCRIPT" == true ]] || return 0
  local index id failed=0
  for index in "${!ORIGINAL_RUNNING_IDS[@]}"; do
    id="${ORIGINAL_RUNNING_IDS[$index]}"
    if ! docker_exec start "$id" >/dev/null 2>&1 || ! wait_container "$id"; then
      warn "无法自动恢复服务 ${ORIGINAL_RUNNING_SERVICES[$index]}，请运行 docker compose ps 和 logs 检查。"
      failed=1
    fi
  done
  if ((failed == 0)); then STOPPED_BY_SCRIPT=false; fi
  return "$failed"
}

on_exit() {
  local status=$?
  if ! restore_original_services; then status=1; fi
  cleanup
  return "$status"
}

usage() {
  cat <<'EOF'
New API Docker 部署入口

用法：
  bash to-install.sh                  打开中文菜单
  bash to-install.sh --mode 1         全新安装
  bash to-install.sh --mode 2         更新 New API 镜像并重启容器
  bash to-install.sh --mode 3         迁移安装
  bash to-install.sh --mode 4         创建迁移备份压缩包
  bash to-install.sh backup           创建迁移备份压缩包

选项：
  --dir <路径>                        部署目录，默认当前目录
  --mode <1|2|3|4|backup>             指定操作，跳过菜单
  --version <版本号>                  全新安装或更新时指定已发布版本，如 v1.0.0-rc.48-orange.1
  --image <GHCR 镜像或摘要>            指定本 fork 的固定版本镜像或 sha256 摘要
  --origin <HTTPS Origin>             全新安装的控制台地址
  --trusted-proxies <IP/CIDR>          全新安装的可信代理，无代理填 none
  --port <端口>                       全新安装的宿主机端口，默认 3000
  --backup-dir <路径>                 备份目录，默认部署目录旁的 new-api-backups
  --health-timeout <秒>               健康检查等待时间，默认 180
  --yes                               跳过确认提示
  --no-pull                           不从仓库拉取镜像，只使用本地镜像
  -h, --help                          显示帮助

远程执行示例：
  curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/new-api-deploy/to-install.sh \
    | bash -s -- --mode 1 --dir /opt/new-api-deploy
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --dir)
        (($# >= 2)) || die "--dir 需要路径。"
        DEPLOY_DIR="$2"
        shift 2
        ;;
      --mode)
        (($# >= 2)) || die "--mode 需要 1、2、3 或 4。"
        [[ -z "$MODE" ]] || die "不能重复指定操作。"
        MODE="${2/backup/4}"
        MODE_EXPLICIT=true
        shift 2
        ;;
      --image)
        (($# >= 2)) || die "--image 需要镜像版本或摘要。"
        [[ -n "$2" ]] || die "--image 需要镜像版本或摘要。"
        [[ -z "$VERSION_OVERRIDE" ]] || die "--image 与 --version 不能同时使用。"
        IMAGE_OVERRIDE="$2"
        shift 2
        ;;
      --version)
        (($# >= 2)) || die "--version 需要已发布的版本号。"
        [[ -z "$IMAGE_OVERRIDE" ]] || die "--version 与 --image 不能同时使用。"
        [[ "$2" == v* && "$2" != */* ]] || die "--version 请填写 v1.0.0-orange 或 v1.0.0-rc.48-orange.1 这样的版本号。"
        VERSION_OVERRIDE="$2"
        shift 2
        ;;
      --origin|--trusted-proxies|--port)
        (($# >= 2)) || die "$1 需要一个值。"
        case "$1" in
          --origin) ORIGIN_OVERRIDE="$2" ;;
          --trusted-proxies) PROXIES_OVERRIDE="$2" ;;
          --port) PORT_OVERRIDE="$2" ;;
        esac
        shift 2
        ;;
      --backup-dir)
        (($# >= 2)) || die "--backup-dir 需要路径。"
        BACKUP_DIR="$2"
        shift 2
        ;;
      --health-timeout)
        (($# >= 2)) || die "--health-timeout 需要秒数。"
        HEALTH_TIMEOUT="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=true
        shift
        ;;
      --no-pull)
        NO_PULL=true
        shift
        ;;
      backup)
        [[ -z "$MODE" ]] || die "不能重复指定操作。"
        MODE=4
        MODE_EXPLICIT=true
        shift
        ;;
      1|2|3|4)
        [[ -z "$MODE" ]] || die "不能重复指定操作。"
        MODE="$1"
        MODE_EXPLICIT=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1"
        ;;
    esac
  done

  [[ "$MODE" =~ ^(1|2|3|4)?$ ]] || die "--mode 必须是 1、2、3 或 4。"
  [[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--health-timeout 必须是正整数。"
}

open_terminal() {
  [[ -n "$TTY_FD" ]] && return 0
  if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then return 0; fi
  TTY_FD=""
  return 1
}

read_menu_choice() {
  local answer
  open_terminal || return 1
  read -r -p "请选择：" answer <&"$TTY_FD" || return 1
  printf '%s' "$answer"
}

choose_mode() {
  [[ "$MODE_EXPLICIT" == true ]] && return 0
  open_terminal || die "没有交互式终端，请明确传入 --mode 1、2、3 或 4。"

  cat >&2 <<'EOF'

New API Docker 部署
  1) 全新安装
  2) 更新 New API 镜像并重启容器
  3) 迁移安装
  4) 创建迁移备份压缩包
  0) 退出
EOF
  while true; do
    local choice
    choice="$(read_menu_choice)" || die "无法读取菜单选项，请明确传入 --mode。"
    case "$choice" in
      1) MODE=1; return 0 ;;
      2) MODE=2; return 0 ;;
      3) MODE=3; return 0 ;;
      4) MODE=4; return 0 ;;
      0) exit 0 ;;
      *) warn "请输入 0 到 4 之间的数字。" ;;
    esac
  done
}

resolve_paths() {
  require_command realpath
  DEPLOY_DIR="$(realpath -m -- "$DEPLOY_DIR")"
  [[ "$DEPLOY_DIR" != / ]] || die "部署目录不能是根目录。"
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$(dirname -- "$DEPLOY_DIR")/new-api-backups"
  fi
  BACKUP_DIR="$(realpath -m -- "$BACKUP_DIR")"
  [[ "$BACKUP_DIR" != / ]] || die "备份目录不能是根目录。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1。"
}

check_tools() {
  require_command docker
  require_command openssl
  require_command tar
  require_command sha256sum
  [[ "$(uname -s)" == Linux ]] || die "请在 Linux 服务器或 WSL 的 Linux 发行版中运行。"
  ((EUID == 0)) || die "请用 sudo bash to-install.sh 运行，以保留数据库文件权限。"
  tar --version | grep -q 'GNU tar' || die "需要 GNU tar。"
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    DOCKER_ENDPOINT="$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')"
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    DOCKER_ENDPOINT="$DOCKER_HOST"
  else
    DOCKER_ENDPOINT="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
  fi
  [[ "$DOCKER_ENDPOINT" == unix://* ]] || die "只支持本机 Docker Unix socket，不操作远程 Docker。"
  docker_exec compose version >/dev/null 2>&1 || die "未找到 Docker Compose 插件，请先安装。"
  docker_exec info >/dev/null 2>&1 || die "Docker 服务未运行或无法访问。"
  if [[ "$MODE" != 4 ]]; then
    local platform
    platform="$(docker_exec version --format '{{.Server.Os}}/{{.Server.Arch}}')"
    [[ "$platform" == linux/amd64 || "$platform" == linux/arm64 ]] || die "本 fork 只支持 Linux amd64（x86_64）或 arm64，当前 Docker 服务为 $platform。"
  fi
}

docker_exec() {
  (
    unset DOCKER_CONTEXT DOCKER_HOST DOCKER_DEFAULT_PLATFORM
    if [[ -n "$DOCKER_ENDPOINT" ]]; then
      docker --host "$DOCKER_ENDPOINT" "$@"
    else
      docker "$@"
    fi
  )
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$DEPLOY_DIR/.new-api-deploy.lock"
    flock -n 9 || die "另一个部署任务正在运行。"
    LOCK_MODE=flock
  else
    LOCK_DIR="$DEPLOY_DIR/.new-api-deploy.lock.d"
    mkdir -- "$LOCK_DIR" 2>/dev/null || die "另一个部署任务正在运行。"
    LOCK_MODE=mkdir
  fi
}

fetch_file() {
  local url="$1" target="$2" temp
  temp="$(mktemp "$target.XXXXXX")"
  TEMP_FILES+=("$temp")
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$temp"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$temp"
  else
    die "需要 curl 或 wget 才能下载部署文件。"
  fi
  [[ -s "$temp" ]] || die "下载文件为空：$url"
  chmod 644 "$temp"
  mv -f -- "$temp" "$target"
}

prepare_file() {
  local name="$1" target="$DEPLOY_DIR/$1" source=""
  [[ -e "$target" ]] && return 0
  if [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/$name" ]]; then
    source="$SOURCE_DIR/$name"
    cp -- "$source" "$target"
  else
    fetch_file "$RAW_BASE_URL/$name" "$target"
  fi
}

prepare_runtime_files() {
  mkdir -p -- "$DEPLOY_DIR"
  prepare_file docker-compose.yml
  prepare_file .env.example
  prepare_file to-install.sh
  chmod 755 "$DEPLOY_DIR/to-install.sh"
  mkdir -p -- "$DEPLOY_DIR/data/app_data" "$DEPLOY_DIR/data/postgres_data" "$DEPLOY_DIR/data/redis_data" "$DEPLOY_DIR/logs"
}

compose_command() {
  printf 'docker compose --project-directory %q --env-file %q -f %q' "$DEPLOY_DIR" "$DEPLOY_DIR/.env" "$DEPLOY_DIR/docker-compose.yml"
  printf ' %q' "$@"
}

compose_env() {
  local env_file="$1"
  shift
  (
    cd -- "$DEPLOY_DIR"
    local name
    while IFS= read -r name; do unset "$name"; done < <(compgen -v COMPOSE_ || true)
    unset NEW_API_IMAGE POSTGRES_IMAGE REDIS_IMAGE POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD REDIS_PASSWORD SESSION_SECRET CRYPTO_SECRET SESSION_COOKIE_SECURE SESSION_COOKIE_TRUSTED_URL TRUSTED_PROXIES BIND_HOST SERVER_PORT TZ NODE_NAME DEFAULT_LANGUAGE
    docker_exec compose --project-directory "$DEPLOY_DIR" --env-file "$env_file" -f "$DEPLOY_DIR/docker-compose.yml" "$@"
  )
}

compose() { compose_env "$DEPLOY_DIR/.env" "$@"; }

read_env_value() {
  local key="$1" file="${2:-$DEPLOY_DIR/.env}" value
  [[ -f "$file" ]] || return 0
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { sub("^[^=]*=", ""); print; }' "$file" | tail -n 1 | tr -d '\r')"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "$value"
}

set_env_value() {
  local key="$1" value="$2" file="${3:-$DEPLOY_DIR/.env}" temp found=0 line
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "配置项不能包含换行。"
  temp="$(mktemp "$DEPLOY_DIR/.new-api-env.XXXXXX")"
  TEMP_FILES+=("$temp")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      if ((found == 0)); then
        printf '%s=%s\n' "$key" "$value" >> "$temp"
        found=1
      fi
    else
      printf '%s\n' "$line" >> "$temp"
    fi
  done < "$file"
  if ((found == 0)); then
    printf '%s=%s\n' "$key" "$value" >> "$temp"
  fi
  chmod 600 "$temp"
  mv -f -- "$temp" "$file"
}

generate_secret() { openssl rand -hex 32; }

prompt_value() {
  local prompt="$1" default="${2:-}" answer
  if open_terminal; then
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]：" answer <&"$TTY_FD" || return 1
      printf '%s' "${answer:-$default}"
    else
      read -r -p "$prompt：" answer <&"$TTY_FD" || return 1
      printf '%s' "$answer"
    fi
  else
    printf '%s' "$default"
  fi
}

confirm_operation() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local answer
  answer="$(prompt_value "$1 [y/N]" n)" || die "无法读取确认。"
  [[ "$answer" == y || "$answer" == Y ]] || die "操作已取消；非交互运行可使用 --yes。"
}

validate_image() {
  local value="$1" last
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] || die "镜像名称含无效字符。"
  last="${value##*/}"
  [[ "$last" == *:* ]] || die "镜像必须包含明确版本标签或 sha256 摘要。"
}

normalize_app_image() {
  local value="$1" digest
  if [[ "$value" == "$DEFAULT_IMAGE_REPOSITORY@sha256:"* ]]; then
    value="${value#"$DEFAULT_IMAGE_REPOSITORY@"}"
  fi
  if [[ "$value" == sha256:* ]]; then
    digest="${value#sha256:}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "镜像摘要必须是 sha256: 后接 64 位小写十六进制字符。"
    printf '%s@sha256:%s' "$DEFAULT_IMAGE_REPOSITORY" "$digest"
    return
  fi
  if [[ "$value" == "$DEFAULT_IMAGE_REPOSITORY:"* ]]; then
    value="${value#"$DEFAULT_IMAGE_REPOSITORY:"}"
  fi
  if [[ ! "$value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || (( ${#value} > 120 )); then
    die "请选择本 fork 已发布的固定版本（如 v1.0.0-orange、v1.0.0-rc.48-orange.1）或 $DEFAULT_IMAGE_REPOSITORY@sha256:<摘要>；不接受其他镜像仓库或 latest 等浮动标签。"
  fi
  printf '%s:%s' "$DEFAULT_IMAGE_REPOSITORY" "$value"
}

verify_app_image() {
  local file="${1:-$DEPLOY_DIR/.env}" image expected actual
  image="$(read_env_value NEW_API_IMAGE "$file")"
  expected="$(docker_exec version --format '{{.Server.Os}}/{{.Server.Arch}}')"
  [[ "$expected" == linux/amd64 || "$expected" == linux/arm64 ]] || die "本 fork 只支持 Linux amd64（x86_64）或 arm64，当前 Docker 服务为 $expected。"
  actual="$(docker_exec image inspect "$image" --format '{{.Os}}/{{.Architecture}}')" || die "本地未找到目标应用镜像；请先拉取镜像，或检查 --no-pull 使用的本地镜像。"
  [[ "$actual" == "$expected" ]] || die "应用镜像平台为 $actual，与本机 Docker 平台 $expected 不一致。"
}

validate_env() {
  local file="${1:-$DEPLOY_DIR/.env}" key value line
  [[ -f "$file" && ! -L "$file" ]] || die "缺少普通 .env 配置文件。"
  local -A seen=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die ".env 请使用每行 KEY=VALUE 的格式。"
    key="${line%%=*}"
    [[ -z "${seen[$key]:-}" ]] || die ".env 存在重复配置项：$key"
    seen[$key]=1
  done < "$file"
  for key in NEW_API_IMAGE POSTGRES_PASSWORD REDIS_PASSWORD SESSION_SECRET CRYPTO_SECRET SESSION_COOKIE_TRUSTED_URL TRUSTED_PROXIES; do
    value="$(read_env_value "$key" "$file")"
    [[ -n "$value" ]] || die ".env 缺少必填配置：$key"
    [[ "$value" != *'$'* && "$value" != *'`'* && "$value" != *'\'* && "$value" != *'"'* && "$value" != *"'"* && ! "$value" =~ [[:space:]] ]] || die "$key 请使用明确字面值，不支持变量表达式或转义。"
  done
  validate_image "$(read_env_value NEW_API_IMAGE "$file")"
  for key in POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD REDIS_PASSWORD; do
    value="$(read_env_value "$key" "$file")"
    [[ "$value" =~ ^[A-Za-z0-9_.~-]+$ ]] || die "$key 只能使用 URI 安全字符。"
  done
  value="$(read_env_value SESSION_COOKIE_TRUSTED_URL "$file")"
  [[ "$value" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(,https://[A-Za-z0-9.-]+(:[0-9]+)?)*$ ]] || die "SESSION_COOKIE_TRUSTED_URL 必须是一个或多个无路径的 HTTPS Origin。"
  value="$(read_env_value TRUSTED_PROXIES "$file")"
  [[ "$value" == none || "$value" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?(,[0-9a-fA-F:.]+(/[0-9]+)?)*$ ]] || die "TRUSTED_PROXIES 必须是代理 IP/CIDR，或 none。"
  value="$(read_env_value SERVER_PORT "$file")"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) || die "SERVER_PORT 必须在 1 到 65535 之间。"
  for key in POSTGRES_IMAGE REDIS_IMAGE; do
    value="$(read_env_value "$key" "$file")"
    [[ -z "$value" ]] || validate_image "$value"
  done
}

has_persistent_data() {
  [[ -f "$DEPLOY_DIR/.env" ]] ||
    [[ -f "$DEPLOY_DIR/data/postgres_data/PG_VERSION" ]] ||
    [[ -f "$DEPLOY_DIR/data/postgres_data/global/pg_control" ]] ||
    [[ -n "$(find "$DEPLOY_DIR/data/app_data" "$DEPLOY_DIR/data/redis_data" "$DEPLOY_DIR/logs" -mindepth 1 -print -quit 2>/dev/null || true)" ]]
}

require_migration_data() {
  [[ -f "$DEPLOY_DIR/.env" ]] || die "迁移安装需要现有 .env。"
  [[ -f "$DEPLOY_DIR/data/postgres_data/PG_VERSION" ]] || die "缺少 data/postgres_data/PG_VERSION。"
  [[ "$(tr -d '\r\n' < "$DEPLOY_DIR/data/postgres_data/PG_VERSION")" == 15 ]] || die "只支持 PostgreSQL 15 数据目录。"
  [[ -f "$DEPLOY_DIR/data/postgres_data/global/pg_control" ]] || die "缺少 PostgreSQL global/pg_control。"
  [[ -d "$DEPLOY_DIR/data/postgres_data/base" ]] || die "缺少 PostgreSQL base 目录。"
  [[ -d "$DEPLOY_DIR/data/app_data" ]] || die "缺少 data/app_data。"
  [[ -d "$DEPLOY_DIR/data/redis_data" ]] || die "缺少 data/redis_data。"
}

config_value() {
  awk -v key="$1" '$1 == key ":" { $1=""; sub(/^[[:space:]]+/, ""); if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) { print substr($0, 2, length($0)-2) } else { print } }'
}

service_config() {
  local service="$1" field="$2"
  awk -v service="$service" -v field="$field" '
    function unquote(value) {
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) return substr(value, 2, length(value)-2)
      return value
    }
    /^services:$/ { services=1; next }
    services && /^[^[:space:]]/ { services=0 }
    services && /^  [A-Za-z0-9_-]+:$/ { selected=($1 == service ":"); volumes=0; next }
    selected && /^    [A-Za-z_]/ {
      volumes=($1 == "volumes:")
      if (field == "image" && $1 == "image:") {
        sub(/^    image: /, ""); print unquote($0)
      }
    }
    selected && volumes && field == "mounts" {
      if ($1 == "-" && $2 == "type:") kind=$3
      if ($1 == "source:") { sub(/^[[:space:]]*source: /, ""); source=unquote($0) }
      if ($1 == "target:") { sub(/^[[:space:]]*target: /, ""); print kind "|" source "|" unquote($0) }
    }
  '
}

verify_config() {
  local file="${1:-$DEPLOY_DIR/.env}" pg_image rendered expected
  validate_env "$file"
  compose_env "$file" config --quiet
  [[ "$(compose_env "$file" config --services | sort)" == $'new-api\npostgres\nredis' ]] || die "Compose 必须包含且只包含 new-api、postgres、redis。"
  rendered="$(compose_env "$file" config)"
  local service actual expected_mounts
  for service in "${SERVICES[@]}"; do
    actual="$(service_config "$service" mounts <<< "$rendered" | sort)"
    case "$service" in
      new-api) expected_mounts="bind|$DEPLOY_DIR/data/app_data|/data"$'\n'"bind|$DEPLOY_DIR/logs|/app/logs" ;;
      postgres) expected_mounts="bind|$DEPLOY_DIR/data/postgres_data|/var/lib/postgresql/data" ;;
      redis) expected_mounts="bind|$DEPLOY_DIR/data/redis_data|/data" ;;
    esac
    [[ "$actual" == "$(sort <<< "$expected_mounts")" ]] || die "Compose 中 $service 的数据挂载不符合本地目录布局。"
  done
  [[ "$(service_config new-api image <<< "$rendered")" == "$(read_env_value NEW_API_IMAGE "$file")" ]] || die "Compose 未使用 .env 中的 NEW_API_IMAGE。"
  expected="$(read_env_value POSTGRES_IMAGE "$file")"
  [[ "$(service_config postgres image <<< "$rendered")" == "${expected:-postgres:15}" ]] || die "Compose 的 PostgreSQL 镜像与 .env 不一致。"
  expected="$(read_env_value REDIS_IMAGE "$file")"
  [[ "$(service_config redis image <<< "$rendered")" == "${expected:-redis:7-alpine}" ]] || die "Compose 的 Redis 镜像与 .env 不一致。"
  expected="postgresql://$(read_env_value POSTGRES_USER "$file"):$(read_env_value POSTGRES_PASSWORD "$file")@postgres:5432/$(read_env_value POSTGRES_DB "$file")"
  [[ "$(config_value SQL_DSN <<< "$rendered")" == "$expected" ]] || die "Compose 的 SQL_DSN 必须指向本地 postgres 服务。"
  expected="redis://:$(read_env_value REDIS_PASSWORD "$file")@redis:6379/0"
  [[ "$(config_value REDIS_CONN_STRING <<< "$rendered")" == "$expected" ]] || die "Compose 的 Redis 连接与 .env 不一致。"
  local key
  for key in SESSION_SECRET CRYPTO_SECRET; do
    [[ "$(config_value "$key" <<< "$rendered")" == "$(read_env_value "$key" "$file")" ]] || die "Compose 的 $key 与 .env 不一致。"
  done
  pg_image="$(read_env_value POSTGRES_IMAGE "$file")"
  pg_image="${pg_image:-postgres:15}"
  [[ "$pg_image" =~ ^postgres(:15([.-][A-Za-z0-9_.-]+)?|@sha256:[0-9a-f]{64})$ ]] || die "POSTGRES_IMAGE 必须是 PostgreSQL 15。"
}

verify_postgres_image() {
  local file="${1:-$DEPLOY_DIR/.env}" image
  image="$(read_env_value POSTGRES_IMAGE "$file")"
  image="${image:-postgres:15}"
  local variables
  variables="$(docker_exec image inspect "$image" --format '{{range .Config.Env}}{{println .}}{{end}}')"
  grep -qx 'PG_MAJOR=15' <<< "$variables" || die "数据库镜像不是 PostgreSQL 15，拒绝启动现有数据目录。"
}

service_id() {
  local identifiers
  identifiers="$(compose ps --all --quiet "$1")"
  [[ "$identifiers" != *$'\n'* ]] || die "服务 $1 有多个容器，此脚本只支持单实例部署。"
  printf '%s' "$identifiers"
}

service_running() {
  local id
  id="$(service_id "$1")"
  [[ -n "$id" ]] && [[ "$(docker_exec inspect --format '{{.State.Running}}' "$id")" == true ]]
}

require_stack_running() {
  local service
  for service in "${SERVICES[@]}"; do
    service_running "$service" || die "服务 $service 没有运行。"
  done
}

verify_mounts() {
  local service id mounts expected working_dir environment key expected_value
  for service in "${SERVICES[@]}"; do
    id="$(service_id "$service")"
    [[ -n "$id" ]] || die "找不到服务 $service 的容器。"
    working_dir="$(docker_exec inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")"
    [[ "$working_dir" == "$DEPLOY_DIR" ]] || die "同名 Compose 项目属于其他目录，拒绝操作。"
    mounts="$(docker_exec inspect --format '{{range .Mounts}}{{printf "%s|%s|%s\n" .Type .Source .Destination}}{{end}}' "$id")"
    case "$service" in
      new-api)
        expected="bind|$DEPLOY_DIR/data/app_data|/data"$'\n'"bind|$DEPLOY_DIR/logs|/app/logs"
        ;;
      postgres) expected="bind|$DEPLOY_DIR/data/postgres_data|/var/lib/postgresql/data" ;;
      redis) expected="bind|$DEPLOY_DIR/data/redis_data|/data" ;;
    esac
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      grep -Fxq "$line" <<< "$mounts" || die "服务 $service 的实际挂载与本地目录不一致。"
    done <<< "$expected"
    [[ "$(sort <<< "$mounts")" == "$(sort <<< "$expected")" ]] || die "服务 $service 存在额外挂载，不能保证迁移完整性。"
    environment="$(docker_exec inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id")"
    case "$service" in
      new-api)
        expected_value="postgresql://$(read_env_value POSTGRES_USER):$(read_env_value POSTGRES_PASSWORD)@postgres:5432/$(read_env_value POSTGRES_DB)"
        grep -Fxq "SQL_DSN=$expected_value" <<< "$environment" || die "实际容器的数据库连接与 .env 不一致。"
        expected_value="redis://:$(read_env_value REDIS_PASSWORD)@redis:6379/0"
        grep -Fxq "REDIS_CONN_STRING=$expected_value" <<< "$environment" || die "实际容器的 Redis 连接与 .env 不一致。"
        for key in SESSION_SECRET CRYPTO_SECRET; do
          grep -Fxq "$key=$(read_env_value "$key")" <<< "$environment" || die "实际容器的 $key 与 .env 不一致。"
        done
        ;;
      postgres)
        for key in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB; do
          grep -Fxq "$key=$(read_env_value "$key")" <<< "$environment" || die "数据库容器的 $key 与 .env 不一致。"
        done
        ;;
      redis)
        grep -Fxq "REDISCLI_AUTH=$(read_env_value REDIS_PASSWORD)" <<< "$environment" || die "Redis 容器的密码与 .env 不一致。"
        ;;
    esac
  done
}

capture_running_services() {
  ORIGINAL_RUNNING_SERVICES=()
  ORIGINAL_RUNNING_IDS=()
  local service
  # 恢复时先启动数据库和 Redis，再启动应用。
  for service in postgres redis new-api; do
    if service_running "$service"; then
      ORIGINAL_RUNNING_SERVICES+=("$service")
      ORIGINAL_RUNNING_IDS+=("$(service_id "$service")")
    fi
  done
}

wait_container() {
  local id="$1" deadline=$((SECONDS + HEALTH_TIMEOUT)) state
  while ((SECONDS < deadline)); do
    state="$(docker_exec inspect --format '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")" || return 1
    case "$state" in
      true\ healthy|true\ ) return 0 ;;
      false*|*unhealthy*) return 1 ;;
    esac
    sleep 2
  done
  return 1
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) status
  while ((SECONDS < deadline)); do
    status="$(compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null || true)"
    if grep -q '^new-api .*running.*healthy' <<< "$status" && grep -q '^postgres .*running.*healthy' <<< "$status" && grep -q '^redis .*running.*healthy' <<< "$status"; then
      log "三个服务均已通过健康检查。"
      return 0
    fi
    sleep 2
  done
  compose ps || true
  die "服务未在 ${HEALTH_TIMEOUT} 秒内通过健康检查。"
}

image_digest() {
  local image="$1" digest
  digest="$(docker_exec image inspect "$image" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')"
  printf '%s' "$digest"
}

write_manifest() {
  local file="$1" service id ref digest arch image_id
  arch="$(docker_exec version --format '{{.Server.Arch}}')"
  {
    printf 'FORMAT=1\nPOSTGRES_MAJOR=15\nARCHITECTURE=%s\n' "$arch"
    for service in "${SERVICES[@]}"; do
      id="$(service_id "$service")"
      ref="$(docker_exec inspect --format '{{.Config.Image}}' "$id")"
      image_id="$(docker_exec inspect --format '{{.Image}}' "$id")"
      digest="$(image_digest "$image_id")"
      printf '%s_IMAGE_REF=%s\n%s_IMAGE_DIGEST=%s\n' "${service^^}" "$ref" "${service^^}" "$digest"
    done
  } > "$file"
  chmod 600 "$file"
}

manifest_value() {
  awk -F= -v key="$1" '$1 == key { value=$0; sub(/^[^=]*=/, "", value); print value; exit }' "$2"
}

pin_manifest_images() {
  local file="${1:-$DEPLOY_DIR/.env}" manifest="$DEPLOY_DIR/migration.manifest" key value
  [[ -f "$manifest" ]] || return 0
  [[ "$(manifest_value FORMAT "$manifest")" == 1 ]] || die "不支持此迁移包格式。"
  [[ "$(manifest_value POSTGRES_MAJOR "$manifest")" == 15 ]] || die "迁移包不是 PostgreSQL 15。"
  if [[ -n "$(manifest_value ARCHITECTURE "$manifest")" ]]; then
    local current_arch expected_arch
    current_arch="$(docker_exec version --format '{{.Server.Arch}}')"
    expected_arch="$(manifest_value ARCHITECTURE "$manifest")"
    [[ "$current_arch" == "$expected_arch" ]] || die "迁移包 CPU 架构为 $expected_arch，当前机器为 $current_arch。"
  fi
  for key in NEW-API POSTGRES REDIS; do
    value="$(manifest_value "${key}_IMAGE_DIGEST" "$manifest")"
    [[ -n "$value" ]] || continue
    case "$key" in
      NEW-API) set_env_value NEW_API_IMAGE "$value" "$file" ;;
      POSTGRES) set_env_value POSTGRES_IMAGE "$value" "$file" ;;
      REDIS) set_env_value REDIS_IMAGE "$value" "$file" ;;
    esac
  done
}

create_backup() {
  require_migration_data
  verify_config
  verify_mounts
  [[ "$BACKUP_DIR/" != "$DEPLOY_DIR/"* ]] || die "备份目录必须位于部署目录之外。"
  mkdir -p -- "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local temp_dir archive_partial archive checksum manifest suffix service id state links
  temp_dir="$(mktemp -d "$BACKUP_DIR/.new-api-migration.XXXXXX")"
  TEMP_DIRS+=("$temp_dir")
  manifest="$temp_dir/migration.manifest"
  TEMP_FILES+=("$manifest")
  write_manifest "$manifest"
  suffix="${temp_dir##*.}"
  archive="$BACKUP_DIR/new-api-migration-$(date +%Y%m%d-%H%M%S)-$suffix.tar.gz"
  archive_partial="$archive.partial"
  TEMP_FILES+=("$archive_partial")
  capture_running_services
  log "备份会短暂停止整个服务栈，完成后恢复备份前正在运行的服务。"
  STOPPED_BY_SCRIPT=true
  compose stop --timeout 60
  for service in "${SERVICES[@]}"; do
    id="$(service_id "$service")"
    state="$(docker_exec inspect --format '{{.State.Running}} {{.State.ExitCode}}' "$id")"
    [[ "$state" == false\ * ]] || die "服务 $service 未停止，拒绝创建物理备份。"
    [[ "$service" != postgres || "$state" == 'false 0' ]] || die "PostgreSQL 未正常退出，拒绝创建物理备份。"
  done
  [[ ! -e "$DEPLOY_DIR/data/postgres_data/postmaster.pid" ]] || die "PostgreSQL 仍存在 postmaster.pid，无法确认已干净停止。"
  links="$(find "$DEPLOY_DIR/data" "$DEPLOY_DIR/logs" -type l -print -quit)"
  [[ -z "$links" ]] || die "数据或日志目录包含符号链接，拒绝打包。"
  tar --numeric-owner --acls --xattrs -czf "$archive_partial" -C "$DEPLOY_DIR" data logs .env .env.example docker-compose.yml to-install.sh -C "$temp_dir" migration.manifest
  mv -f -- "$archive_partial" "$archive"
  chmod 600 "$archive"
  checksum="$archive.sha256"
  (cd -- "$BACKUP_DIR" && sha256sum "${archive##*/}") > "$checksum"
  chmod 600 "$checksum"
  rm -f -- "$manifest"
  rmdir -- "$temp_dir"
  restore_original_services || die "迁移包已保存，但原运行服务未能全部恢复，请检查容器状态。"
  BACKUP_ARCHIVE="$archive"
  log "迁移备份已生成：$archive"
  log "校验文件已生成：$checksum"
}

fresh_install() {
  [[ ! -e "$DEPLOY_DIR/.env" ]] || die "当前目录已有 .env，请选择迁移安装或更新。"
  local path contents
  for path in "$DEPLOY_DIR/data" "$DEPLOY_DIR/logs"; do
    if [[ -d "$path" ]]; then
      contents="$(find "$path" -mindepth 1 ! -type d -print -quit)"
      [[ -z "$contents" ]] || die "当前目录已有运行数据，全新安装已拒绝。"
    fi
  done
  prepare_runtime_files
  local image origin proxies key candidate port
  image="${IMAGE_OVERRIDE:-${VERSION_OVERRIDE:-$(prompt_value '请输入已发布版本号（如 v1.0.0-rc.48-orange.1）或本 fork 的 GHCR 镜像/摘要')}}"
  [[ -n "$image" ]] || die "必须填写 NEW_API_IMAGE。"
  image="$(normalize_app_image "$image")"
  origin="${ORIGIN_OVERRIDE:-$(prompt_value '请输入控制台 HTTPS Origin（例如 https://api.example.com）')}"
  proxies="${PROXIES_OVERRIDE:-$(prompt_value '请输入可信反向代理 IP/CIDR；无代理填 none' none)}"
  port="${PORT_OVERRIDE:-$(prompt_value '请输入应用宿主机端口' 3000)}"
  candidate="$(mktemp "$DEPLOY_DIR/.new-api-env.XXXXXX")"
  TEMP_FILES+=("$candidate")
  cp -- "$DEPLOY_DIR/.env.example" "$candidate"
  set_env_value NEW_API_IMAGE "$image" "$candidate"
  set_env_value SESSION_COOKIE_TRUSTED_URL "$origin" "$candidate"
  set_env_value TRUSTED_PROXIES "$proxies" "$candidate"
  set_env_value SERVER_PORT "$port" "$candidate"
  for key in "${SECRET_KEYS[@]}"; do
    set_env_value "$key" "$(generate_secret)" "$candidate"
  done
  verify_config "$candidate"
  [[ -z "$(compose_env "$candidate" ps --all --quiet)" ]] || die "同名 Compose 项目已有容器，拒绝全新安装。"
  if [[ "$NO_PULL" != true ]]; then compose_env "$candidate" pull; fi
  verify_app_image "$candidate"
  verify_postgres_image "$candidate"
  chmod 600 "$candidate"
  mv -- "$candidate" "$DEPLOY_DIR/.env"
  compose up -d --no-build --pull never --wait --wait-timeout "$HEALTH_TIMEOUT"
  log "全新安装完成。请配置 HTTPS 反向代理并打开控制台初始化管理员账号。"
}

update_install() {
  [[ -f "$DEPLOY_DIR/.env" ]] || die "更新要求已有 .env。"
  prepare_runtime_files
  verify_config
  require_stack_running
  local image current temp_env default_image=""
  current="$(read_env_value NEW_API_IMAGE)"
  if default_image="$(normalize_app_image "$current" 2>/dev/null)"; then
    image="${IMAGE_OVERRIDE:-${VERSION_OVERRIDE:-$(prompt_value "请输入目标版本号或 GHCR 镜像；留空继续使用 $default_image" "$default_image")}}"
  else
    image="${IMAGE_OVERRIDE:-${VERSION_OVERRIDE:-$(prompt_value '当前镜像不是本 fork 的固定版本，请输入已发布版本号或本 fork 的 GHCR 镜像/摘要')}}"
  fi
  [[ -n "$image" ]] || die "目标镜像不能为空。"
  image="$(normalize_app_image "$image")"
  temp_env="$(mktemp "$DEPLOY_DIR/.new-api-env.XXXXXX")"
  TEMP_FILES+=("$temp_env")
  cp -- "$DEPLOY_DIR/.env" "$temp_env"
  set_env_value NEW_API_IMAGE "$image" "$temp_env"
  verify_config "$temp_env"
  if [[ "$NO_PULL" != true ]]; then compose_env "$temp_env" pull new-api; fi
  verify_app_image "$temp_env"
  confirm_operation "更新前将短暂停机备份，是否继续？"
  create_backup
  mv -f -- "$temp_env" "$DEPLOY_DIR/.env"
  if ! compose up -d --no-build --pull never --no-deps --force-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" new-api; then
    die "更新未通过健康检查，未自动回滚数据库。更新前备份：$BACKUP_ARCHIVE"
  fi
  log "New API 镜像更新完成；PostgreSQL 和 Redis 未重建。"
}

migration_install() {
  require_migration_data
  prepare_runtime_files
  verify_config
  local service candidate
  for service in "${SERVICES[@]}"; do
    if service_running "$service"; then die "目标目录已有服务运行，不能执行迁移安装。"; fi
  done
  candidate="$(mktemp "$DEPLOY_DIR/.new-api-env.XXXXXX")"
  TEMP_FILES+=("$candidate")
  cp -- "$DEPLOY_DIR/.env" "$candidate"
  pin_manifest_images "$candidate"
  verify_config "$candidate"
  if [[ "$NO_PULL" != true ]]; then compose_env "$candidate" pull; fi
  verify_app_image "$candidate"
  verify_postgres_image "$candidate"
  chmod 600 "$candidate"
  mv -f -- "$candidate" "$DEPLOY_DIR/.env"
  compose up -d --no-build --pull never --wait --wait-timeout "$HEALTH_TIMEOUT"
  log "迁移安装完成，原有 .env、数据库和 Redis 数据已保留。"
}

main() {
  umask 077
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  parse_args "$@"
  choose_mode
  resolve_paths
  if [[ "$MODE" == 1 ]]; then
    mkdir -p -- "$DEPLOY_DIR"
  else
    [[ -d "$DEPLOY_DIR" ]] || die "部署目录不存在：$DEPLOY_DIR"
  fi
  check_tools
  acquire_lock
  local path
  for path in .env docker-compose.yml .env.example to-install.sh data logs data/app_data data/postgres_data data/redis_data; do
    [[ ! -L "$DEPLOY_DIR/$path" ]] || die "部署文件或数据目录不能是符号链接：$path"
  done
  case "$MODE" in
    1) fresh_install ;;
    2) update_install ;;
    3) migration_install ;;
    4) confirm_operation "备份将短暂停止服务，是否继续？"; create_backup ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
