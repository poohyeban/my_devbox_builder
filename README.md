# DevBox 通用开发环境构建工具

DevBox 旨在帮助团队快速、稳定地构建可复用的容器化开发环境。本项目提供两个核心脚本：

- `install_devbox.sh`：安装与初始化工具，负责准备工作目录、模板仓库以及管理脚本。
- `devbox.sh`：安装完成后生成的管理脚本，可用于交互式或命令行模式管理开发容器。

通过模板机制，DevBox 能够为不同技术栈提供标准化的环境定义；结合安全脚本与初始化钩子，可在创建实例时自动完成加固与个性化配置。

## 快速开始

1. **执行安装脚本**：
   ```bash
   ./install_devbox.sh
   ```
   默认会引导配置工作目录、镜像命名前缀、模板等。若希望完全自动化，可使用 `DEVBOX_AUTO=1` 并通过环境变量或 `devbox.conf` 预设参数。

2. **进入工作目录**：
   ```bash
   cd <工作目录>
   ./devbox.sh
   ```
   交互式菜单会引导创建或管理实例。也可使用命令行子命令完成自动化操作（见后文）。

## 模板目录结构

安装脚本会在工作目录下创建 `templates/`，并至少包含一个默认模板（默认名称为 `debian-bookworm`）。每个模板都是一个完整的环境定义，目录结构示例如下：

```
templates/
  └── debian-bookworm/
      ├── Dockerfile
      ├── security_setup.sh   # 可选：执行安全加固（如 Fail2ban）
      └── post_create.sh      # 可选：实例首次启动后的个性化初始化脚本
```

### Dockerfile

- 负责编译最终的开发镜像。
- 安装脚本提供的默认 Dockerfile 采用最小化 Debian 环境，预装 `openssh-server`、`zsh`、`sudo` 等基础工具。
- 可根据团队需求自由修改或新增模板目录。

### security_setup.sh

- 约定参数：`$1`，可取 `enable`、`disable` 或 `status`。
- 安装脚本提供的默认脚本会安装并配置 Fail2ban，支持多发行版扩展。
- 在 `devbox.sh` 中执行 `cli fail2ban enable <实例>` 时，该脚本会被复制进容器并以 `root` 权限执行。

### post_create.sh

- 在新实例首次启动并完成 SSH 服务准备后自动执行。
- 可安装常用工具、拉取 dotfiles 或进行其他个性化操作。
- 默认脚本演示了为 `dev` 用户准备 `.ssh` 目录的流程。

## 全局配置文件 `devbox.conf`

- 放置于工作目录根目录，采用 `key=value` 格式。
- 优先级：**配置文件 < 环境变量 < 命令行参数**。
- 常用键：
  - `WORKDIR`（仅用于文档记录，安装时仍需先确认工作目录）
  - `IMAGE_NAME`、`IMAGE_TAG`
  - `DEFAULT_TEMPLATE`
  - `NET_NAME`、`PORT_BASE`
  - `CNAME_PREFIX`
  - `MEM`、`CPUS`、`PIDS`
  - `SOCAT_IMAGE`（如需覆盖默认转发镜像版本）

示例：
```ini
IMAGE_NAME=team-dev
IMAGE_TAG=2024.06
DEFAULT_TEMPLATE=python-dev
NET_NAME=team-dev-net
PORT_BASE=36022
MEM=2g
CPUS=2.0
```

## 安装脚本 `install_devbox.sh`

- **自动模式**：`DEVBOX_AUTO=1 ./install_devbox.sh --auto`。
- **自检**：`./install_devbox.sh --self-test`。
- 安装流程会：
  1. 检查 Docker 环境并提示修复建议。
  2. 创建/更新模板目录与示例文件。
  3. 构建默认模板对应的镜像（输出实时构建日志）。
  4. 生成新版 `devbox.sh` 管理脚本（写入 `.devbox` 调试日志时遵循 `DEVBOX_DEBUG=1`）。
  5. 在选择自动启动示例实例时，会使用默认模板启动一个容器并运行 `post_create.sh`。

