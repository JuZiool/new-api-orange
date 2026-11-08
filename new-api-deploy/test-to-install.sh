#!/usr/bin/env bash
# 回归测试只使用临时目录和模拟 Docker；不连接 Docker 服务。
set -Eeuo pipefail

TEST_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SUBJECT="$TEST_SCRIPT_DIR/to-install.sh"
SELF="${BASH_SOURCE[0]}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Missing [$2] in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "Unexpected [$2] in $1"; }

make_fixture() {
  mkdir -p -- "$TEST_CASE_DIR/deployment with spaces" "$TEST_CASE_DIR/backups"
  local directory="$TEST_CASE_DIR/deployment with spaces"
  cp -- "$TEST_SCRIPT_DIR/docker-compose.yml" "$directory/docker-compose.yml"
  cp -- "$TEST_SCRIPT_DIR/.env.example" "$directory/.env.example"
  cp -- "$SUBJECT" "$directory/to-install.sh"
  cat > "$directory/.env" <<'EOF'
NEW_API_IMAGE=registry.example.test/new-api:v1
POSTGRES_IMAGE=postgres:15
REDIS_IMAGE=redis:7-alpine
POSTGRES_USER=newapi
POSTGRES_DB=new-api
POSTGRES_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REDIS_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SESSION_SECRET=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
CRYPTO_SECRET=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SESSION_COOKIE_TRUSTED_URL=https://api.example.test
TRUSTED_PROXIES=172.20.0.1
BIND_HOST=0.0.0.0
SERVER_PORT=3000
TZ=Asia/Shanghai
EOF
  : > "$TEST_CASE_DIR/calls"
}

database_fixture() {
  mkdir -p -- "$DEPLOY_DIR/data/app_data" "$DEPLOY_DIR/data/postgres_data/global" "$DEPLOY_DIR/data/postgres_data/base" "$DEPLOY_DIR/data/redis_data" "$DEPLOY_DIR/logs"
  printf '15\n' > "$DEPLOY_DIR/data/postgres_data/PG_VERSION"
  printf 'fixture control' > "$DEPLOY_DIR/data/postgres_data/global/pg_control"
  printf 'application data' > "$DEPLOY_DIR/data/app_data/app-file"
  printf 'redis append data' > "$DEPLOY_DIR/data/redis_data/appendonly.aof"
  printf 'program log' > "$DEPLOY_DIR/logs/oneapi.log"
}

running_fixture() {
  local service
  for service in new-api postgres redis; do
    printf 'true\n' > "$TEST_CASE_DIR/$service.running"
    : > "$TEST_CASE_DIR/$service.exists"
  done
}

