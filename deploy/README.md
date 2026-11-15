# 一键部署脚本

一个 `install.sh` 把 new-api-orange + PostgreSQL 15 + Redis 7 装起来，数据全部落在脚本所在目录。
脚本在哪个目录跑就装在哪，默认取当前目录，用 `--dir` 可以换。

适用环境：Linux（amd64 / arm64），需要 Docker Engine、Compose v2、Bash 4+、`curl`、`openssl`、`tar`、GNU `find`。
macOS 未验证。Windows 请用 WSL 或直接上 Linux 服务器。

## 在线安装

```bash
mkdir -p /srv/new-api && cd /srv/new-api
curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy/install.sh | bash -s -- install
```

脚本会把自己、`docker-compose.yml`、`.env.example` 一起下载到当前目录，然后生成 `.env`、拉镜像、起容器。
跑完打开 `http://服务器地址:3000`，第一次访问会引导创建管理员账号。

想换端口和监听地址：

```bash
curl -fsSL .../deploy/install.sh | bash -s -- install --port 8080 --bind 127.0.0.1
```

网络受限拉不动 raw 文件时，手动下三个文件放同一目录再跑：

```bash
base=https://raw.githubusercontent.com/JuZiool/new-api-orange/main/deploy
curl -fsSLO "$base/install.sh"
curl -fsSLO "$base/docker-compose.yml"
curl -fsSLO "$base/.env.example"
chmod +x install.sh
./install.sh install
```

装好之后，日常操作都用部署目录里的 `./install.sh`。

## 目录结构

装完是这样的：

```
/srv/new-api/
├── install.sh             # 脚本自己，之后都跑这个
├── docker-compose.yml
├── .env                   # 自动生成的配置，权限 600，含随机密码
├── .env.example           # 配置模板
├── .deploy-state.json     # update 的最近一次结果（只有 update 会写）
├── .install.lock          # 运行时锁；用 flock 的机器跑完会留一个空文件，不影响下次运行
├── data/                  # 挂给容器的 /data，日志在 data/logs
├── postgres_data/         # PostgreSQL 数据目录
└── backups/               # 备份，权限 700
    └── 20261115-215906/
        ├── postgres.dump
        ├── env
        ├── docker-compose.yml
        ├── data.tar.gz
        └── metadata.txt
```

迁移、升级、备份都以这个目录为单位。整个目录拷走就是完整的一份部署。

## 六个命令

不带参数直接跑 `./install.sh` 会出菜单；没有终端时默认 `install`。

| 命令 | 作用 | 备注 |
| --- | --- | --- |
| `./install.sh install` | 全新安装 | 目录里已有 `.env` 或 `postgres_data` 非空会拒绝 |
| `./install.sh migrate` | 迁移安装 | 目录里已有 `.env` 和 `postgres_data`，只起容器不动配置 |
| `./install.sh update` | 更新应用镜像 | 先备份、再换镜像，健康检查不过自动回滚镜像 |
| `./install.sh backup` | 备份数据库和配置 | 备份前先做健康检查 |
| `./install.sh restore --from <路径>` | 从备份恢复 | 会清空当前库再导入，需要确认 |
| `./install.sh health` | 健康检查 | 只看状态，不改任何东西 |

