# New API Orange

`new-api-orange` 是基于 [QuantumNous/new-api](https://github.com/QuantumNous/new-api) 的二次开发项目，用于统一接入模型服务，管理渠道、API Key、用户权限、用量与费用。

本仓库的生产部署采用 **New API + PostgreSQL + Redis**。应用、数据库和 Redis 的持久化文件通过宿主机目录挂载保存，便于备份、迁移和重建容器。根目录以本中文版 README 为准。

## 部署

在服务器上执行以下命令，按中文菜单选择全新安装、更新、迁移或备份：

```bash
mkdir -p new-api-deploy && cd new-api-deploy && curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/new-api-deploy/to-install.sh | sudo bash
```

安装和更新时输入已发布的版本号（如 `v1.0.0-rc.48-orange`，仅为格式示例），脚本会补全为 `ghcr.io/juziool/new-api-orange:<版本号>`，也支持固定镜像摘要。命令行可使用 `--version <版本号>`，或用 `--image <完整 GHCR 镜像地址>` 指定目标。脚本仅支持 Linux `amd64`（x86_64）和 `arm64`，并在启动前核对镜像架构。

## 发布

本 fork 使用 GitHub Release 分发程序，使用 GHCR 分发镜像，镜像地址为 `ghcr.io/juziool/new-api-orange:<版本号>`。推送代码或 Git 标签均不会触发发布；只有项目维护者明确要求发布时，才手动运行 [release.yml](./.github/workflows/release.yml)，填写仓库中已存在的版本标签。

版本标签采用 `<上游版本号>-orange`，例如上游 `v1.0.0-rc.48` 对应 `v1.0.0-rc.48-orange`，上游 `v1.0.0` 对应 `v1.0.0-orange`。应选用当前源码已完整包含的上游版本；发布流程会校验上游标签对应的提交已经合入。`-orange` 是本 fork 的标记，预发布状态根据上游版本中的 `rc` 等后缀判断。

手动发布仅构建该标签对应的 Linux `amd64`（x86_64）和 `arm64` 程序及校验文件，并发布支持这两种架构的 GHCR 镜像。默认不更新 `latest`，部署时使用已发布的固定版本标签或镜像摘要。

首次发布后，需在 GitHub 的 Package settings 中将镜像包设为 Public，服务器才能直接匿名拉取。

服务器升级时重新运行部署脚本，选择“更新”并填写目标 GHCR 镜像。发布新版本不会自动升级已部署的服务器。

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