fake_compose() {
  local env_file="$1" command="$2"
  shift 2
  printf 'compose %s' "$command" >> "$TEST_CASE_DIR/calls"
  printf ' %s' "$@" >> "$TEST_CASE_DIR/calls"
  printf '\n' >> "$TEST_CASE_DIR/calls"
  case "$command" in
    config)
      local argument
      if (($# == 0)); then
        printf 'services:\n  new-api:\n    image: %s\n    environment:\n' "$(read_env_value NEW_API_IMAGE "$env_file")"
        printf '      SQL_DSN: postgresql://%s:%s@postgres:5432/%s\n' "$(read_env_value POSTGRES_USER "$env_file")" "$(read_env_value POSTGRES_PASSWORD "$env_file")" "$(read_env_value POSTGRES_DB "$env_file")"
        printf '      REDIS_CONN_STRING: redis://:%s@redis:6379/0\n' "$(read_env_value REDIS_PASSWORD "$env_file")"
        printf '      SESSION_SECRET: %s\n      CRYPTO_SECRET: %s\n' "$(read_env_value SESSION_SECRET "$env_file")" "$(read_env_value CRYPTO_SECRET "$env_file")"
        printf '    volumes:\n      - type: bind\n        source: %s/data/app_data\n        target: /data\n      - type: bind\n        source: %s/logs\n        target: /app/logs\n' "$DEPLOY_DIR" "$DEPLOY_DIR"
        printf '  postgres:\n    image: %s\n    volumes:\n      - type: bind\n        source: %s/data/postgres_data\n        target: /var/lib/postgresql/data\n' "$(read_env_value POSTGRES_IMAGE "$env_file")" "$DEPLOY_DIR"
        printf '  redis:\n    image: %s\n    volumes:\n      - type: bind\n        source: %s/data/redis_data\n        target: /data\n' "$(read_env_value REDIS_IMAGE "$env_file")" "$DEPLOY_DIR"
      fi
      for argument in "$@"; do
        case "$argument" in
          --services) printf 'new-api\npostgres\nredis\n' ;;
          --images) printf '%s\n' "$(read_env_value NEW_API_IMAGE "$env_file")" "$(read_env_value POSTGRES_IMAGE "$env_file")" "$(read_env_value REDIS_IMAGE "$env_file")" ;;
        esac
      done
      ;;
    pull)
      [[ ! -f "$TEST_CASE_DIR/fail-pull" ]] || return 42
      ;;
    ps)
      local service="" argument formatting=false
      for argument in "$@"; do
        case "$argument" in new-api|postgres|redis) service="$argument" ;; esac
        [[ "$argument" != --format ]] || formatting=true
      done
      if [[ "$formatting" == true ]]; then
        printf 'new-api running healthy\npostgres running healthy\nredis running healthy\n'
      elif [[ -n "$service" ]]; then
        [[ ! -f "$TEST_CASE_DIR/$service.exists" ]] || printf '%s-id\n' "$service"
      else
        for service in new-api postgres redis; do
          [[ ! -f "$TEST_CASE_DIR/$service.exists" ]] || printf '%s-id\n' "$service"
        done
      fi
      ;;
    stop)
      local service
      for service in new-api postgres redis; do
        [[ ! -f "$TEST_CASE_DIR/$service.exists" ]] || printf 'false\n' > "$TEST_CASE_DIR/$service.running"
      done
      ;;
    start)
      local service
      for service in "$@"; do
        [[ "$service" != -* ]] || continue
        printf 'true\n' > "$TEST_CASE_DIR/$service.running"
      done
      ;;
    up)
      [[ ! -f "$TEST_CASE_DIR/fail-up" ]] || return 43
      ;;
    version) printf 'Docker Compose version v2.40.0\n' ;;
    *) fail "Unexpected fake Compose command: $command $*" ;;
  esac
}