常用参数：

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
--install-docker        缺 Docker 时尝试自动装（需要 root）
--raw-base <URL>        换下载地址（镜像站、内网）
--yes                   跳过确认，脚本里用
-h, --help              看帮助
```

也可以用环境变量：`NEW_API_DEPLOY_DIR`、`NEW_API_IMAGE`、`NEW_API_RAW_BASE`、`NEW_API_HEALTH_TIMEOUT`、`NEW_API_BACKUP_KEEP`。

## 更新

```bash
cd /srv/new-api
./install.sh update
```

流程是：把当前镜像打成本地回滚标签 → 备份（`--no-backup` 可跳过）→ 拉新镜像 → 只重建 `new-api` 容器 → 等健康检查。

健康检查不过会自动用回滚标签把旧镜像起回来，结果写在 `.deploy-state.json`：

```json
{
  "status": "success",
  "image": "ghcr.io/juziool/new-api-orange:latest",
  "imageId": "sha256:...",
  "rollbackTag": "new-api-orange:rollback-20261115215906",
  "previousImage": "ghcr.io/juziool/new-api-orange:latest",
  "backup": "/srv/new-api/backups/20261115-215906",
  "recordedAt": "2026-11-15T13:59:06Z",
  "error": ""
}
```

两点要注意：

- 回滚只回滚镜像，数据库结构不会自动回退。真要回退数据，用 `restore` 导回更新前的备份。
- 想钉死版本就用 `--image ghcr.io/juziool/new-api-orange:v0.9.12-orange`，这个值会写进 `.env`。

## 备份

```bash
./install.sh backup
```

会先确认三个容器都健康，再导出：

- PostgreSQL：`pg_dump -Fc`，完整库
- `.env`、`docker-compose.yml`：恢复配置要用的
- `data/`：打成 `data.tar.gz`，排除 `data/logs`
- `metadata.txt`：创建时间、镜像、PG 版本、库名

Redis 是纯缓存，不备份。日志不进备份，需要留就自己单独拷 `data/logs`。

备份放 `backups/<时间戳>/`，目录权限 700、文件权限 600。默认留最近 7 份，多的自动删，用 `--keep` 改份数。

单个备份目录可以打成 tar 带走，`restore --from` 直接认：

```bash
tar -czf new-api-backup-20261115.tar.gz -C backups 20261115-215906
```

整机迁移用的目录 tar 不行，那种里面是 `data/` 和 `postgres_data/`，没有 `postgres.dump`，两者别混。

## 整目录迁移

老机器上停容器，打包整个部署目录：

```bash
cd /srv/new-api
docker compose --env-file .env -f docker-compose.yml stop
cd ..
tar -czf new-api-migrate-$(date +%F).tar.gz new-api
```

把 tar 拷到新机器，解压后执行 `migrate`：

```bash
mkdir -p /srv
tar -xzf new-api-migrate-2026-11-15.tar.gz -C /srv
cd /srv/new-api
./install.sh migrate
```

`migrate` 做四件事：检查 PG 数据版本、拉镜像、起容器、等健康检查。它**不会**重新生成 `.env`，也不会初始化数据库，所以密码、`SESSION_SECRET`、用户数据、登录状态都原样保留。

脚本会核对 `postgres_data/PG_VERSION` 和 `.env` 里的 `POSTGRES_IMAGE_TAG` 大版本。比如数据目录是 `15`，镜像标签必须是 `15-*`，不一致会直接拒绝并给出提示，避免 PG 起不来把数据搞坏。

迁移前建议先跑一次 `./install.sh backup`，多一份保险。

## 恢复

```bash
# 从备份目录恢复
./install.sh restore --from backups/20261115-215906

# 从备份 tar 包恢复（里面要有 postgres.dump）
./install.sh restore --from /root/new-api-backup.tar.gz --yes
```

恢复会：起 PostgreSQL 和 Redis → 确认 → 停 `new-api` → 清空并重建 `public` schema → 导入 dump → 起服务 → 等健康检查。

几点说明：

- 备份里的 `SESSION_SECRET`（有的话还有 `CRYPTO_SECRET`）会写回当前 `.env`，这样恢复后用户不用重新登录。会话密钥没变，登录态就还在。
- `restore` 会覆盖当前数据库，命令会要一次确认，非交互环境加 `--yes`。
- 往新目录恢复时，脚本会生成新的 `.env`（新密码），并用新密码初始化新的 PostgreSQL，两者是配套的，能正常连上。
- 反过来说，目标目录里如果已经有 `postgres_data` 却没有 `.env`，脚本生成的新密码对不上旧数据目录，服务会连不上。这种情况先把原来的 `.env` 放回去再恢复，别让脚本重新生成。

## .env 说明

`.env` 由 `.env.example` 生成，密码和密钥是随机的，权限 600。改完需要 `docker compose up -d` 重建容器才生效。

| 变量 | 说明 |
| --- | --- |
| `COMPOSE_PROJECT_NAME` | 项目名，决定容器名前缀 |
| `NEW_API_IMAGE` | 应用镜像，`update --image` 会改这里 |
| `BIND_HOST` / `HTTP_PORT` | 监听地址和端口，默认 `0.0.0.0:3000` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | 数据库账号，密码随机 48 位 |
| `POSTGRES_IMAGE_TAG` | PostgreSQL 镜像标签，默认 `15-alpine`；数据目录建好后不要跨大版本改 |
| `REDIS_PASSWORD` / `REDIS_IMAGE_TAG` | Redis 密码和镜像，默认 `7-alpine` |
| `SESSION_SECRET` | 会话签名密钥，**迁移和恢复时必须保持不变**，否则所有人要重新登录 |
| `CRYPTO_SECRET` | 可选，加密密钥；留空时自动用 `SESSION_SECRET`，设了也要保持不变 |
| `TZ` | 时区，默认 `Asia/Shanghai` |
| `ERROR_LOG_ENABLED` / `BATCH_UPDATE_ENABLED` / `NODE_NAME` / `SYNC_FREQUENCY` | 应用行为开关，按需改 |
| `FRONTEND_BASE_URL` | 对外地址，前面挂反向代理时填 |
| `SESSION_COOKIE_SECURE` / `SESSION_COOKIE_TRUSTED_URL` | 走 HTTPS 时开，见下面常见问题 |
| `BACKUP_KEEP` | 备份保留份数，默认 7 |

密码里不要用 `#`、`$`、引号、空格这类字符，脚本生成的都是十六进制，手工改请照这个来。