## 管理脚本 `devbox.sh`

运行方式：

- **交互式菜单**：直接执行 `./devbox.sh`，提供模板选择、资源限制、端口映射、Fail2ban 管理、SSH 公钥注入等操作，所有提示均给出推荐值与说明。
- **命令行子命令**：
  ```bash
  ./devbox.sh cli image build --template debian-bookworm
  ./devbox.sh cli instance start demo \
      --template debian-bookworm \
      --port-base 36022 \
      --memory 2g --cpus 2 --pids 512 \
      --enable-fail2ban
  ./devbox.sh cli instance ssh-key add demo ~/.ssh/id_ed25519.pub --disable-password
  ./devbox.sh cli forward add demo 36080 8080
  ./devbox.sh cli fail2ban status demo
  ./devbox.sh cli status
  ```

### 关键特性

1. **多模板支持**：在创建实例时可指定模板，镜像名称自动生成为 `<前缀>-<模板>:<tag>`；CLI 提供 `cli image build --template`、`cli instance start --template` 等参数。
2. **安全脚本解耦**：Fail2ban 等安全加固逻辑通过模板目录的 `security_setup.sh` 执行，实现跨发行版兼容；CLI 同步提供 `fail2ban enable/disable/status` 命令。
3. **初始化钩子**：`post_create.sh` 会在容器首次成功启动后自动运行，可用于安装工具、配置环境变量等个性化需求。
4. **实时构建输出**：镜像构建默认直接输出 Docker 日志，便于观察进度与快速定位错误；仅在自动模式下会写入调试日志文件。
5. **资源限制交互配置**：交互式创建实例时会提示输入内存、CPU、PIDs 限制，并在元数据文件中持久化，后续重启自动沿用。
6. **SSH 公钥管理**：`cli instance ssh-key add <实例> [公钥路径] [--disable-password]` 可直接向容器追加 `authorized_keys` 并可选禁用密码登录，提升安全性。
7. **端口转发代理**：基于固定版本的 `alpine/socat:1.7.4.4-r0` 创建轻量代理容器，支持添加、查看、删除端口映射。
8. **元数据管理**：`.devbox/instances/<name>.env` 存储模板、镜像、资源限制、端口与安全状态；`.devbox/<name>.pass` 记录当前密码；端口映射与安全状态也有独立记录文件，便于自动化脚本消费。

## 模板扩展建议

- 新建模板目录，例如 `templates/python-dev/`，复制默认 Dockerfile 并根据需求安装依赖。
- 若需定制安全策略，在模板目录提供自定义的 `security_setup.sh`。同一套 DevBox 工具可同时管理多种基础镜像（Debian、Alpine、CentOS 等）。
- 在 `post_create.sh` 中添加 Idempotent 脚本以确保重复执行不会产生副作用，例如检测命令是否存在、使用 `install -d` 创建目录等。

## 常见问题

- **构建失败**：终端会直接输出 Docker 构建日志，请检查网络连接或 Dockerfile 语法，并确认磁盘空间充足。
- **模板未被识别**：确保模板目录名称合法（字母、数字、`.`、`_`、`-`），且包含有效的 `Dockerfile`。
- **端口冲突**：默认每次递增 100 进行尝试，可通过 `--port-base` 或 `PORT_BASE` 配置避免与现有服务冲突。
- **SSH 公钥未追加**：确认公钥文件路径正确且非空；脚本会在容器内自动创建 `.ssh/authorized_keys` 并设置权限。

## 测试

项目提供 `tests/run_tests.sh`，会执行安装脚本自检并在具备 Docker 权限的环境中完成端到端集成测试：

- 自动化安装至临时目录。
- 构建默认模板镜像并创建实例。
- 验证密码生成、Fail2ban 启用与关闭、端口映射、SSH 公钥追加、资源限制持久化等功能。

执行测试：
```bash
bash tests/run_tests.sh
```

## 许可证

本项目按照仓库声明的许可证分发。如需在商业环境中使用，请确保遵循相关条款，并在模板中妥善处理第三方软件的许可要求。