docker() {
  while [[ "${1:-}" == --host || "${1:-}" == --context ]]; do shift 2; done
  local action="${1:-}"
  shift || true
  if [[ "$action" == compose ]]; then
    local env_file="$DEPLOY_DIR/.env"
    while [[ "${1:-}" == -* ]]; do
      case "$1" in
        --env-file) env_file="$2"; shift 2 ;;
        --project-directory|-f|--file|-p|--project-name) shift 2 ;;
        *) shift ;;
      esac
    done
    fake_compose "$env_file" "$@"
    return
  fi
  if [[ "$action" == info || "$action" == version ]]; then printf 'amd64\n'; return; fi
  if [[ "$action" == context ]]; then printf 'unix:///var/run/docker.sock\n'; return; fi
  if [[ "$action" == start ]]; then
    local identifier service
    for identifier in "$@"; do
      service="${identifier%-id}"
      printf 'docker start %s\n' "$identifier" >> "$TEST_CASE_DIR/calls"
      printf 'true\n' > "$TEST_CASE_DIR/$service.running"
    done
    return
  fi
  if [[ "$action" == image ]]; then
    [[ "${1:-}" == inspect ]] || fail "Unexpected fake image operation"
    shift
    local image="${1:-}" format="${3:-}"
    if [[ "$image" == --format ]]; then format="$2"; image="$3"; fi
    if [[ "$format" == *Config.Env* ]]; then printf 'PG_MAJOR=15\n'; return; fi
    if [[ "$format" == *Architecture* ]]; then printf 'amd64\n'; return; fi
    case "$image" in
      *postgres*) printf 'postgres@sha256:%064d\n' 1 ;;
      *redis*) printf 'redis@sha256:%064d\n' 2 ;;
      *) printf 'registry.example.test/new-api@sha256:%064d\n' 3 ;;
    esac
    return
  fi
  if [[ "$action" == inspect ]]; then
    local identifier="" format="" argument service
    while (($#)); do
      case "$1" in --format|-f) format="$2"; shift 2 ;; *) identifier="$1"; shift ;; esac
    done
    service="${identifier%-id}"
    case "$format" in
      *State.Running*State.ExitCode*) printf '%s 0\n' "$(cat "$TEST_CASE_DIR/$service.running")" ;;
      *State.Running*State.Health*) printf '%s healthy\n' "$(cat "$TEST_CASE_DIR/$service.running")" ;;
      *State.Running*) cat "$TEST_CASE_DIR/$service.running" ;;
      *State.ExitCode*) printf '0\n' ;;
      *State.Health.Status*) printf 'healthy\n' ;;
      *Config.Labels*) printf '%s\n' "$DEPLOY_DIR" ;;
      *Config.Image*)
        case "$service" in new-api) printf 'registry.example.test/new-api:v1\n' ;; postgres) printf 'postgres:15\n' ;; redis) printf 'redis:7-alpine\n' ;; esac
        ;;
      '{{.Image}}') printf '%s-image-id\n' "$service" ;;
      *Config.Env*)
        case "$service" in
          new-api)
            printf 'SQL_DSN=postgresql://newapi:%s@postgres:5432/new-api\nREDIS_CONN_STRING=redis://:%s@redis:6379/0\nSESSION_SECRET=%s\nCRYPTO_SECRET=%s\n' "$(read_env_value POSTGRES_PASSWORD)" "$(read_env_value REDIS_PASSWORD)" "$(read_env_value SESSION_SECRET)" "$(read_env_value CRYPTO_SECRET)"
            ;;
          postgres) printf 'POSTGRES_USER=newapi\nPOSTGRES_DB=new-api\nPOSTGRES_PASSWORD=%s\n' "$(read_env_value POSTGRES_PASSWORD)" ;;
          redis) printf 'REDISCLI_AUTH=%s\n' "$(read_env_value REDIS_PASSWORD)" ;;
        esac
        ;;
      *Mounts*)
        local source_prefix="$DEPLOY_DIR"
        [[ ! -f "$TEST_CASE_DIR/wrong-mount" ]] || source_prefix="$TEST_CASE_DIR/wrong"
        case "$service" in
          new-api) printf 'bind|%s/data/app_data|/data\nbind|%s/logs|/app/logs\n' "$source_prefix" "$source_prefix" ;;
          postgres) printf 'bind|%s/data/postgres_data|/var/lib/postgresql/data\n' "$source_prefix" ;;
          redis) printf 'bind|%s/data/redis_data|/data\n' "$source_prefix" ;;
        esac
        ;;
      *) fail "Unexpected fake inspect template: $format" ;;
    esac
    return
  fi
  fail "Unexpected fake Docker call: $action $*"
}

load_subject() {
  # shellcheck source=to-install.sh
  source "$SUBJECT"
  # 源文件仅 main 安装 trap；函数级测试显式使用同样的失败恢复入口。
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  DEPLOY_DIR="$TEST_CASE_DIR/deployment with spaces"
  BACKUP_DIR="$TEST_CASE_DIR/backups"
  SOURCE_DIR="$TEST_SCRIPT_DIR"
  HEALTH_TIMEOUT=2
  ASSUME_YES=true
  prompt_value() {
    case "$1" in
      *HTTPS*) printf 'https://api.example.test' ;;
      *代理*) printf '172.20.0.1' ;;
      *) printf '%s' "${2:-registry.example.test/new-api:v1}" ;;
    esac
  }
}

