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

## 部署

在服务器上执行以下命令，按中文菜单选择全新安装、更新、迁移或备份：

```bash
mkdir -p new-api-deploy && cd new-api-deploy && curl -fsSL https://raw.githubusercontent.com/JuZiool/new-api-orange/main/new-api-deploy/to-install.sh | sudo bash
```

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
