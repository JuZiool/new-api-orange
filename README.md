# New API Orange

`new-api-orange` 是基于 [QuantumNous/new-api](https://github.com/QuantumNous/new-api) 的二次开发项目，用于统一接入模型服务，管理渠道、API Key、用户权限、用量与费用。

本仓库的生产部署采用 **New API + PostgreSQL + Redis**。应用、数据库和 Redis 的持久化文件通过宿主机目录挂载保存，便于备份、迁移和重建容器。根目录以本中文版 README 为准。

## 主要能力

| 功能 | 说明 |
| --- | --- |
| 模型接入 | 支持 OpenAI Chat Completions、Responses、Anthropic Messages、Gemini 等协议 |
| 渠道管理 | 模型映射、优先级与权重、多密钥、失败重试和渠道测试 |
| 用户与权限 | 用户分组、API Key 限制、权限管理及多种登录方式 |
| 用量与计费 | 额度、订阅、模型定价、使用日志与审计日志 |
| 异步任务 | 通过 JavaScript 插件扩展图片、视频等任务接口 |
| 管理控制台 | 配置渠道和模型、查看统计数据、使用 Playground 调试 |

接口和模型能否使用，取决于实际接入的上游服务、账号权限和渠道配置。上游 API Key 填在渠道中；调用本网关时使用 New API 签发的 API Key。

## 生产部署目录

部署入口为 [new-api-deploy/docker-compose.yml](./new-api-deploy/docker-compose.yml)。根目录的 [docker-compose.dev.yml](./docker-compose.dev.yml) 仅供开发使用。

```text
new-api-deploy/
├── data/
│   ├── app_data/        # New API 容器的 /data
│   ├── postgres_data/   # PostgreSQL 数据目录
│   └── redis_data/      # Redis 持久化文件
├── logs/                # New API 程序日志
├── to-install.sh        # 安装、更新、迁移和备份菜单
├── .env.example         # 可提交的配置模板
├── .env                 # 实际密码和固定密钥，不提交 Git
└── docker-compose.yml
```

| 宿主机目录 | 容器内路径 | 保存内容 |
| --- | --- | --- |
| `./data/app_data` | New API 的 `/data` | 应用运行数据；账户、渠道、余额及控制台设置主要保存在 PostgreSQL |
| `./data/postgres_data` | PostgreSQL 的 `/var/lib/postgresql/data` | 主数据库，默认也包含用量和审计日志 |
| `./data/redis_data` | Redis 的 `/data` | Redis 持久化文件，启用 AOF 并每秒同步 |
| `./logs` | New API 的 `/app/logs` | 程序日志文件 |

以上相对路径均以 `new-api-deploy/` 为基准。容器重建不会主动删除这些宿主机目录，删除目录则会丢失相应数据。`.env`、`data/` 和 `logs/` 均排除在 Git 和镜像构建上下文之外。

这里的“数据本地保存”指平台自身的持久化数据。当前代码没有完整的任务产物本地文件存储后端，图片、视频等上游生成内容可能仍依赖上游 URL 或代理访问，不能将本方案视为生成媒体的永久本地归档。

## 准备环境与配置

正式部署使用 Linux 服务器和 Docker Compose。Windows 本机测试也可借助 WSL；`wslc` 没有 Compose 子命令，不能直接执行本节的 `docker compose` 命令。

本配置不包含反向代理或证书。应用默认绑定宿主机 `0.0.0.0:3000`，监听全部 IPv4 接口；正式使用时通过 HTTPS 反向代理提供入口。PostgreSQL 和 Redis 仅通过容器网络访问，不发布宿主机端口。

以下为手动配置方式。使用下文的部署脚本全新安装时，不要提前创建 `.env` 或运行数据；脚本会准备文件并生成密码、密钥。

从本仓库准备部署文件：

```bash
git clone https://github.com/JuZiool/new-api-orange.git
cd new-api-orange/new-api-deploy

# 已有 .env 时保留原文件，避免覆盖正在使用的固定密钥。
if [ ! -f .env ]; then cp .env.example .env; fi
chmod 600 .env
mkdir -p data/app_data data/postgres_data data/redis_data logs
```

编辑 `.env`，填写以下必需配置；空值会阻止 Compose 启动：

| 配置项 | 填写要求 |
| --- | --- |
| `NEW_API_IMAGE` | 实际发布的本仓库镜像，使用明确版本或 digest |
| `POSTGRES_PASSWORD` | PostgreSQL 密码，建议使用随机十六进制字符串 |
| `REDIS_PASSWORD` | Redis 密码，与数据库密码分别生成 |
| `SESSION_SECRET` | 固定会话密钥，重建容器时保持不变 |
| `CRYPTO_SECRET` | 固定加密密钥，保存并随备份迁移 |
| `SESSION_COOKIE_TRUSTED_URL` | 控制台真实 HTTPS Origin，多项用英文逗号分隔，例如 `https://api.example.com` |
| `TRUSTED_PROXIES` | 应用实际看到的可信反向代理 IP 或 CIDR；没有代理时为 `none` |

可多次执行以下命令，分别生成四项密码和密钥，再写入 `.env`：

```bash
openssl rand -hex 32
```

数据库和 Redis 密码会拼入连接 URI。使用十六进制字符串可避免 `@`、`:`、`/`、`?` 等保留字符的 URL 编码问题。不要使用示例密码，也不要在每次启动时重新生成固定密钥。

`NEW_API_IMAGE` 不提供默认值，避免误部署其他版本。上游 `calciumion/new-api` 镜像可以体验上游版本，但不包含本仓库的二次开发改动；部署本仓库时应填写由本仓库源码发布的镜像。本次目录调整不自动构建或发布镜像。

其他常用配置已有默认值：

| 配置项 | 默认值 | 用途 |
| --- | --- | --- |
| `BIND_HOST` | `0.0.0.0` | 应用宿主机监听地址，默认全部 IPv4 接口 |
| `SERVER_PORT` | `3000` | 应用宿主机端口 |
| `POSTGRES_USER` | `newapi` | 数据库用户 |
| `POSTGRES_DB` | `new-api` | 数据库名称 |
| `POSTGRES_IMAGE` | `postgres:15` | 数据库镜像，迁移包有镜像摘要时固定到原镜像 |
| `REDIS_IMAGE` | `redis:7-alpine` | Redis 镜像，迁移包有镜像摘要时固定到原镜像 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `NODE_NAME` | `new-api-node-1` | 日志中的节点标识 |
| `DEFAULT_LANGUAGE` | `zh-CN` | 服务端日志及默认消息语言 |

生产配置启用 Secure 刷新 Cookie，因此控制台应通过配置的 HTTPS 地址访问。`SESSION_COOKIE_TRUSTED_URL` 填写精确 Origin，不带业务路径；`TRUSTED_PROXIES` 填写代理连接到应用时的实际来源地址，不能直接照抄示例网段。

`.env` 由 Compose 用于变量替换，只有 Compose `environment` 中声明的项目会注入容器。完整的应用环境变量说明仍可参考根目录 [.env.example](./.env.example)；增加其他变量时也要在部署 Compose 中显式传入。

## 部署管理脚本

[to-install.sh](./new-api-deploy/to-install.sh) 是单文件 Bash 部署入口，提供中文菜单和四项操作。需要 Linux、Bash 4+、Docker Engine、Compose 插件、OpenSSL、GNU tar 和 coreutils（包含 `sha256sum`、`realpath`）。使用 root 权限读写 PostgreSQL 物理文件并保留属主；不需要 Python，不从源码构建镜像。

在 `new-api-deploy/` 中运行中文菜单：

```bash
sudo bash to-install.sh
```

也可直接执行指定操作：

```bash
sudo bash to-install.sh --mode 1
sudo bash to-install.sh --mode 2 --image 你的镜像仓库/new-api:明确版本
sudo bash to-install.sh --mode 3
sudo bash to-install.sh --mode 4
```

| 操作 | 行为 |
| --- | --- |
| 1 全新安装 | 拒绝覆盖已有 `.env` 或运行数据；准备配置文件，生成四项独立密码和密钥，询问镜像、HTTPS Origin 和可信代理，校验后启动三个服务 |
| 2 更新镜像 | 先拉取目标 New API 镜像，拉取失败时不停止现有服务；成功后创建迁移备份，再仅重建 New API 容器，不升级 PostgreSQL 和 Redis |
| 3 迁移安装 | 使用已有 `.env` 和完整 `data/`，保留原密码、固定密钥和数据；拒绝不完整的 PostgreSQL 15 数据，不创建空库冒充迁移 |
| 4 创建迁移包 | 短暂停止服务，打包数据、日志、`.env`、Compose、脚本和 `migration.manifest`，生成 SHA256 校验文件，再恢复原先运行的容器；打包失败也会尝试恢复 |

备份默认位于部署目录旁的 `new-api-backups/`，也可用 `--backup-dir /你的备份目录` 指定部署目录之外的位置。压缩包含实际密码和密钥，文件权限限制为 `600`；默认备份目录已加入 Git 和镜像构建排除规则。更新过程也会有一次备份停机；健康检查失败时保留更新前备份，不自动回滚可能已迁移的数据库。

默认部署目录是运行脚本时的当前目录，`--dir /opt/new-api-deploy` 可以指定其他位置。缺少的 Compose、`.env.example` 和脚本会优先从本地复制，否则从本仓库下载。还支持 `--origin`、`--trusted-proxies`、`--port`、`--backup-dir`、`--health-timeout`、`--yes` 和 `--no-pull`；`--no-pull` 只使用已存在的本地镜像。更新不传 `--image` 时会提示选择目标镜像，留空重新拉取当前引用。

脚本推送到远程仓库后，可在空部署目录下载并运行；管道运行仍从终端读取菜单和安装配置：

```bash
mkdir -p new-api-deploy && cd new-api-deploy
curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/new-api-deploy/to-install.sh | sudo bash
```

自动化运行时明确传入 `--mode`，全新安装还可用 `--image`、`--origin` 和 `--trusted-proxies` 填写镜像、实际 HTTPS 地址和代理来源。无交互终端且未指定模式时，脚本会退出并提示填写参数。

迁移前将备份包和同名 `.sha256` 文件传到目标机器，校验后解压到一个空目录。例如以下命令中的文件名需替换为实际备份名：

```bash
sha256sum -c new-api-migration-时间戳.tar.gz.sha256
sudo mkdir -p /srv/new-api-deploy
sudo tar --numeric-owner -xzpf new-api-migration-时间戳.tar.gz -C /srv/new-api-deploy
cd /srv/new-api-deploy
sudo bash to-install.sh --mode 3
```

解压结果须包含原 `.env` 和 `data/app_data`、`data/postgres_data`、`data/redis_data`。不要覆盖正在运行的部署。脚本记录并在可用时使用原有三个服务的镜像摘要，物理迁移要求相同 CPU 架构和 PostgreSQL 15；跨架构或数据库大版本请使用逻辑备份与专门的迁移流程。域名或代理地址变化时，先核对 `.env` 中对应配置，保留原密码和固定密钥。

## 启动与首次使用

在填写镜像、密码、密钥和域名后，从 `new-api-deploy/` 执行：

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail 100 new-api
```

`config --quiet` 只验证配置；生产可用性仍需在目标服务器验证。应用会等待 PostgreSQL 和 Redis 健康检查通过后启动。

为反向代理配置 HTTPS 证书，将请求转发到 `127.0.0.1:3000`。需要支持流式响应和 WebSocket 升级，避免代理缓冲流式输出，并根据模型响应时间设置超时。公网入口开放 `80/443`，数据库和 Redis 端口保持内部访问。

完成代理后，通过 `.env` 配置的 HTTPS 控制台地址打开初始化向导，创建管理员账号。然后：

1. 新建渠道，填写已授权的上游 API Key、模型与分组，执行渠道测试。
2. 配置模型价格、额度或订阅，确认用户具备调用权限。
3. 创建 New API 的 API Key。
4. 将客户端 Base URL 设置为 `https://你的域名/v1`。

常用接口包括 `POST /v1/chat/completions`、`POST /v1/responses`、`POST /v1/messages` 和 `POST /v1/embeddings`。Gemini、图片、音频与任务插件接口按各自协议使用。

## 日常维护与升级

以下命令均在 `new-api-deploy/` 内执行：

```bash
docker compose ps
docker compose logs --tail 100 -f new-api
docker compose restart new-api
docker compose down
```

`down` 停止并移除容器及 Compose 网络，目录挂载的数据仍在宿主机。镜像更新不会自动应用到已运行的容器；先备份，再修改 `.env` 中的 `NEW_API_IMAGE`，执行 `docker compose pull new-api` 和 `docker compose up -d new-api`。

数据库迁移可能随应用升级发生。回退应用镜像前检查版本兼容性；必要时从对应的数据库备份恢复。不要仅修改 PostgreSQL 镜像的大版本来升级数据库，现有物理数据目录不能直接作为跨大版本迁移方案。

若原来使用根目录 Compose 的 `pg_data` 命名卷，改为目录挂载不会自动转移旧数据，应先备份并恢复到新数据库。管理脚本的迁移操作针对本 README 约定的完整本地目录，不能直接转换旧命名卷或 SQLite 数据库。

## 备份与迁移

在线数据库备份可以使用 `pg_dump`，在 `new-api-deploy/` 内执行：

```bash
umask 077
mkdir -p ../new-api-backups
docker compose exec -T postgres sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "../new-api-backups/new-api-$(date +%Y%m%d-%H%M%S).dump"
```

备份写到部署目录旁的 `new-api-backups/`，该目录已排除在 Git 和镜像构建上下文之外。同时保存 `.env`、Compose 文件和必要的应用数据。备份含有数据库内容和密钥，应限制读取权限，并另存到其他机器或存储位置。

完整的迁移压缩包使用部署管理脚本生成，它会停止服务、打包并恢复原运行状态：

```bash
sudo bash to-install.sh backup
```

不要在 PostgreSQL 持续写入时直接打包其数据目录并当作一致备份。迁移时保留 `.env` 中的固定密钥、目录属主与权限；物理目录恢复应使用兼容的 PostgreSQL 版本，跨大版本优先使用经过验证的逻辑备份恢复或官方升级流程。备份需要实际演练恢复后才能确认可用。

## 开发

后端使用 Go、Gin 与 GORM，前端使用 React、TypeScript、Rsbuild 和 Tailwind CSS。Go 版本要求以 [go.mod](./go.mod) 为准，前端使用 Bun。

后端嵌入 `web/dist`，本地开发前先准备前端文件：

```bash
cd web
bun install --frozen-lockfile
bun run build
cd ..
go run .
```

另开终端运行 `cd web && bun run dev -- --port 5173`，访问 `http://localhost:5173`。开发服务器默认将 API 请求代理到 `http://localhost:3000`。本地直接运行且未配置 `SQL_DSN` 时使用 SQLite，此路径与上述 PostgreSQL 生产部署分开。

| 目录 | 作用 |
| --- | --- |
| `router/`、`middleware/`、`controller/` | 路由、中间件与管理接口 |
| `relay/` | 模型协议接入和上游转发 |
| `service/`、`model/`、`setting/` | 业务服务、持久化和配置 |
| [relaykit/](./relaykit/README.md) | 独立的协议 DTO 与转换模块 |
| [tokenkit/](./tokenkit/README.md) | 独立的 Token 估算模块 |
| `plugins/tasks/` | JavaScript 任务插件，接口见 [Task Plugin API v1](./docs/plugin-api/v1.md) |
| `web/` | 管理控制台 |
| [electron/](./electron/README.md) | 桌面封装 |

修改前阅读 [AGENTS.md](./AGENTS.md) 与相关模块说明。根据实际改动运行 `make test`、前端类型检查及相应测试；独立 Go 模块还需在各自目录验证。模块内 README 保留各自用途，根目录不再维护多份语言版本。

## 项目来源与许可证

上游项目：[QuantumNous/new-api](https://github.com/QuantumNous/new-api)。New API 在 [One API](https://github.com/songquanpeng/one-api) 的基础上发展而来，本仓库保留原项目及贡献者署名。上游使用说明可参考 [New API 官方文档](https://docs.newapi.ai/zh/docs)。

Copyright (c) QuantumNous and contributors.

Frontend design and development by New API contributors.

项目使用 [GNU Affero 通用公共许可证 v3.0](./LICENSE)，附加条款和署名要求见 [NOTICE](./NOTICE)，依赖许可证见 [THIRD-PARTY-LICENSES.md](./THIRD-PARTY-LICENSES.md)。对外服务应使用合法授权的上游资源，并按项目许可证及所用上游服务条款运营。