invoke_subject() {
  local function="$1" status
  shift
  set +e
  TEST_CASE_DIR="$TEST_CASE_DIR" "$BASH" "$SELF" --invoke "$function" "$@" > "$TEST_CASE_DIR/output" 2>&1
  status=$?
  set -e
  return "$status"
}

test_help_and_syntax() {
  "$BASH" -n "$SUBJECT"
  "$BASH" "$SUBJECT" --help > "$TEST_CASE_DIR/help"
  assert_contains "$TEST_CASE_DIR/help" '--mode 1'
  assert_contains "$TEST_CASE_DIR/help" '--mode 2'
  assert_contains "$TEST_CASE_DIR/help" '--mode 3'
  assert_contains "$TEST_CASE_DIR/help" '--mode 4'
}

test_four_modes_and_alias() {
  local expected
  for expected in 1 2 3 4; do
    MODE=""; MODE_EXPLICIT=false
    parse_args --mode "$expected"
    assert_equal "$MODE" "$expected" 'CLI mode'
    choose_mode
    assert_equal "$MODE" "$expected" 'Explicit menu bypass'
  done
  MODE=""; MODE_EXPLICIT=false
  parse_args backup
  assert_equal "$MODE" 4 'Backup alias'
}

test_literal_dotenv_and_preserved_secrets() {
  printf 'EXTRA=\x27$(touch should-not-exist)\x27\n' >> "$DEPLOY_DIR/.env"
  assert_equal "$(read_env_value EXTRA)" '$(touch should-not-exist)' 'Literal dotenv'
  local before
  before="$(read_env_value SESSION_SECRET)"
  set_env_value NEW_API_IMAGE registry.example.test/new-api:v2
  assert_equal "$(read_env_value SESSION_SECRET)" "$before" 'Fixed secret'
  assert_equal "$(read_env_value NEW_API_IMAGE)" registry.example.test/new-api:v2 'Changed image'
  [[ ! -e "$DEPLOY_DIR/should-not-exist" ]] || fail 'Dotenv was executed'
}

test_fresh_refuses_existing_env() {
  cp -- "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  if invoke_subject fresh_install; then fail 'Fresh install accepted existing .env'; fi
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  [[ ! -s "$TEST_CASE_DIR/calls" ]] || fail 'Docker called before rejecting existing env'
}

test_fresh_refuses_existing_data() {
  database_fixture
  rm -f -- "$DEPLOY_DIR/.env"
  if invoke_subject fresh_install; then fail 'Fresh install accepted existing data'; fi
  [[ -f "$DEPLOY_DIR/data/postgres_data/global/pg_control" ]] || fail 'Data removed'
  [[ ! -s "$TEST_CASE_DIR/calls" ]] || fail 'Docker called before rejecting existing data'
}

test_fresh_generates_independent_credentials() {
  rm -f -- "$DEPLOY_DIR/.env"
  invoke_subject fresh_install || { cat "$TEST_CASE_DIR/output"; fail 'Fresh install failed'; }
  assert_equal "$(read_env_value BIND_HOST)" 0.0.0.0 'Default host binding'
  local key value
  for key in POSTGRES_PASSWORD REDIS_PASSWORD SESSION_SECRET CRYPTO_SECRET; do
    value="$(read_env_value "$key")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid generated $key"
    printf '%s\n' "$value" >> "$TEST_CASE_DIR/generated-secrets"
  done
  assert_equal "$(sort -u "$TEST_CASE_DIR/generated-secrets" | wc -l | tr -d '[:space:]')" 4 'Independent keys'
  [[ -d "$DEPLOY_DIR/data/app_data" && -d "$DEPLOY_DIR/data/postgres_data" && -d "$DEPLOY_DIR/data/redis_data" ]] || fail 'Missing data directories'
}

