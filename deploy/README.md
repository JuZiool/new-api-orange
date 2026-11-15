# 部署手册

`deploy/` 里是一套单脚本部署方案：new-api-orange + PostgreSQL 15 + Redis 7，一个 `install.sh` 搞定。
脚本在哪个目录运行就装在哪，默认当前目录，可用 `--dir` 指定。

数据全部落在部署目录：`./data`、`./postgres_data`、`./backups`。Redis 只做缓存，不落盘。

## 1. 环境要求

- Linux，amd64 / arm64
- Docker Engine + Docker Compose v2
- Bash 4.0+
- `curl`、`openssl`、`tar`、GNU `find`

macOS 未验证；Windows 请用 WSL 或直接用 Linux 服务器。

## 2. 安装

### 在线安装

```bash
mkdir -p /srv/new-api && cd /srv/new-api
curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy/install.sh | bash -s -- install
```

脚本会把自己、`docker-compose.yml`、`.env.example` 下载到当前目录，生成带随机密码的 `.env`，拉镜像、起容器，最后等健康检查通过。

指定端口和监听地址：

```bash
curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy/install.sh \
  | bash -s -- install --port 8080 --bind 127.0.0.1
```

### 手动安装

raw 文件下不动时，把三个文件放到同一目录再执行：

```bash
base=https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy
curl -fsSLO "$base/install.sh"
curl -fsSLO "$base/docker-compose.yml"
curl -fsSLO "$base/.env.example"
chmod +x install.sh
./install.sh install
```

之后的日常操作都用部署目录里的 `./install.sh`。

### 装完确认

```bash
cd /srv/new-api
./install.sh health
```

打开 `http://服务器地址:3000`，首次访问会引导创建管理员账号。

安装会被拒绝的两种情况：

- 目录里已有 `.env` 或 `postgres_data` 非空 —— 用 `migrate` 或 `update`。
- 目录里有 `go.mod` 和 `main.go` —— 判定为源码仓库，换空目录部署。

## 3. 目录结构

```
/srv/new-api/
├── install.sh             # 脚本自己
├── docker-compose.yml
├── .env                   # 自动生成，权限 600，含随机密码
├── .env.example           # 配置模板
├── .deploy-state.json     # update 的最近一次结果，只有 update 会写
├── .install.lock          # 运行时锁，flock 模式跑完留一个空文件，不影响下次运行
├── data/                  # 挂给容器 /data，日志在 data/logs
├── postgres_data/         # PostgreSQL 数据目录
└── backups/               # 备份，目录权限 700
    └── 20261115-221153/
        ├── postgres.dump
        ├── env
        ├── docker-compose.yml
        ├── data.tar.gz
        └── metadata.txt
```

升级、备份、迁移都以这个目录为单位。

## 4. 命令

不带参数运行 `./install.sh` 会出菜单；没有终端时默认 `install`。

| 命令 | 作用 | 前提 / 备注 |
| --- | --- | --- |
| `./install.sh install` | 全新安装 | 空目录；已有 `.env` 或数据会拒绝 |
| `./install.sh migrate` | 迁移安装 | 已有 `.env` 和 `postgres_data`；不动配置、不初始化库 |
| `./install.sh update` | 更新应用镜像 | 已有部署；默认先备份，健康检查不过回滚镜像 |
| `./install.sh backup` | 备份数据库和配置 | 已有部署且服务健康 |
| `./install.sh restore --from <路径>` | 从备份恢复 | 会清空当前库，需要确认 |
| `./install.sh health` | 健康检查 | 只读，不改动任何东西 |

参数：

```
--dir <路径>            部署目录，默认当前目录
--image <tag|digest>    指定镜像
--bind <地址>           监听地址，默认 0.0.0.0
--port <端口>           监听端口，默认 3000
--health-timeout <秒>   健康检查超时，默认 180
--keep <份数>           备份保留份数，默认 7
--from <路径>           restore 的备份来源（目录或 tar.gz）
--no-backup             update 前跳过备份
--no-pull               用本地已有镜像，不拉取
--install-docker        缺 Docker 时尝试自动安装（需要 root）
--raw-base <URL>        换运行时文件下载地址
--yes                   跳过确认
-h, --help              帮助
```

