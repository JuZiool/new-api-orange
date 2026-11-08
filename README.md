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

本配置不包含反向代理或证书。应用默认仅绑定宿主机 `127.0.0.1:3000`，由同机 HTTPS 反向代理提供公网入口；PostgreSQL 和 Redis 仅通过容器网络访问，不发布宿主机端口。

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
| `BIND_HOST` | `127.0.0.1` | 应用宿主机监听地址 |
| `SERVER_PORT` | `3000` | 应用宿主机端口 |
| `POSTGRES_USER` | `newapi` | 数据库用户 |
| `POSTGRES_DB` | `new-api` | 数据库名称 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `NODE_NAME` | `new-api-node-1` | 日志中的节点标识 |
| `DEFAULT_LANGUAGE` | `zh-CN` | 服务端日志及默认消息语言 |

生产配置启用 Secure 刷新 Cookie，因此控制台应通过配置的 HTTPS 地址访问。`SESSION_COOKIE_TRUSTED_URL` 填写精确 Origin，不带业务路径；`TRUSTED_PROXIES` 填写代理连接到应用时的实际来源地址，不能直接照抄示例网段。

`.env` 由 Compose 用于变量替换，只有 Compose `environment` 中声明的项目会注入容器。完整的应用环境变量说明仍可参考根目录 [.env.example](./.env.example)；增加其他变量时也要在部署 Compose 中显式传入。

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

若原来使用根目录 Compose 的 `pg_data` 命名卷，改为目录挂载不会自动转移旧数据，应先备份并恢复到新数据库。此处提供的是新部署布局，未包含自动数据迁移脚本。

## 备份与迁移

在线数据库备份可以使用 `pg_dump`，在 `new-api-deploy/` 内执行：

```bash
umask 077
mkdir -p ../../new-api-backups
docker compose exec -T postgres sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "../../new-api-backups/new-api-$(date +%Y%m%d-%H%M%S).dump"
```

备份默认写到仓库外的 `new-api-backups/`，避免混入源码提交和镜像构建。同时保存 `.env`、Compose 文件和必要的应用数据。备份含有数据库内容和密钥，应限制读取权限，并另存到其他机器或存储位置。

如果要打包整个部署目录，先停止整个服务栈，再从仓库根目录归档：

```bash
cd new-api-deploy
docker compose down
cd ..
umask 077
mkdir -p ../new-api-backups
sudo tar --numeric-owner -czf "../new-api-backups/new-api-deploy-$(date +%Y%m%d-%H%M%S).tar.gz" new-api-deploy/
cd new-api-deploy
docker compose up -d
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