test_migration_requires_complete_pg15() {
  database_fixture
  cp -- "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  printf '16\n' > "$DEPLOY_DIR/data/postgres_data/PG_VERSION"
  if invoke_subject migration_install; then fail 'Migration accepted PostgreSQL 16'; fi
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  printf '15\n' > "$DEPLOY_DIR/data/postgres_data/PG_VERSION"
  rm -f -- "$DEPLOY_DIR/data/postgres_data/global/pg_control"
  if invoke_subject migration_install; then fail 'Migration accepted missing pg_control'; fi
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
}

test_migration_preserves_credentials() {
  database_fixture
  cp -- "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  invoke_subject migration_install || { cat "$TEST_CASE_DIR/output"; fail 'Migration failed'; }
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  assert_contains "$TEST_CASE_DIR/calls" 'compose up'
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose stop'
}

test_migration_missing_secret_is_not_regenerated() {
  database_fixture
  set_env_value SESSION_SECRET ''
  cp -- "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  if invoke_subject migration_install; then fail 'Migration accepted missing fixed secret'; fi
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose up'
}

test_update_pull_failure_preserves_running_state() {
  database_fixture
  running_fixture
  : > "$TEST_CASE_DIR/fail-pull"
  cp -- "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  if invoke_subject update_install; then fail 'Update accepted failed pull'; fi
  cmp "$DEPLOY_DIR/.env" "$TEST_CASE_DIR/original.env"
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose stop'
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose up'
  assert_equal "$(cat "$TEST_CASE_DIR/postgres.running")" true 'Database remains running'
}

test_backup_has_real_archive_and_checksum() {
  database_fixture
  running_fixture
  printf 'lock' > "$DEPLOY_DIR/.new-api-deploy.lock"
  printf 'private candidate' > "$DEPLOY_DIR/.env.update.fixture"
  invoke_subject create_backup || { cat "$TEST_CASE_DIR/output"; fail 'Backup failed'; }
  local archive checksum listing
  archive="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' -print -quit)"
  [[ -n "$archive" ]] || fail 'No backup archive'
  checksum="$archive.sha256"
  [[ -f "$checksum" ]] || fail 'No checksum'
  (cd -- "$BACKUP_DIR" && sha256sum -c "$(basename -- "$checksum")") > "$TEST_CASE_DIR/checksum-result"
  listing="$TEST_CASE_DIR/archive-contents"
  tar -tzf "$archive" > "$listing"
  local name
  for name in .env .env.example docker-compose.yml to-install.sh migration.manifest data/postgres_data/PG_VERSION data/postgres_data/global/pg_control data/redis_data/appendonly.aof data/app_data/app-file logs/oneapi.log; do
    grep -Eq "(^|/)$name$" "$listing" || fail "Missing backup entry $name"
  done
  assert_not_contains "$listing" '.env.update.fixture'
  assert_not_contains "$listing" '.new-api-deploy.lock'
  assert_equal "$(cat "$TEST_CASE_DIR/postgres.running")" true 'Database restored'
  assert_equal "$(cat "$TEST_CASE_DIR/new-api.running")" true 'App restored'
}

test_backup_rejects_wrong_actual_mount() {
  database_fixture
  running_fixture
  : > "$TEST_CASE_DIR/wrong-mount"
  if invoke_subject create_backup; then fail 'Backup accepted wrong actual mount'; fi
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose stop'
}

test_manifest_pins_all_three_images_and_preserves_keys() {
  database_fixture
  running_fixture
  local before
  before="$(read_env_value SESSION_SECRET)"
  write_manifest "$DEPLOY_DIR/migration.manifest"
  pin_manifest_images
  [[ "$(read_env_value NEW_API_IMAGE)" == registry.example.test/new-api@sha256:* ]] || fail 'App digest not pinned'
  [[ "$(read_env_value POSTGRES_IMAGE)" == postgres@sha256:* ]] || fail 'PostgreSQL digest not pinned'
  [[ "$(read_env_value REDIS_IMAGE)" == redis@sha256:* ]] || fail 'Redis digest not pinned'
  assert_equal "$(read_env_value SESSION_SECRET)" "$before" 'Manifest preserves fixed key'
}