环境变量：`NEW_API_DEPLOY_DIR`、`NEW_API_IMAGE`、`NEW_API_RAW_BASE`、`NEW_API_HEALTH_TIMEOUT`、`NEW_API_BACKUP_KEEP`。

## 5. 更新

```bash
cd /srv/new-api
./install.sh update
```

顺序是：给当前镜像打本地回滚标签 → 备份（`--no-backup` 可跳过）→ 拉新镜像 → 只重建 `new-api` 容器 → 等健康检查。

健康检查不过会自动用回滚标签把旧镜像起回来。结果写进 `.deploy-state.json`：

```json
{
  "status": "success",
  "image": "ghcr.io/juziool/new-api-orange:latest",
  "imageId": "sha256:...",
  "rollbackTag": "new-api-orange:rollback-20261115221153",
  "previousImage": "ghcr.io/juziool/new-api-orange:latest",
  "backup": "/srv/new-api/backups/20261115-221153",
  "recordedAt": "2026-11-15T14:11:53Z",
  "error": ""
}
```

- 回滚只回滚镜像，数据库结构不会回退；要回退数据用 `restore` 导回更新前的备份。
- 固定版本用 `--image ghcr.io/juziool/new-api-orange:v0.9.12-orange`，该值会写进 `.env`。

## 6. 备份

```bash
./install.sh backup
```

先确认三个容器健康，再导出：

- PostgreSQL：`pg_dump -Fc` 完整库，落到 `postgres.dump`
- `.env`、`docker-compose.yml`
- `data/`：打成 `data.tar.gz`，排除 `data/logs`
- `metadata.txt`：创建时间、镜像、PG 版本、库名

Redis 不备份，日志不进备份。备份目录权限 700、文件 600，默认保留最近 7 份，`--keep` 可改。

单个备份目录打成 tar 后可以直接给 `restore` 用：

```bash
tar -czf new-api-backup-20261115.tar.gz -C backups 20261115-221153
```

整机迁移用的目录 tar 不含 `postgres.dump`，不能当备份用。

## 7. 恢复

```bash
./install.sh restore --from backups/20261115-221153
./install.sh restore --from /root/new-api-backup-20261115.tar.gz --yes
```

流程：起 PostgreSQL 和 Redis → 确认 → 停 `new-api` → 重建 `public` schema → 导入 dump → 起服务 → 等健康检查。

- 备份里的 `SESSION_SECRET`（以及存在时的 `CRYPTO_SECRET`）会写回当前 `.env`，恢复后用户不用重新登录。
- 非交互环境必须加 `--yes`。
- 恢复进空目录时，脚本生成新密码的 `.env` 并用它初始化新库，两者配套。
- 目标目录已有 `postgres_data` 却没有 `.env` 时，新密码对不上旧数据目录，服务起不来；先把原 `.env` 放回去再恢复。

## 8. 整目录迁移

老机器停容器并打包：

```bash
cd /srv/new-api
docker compose --env-file .env -f docker-compose.yml stop
cd ..
tar -czf new-api-migrate-$(date +%F).tar.gz new-api
```

新机器解压后执行 `migrate`：

```bash
mkdir -p /srv
tar -xzf new-api-migrate-2026-11-15.tar.gz -C /srv
cd /srv/new-api
./install.sh migrate
```

`migrate` 会核对 `postgres_data/PG_VERSION` 与 `.env` 里 `POSTGRES_IMAGE_TAG` 的大版本（数据是 `15`，标签必须是 `15-*`），然后拉镜像、起容器、等健康检查。不重新生成 `.env`，不初始化数据库，密码、密钥、数据、登录态原样保留。

迁移前建议先跑一次 `./install.sh backup`。

## 9. 配置（.env）

`.env` 由 `.env.example` 生成，密码和密钥随机，权限 600。改完执行 `docker compose --env-file .env -f docker-compose.yml up -d` 生效。