## 常见问题

**端口被占用**：换端口，`./install.sh install --port 8080`，或改 `.env` 里的 `HTTP_PORT` 后 `docker compose up -d`。

**健康检查超时**：先看日志。

```bash
cd /srv/new-api
docker compose --env-file .env -f docker-compose.yml ps
docker compose --env-file .env -f docker-compose.yml logs --tail=200 new-api postgres redis
```

常见原因是 PostgreSQL 还没初始化完、磁盘满了、或者镜像本身起不来。

**提示 PostgreSQL 版本不一致**：数据目录是 `14` 就把 `.env` 的 `POSTGRES_IMAGE_TAG` 改成 `14-alpine` 再跑 `migrate`。跨大版本升级 PostgreSQL 要先单独用 `pg_dump` / `pg_upgrade` 处理，脚本不代劳。

**镜像拉不下来**：`--image` 换可用的镜像地址，或者先 `docker pull` 到本地再 `--no-pull`。

**提示"当前目录是源码仓库"**：脚本检测到目录里有 `go.mod` 和 `main.go`，为免把数据写进代码仓库，直接拒绝。换一个空目录部署。

**脚本装到一半断了**：重新跑同一条命令即可，已生成的文件不会重复生成。如果提示"另一个安装、更新或备份任务正在运行"，先确认没有别的脚本在跑，再删掉 `.install.lock`（`flock` 锁在进程退出时会自动释放，这个空文件本身不挡路）。

**更新被"备份前健康检查失败"拦住了**：`update` 默认先备份，而备份要求当前服务健康。当前服务本身有问题时加 `--no-backup` 跳过备份再更新，或者先按上一条排查。

**换机器后所有人都要重新登录**：多半是 `SESSION_SECRET` 变了。用整目录迁移，或者 `restore` 时保留备份里的 `SESSION_SECRET`，就不会出现。

**要上 HTTPS**：脚本不管证书，用 Nginx 或 Caddy 反代到 `127.0.0.1:3000`，然后设 `SESSION_COOKIE_SECURE=true`、`SESSION_COOKIE_TRUSTED_URL=https://你的域名`，再 `docker compose up -d`。反代要放行流式响应和 WebSocket。

**Redis 重启后缓存空了**：正常，Redis 只做缓存，不落盘，重启后限流计数和缓存会重置。

**脚本化的静默安装**：加 `--yes`，并用 `NEW_API_NO_PROMPT=1` 跳过端口和地址的询问：

```bash
NEW_API_NO_PROMPT=1 ./install.sh install --port 3000 --bind 0.0.0.0 --yes
```

**日志在哪**：应用日志在 `data/logs/`，容器标准输出用 `docker compose logs -f new-api` 看。

**不想用脚本了**：这个目录就是一份标准 Compose 项目，`docker compose --env-file .env -f docker-compose.yml up -d` 照样能起。脚本只是把常见操作串起来，没有额外魔法。