test_backup_rejects_output_inside_deployment() {
  database_fixture
  running_fixture
  if invoke_subject backup_inside; then fail 'Backup accepted nested output'; fi
  assert_not_contains "$TEST_CASE_DIR/calls" 'compose stop'
}

backup_inside() { BACKUP_DIR="$DEPLOY_DIR/data/backups"; create_backup; }

test_backup_failure_restores_running_services() {
  database_fixture
  running_fixture
  : > "$TEST_CASE_DIR/fail-tar"
  if invoke_subject backup_with_failed_tar; then fail 'Backup accepted failed tar'; fi
  assert_equal "$(cat "$TEST_CASE_DIR/postgres.running")" true 'Database restored after failure'
  assert_equal "$(cat "$TEST_CASE_DIR/new-api.running")" true 'App restored after failure'
}

backup_with_failed_tar() { tar() { return 44; }; create_backup; }

test_backup_does_not_start_previously_stopped_service() {
  database_fixture
  running_fixture
  printf 'false\n' > "$TEST_CASE_DIR/redis.running"
  invoke_subject create_backup || { cat "$TEST_CASE_DIR/output"; fail 'Backup of partly stopped stack failed'; }
  assert_equal "$(cat "$TEST_CASE_DIR/redis.running")" false 'Stopped Redis preserved'
  assert_equal "$(cat "$TEST_CASE_DIR/postgres.running")" true 'Running database restored'
}

test_update_recreates_only_app() {
  database_fixture
  running_fixture
  invoke_subject update_install || { cat "$TEST_CASE_DIR/output"; fail 'Update failed'; }
  local commands="$TEST_CASE_DIR/calls"
  assert_contains "$commands" 'compose pull new-api'
  grep '^compose up ' "$commands" > "$TEST_CASE_DIR/recreation"
  assert_contains "$TEST_CASE_DIR/recreation" '--no-deps'
  assert_contains "$TEST_CASE_DIR/recreation" '--force-recreate'
  grep -q ' new-api$' "$TEST_CASE_DIR/recreation" || fail 'Update recreated more than app'
  assert_equal "$(read_env_value SESSION_SECRET)" cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 'Update preserved key'
}

if [[ "${1:-}" == --invoke ]]; then
  shift
  load_subject
  "$@"
  exit 0
elif [[ "${1:-}" == --case ]]; then
  shift
  make_fixture
  load_subject
  "$@"
  exit 0
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/new-api-shell-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
tests=(
  test_help_and_syntax
  test_four_modes_and_alias
  test_literal_dotenv_and_preserved_secrets
  test_fresh_refuses_existing_env
  test_fresh_refuses_existing_data
  test_fresh_generates_independent_credentials
  test_migration_requires_complete_pg15
  test_migration_preserves_credentials
  test_migration_missing_secret_is_not_regenerated
  test_update_pull_failure_preserves_running_state
  test_backup_has_real_archive_and_checksum
  test_backup_rejects_wrong_actual_mount
  test_manifest_pins_all_three_images_and_preserves_keys
  test_backup_rejects_output_inside_deployment
  test_backup_failure_restores_running_services
  test_backup_does_not_start_previously_stopped_service
  test_update_recreates_only_app
)
passed=0
failed=0
for name in "${tests[@]}"; do
  case_dir="$TEST_ROOT/$name"
  mkdir -p -- "$case_dir"
  if TEST_CASE_DIR="$case_dir" "$BASH" "$SELF" --case "$name" > "$case_dir/result" 2>&1; then
    printf 'PASS %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    cat "$case_dir/result" >&2
    failed=$((failed + 1))
  fi
done
printf '\n%s passed; %s failed (mock Docker only).\n' "$passed" "$failed"
((failed == 0))