| 变量 | 说明 |
| --- | --- |
| `COMPOSE_PROJECT_NAME` | 项目名，决定容器名前缀 |
| `NEW_API_IMAGE` | 应用镜像，`update --image` 会改这里 |
| `BIND_HOST` / `HTTP_PORT` | 监听地址和端口，默认 `0.0.0.0:3000` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | 数据库账号，密码随机 48 位 |
| `POSTGRES_IMAGE_TAG` | PostgreSQL 镜像标签，默认 `15-alpine`；数据目录建好后不要跨大版本改 |
| `REDIS_PASSWORD` / `REDIS_IMAGE_TAG` | Redis 密码和镜像，默认 `7-alpine` |
| `SESSION_SECRET` | 会话签名密钥，迁移和恢复时必须保持不变 |
| `CRYPTO_SECRET` | 可选加密密钥，留空自动用 `SESSION_SECRET`；设了同样要保持不变 |
| `TZ` | 时区，默认 `Asia/Shanghai` |
| `ERROR_LOG_ENABLED` / `BATCH_UPDATE_ENABLED` / `NODE_NAME` / `SYNC_FREQUENCY` | 应用行为开关 |
| `FRONTEND_BASE_URL` | 对外地址，挂反向代理时填 |
| `SESSION_COOKIE_SECURE` / `SESSION_COOKIE_TRUSTED_URL` | 走 HTTPS 时配置 |
| `BACKUP_KEEP` | 备份保留份数，默认 7 |

密码不要用 `#`、`$`、引号、空格，脚本生成的都是十六进制。

## 10. 常见问题

**端口被占用**：`./install.sh install --port 8080`，或改 `.env` 的 `HTTP_PORT` 后 `docker compose up -d`。

**健康检查超时**：看状态和日志。

```bash
cd /srv/new-api
docker compose --env-file .env -f docker-compose.yml ps
docker compose --env-file .env -f docker-compose.yml logs --tail=200 new-api postgres redis
```

常见原因是 PostgreSQL 未初始化完、磁盘满、镜像起不来。

**PostgreSQL 版本不一致**：数据目录是 `14` 就把 `POSTGRES_IMAGE_TAG` 改成 `14-alpine` 再跑 `migrate`。跨大版本升级要先单独用 `pg_dump` / `pg_upgrade` 处理。

**镜像拉不下来**：`--image` 换可用地址，或先 `docker pull` 到本地再 `--no-pull`。

**update 被"备份前健康检查失败"拦住**：当前服务不健康时备份会失败；加 `--no-backup` 跳过备份再更新，或先按上一条排查。

**脚本跑一半断了**：重跑同一条命令，已生成的文件不会重复生成。提示"另一个安装、更新或备份任务正在运行"时先确认没有别的脚本在跑；`flock` 锁在进程退出时自动释放，空 `.install.lock` 不挡路。

**换机器后所有人要重新登录**：`SESSION_SECRET` 变了。用整目录迁移，或 restore 时保留备份里的 `SESSION_SECRET`。

**要上 HTTPS**：脚本不管证书，用 Nginx 或 Caddy 反代到 `127.0.0.1:3000`，设 `SESSION_COOKIE_SECURE=true`、`SESSION_COOKIE_TRUSTED_URL=https://你的域名`，再 `docker compose up -d`。反代需放行流式响应和 WebSocket。

**Redis 重启后缓存空了**：正常，Redis 不落盘，限流计数和缓存会重置。

**静默安装**：加 `--yes`，并用 `NEW_API_NO_PROMPT=1` 跳过端口和地址询问。

```bash
NEW_API_NO_PROMPT=1 ./install.sh install --port 3000 --bind 0.0.0.0 --yes
```

**日志在哪**：应用日志在 `data/logs/`，容器输出用 `docker compose logs -f new-api`。

**不用脚本了**：这个目录就是标准 Compose 项目，`docker compose --env-file .env -f docker-compose.yml up -d` 照样能起。
