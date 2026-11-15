#!/usr/bin/env bash
#
# deploy/install.sh 的逻辑测试，不需要真实 Docker。
# 用法：bash deploy/tests/install_script_test.sh

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_SRC="$(cd -- "$TEST_DIR/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }

expect_ok() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

expect_fail_contains() {
  local name="$1" pattern="$2"
  shift 2
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  if ((status == 0)); then
    bad "$name（命令意外成功）"
    return
  fi
  if [[ "$output" == *"$pattern"* ]]; then
    ok "$name"
  else
    bad "$name（输出里没有：$pattern）"
    printf '%s\n' "$output" >&2
  fi
}

mkdir -p "$WORK/bin" "$WORK/source" "$WORK/deploy" "$WORK/restored"
cp -- "$DEPLOY_SRC/install.sh" "$DEPLOY_SRC/docker-compose.yml" "$DEPLOY_SRC/.env.example" "$WORK/source/"

cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"

if [[ "${1:-}" == "info" ]]; then exit 0; fi
if [[ "${1:-}" == "inspect" ]]; then printf 'healthy\n'; exit 0; fi
if [[ "${1:-}" == "tag" ]]; then exit 0; fi
if [[ "${1:-}" == "image" ]]; then exit 0; fi
if [[ "${1:-}" != "compose" ]]; then exit 0; fi

shift
while (($# > 0)); do
  case "$1" in
    --env-file|-f) shift 2 ;;
    *) break ;;
  esac
done

cmd="${1:-}"
case "$cmd" in
  version) printf 'Docker Compose version v2.24.0\n' ;;
  ps) printf 'fake-%s\n' "${@: -1}" ;;
  images)
    if [[ "$*" == *" -q "* || "${*: -1}" == "-q" ]]; then
      printf 'sha256:fake\n'
    else
      printf 'ghcr.io/juziool/new-api-orange:latest\n'
    fi
    ;;
  cp)
    dest="${@: -1}"
    if [[ "$dest" != postgres:* ]]; then
      printf 'fake-dump\n' > "$dest"
    fi
    ;;
  *) ;;
esac
exit 0
FAKE

cat > "$WORK/bin/openssl" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" ]]; then
  count="${3:-16}"
  head -c "$((count * 2))" /dev/zero | tr '\0' 'a'
  printf '\n'
  exit 0
fi
exit 1
FAKE

cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while (($# > 0)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$out" ]]; then
  printf 'fake\n' > "$out"
else
  printf '{"success":true}\n'
fi
FAKE

chmod +x "$WORK/bin/docker" "$WORK/bin/openssl" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FAKE_DOCKER_LOG="$WORK/docker.log"
export NEW_API_NO_PROMPT=1
: > "$FAKE_DOCKER_LOG"

printf 'install.sh 测试\n'

expect_ok "help 输出命令列表" bash -c "bash '$WORK/source/install.sh' --help | grep -q 'install.sh install'"
expect_fail_contains "未知参数被拒绝" "未知参数" bash "$WORK/source/install.sh" --bogus

mkdir -p "$WORK/source-root"
printf 'module test\n' > "$WORK/source-root/go.mod"
printf 'package main\n' > "$WORK/source-root/main.go"
expect_fail_contains "源码根目录拒绝安装" "源码仓库" \
  bash "$WORK/source/install.sh" install --dir "$WORK/source-root"

printf 'EXISTING=1\n' > "$WORK/deploy/.env"
expect_fail_contains "已有 .env 拒绝全新安装" "已有 .env" \
  bash "$WORK/source/install.sh" install --dir "$WORK/deploy"
rm -f "$WORK/deploy/.env"

expect_ok "全新安装" bash "$WORK/source/install.sh" install \
  --dir "$WORK/deploy" --port 13000 --bind 127.0.0.1

[[ -f "$WORK/deploy/.env" ]] && ok ".env 已生成" || bad ".env 未生成"
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  ok ".env 权限检查跳过（Windows 不支持 chmod 600）"
else
  [[ "$(stat -c '%a' "$WORK/deploy/.env" 2>/dev/null)" == "600" ]] && ok ".env 权限 600" || bad ".env 权限不是 600"
fi
[[ "$(awk -F= '$1=="POSTGRES_PASSWORD"{print length($2)}' "$WORK/deploy/.env")" == "48" ]] &&
  ok "数据库密码长度 48" || bad "数据库密码长度不对"
[[ "$(awk -F= '$1=="SESSION_SECRET"{print length($2)}' "$WORK/deploy/.env")" == "64" ]] &&
  ok "会话密钥长度 64" || bad "会话密钥长度不对"
grep -q '^HTTP_PORT=13000$' "$WORK/deploy/.env" && ok "端口写入 .env" || bad "端口未写入 .env"
grep -q 'change_me' "$WORK/deploy/.env" && bad ".env 还有占位密码" || ok "占位密码已替换"
[[ -d "$WORK/deploy/data" && -d "$WORK/deploy/postgres_data" && -d "$WORK/deploy/backups" ]] &&
  ok "数据目录已创建" || bad "数据目录缺失"
grep -q 'up -d' "$FAKE_DOCKER_LOG" && ok "执行了 compose up" || bad "没有执行 compose up"

printf '14\n' > "$WORK/deploy/postgres_data/PG_VERSION"
expect_fail_contains "迁移时 PG 大版本不一致被拒绝" "数据目录是 14" \
  bash "$WORK/source/install.sh" migrate --dir "$WORK/deploy"
printf '15\n' > "$WORK/deploy/postgres_data/PG_VERSION"
expect_ok "迁移安装" bash "$WORK/source/install.sh" migrate --dir "$WORK/deploy"

expect_ok "备份" bash "$WORK/source/install.sh" backup --dir "$WORK/deploy"
BACKUP_DIR="$(find "$WORK/deploy/backups" -mindepth 1 -maxdepth 1 -type d -name '20*' | head -n 1)"
[[ -n "$BACKUP_DIR" ]] && ok "备份目录存在" || bad "备份目录不存在"
[[ -f "$BACKUP_DIR/postgres.dump" && -f "$BACKUP_DIR/env" && -f "$BACKUP_DIR/metadata.txt" ]] &&
  ok "备份内容完整" || bad "备份内容缺失"
OLD_SESSION="$(awk -F= '$1=="SESSION_SECRET"{print $2}' "$BACKUP_DIR/env")"

expect_ok "从备份恢复" bash "$WORK/source/install.sh" restore \
  --dir "$WORK/restored" --from "$BACKUP_DIR" --port 13001 --bind 127.0.0.1 --yes
NEW_SESSION="$(awk -F= '$1=="SESSION_SECRET"{print $2}' "$WORK/restored/.env")"
[[ -n "$OLD_SESSION" && "$OLD_SESSION" == "$NEW_SESSION" ]] &&
  ok "恢复后沿用会话密钥" || bad "恢复后会话密钥不一致"
grep -q 'pg_restore' "$FAKE_DOCKER_LOG" && ok "执行了 pg_restore" || bad "没有执行 pg_restore"

printf '\n结果：%d 通过，%d 失败\n' "$PASS" "$FAIL"
((FAIL == 0))
