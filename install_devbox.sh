#!/usr/bin/env bash
set -Eeuo pipefail

# ========== 全局配置 ==========
SCRIPT_VERSION="2.0.0"
DEBUG="${DEVBOX_DEBUG:-0}"
DEBUG_LOG=""
AUTO_MODE="${DEVBOX_AUTO:-0}"
case "${AUTO_MODE,,}" in
  1|y|yes|true|on)
    AUTO_MODE=1
    ;;
  *)
    AUTO_MODE=0
    ;;
esac
RUN_SELF_TEST=0

# ========== 调试与日志 ==========
setup_debug() {
  if [[ "$DEBUG" == "1" ]]; then
    DEBUG_LOG="${WORKDIR:-.}/.devbox/debug.log"
    mkdir -p "$(dirname "$DEBUG_LOG")"
    exec 3>>"$DEBUG_LOG"
    log_debug "=== Debug session started at $(date) ==="
    log_debug "Installer version: $SCRIPT_VERSION"
  fi
}

log_debug() {
  if [[ "$DEBUG" == "1" && -n "${DEBUG_LOG:-}" ]]; then
    echo "[DEBUG $(date +%T)] $*" >&3
  fi
}

# ========== 信号处理 ==========
cleanup_on_interrupt() {
  echo
  err "用户中断操作 (Ctrl+C)"
  # 清理临时文件
  if [[ -n "${TMP_FILES:-}" ]]; then
    rm -f -- "$TMP_FILES" 2>/dev/null || true
  fi
  exit 130
}
trap cleanup_on_interrupt INT
trap 'code=$?; echo; err "安装助手在第 $LINENO 行遇到问题 (退出码 $code)"; echo; exit $code' ERR

# ========== UI 工具 ==========
color() { local code="${1:-}"; shift || true; printf "\e[%sm%s\e[0m" "$code" "${*:-}"; }
log()  { printf "%b  %s\n" "$(color '1;32' 'OK')" "$*"; }
info() { printf "%b  %s\n" "$(color '1;36' 'INFO')" "$*"; }
warn() { printf "%b  %s\n" "$(color '1;33' 'WARN')" "$*"; }
err()  { printf "%b  %s\n" "$(color '1;31' 'ERROR')" "$*"; }
ui_rule() { printf '%s\n' "$(color '0;37' '────────────────────────────────────────')"; }
ui_title() {
  echo
  ui_rule
  printf '%s\n' "$(color '1;37' "${1:-}")"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$(color '0;37' "${2}")"
  fi
  ui_rule
}
ui_caption() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$(color '0;90' "${1}")"
  fi
}
progress() { local msg="$1"; printf '%b  %s' "$(color '1;36' '⏳')" "$msg"; }
progress_done() { printf '\r%b  %s\n' "$(color '1;32' '✓')" "$1"; }

print_usage() {
  cat <<'USAGE'
DevBox 安装助手 v2.0.0

用法:
  ./install_devbox.sh [选项]

常用选项:
  -h, --help        显示本帮助
  --version         显示脚本版本
  --auto, --defaults
                    直接采用推荐配置（可通过环境变量 DEVBOX_* 覆盖），无需交互
  --self-test       运行内建自检并退出

主要环境变量:
  DEVBOX_WORKDIR          工作目录（默认 /opt/my_dev_box）
  DEVBOX_IMAGE_NAME       镜像名称（默认 acm-lite）
  DEVBOX_IMAGE_TAG        镜像标签（默认 latest）
  DEVBOX_NET_NAME         Docker 网络名称（默认 devbox-net）
  DEVBOX_PORT_BASE        SSH 起始端口（默认 30022）
  DEVBOX_CNAME_PREFIX     实例名前缀（默认镜像名）
  DEVBOX_AUTO_START       y 或 n，决定是否自动创建首个实例（默认 n）
  DEVBOX_MEM/CPUS/PIDS    资源限制（默认 1g / 1.0 / 256）
  DEVBOX_AUTO             设为 1 等同于 --auto
  DEVBOX_ASSUME_YES       自动对确认问题回答 "是"，适合 CI / 自动化环境

示例:
  ./install_devbox.sh
  DEVBOX_AUTO=1 DEVBOX_WORKDIR=$HOME/devbox ./install_devbox.sh --auto
  DEVBOX_DEBUG=1 ./install_devbox.sh --self-test
USAGE
}

parse_args() {
  local positional=()
  while (($#)); do
    case "$1" in
      -h|--help)
        print_usage
        exit 0
        ;;
      --version)
        echo "$SCRIPT_VERSION"
        exit 0
        ;;
      --self-test)
        RUN_SELF_TEST=1
        ;;
      --auto|--defaults)
        AUTO_MODE=1
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        printf '未知选项: %s\n' "$1" >&2
        print_usage >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift || true
  done

  if ((${#positional[@]} > 0)); then
    printf '不支持的位置参数: %s\n' "${positional[*]}" >&2
    print_usage >&2
    exit 1
  fi
}

# ========== 基础工具 ==========
has() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$UID}" -eq 0 ]]; }
strip_control_chars() {
  local input="${1-}"
  printf '%s' "$input" | LC_ALL=C tr -d '[:cntrl:]'
}

# ========== 输入验证 ==========
validate_port() { local port="$1"; [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )); }
validate_container_name() { local name="$1"; [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; }
validate_yes_no() { local input="$1"; [[ "$input" =~ ^[YyNn]$ ]]; }

# ========== 交互函数 ==========
ask() {
  local prompt="$1" def="${2:-}" note="${3:-}" ans cleaned def_clean
  echo >&2
  printf '%s %s\n' "$(color '1;36' '提示')" "$(color '1;37' "$prompt")" >&2
  if [[ -n "$note" ]]; then
    printf '   %s\n' "$(color '0;37' "$note")" >&2
  fi
  if [[ -n "$def" ]]; then
    printf '   %s %s\n' "$(color '0;37' '默认值')" "$(color '1;37' "$def")" >&2
    printf '   %s → ' "$(color '0;37' '输入值 (回车采用默认)')" >&2
    IFS= read -r ans
    cleaned="$(strip_control_chars "$ans")"
    def_clean="$(strip_control_chars "$def")"
    printf '%s\n' "${cleaned:-$def_clean}"
  else
    printf '   %s → ' "$(color '0;37' '输入值')" >&2
    IFS= read -r ans
    cleaned="$(strip_control_chars "$ans")"
    printf '%s\n' "$cleaned"
  fi
}
confirm() {
  local prompt="$1" def="${2:-N}" ans
  if [[ "${DEVBOX_ASSUME_YES:-0}" == "1" ]]; then
    printf '%s [auto-yes]\n' "$(color '1;33' "$prompt")" >&2
    return 0
  fi
  printf '%s [%s/%s] → ' "$(color '1;33' "$prompt")" "$([[ "$def" =~ [Yy] ]] && echo 'Y' || echo 'y')" "$([[ "$def" =~ [Nn] ]] && echo 'N' || echo 'n')" >&2
  IFS= read -r ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ========== 预检查 ==========
diagnose_docker_runtime() {
  local hints=()

  if ! is_root && [[ ! -S /var/run/docker.sock ]]; then
    hints+=("当前用户非 root，且未检测到可写的 /var/run/docker.sock。请考虑使用 sudo 运行，或将当前用户加入 docker 组。")
  fi

  if [[ -S /var/run/docker.sock && ! -w /var/run/docker.sock ]]; then
    hints+=("/var/run/docker.sock 存在但不可写，确认运行用户是否具备访问该套接字的权限。")
  fi

  if [[ -e /proc/sys/net/ipv4/ip_forward ]]; then
    if [[ ! -w /proc/sys/net/ipv4/ip_forward ]]; then
      hints+=("宿主机禁止修改 /proc/sys/net/ipv4/ip_forward（只读）。Docker 需要启用 IP 转发，若运行在受限容器中，请在宿主机上执行安装。")
    fi
  else
    hints+=("未检测到 /proc/sys/net/ipv4/ip_forward，宿主机内核可能缺失必要的网络功能。")
  fi

  if has iptables; then
    local iptables_err
    if ! iptables -L >/dev/null 2>&1; then
      iptables_err="$(iptables -L 2>&1 || true)"
      iptables_err="${iptables_err%%$'\n'*}"
      iptables_err="$(strip_control_chars "$iptables_err")"
      hints+=("执行 iptables 失败：${iptables_err:-需要 CAP_NET_ADMIN 权限}。请在具备 NET_ADMIN 能力的环境运行。")
    fi
  else
    hints+=("未安装 iptables，Docker 默认网络功能无法使用。请先安装 iptables 包。")
  fi

  if ! pgrep -x dockerd >/dev/null 2>&1; then
    hints+=("未检测到 dockerd 进程，使用 systemctl start docker 或手动运行 dockerd 启动守护进程。")
  fi

  if (( ${#hints[@]} == 0 )); then
    warn "未发现明显的宿主机问题，请查看 dockerd 日志以进一步排查。"
    return
  fi

  local item
  for item in "${hints[@]}"; do
    warn "${item}"
  done
}

check_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    log_debug "Docker daemon check passed"
    return 0
  fi

  err "Docker 守护进程未运行或当前用户无权限访问"
  info "请检查以下可能原因："
  diagnose_docker_runtime
  exit 1
}
check_disk_space() {
  local min_mb=1024
  local avail
  avail=$(df -BM "${WORKDIR:-.}" | awk 'NR==2 {print $4}' | sed 's/M//')
  log_debug "Available disk space: ${avail}MB"
  if (( avail < min_mb )); then
    warn "磁盘空间不足 (可用: ${avail}MB，建议: >${min_mb}MB)"
    if ! confirm "是否继续？"; then exit 1; fi
  fi
}

# ========== 依赖安装 ==========
need_curl() {
  if has curl; then return 0; fi
  warn "未检测到 curl，尝试安装..."
  if has apt-get; then apt-get update && apt-get install -y curl
  elif has dnf; then dnf install -y curl
  elif has yum; then yum install -y curl
  elif has apk; then apk add --no-cache curl
  else err "无法自动安装 curl，请手动安装后重试"; exit 1; fi
}
install_docker() {
  if has docker; then
    info "已检测到 Docker: $(docker --version)"
    check_docker_daemon; return
  fi
  need_curl
  warn "未检测到 Docker，开始安装（官方安装脚本）..."
  if ! sh -c "$(curl -fsSL https://get.docker.com)"; then err "Docker 安装失败"; exit 1; fi
  if has systemctl; then systemctl enable --now docker || true; else service docker start || true; fi
  sleep 2
  check_docker_daemon
  log "Docker 安装完成: $(docker --version)"
}

# ========== 网络与端口 ==========
ensure_network() { local net="$1"; docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null; }
port_in_use_host() {
  local hp="$1" entry

  if [[ -n "${DEVBOX_RESERVED_HOST_PORTS:-}" ]]; then
    IFS=', ' read -r -a __devbox_reserved_ports <<<"${DEVBOX_RESERVED_HOST_PORTS//,/ }"
    for entry in "${__devbox_reserved_ports[@]}"; do
      [[ -z "$entry" ]] && continue
      if [[ "$entry" == "$hp" ]]; then
        log_debug "Host port ${hp} marked as reserved via DEVBOX_RESERVED_HOST_PORTS"
        return 0
      fi
    done
    unset __devbox_reserved_ports
  fi

  if timeout 0.2 bash -lc ":</dev/tcp/127.0.0.1/${hp}" 2>/dev/null; then return 0; fi
  if has ss && ss -ltn | grep -q ":${hp}\b"; then return 0; fi
  if docker ps --format '{{.Ports}}' | grep -qE "0\.0\.0\.0:${hp}->|:${hp}->"; then return 0; fi
  return 1
}
pick_port_strict() { local base="$1" tries="$2"; for ((i=0;i<tries;i++)); do local try=$((base+i*100)); if ! port_in_use_host "$try"; then log_debug "Found available port: $try"; echo "$try"; return 0; fi; done; log_debug "No available port found in range"; return 1; }

# ========== 交互式初始化 ==========
ask_init_adv_limits() {
  # 高级资源限制（默认安全值，可用环境变量覆盖）
  DEFAULT_MEM="${DEVBOX_MEM:-1g}"
  DEFAULT_CPUS="${DEVBOX_CPUS:-1.0}"
  DEFAULT_PIDS="${DEVBOX_PIDS:-256}"
}
init_prompt_auto() {
  ui_title "DevBox 安装偏好" "已启用自动模式，使用环境变量或默认值完成配置。"

  WORKDIR="${DEVBOX_WORKDIR:-/opt/my_dev_box}"
  IMAGE_NAME="${DEVBOX_IMAGE_NAME:-acm-lite}"
  if [[ ! "$IMAGE_NAME" =~ ^[a-z0-9-]+$ ]]; then
    err "环境变量 DEVBOX_IMAGE_NAME 无效（仅限小写字母、数字和短横线）"
    exit 1
  fi
  IMAGE_TAG="${DEVBOX_IMAGE_TAG:-latest}"
  IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
  NET_NAME="${DEVBOX_NET_NAME:-devbox-net}"
  PORT_BASE_DEFAULT="${DEVBOX_PORT_BASE:-30022}"
  if ! validate_port "$PORT_BASE_DEFAULT"; then
    err "环境变量 DEVBOX_PORT_BASE 必须是有效端口 (1-65535)"
    exit 1
  fi
  MAX_TRIES=80
  CNAME_PREFIX="${DEVBOX_CNAME_PREFIX:-$IMAGE_NAME}"
  if ! validate_container_name "${CNAME_PREFIX}-test"; then
    err "环境变量 DEVBOX_CNAME_PREFIX 无效，请仅使用字母、数字、点、下划线或短横线"
    exit 1
  fi
  AUTO_START="${DEVBOX_AUTO_START:-n}"
  AUTO_START="${AUTO_START,,}"
  if [[ ! "$AUTO_START" =~ ^[yn]$ ]]; then
    err "环境变量 DEVBOX_AUTO_START 只能是 y 或 n"
    exit 1
  fi

  ask_init_adv_limits

  echo
  ui_caption "配置预览："
  printf "   • 工作目录：%s\n" "$(color '1;37' "$WORKDIR")"
  printf "   • 镜像：%s\n" "$(color '1;37' "$IMAGE")"
  printf "   • 网络：%s\n" "$(color '1;37' "$NET_NAME")"
  printf "   • SSH 端口：%s\n" "$(color '1;37' "$PORT_BASE_DEFAULT")"
  printf "   • 实例前缀：%s\n" "$(color '1;37' "$CNAME_PREFIX")"
  printf "   • 自动启动：%s\n" "$(color '1;37' "${AUTO_START^^}")"
  printf "   • 资源限制：%s, %s, pids=%s\n" "$(color '1;37' "$DEFAULT_MEM")" "$(color '1;37' "$DEFAULT_CPUS")" "$(color '1;37' "$DEFAULT_PIDS")"

  mkdir -p -- "$WORKDIR" "$WORKDIR/.devbox"
  if [[ ! -w "$WORKDIR" ]]; then
    err "工作目录不可写：$WORKDIR"
    exit 1
  fi
  META_DIR="${WORKDIR}/.devbox"

  setup_debug
  log_debug "Auto initialization complete: WORKDIR=$WORKDIR IMAGE=$IMAGE NET=$NET_NAME PORTBASE=$PORT_BASE_DEFAULT"
}

init_prompt_interactive() {
  ui_title "DevBox 安装偏好" "请根据自己的环境调整参数，回车即可采用推荐值。"

  while true; do
    WORKDIR="$(ask '选择工作目录' '/opt/my_dev_box' '用于保存 Dockerfile、devbox.sh 以及实例口令。')"
    [[ -d "$WORKDIR" ]] || mkdir -p "$WORKDIR" 2>/dev/null || { warn "无法创建目录"; continue; }
    break
  done
  while true; do
    IMAGE_NAME="$(ask '镜像名称' 'acm-lite' '简短的小写名称，例如 acm-lite。')"
    [[ "$IMAGE_NAME" =~ ^[a-z0-9-]+$ ]] && break
    warn "镜像名只能包含小写字母、数字和短横线"
  done
  IMAGE_TAG="$(ask '镜像标签' 'latest' '用于区分版本，例如 latest 或 2024.04。')"
  IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
  NET_NAME="$(ask 'Docker 自定义网络名' 'devbox-net' '用于串联实例与端口代理。')"
  while true; do
    PORT_BASE_DEFAULT="$(ask 'SSH 起始端口 (按 100 递增尝试)' '30022' '若端口被占用，将自动尝试 +100。')"
    validate_port "$PORT_BASE_DEFAULT" && break
    warn "请输入有效端口号 (1-65535)"
  done
  MAX_TRIES=80
  while true; do
    CNAME_PREFIX="$(ask '实例名前缀' "$IMAGE_NAME" '最终容器名会附带时间戳。')"
    validate_container_name "${CNAME_PREFIX}-test" && break
    warn "名称格式不符合 Docker 命名规范"
  done
  while true; do
    AUTO_START="$(ask '安装结束后立即创建并启动一个容器？(y/n)' 'n' '选择 y 将自动创建首个实例。')"
    validate_yes_no "$AUTO_START" && break
    warn "请输入 y 或 n"
  done

  ask_init_adv_limits

  echo
  ui_caption "配置预览："
  printf "   • 工作目录：%s\n" "$(color '1;37' "$WORKDIR")"
  printf "   • 镜像：%s\n" "$(color '1;37' "$IMAGE")"
  printf "   • 网络：%s\n" "$(color '1;37' "$NET_NAME")"
  printf "   • SSH 端口：%s\n" "$(color '1;37' "$PORT_BASE_DEFAULT")"
  printf "   • 实例前缀：%s\n" "$(color '1;37' "$CNAME_PREFIX")"
  printf "   • 自动启动：%s\n" "$(color '1;37' "$AUTO_START")"
  printf "   • 资源限制：%s, %s, pids=%s\n" "$(color '1;37' "$DEFAULT_MEM")" "$(color '1;37' "$DEFAULT_CPUS")" "$(color '1;37' "$DEFAULT_PIDS")"

  if [[ ! -d "$WORKDIR" ]]; then
    mkdir -p -- "$WORKDIR"
  fi
  if [[ ! -w "$WORKDIR" ]]; then
    err "工作目录不可写：$WORKDIR"
    exit 1
  fi
  META_DIR="${WORKDIR}/.devbox"
  if [[ ! -d "$META_DIR" ]]; then
    mkdir -p -- "$META_DIR"
  fi

  setup_debug
  log_debug "Initialization complete: WORKDIR=$WORKDIR IMAGE=$IMAGE NET=$NET_NAME PORTBASE=$PORT_BASE_DEFAULT"
}

init_prompt() {
  if [[ "$AUTO_MODE" == "1" ]]; then
    init_prompt_auto
  else
    init_prompt_interactive
  fi
}

# ========== Dockerfile 生成 ==========
write_min_dockerfile() {
  if [[ -f "$WORKDIR/Dockerfile" ]]; then
    info "检测到现有 Dockerfile，跳过生成"
    return
  fi
  log "生成 Dockerfile 到 $WORKDIR/Dockerfile"
  log_debug "Creating minimal Dockerfile"
  cat >"$WORKDIR/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive

# 仅安装必要组件：最小攻击面
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server zsh \
      zsh-autosuggestions zsh-syntax-highlighting \
      ca-certificates locales sudo \
    && rm -rf /var/lib/apt/lists/*

# 创建非 root 用户 dev（作为登录与日常使用账号；root 登录禁用）
RUN useradd -m -s /usr/bin/zsh dev && usermod -aG sudo dev \
 && printf 'dev ALL=(ALL) ALL\n' >/etc/sudoers.d/dev

# SSH 基础设置（限制 root 登录；启用密码登录以便首次接入）
RUN mkdir -p /var/run/sshd \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config

# 简洁 zsh 配置：启用补全/联想/高亮（保持默认主题）
USER dev
RUN echo '\
autoload -Uz compinit && compinit\n\
zstyle ":completion:*" menu select\n\
[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh\n\
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\n\
' >> /home/dev/.zshrc

# 说明：运行 sshd 需要特权操作，容器入口仍以 root 运行 sshd，
# 但登录与日常操作使用非 root 用户 dev，且禁用 root 登录。
USER root
WORKDIR /home/dev
EXPOSE 22
CMD ["/usr/sbin/sshd","-D"]
DOCKERFILE
}

check_dockerfile_compatibility() {
  local dockerfile="$WORKDIR/Dockerfile"
  [[ -f "$dockerfile" ]] || return 0

  local issues=()
  if ! grep -qiE '^[[:space:]]*EXPOSE[[:space:]]+22\b' "$dockerfile"; then
    issues+=("未检测到 EXPOSE 22；DevBox 默认期望通过 22 端口提供 SSH 服务。")
  fi
  if ! grep -qi 'sshd' "$dockerfile"; then
    issues+=("Dockerfile 中未发现 sshd 相关命令，请确认容器入口能启动 SSH 服务。")
  fi
  if ! grep -qi 'useradd' "$dockerfile" && ! grep -qi 'adduser' "$dockerfile"; then
    issues+=("建议为开发者准备一个非 root 账号（例如 dev），否则脚本将无法自动创建安全凭据。")
  fi

  if ((${#issues[@]} == 0)); then
    log_debug "Dockerfile compatibility check passed"
    return 0
  fi

  if [[ "${AUTO_MODE:-0}" == "1" ]]; then
    err "自动模式下检测到 Dockerfile 存在以下潜在问题："
    local warn_item
    for warn_item in "${issues[@]}"; do
      ui_caption "  - ${warn_item}"
    done
    ui_caption "请修正 Dockerfile 后重试，或在交互模式下确认继续。"
    exit 1
  fi

  warn "检测到 Dockerfile 可能与 DevBox 管理脚本要求不完全匹配："
  local item
  for item in "${issues[@]}"; do
    ui_caption "  - ${item}"
  done
  ui_caption "如果确认镜像使用了自定义端口或入口，请在安装后修改 devbox.sh 中的配置或使用相应菜单选项。"
  if ! confirm "继续构建该 Dockerfile 吗？" Y; then
    err "用户取消构建以调整 Dockerfile 配置"
    exit 1
  fi
  return 0
}

# ========== 镜像构建 ==========
build_image() {
  log "开始构建镜像: $IMAGE"
  log_debug "Building image with DOCKER_BUILDKIT=1"
  check_disk_space
  progress "正在构建镜像..."
  if DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$WORKDIR" >>"${DEBUG_LOG:-/dev/null}" 2>&1; then
    progress_done "镜像构建完成: $IMAGE"
  else
    echo
    err "镜像构建失败"
    info "请检查："
    ui_caption "  1. Dockerfile 语法是否正确"
    ui_caption "  2. 网络连接是否正常"
    ui_caption "  3. Docker 磁盘空间是否充足"
    [[ -f "${DEBUG_LOG:-}" ]] && ui_caption "  详细日志: $DEBUG_LOG"
    exit 1
  fi
}

# ========== 管理脚本生成 ==========
write_devbox_script() {
  log "生成管理脚本：$WORKDIR/devbox.sh"
  log_debug "Writing devbox.sh with placeholders"

  cat >"$WORKDIR/devbox.sh" <<'EOF_DEVBOX'
#!/usr/bin/env bash
set -Eeuo pipefail

# ========== 配置 ==========
SCRIPT_VERSION="2.0.0"
IMAGE_DEFAULT="__IMAGE__"
PORT_BASE_DEFAULT="__PORTBASE__"
MAX_TRIES="__MAXTRIES__"
NET_NAME="__NETNAME__"
CNAME_PREFIX="__CNAMEPREFIX__"
DEBUG="${DEVBOX_DEBUG:-0}"

# 资源限制（环境变量可覆盖）
DEFAULT_MEM="${DEVBOX_MEM:-1g}"
DEFAULT_CPUS="${DEVBOX_CPUS:-1.0}"
DEFAULT_PIDS="${DEVBOX_PIDS:-256}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="${WORKDIR}/.devbox"
mkdir -p "${META_DIR}"

# ========== 帮助信息 ==========
show_help() {
  cat <<'HELP'
DevBox 管理工具 v2.0.0

用法:
  ./devbox.sh [选项]
  ./devbox.sh cli <命令> [参数]    # 非交互式子命令，适合自动化

选项:
  -h, --help      显示此帮助信息
  --debug         启用调试模式（日志输出到 .devbox/debug.log）

功能:
  • 创建和管理多个独立的开发容器实例
  • 自动端口分配和 SSH 访问
  • 端口转发代理（通过轻量 socat 容器）
  • Fail2ban 安全保护（启用/查看/重置/卸载）
  • 密码管理和旋转
  • DEVBOX_RESERVED_HOST_PORTS 用于声明不可占用的宿主机端口
  • DEVBOX_ASSUME_YES=1 可在自动化脚本中跳过确认提示

安全基线:
  • 严禁 --privileged、严禁挂载宿主目录或 /var/run/docker.sock
  • 默认资源限制: --memory 1g --cpus 1.0 --pids-limit 256
  • 仅安装必要软件包，镜像中不存放敏感凭据

示例:
  ./devbox.sh
  DEVBOX_DEBUG=1 ./devbox.sh
  DEVBOX_MEM=2g DEVBOX_CPUS=2 ./devbox.sh
  ./devbox.sh cli instance start demo --enable-fail2ban

HELP
  exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && show_help
[[ "${1:-}" == "--debug" ]] && export DEVBOX_DEBUG=1

# ========== 调试 ==========
DEBUG_LOG=""
setup_debug() {
  if [[ "$DEBUG" == "1" ]]; then
    DEBUG_LOG="${META_DIR}/debug.log"
    exec 3>>"$DEBUG_LOG"
    log_debug "=== Management session started at $(date) ==="
    log_debug "DevBox manager version: $SCRIPT_VERSION"
  fi
}
log_debug() { [[ "$DEBUG" == "1" && -n "${DEBUG_LOG:-}" ]] && echo "[DEBUG $(date +%T)] $*" >&3 || true; }
setup_debug

# ========== 信号处理 ==========
trap 'code=$?; echo; err "控制面板在第 $LINENO 行遇到问题 (退出码 $code)"; pause_for_enter' ERR
trap 'echo; err "用户中断操作"; exit 130' INT

# ========== Ctrl+C 助手 ==========
# 在进入长时间跟随日志前，父进程暂时忽略 INT，子进程清空 INT trap，
# 用户按 Ctrl+C 时只结束子进程跟随，不会触发全局 INT trap，随后恢复。
begin_ignore_int() {
  SAVED_INT_TRAP="$(trap -p INT 2>/dev/null || true)"
  trap '' INT
}
end_restore_int() {
  if [[ -n "${SAVED_INT_TRAP:-}" ]]; then
    eval "$SAVED_INT_TRAP"
  else
    trap 'echo; err "用户中断操作"; exit 130' INT
  fi
  unset SAVED_INT_TRAP
}

# ========== UI 工具 ==========
color() { local code="${1:-}"; shift || true; printf "\e[%sm%s\e[0m" "$code" "${*:-}"; }
log()  { printf "%b  %s\n" "$(color '1;32' 'OK')" "$*"; }
info() { printf "%b  %s\n" "$(color '1;36' 'INFO')" "$*"; }
warn() { printf "%b  %s\n" "$(color '1;33' 'WARN')" "$*"; }
err()  { printf "%b  %s\n" "$(color '1;31' 'ERROR')" "$*"; }
ui_rule() { printf '%s\n' "$(color '0;37' '────────────────────────────────────────')"; }
ui_title() {
  echo
  ui_rule
  printf '%s\n' "$(color '1;37' "${1:-}")"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$(color '0;37' "${2}")"
  fi
  ui_rule
}
ui_caption() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$(color '0;90' "${1}")"
  fi
}
ui_block_title() { printf '\n%s %s\n' "$(color '1;37' '❯')" "$(color '1;37' "$1")"; }
ui_kv() { local key="$1" val="${2:-}"; printf '  %-14s: %s\n' "$(color '0;37' "$key")" "$(color '1;37' "$val")"; }
menu_option() {
  local key="$1" title="$2" hint="${3:-}"
  printf '   %s %s\n' "$(color '1;36' "[$key]")" "$(color '1;37' "$title")"
  if [[ -n "$hint" ]]; then
    printf '      %s\n' "$(color '0;37' "$hint")"
  fi
}
pause_for_enter() { echo; printf '%s' "$(color '0;37' '按回车继续')"; read -r _; }
ask_field() {
  local prompt="$1" def="${2:-}" note="${3:-}" ans
  echo >&2
  printf '%s %s\n' "$(color '1;36' '提示')" "$(color '1;37' "$prompt")" >&2
  if [[ -n "$note" ]]; then
    printf '   %s\n' "$(color '0;37' "$note")" >&2
  fi
  if [[ -n "$def" ]]; then
    printf '   %s %s\n' "$(color '0;37' '默认值')" "$(color '1;37' "$def")" >&2
    printf '   %s → ' "$(color '0;37' '输入值 (回车采用默认)')" >&2
    IFS= read -r ans; echo "${ans:-$def}"
  else
    printf '   %s → ' "$(color '0;37' '输入值')" >&2
    IFS= read -r ans; echo "$ans"
  fi
}
confirm() {
  local prompt="$1" def="${2:-N}" ans
  if [[ "${DEVBOX_ASSUME_YES:-0}" == "1" ]]; then
    printf '%s [auto-yes]\n' "$(color '1;33' "$prompt")" >&2
    return 0
  fi
  printf '%s [%s/%s] → ' "$(color '1;33' "$prompt")" "$([[ "$def" =~ [Yy] ]] && echo 'Y' || echo 'y')" "$([[ "$def" =~ [Nn] ]] && echo 'N' || echo 'n')" >&2
  IFS= read -r ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ========== 权限检查 ==========
need_sudo() { ! docker info >/dev/null 2>&1; }
die_need_sudo() { ui_title "需要 Docker 权限"; warn "当前用户无法访问 Docker 守护进程。"; ui_caption "提示：请使用 sudo ./devbox.sh 再次运行。"; exit 1; }

# ========== 容器过滤 ==========
label_filter() {
  local pref="$CNAME_PREFIX"
  (
    docker ps -a --filter "label=devbox.managed=true" --format '{{.Names}}\t{{.Labels}}'
    if [[ -n "$pref" ]]; then
      docker ps -a --format '{{.Names}}\t{{.Labels}}' | awk -F'\t' -v p="$pref" 'index($1,p)==1 && ($1==p || substr($1,length(p)+1,1)=="-")'
    fi
  ) | awk -F'\t' 'NF && $1 { if ($0 ~ /devbox\.forward=true/) next; if (!seen[$1]++) print $1 }'
}

# ========== 基础工具 ==========
exists_image() { docker images --format '{{.Repository}}:{{.Tag}}' | grep -Fqx -- "$1"; }
exists_container() { docker ps -a --format '{{.Names}}' | grep -Fqx -- "$1"; }
running_container() { docker ps --format '{{.Names}}' | grep -Fqx -- "$1"; }
passfile_of() { echo "${META_DIR}/$1.pass"; }
ensure_network() { docker network inspect "${NET_NAME}" >/dev/null 2>&1 || docker network create "${NET_NAME}" >/dev/null; }
port_in_use_host() {
  local hp="$1" entry

  if [[ -n "${DEVBOX_RESERVED_HOST_PORTS:-}" ]]; then
    IFS=', ' read -r -a __devbox_reserved_ports <<<"${DEVBOX_RESERVED_HOST_PORTS//,/ }"
    for entry in "${__devbox_reserved_ports[@]}"; do
      [[ -z "$entry" ]] && continue
      if [[ "$entry" == "$hp" ]]; then
        log_debug "Host port ${hp} marked as reserved via DEVBOX_RESERVED_HOST_PORTS"
        return 0
      fi
    done
    unset __devbox_reserved_ports
  fi

  timeout 0.2 bash -lc ":</dev/tcp/127.0.0.1/${hp}" 2>/dev/null && return 0
  command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":${hp}\\b" && return 0
  docker ps --format '{{.Ports}}' | grep -qE "0\.0\.0\.0:${hp}->|:${hp}->" && return 0
  return 1
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1>=1 && $1<=65535 )); }
pick_port_strict() { local base="${1:-$PORT_BASE_DEFAULT}"; for ((i=0;i<${2:-$MAX_TRIES};i++)); do local try=$((base+i*100)); port_in_use_host "$try" || { echo "$try"; return 0; }; done; return 1; }

# ========== CLI 接口辅助 ==========
cli_usage() {
  cat <<'CLI'
用法: ./devbox.sh cli <命令> [参数]

命令:
  image build [镜像]          构建镜像（默认使用安装时的镜像名）
  image rebuild [镜像]        强制忽略缓存重建镜像
  instance start <名称> [--image 镜像] [--port-base 起始端口] [--enable-fail2ban]
  instance stop <名称>        停止容器
  instance remove <名称>      删除容器及其记录
  instance status <名称>      输出实例状态摘要
  instance password <名称>    重新生成 dev 用户密码
  fail2ban enable <名称>      安装并启动 fail2ban
  fail2ban disable <名称>     卸载 fail2ban
  fail2ban status <名称>      显示 fail2ban 状态和日志摘要
  forward add <名称> <宿主端口> <容器端口> [绑定地址]
  forward remove <名称> <宿主端口> <容器端口> [绑定地址]
  forward list <名称>         列出端口转发映射
  status                      列出所有已知实例状态
  help                        显示本帮助

所有 CLI 子命令默认启用 DEVBOX_ASSUME_YES=1，以方便自动化脚本使用。
CLI
}

cli_require_name() {
  local name="$1"
  if [[ -z "${name:-}" ]]; then
    err "缺少实例名称"
    return 1
  fi
  echo "$name"
}

cli_instance_start() {
  local name="$1"; shift || true
  local image="$IMAGE_DEFAULT" port_base="$PORT_BASE_DEFAULT" enable_fail2ban=0
  while (($#)); do
    case "$1" in
      --image)
        image="$2"; shift 2 || return 1 ;;
      --port-base)
        port_base="$2"; shift 2 || return 1 ;;
      --enable-fail2ban)
        enable_fail2ban=1; shift ;;
      *)
        err "未知选项: $1"; return 1 ;;
    esac
  done
  op_start_instance "$name" "$image" "$port_base" || return 1
  if (( enable_fail2ban )); then
    op_enable_fail2ban "$name" force || return 1
  fi
}

cli_forward_add() {
  local cname="$1" host_port="$2" container_port="$3" bind_addr="${4:-127.0.0.1}"
  if [[ -z "$cname" || -z "$host_port" || -z "$container_port" ]]; then
    err "forward add 需要 <名称> <宿主端口> <容器端口> [绑定地址]"
    return 1
  fi
  if ! valid_port "$host_port" || ! valid_port "$container_port"; then
    err "端口号无效"
    return 1
  fi
  if port_in_use_host "$host_port"; then
    err "宿主机端口 ${host_port} 已被占用或被标记为保留"
    return 1
  fi
  running_container "$cname" || { err "容器未运行：$cname"; return 1; }
  ensure_network
  docker network connect "${NET_NAME}" "$cname" >/dev/null 2>&1 || true
  local meta="$(pf_meta_file "$cname")"
  mkdir -p "$META_DIR"
  if [[ -f "$meta" ]] && awk -F':' -v b="$bind_addr" -v hp="$host_port" -v cp="$container_port" 'BEGIN{found=0} $1==b && $2==hp && $3==cp {found=1} END{exit !found}' "$meta"; then
    info "端口映射已存在：${bind_addr}:${host_port} → ${cname}:${container_port}"
    return 0
  fi
  printf '%s:%s:%s\n' "$bind_addr" "$host_port" "$container_port" >>"$meta"
  if sync_forward_proxy "$cname"; then
    log "已添加端口映射：${bind_addr}:${host_port} → ${cname}:${container_port}"
    return 0
  fi
  warn "代理容器创建失败，回滚此次映射"
  if [[ -f "$meta" ]]; then
    awk -F':' -v b="$bind_addr" -v hp="$host_port" -v cp="$container_port" '$1!=b || $2!=hp || $3!=cp' "$meta" >"${meta}.tmp" && mv "${meta}.tmp" "$meta"
  fi
  return 1
}

cli_forward_remove() {
  local cname="$1" host_port="$2" container_port="$3" bind_addr="${4:-127.0.0.1}"
  if [[ -z "$cname" || -z "$host_port" || -z "$container_port" ]]; then
    err "forward remove 需要 <名称> <宿主端口> <容器端口> [绑定地址]"
    return 1
  fi
  local meta="$(pf_meta_file "$cname")"
  if [[ ! -f "$meta" ]]; then
    warn "未找到端口映射记录"
    return 0
  fi
  local removed=0 tmp="${meta}.tmp"
  if awk -F':' -v b="$bind_addr" -v hp="$host_port" -v cp="$container_port" 'BEGIN{changed=0} { if ($1==b && $2==hp && $3==cp) {changed=1; next} print } END{exit !changed}' "$meta" >"$tmp"; then
    mv "$tmp" "$meta"
    removed=1
  else
    rm -f "$tmp"
  fi
  if (( removed == 0 )); then
    warn "未匹配到指定的端口映射"
    return 1
  fi
  [[ -s "$meta" ]] || rm -f "$meta"
  if sync_forward_proxy "$cname"; then
    log "已删除端口映射：${bind_addr}:${host_port}"
    return 0
  fi
  warn "更新代理容器失败"
  return 1
}

run_cli() {
  local cmd="$1"
  shift || true
  if [[ -z "${cmd:-}" ]]; then
    cli_usage
    return 1
  fi
  if need_sudo; then
    die_need_sudo
  fi
  case "$cmd" in
    help|-h|--help)
      cli_usage
      ;;
    image)
      case "${1:-}" in
        build)
          shift || true
          op_build_image "${1:-$IMAGE_DEFAULT}" ;;
        rebuild)
          shift || true
          op_rebuild_image "${1:-$IMAGE_DEFAULT}" ;;
        *)
          err "未知 image 子命令"
          cli_usage
          return 1 ;;
      esac
      ;;
    instance)
      case "${1:-}" in
        start)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          cli_instance_start "$name" "$@" ;;
        stop)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          op_stop_only "$name" ;;
        remove)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          op_remove_container "$name" ;;
        status)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          status_of "$name" ;;
        password)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          op_rotate_password "$name" ;;
        *)
          err "未知 instance 子命令"
          cli_usage
          return 1 ;;
      esac
      ;;
    fail2ban)
      case "${1:-}" in
        enable)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          op_enable_fail2ban "$name" force ;;
        disable)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          op_disable_fail2ban "$name" ;;
        status)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          fail2ban_status_report "$name" ;;
        *)
          err "未知 fail2ban 子命令"
          cli_usage
          return 1 ;;
      esac
      ;;
    forward)
      case "${1:-}" in
        add)
          shift || true
          cli_forward_add "$1" "$2" "$3" "${4:-127.0.0.1}" ;;
        remove)
          shift || true
          cli_forward_remove "$1" "$2" "$3" "${4:-127.0.0.1}" ;;
        list)
          shift || true
          local name; name="$(cli_require_name "${1:-}")" || return 1
          shift || true
          pf_list_for_instance "$name" ;;
        *)
          err "未知 forward 子命令"
          cli_usage
          return 1 ;;
      esac
      ;;
    status)
      list_all_status ;;
    *)
      err "未知命令: $cmd"
      cli_usage
      return 1 ;;
  esac
  return 0
}

# ========== 容器操作 ==========
wait_sshd_ready() {
  local cname="$1" port="$2"
  info "等待 SSHD 服务就绪 (端口 ${port})..."
  for _ in {1..60}; do
    if timeout 0.3 bash -lc ":</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      if docker exec -u root "${cname}" bash -lc "pgrep -x sshd >/dev/null" 2>/dev/null; then
        log "SSHD 已就绪"; return 0
      fi
    fi
    sleep 0.5
  done
  warn "SSHD 未在预期时间内就绪"
  return 1
}
ensure_home_perm() { local cname="$1"; docker exec -u root "${cname}" sh -lc 'chown -R $(id -u dev):$(id -g dev) /home/dev' 2>/dev/null || true; }
set_random_password() {
  local cname="$1" pfile; pfile="$(passfile_of "$cname")"
  local newpass; newpass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "Dev$(date +%s)")"
  if docker exec -u root "${cname}" bash -lc "echo 'dev:${newpass}' | chpasswd" 2>/dev/null; then
    echo "${newpass}" > "${pfile}"
    log "已为 dev 生成新密码：${newpass}"
    ui_caption "密码保存在 $(basename "$pfile")"
  else
    warn "设置密码失败"
  fi
}

# ========== 状态显示 ==========
status_of() {
  local cname="$1"
  local state port ip image
  state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo '-')"
  port="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{(index . 0).HostPort}}{{end}}' "$cname" 2>/dev/null || true)"
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null || true)"
  image="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || echo '-')"
  ui_block_title "实例状态"
  ui_kv "当前状态" "$state"
  ui_kv "使用镜像" "$image"
  ui_kv "SSH 端口" "${port:--}"
  ui_kv "内部 IP" "${ip:--}"
}
ssh_hint() { local cname="$1" port; port="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{(index . 0).HostPort}}{{end}}' "$cname" 2>/dev/null || true)"; echo; ui_caption "SSH 连接: ssh dev@<服务器IP> -p ${port}"; }

# ========== Fail2ban 管理 ==========
fail2ban_meta_file() { echo "${META_DIR}/$1.fail2ban"; }
fail2ban_requested() { [[ -f "$(fail2ban_meta_file "$1")" ]]; }
fail2ban_menu_hint() {
  local cname="$1"
  if fail2ban_requested "$cname"; then echo '已启用'
  elif running_container "$cname" && docker exec -u root "$cname" bash -lc 'command -v fail2ban-client' >/dev/null 2>&1; then echo '需修复'
  else echo '未启用'; fi
}

fail2ban_apply() {
  local cname="$1" mode="${2:-keep}"
  log_debug "Applying fail2ban config for $cname (mode=$mode)"
  docker exec -u root -i "$cname" bash -s "$mode" <<'SCRIPT' || return 1
set -Eeuo pipefail
MODE="${1:-keep}"
export DEBIAN_FRONTEND=noninteractive
log_step() { printf '[fail2ban] %s\n' "$*"; }
log_warn() { printf '[fail2ban][WARN] %s\n' "$*" >&2; }

apt_updated=false
ensure_pkg() {
  local pkg="$1" mode="${2:-check}" status reinstall_flag=()
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  if [[ "$status" == "install ok installed" && "$mode" != "force" ]]; then
    log_step "软件包已存在: $pkg"
    return 0
  fi
  if [[ "$apt_updated" == false ]]; then
    log_step "apt-get update..."
    apt-get update || exit 20
    apt_updated=true
  fi
  if [[ "$mode" == "force" ]]; then
    reinstall_flag+=(--reinstall)
    log_step "重新安装: $pkg"
  else
    log_step "安装: $pkg"
  fi
  apt-get install -y --no-install-recommends "${reinstall_flag[@]}" "$pkg" || exit 21
}

log_step "安装依赖..."
ensure_pkg fail2ban
ensure_pkg rsyslog
ensure_pkg nano

if ! command -v fail2ban-client >/dev/null 2>&1; then
  log_warn "fail2ban-client 未找到，尝试重新安装 fail2ban"
  ensure_pkg fail2ban force
  command -v fail2ban-client >/dev/null 2>&1 || { log_warn "重新安装后仍未找到 fail2ban-client"; exit 22; }
fi

log_step "准备配置..."
mkdir -p /run /var/run /var/log /var/run/fail2ban /etc/fail2ban/action.d /etc/ssh/sshd_config.d
touch /var/log/auth.log

block="/etc/ssh/sshd_config.d/99-fail2ban-blocklist.conf"
[[ "$MODE" == "force" || ! -f "$block" ]] && { log_step "创建 SSH blocklist"; : >"$block"; }
chmod 600 "$block"

grep -Eq "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config || printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >>/etc/ssh/sshd_config
grep -Eq '^[[:space:]]*SyslogFacility[[:space:]]+AUTHPRIV' /etc/ssh/sshd_config || printf 'SyslogFacility AUTHPRIV\n' >>/etc/ssh/sshd_config
grep -Eq '^[[:space:]]*LogLevel[[:space:]]+INFO' /etc/ssh/sshd_config || printf 'LogLevel INFO\n' >>/etc/ssh/sshd_config

helper="/usr/local/bin/fail2ban-sshd-match"
if [[ "$MODE" == "force" || ! -f "$helper" ]]; then
  log_step "创建 helper 脚本"
  cat <<'HELPER' >"$helper"
#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-}"; name="${2:-}"; ip="${3:-}"
file="/etc/ssh/sshd_config.d/99-fail2ban-blocklist.conf"
tmp="$(mktemp)"; cleanup(){ [[ -n "$tmp" && -e "$tmp" ]] && rm -f "$tmp"; }; trap cleanup EXIT
mkdir -p "$(dirname "$file")"; touch "$file"; chmod 600 "$file"
case "$mode" in
  ban)
    grep -Fq "# BEGIN FAIL2BAN ${name} ${ip}" "$file" && { tmp=""; } || {
      { cat "$file"; printf '# BEGIN FAIL2BAN %s %s\nMatch Address %s\n  PasswordAuthentication no\n  PubkeyAuthentication no\n# END FAIL2BAN %s %s\n' "$name" "$ip" "$ip" "$name" "$ip"; } >"$tmp"
      mv "$tmp" "$file"; tmp=""
    }
    ;;
  unban)
    [[ -s "$file" ]] && { awk -v name="$name" -v ip="$ip" 'BEGIN{skip=0} $0=="# BEGIN FAIL2BAN "name" "ip{skip=1;next} $0=="# END FAIL2BAN "name" "ip{skip=0;next} skip==0{print}' "$file" >"$tmp"; mv "$tmp" "$file"; tmp=""; }
    ;;
  *) echo "Usage: fail2ban-sshd-match {ban|unban} <name> <ip>" >&2; exit 2 ;;
esac
chmod 600 "$file"; pkill -HUP -x sshd 2>/dev/null || true
HELPER
  chmod 0755 "$helper"
fi

action="/etc/fail2ban/action.d/sshd-match.conf"
if [[ "$MODE" == "force" || ! -f "$action" ]]; then
  cat <<'ACTION' >"$action"
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/fail2ban-sshd-match ban <name> <ip>
actionunban = /usr/local/bin/fail2ban-sshd-match unban <name> <ip>
ACTION
  chmod 0644 "$action"
fi

jail="/etc/fail2ban/jail.local"
if [[ "$MODE" == "force" || ! -f "$jail" ]]; then
  cat <<'JAIL' >"$jail"
# Fail2ban jail configuration
# Parameters:
#   findtime: time window to count retries
#   bantime:  ban duration
#   maxretry: maximum failed attempts
[DEFAULT]
backend = auto
# 10 minutes time window
findtime = 10m
# ban for 1 hour
bantime = 1h
# allow up to 5 failures
maxretry = 5
[sshd]
enabled = true
logpath = /var/log/auth.log
action = sshd-match[name=sshd]
JAIL
  chmod 0644 "$jail"
fi
SCRIPT
}

fail2ban_diag() {
  local cname="$1"
  ui_caption "=== 诊断: fail2ban ==="
  docker exec -u root "$cname" bash -lc '
    echo "[fail2ban-client version]"; fail2ban-client -V 2>/dev/null | head -n1 || echo "(不可用)"
    echo; echo "[process: sshd & rsyslogd]"; ps -ef | grep -E "(sshd|rsyslogd)\b" | grep -v grep || echo "(无进程)"
    echo; echo "[sshd -T (key settings)]"; command -v sshd >/dev/null && sshd -T 2>/dev/null | grep -E "^(syslogfacility|loglevel|usepam)" || echo "(不可用)"
    echo; echo "[rsyslogd detected]"; if command -v rsyslogd >/dev/null; then echo yes; else echo no; fi
    echo; echo "[/etc/os-release]"; [[ -f /etc/os-release ]] && sed -n "1,20p" /etc/os-release || echo "(缺失)"
    echo; echo "[/etc/apt/sources.list]"; [[ -f /etc/apt/sources.list ]] && sed -n "1,80p" /etc/apt/sources.list || echo "(缺失)"
    echo; echo "[/etc/apt/sources.list.d]"; ls -l /etc/apt/sources.list.d 2>/dev/null || echo "(目录不存在)"; for f in /etc/apt/sources.list.d/*.list; do [[ -f "$f" ]] && { echo "---- $f (前 30 行)"; sed -n "1,30p" "$f"; }; done
    echo; echo "[apt-cache policy fail2ban]"; apt-cache policy fail2ban 2>/dev/null || echo "(apt-cache 无法获取)"
    echo; echo "[dpkg -s fail2ban]"; dpkg -s fail2ban 2>/dev/null | sed -n "1,40p" || echo "(未安装)"
    echo; echo "[/etc/fail2ban/jail.local]"; [[ -f /etc/fail2ban/jail.local ]] && sed -n "1,120p" /etc/fail2ban/jail.local || echo "(缺失)"
    echo; echo "[/var/log/fail2ban.log tail -n 20]"; [[ -f /var/log/fail2ban.log ]] && tail -n 20 /var/log/fail2ban.log || echo "(日志不存在)"
    echo; echo "[/var/log/auth.log 关键 sshd 行]"; [[ -f /var/log/auth.log ]] && grep -iE "sshd|fail|invalid|refused" /var/log/auth.log | tail -n 30 || echo "(无记录)"
  ' 2>/dev/null || true
}

rollback_fail2ban() {
  local cname="$1"
  docker exec -u root "$cname" bash -lc '
    set -Eeuo pipefail
    if command -v fail2ban-client >/dev/null 2>&1; then fail2ban-client -x stop >/dev/null 2>&1 || true; fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y fail2ban >/dev/null 2>&1 || apt-get remove -y fail2ban >/dev/null 2>&1 || true
    rm -f /etc/fail2ban/jail.local /etc/fail2ban/action.d/sshd-match.conf /usr/local/bin/fail2ban-sshd-match /var/log/fail2ban.log /etc/ssh/sshd_config.d/99-fail2ban-blocklist.conf || true
    pkill -HUP -x sshd 2>/dev/null || true
  ' || true
  rm -f "$(fail2ban_meta_file "$cname")"
}

start_fail2ban() {
  local cname="$1"
  log_debug "Starting fail2ban in $cname"
  docker exec -u root "$cname" bash -lc 'set -Eeuo pipefail
command -v rsyslogd >/dev/null && ! pgrep -x rsyslogd >/dev/null && rsyslogd || true
command -v fail2ban-client >/dev/null || {
  echo "fail2ban-client 不存在" >&2
  dpkg_info="$(dpkg -s fail2ban 2>/dev/null || true)"
  echo "[dpkg -s fail2ban]" >&2
  if [[ -n "$dpkg_info" ]]; then
    printf "%s\n" "$dpkg_info" | sed "1,20p" >&2 || true
  else
    echo "(dpkg 未登记 fail2ban)" >&2
  fi
  echo "[apt-cache policy fail2ban]" >&2
  apt_policy="$(apt-cache policy fail2ban 2>/dev/null || true)"
  if [[ -n "$apt_policy" ]]; then
    printf "%s\n" "$apt_policy" | sed "1,20p" >&2 || true
  else
    echo "(apt-cache 无法获取 fail2ban 信息)" >&2
  fi
  echo "[command -v fail2ban-client]" >&2
  command -v fail2ban-client 2>/dev/null >&2 || echo "(command -v 无输出)" >&2
  echo "[最近 apt term.log]" >&2
  if [[ -f /var/log/apt/term.log ]]; then
    tail -n 40 /var/log/apt/term.log >&2
  else
    echo "(未找到 /var/log/apt/term.log)" >&2
  fi
  exit 1
}
start_ok=false
if fail2ban-client status >/dev/null 2>&1; then
  fail2ban-client reload >/dev/null 2>&1 || true
  start_ok=true
else
  if fail2ban-client -x start >/dev/null 2>&1 || service fail2ban start >/dev/null 2>&1 || /etc/init.d/fail2ban start >/dev/null 2>&1 || fail2ban-client start >/dev/null 2>&1; then
    start_ok=true
  fi
fi
if ! $start_ok; then
  echo "=== Fail2ban 启动失败 ===" >&2
  [[ -f /etc/fail2ban/jail.local ]] && { echo "[jail.local]" >&2; head -50 /etc/fail2ban/jail.local >&2; } || echo "(jail.local 缺失)" >&2
  [[ -f /var/log/fail2ban.log ]] && { echo "[fail2ban.log]" >&2; tail -50 /var/log/fail2ban.log >&2; } || echo "(日志不存在)" >&2
  exit 1
fi
fail2ban-client status sshd >/dev/null 2>&1 || { echo "sshd jail 未运行" >&2; exit 1; }
' || return 1
  return 0
}

resume_fail2ban_if_requested() {
  local cname="$1" mode="${2:-check}"
  [[ "$mode" != "force" ]] && ! fail2ban_requested "$cname" && return 0
  running_container "$cname" || return 1
  local apply_mode="keep"; [[ "$mode" == "force" ]] && apply_mode="force"
  fail2ban_apply "$cname" "$apply_mode" || return 1
  start_fail2ban "$cname" || return 1
  return 0
}

fail2ban_status_report() {
  local cname="$1"
  running_container "$cname" || { warn "容器未运行"; return 1; }
  docker exec -u root "$cname" bash -lc 'command -v fail2ban-client >/dev/null' || { warn "fail2ban 未安装"; return 1; }
  ui_caption "整体状态:"; docker exec -u root "$cname" fail2ban-client status 2>/dev/null || true
  echo; ui_caption "sshd 详情:"; docker exec -u root "$cname" fail2ban-client status sshd 2>/dev/null || true
  echo; ui_caption "最近日志:"; docker exec -u root "$cname" bash -lc '[[ -f /var/log/fail2ban.log ]] && tail -30 /var/log/fail2ban.log || echo "(日志不存在)"' 2>/dev/null || true
  echo; ui_caption "auth.log 近期 sshd 相关:"; docker exec -u root "$cname" bash -lc '[[ -f /var/log/auth.log ]] && grep -iE "sshd|fail|invalid|refused" /var/log/auth.log | tail -n 30 || echo "(无记录)"' 2>/dev/null || true
}

fail2ban_edit_config() {
  local cname="$1"
  running_container "$cname" || { warn "容器未运行"; return 1; }
  if ! docker exec -u root "$cname" bash -lc '[[ -f /etc/fail2ban/jail.local ]]' 2>/dev/null; then
    info "创建默认配置..."; fail2ban_apply "$cname" keep || { warn "创建失败"; return 1; }
  fi
  docker exec -it "$cname" bash -lc 'nano /etc/fail2ban/jail.local' || { warn "编辑器异常退出"; return 1; }
  if docker exec -u root "$cname" fail2ban-client reload >/dev/null 2>&1; then
    log "配置已重载"
  else
    warn "重载失败"; docker exec -u root "$cname" bash -lc 'tail -30 /var/log/fail2ban.log 2>/dev/null || true'
  fi
}

op_enable_fail2ban() {
  local cname="$1" mode="${2:-force}"
  running_container "$cname" || { warn "容器未运行"; rm -f "$(fail2ban_meta_file "$cname")"; return 1; }
  info "配置 fail2ban..."
  if ! fail2ban_apply "$cname" "$mode"; then
    warn "配置失败 (apt 或文件写入失败)"; rollback_fail2ban "$cname"; fail2ban_diag "$cname"; return 1
  fi
  if start_fail2ban "$cname"; then
    echo "enabled" >"$(fail2ban_meta_file "$cname")"
    log "Fail2ban 已启用"; fail2ban_status_report "$cname" || true
  else
    warn "启动失败，执行回滚并输出诊断"
    fail2ban_diag "$cname"
    rollback_fail2ban "$cname"
    return 1
  fi
}

op_disable_fail2ban() {
  local cname="$1"
  running_container "$cname" || { warn "容器未运行"; rm -f "$(fail2ban_meta_file "$cname")"; return 1; }
  rollback_fail2ban "$cname"
  log "Fail2ban 已移除"
}

fail2ban_menu() {
  local cname="$1"
  while true; do
    clear
    ui_title "安全配置 - Fail2ban" "实例: ${cname}"
    local enabled=false; fail2ban_requested "$cname" && enabled=true
    ui_caption "当前状态: $(fail2ban_menu_hint "$cname")"
    ui_caption "配置文件: /etc/fail2ban/jail.local"
    menu_option 1 "查看状态（含日志摘要）"
    menu_option 2 "$([[ "$enabled" == true ]] && echo '重新应用配置并重启' || echo '启用 Fail2ban')"
    menu_option 3 "编辑配置 (nano)"
    menu_option 4 "重置为默认模板"
    menu_option 5 "卸载 Fail2ban"
    menu_option 0 "返回"
    printf '%s' "$(color '0;37' '选择 → ')"; local choice; IFS= read -r choice
    case "$choice" in
      1) fail2ban_status_report "$cname" || true; pause_for_enter ;;
      2) op_enable_fail2ban "$cname" "$([[ "$enabled" == true ]] && echo keep || echo force)"; pause_for_enter ;;
      3) fail2ban_edit_config "$cname"; pause_for_enter ;;
      4) confirm "确认重置配置？" && op_enable_fail2ban "$cname" force; pause_for_enter ;;
      5) confirm "确认卸载 Fail2ban？" && op_disable_fail2ban "$cname"; pause_for_enter ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

# ========== 端口转发 ==========
pf_name() { echo "$1-pf"; }
pf_meta_file() { echo "${META_DIR}/$1.forward"; }

sync_forward_proxy() {
  local cname="$1" meta pf
  meta="$(pf_meta_file "$cname")"; pf="$(pf_name "$cname")"
  docker rm -f "$pf" 2>/dev/null || true
  [[ ! -f "$meta" ]] && return 0
  local entries=(); mapfile -t entries <"$meta" 2>/dev/null || true
  ((${#entries[@]}==0)) && return 0
  ensure_network
  local ports=() script="" has_spec=false
  for item in "${entries[@]}"; do
    [[ -z "$item" ]] && continue
    IFS=':' read -r bind_addr host_port container_port <<<"$item"
    [[ -z "$host_port" ]] && continue
    has_spec=true
    ports+=("-p" "${bind_addr}:${host_port}:${host_port}")
    printf -v line 'socat -dd TCP-LISTEN:%s,fork,reuseaddr TCP:%s:%s &\n' "$host_port" "$cname" "$container_port"
    script+="$line"
  done
  [[ "$has_spec" == false ]] && return 0
  script+=$'wait\n'
  log_debug "Creating forward proxy: $pf"
  docker run -d --name "$pf" \
    --network "${NET_NAME}" \
    --restart unless-stopped \
    --read-only --memory 64m --cpus 0.2 --pids-limit 64 \
    --security-opt no-new-privileges \
    -l devbox.managed=true -l devbox.forward=true -l "devbox.parent=$cname" \
    "${ports[@]}" \
    --entrypoint /bin/sh \
    alpine/socat:latest -c "$script" >/dev/null || return 1
}

pf_list_for_instance() {
  local cname="$1" meta
  meta="$(pf_meta_file "$cname")"; [[ ! -f "$meta" ]] && return
  local pf status; pf="$(pf_name "$cname")"
  status="$(docker ps -a --filter "name=^/${pf}$" --format '{{.Status}}')"; [[ -z "$status" ]] && status="未运行"
  while IFS=':' read -r bind_addr host_port container_port; do
    [[ -z "$host_port" ]] && continue
    printf '%s:%s\t%s\t%s\n' "${bind_addr}" "${host_port}" "${container_port}" "${status}"
  done <"$meta"
}

show_forward_summary() {
  local cname="$1" rows=(); mapfile -t rows < <(pf_list_for_instance "$cname")
  ui_block_title "端口转发"
  ((${#rows[@]}==0)) && { printf '  %s\n' "$(color '0;90' '暂无转发规则')"; return; }
  printf '  %-22s %-5s %-15s %s\n' "$(color '0;37' '主机地址:端口')" "" "$(color '0;37' '容器端口')" "$(color '0;37' '状态')"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r host container stat <<<"$row"
    printf '  %-22s %-5s %-15s %s\n' "$(color '1;36' "$host")" "$(color '1;37' '→')" "$(color '1;37' "$container")" "$(color '0;32' "$stat")"
  done
}

op_add_forward() {
  local cname="$1"
  running_container "$cname" || { warn "容器未运行"; return 1; }
  ensure_network
  docker network connect "${NET_NAME}" "$cname" 2>/dev/null || true

  local meta; meta="$(pf_meta_file "$cname")"
  ui_title "新增端口映射" "宿主机端口将通过代理容器转发至实例 ${cname}。"
  local bind_addr host_port container_port

  bind_addr="$(ask_field '绑定地址' '127.0.0.1' '127.0.0.1 为仅本机访问；公网可填 0.0.0.0。')"

  while true; do
    host_port="$(ask_field '宿主机端口' '' '请输入 1-65535 的端口号，例如 8080。')"
    if ! valid_port "$host_port"; then warn "端口无效"; continue; fi
    # 重复检测
    if [[ -f "$meta" ]] && awk -F':' -v hp="$host_port" '$2==hp {found=1} END{exit !found}' "$meta"; then
      warn "端口 ${host_port} 已被本实例映射使用"; continue
    fi
    if port_in_use_host "$host_port"; then warn "端口 ${host_port} 已被系统占用"; continue; fi
    break
  done

  while true; do
    container_port="$(ask_field '容器内部端口' '' '例如应用监听的 8080 或 3000。')"
    if ! valid_port "$container_port"; then warn "端口无效"; continue; fi
    break
  done

  mkdir -p "${META_DIR}"
  printf '%s:%s:%s\n' "$bind_addr" "$host_port" "$container_port" >>"$meta"

  info "应用端口映射：${bind_addr}:${host_port} → ${cname}:${container_port}"
  if sync_forward_proxy "$cname"; then
    log "映射已生效"
    ui_caption "访问示例：<服务器IP>:${host_port}"
  else
    warn "代理容器启动失败，回滚此映射"
    # 删除最后添加的行
    tac "$meta" | sed '1d' | tac >"${meta}.tmp" && mv "${meta}.tmp" "$meta"
  fi
}

op_list_remove_forward() {
  local cname="$1"
  ui_title "端口映射管理" "实例：${cname}"
  local rows; mapfile -t rows < <(pf_list_for_instance "$cname")
  if ((${#rows[@]}==0)); then ui_caption "当前没有代理映射。"; return; fi
  local i=1
  for r in "${rows[@]}"; do
    local host container stat; IFS=$'\t' read -r host container stat <<<"$r"
    printf '%s  %s\n' "$(color '1;36' "[$i]")" "$(color '1;37' "${host} → ${container}")"
    ui_caption "    代理状态：${stat}"
    ((i++))
  done
  printf '%s' "$(color '0;37' '输入编号删除映射（回车跳过） → ')" ; local idx; IFS= read -r idx
  if [[ -z "${idx:-}" ]]; then return; fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx<1 || idx>${#rows[@]} )); then warn "无效选择"; return; fi

  local host container stat; IFS=$'\t' read -r host container stat <<<"${rows[$((idx-1))]}"
  local bind_addr="${host%%:*}" host_port="${host##*:}" container_port="$container"
  local meta tmp; meta="$(pf_meta_file "$cname")"; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${bind_addr}:${host_port}:${container_port}" ]] && continue
    printf '%s\n' "$line" >>"$tmp"
  done <"$meta"
  mv "$tmp" "$meta"; [[ -s "$meta" ]] || rm -f "$meta"
  if sync_forward_proxy "$cname"; then log "已删除映射：${host} → ${cname}:${container_port}"; else warn "代理容器更新失败"; fi
}

# ========== 镜像与实例 ==========
op_build_image() { local image="$1"; ui_title "构建镜像" "$image"; docker build -t "$image" "$WORKDIR" && log "构建完成" || err "构建失败"; }
op_rebuild_image() { local image="$1"; ui_title "强制重建镜像" "$image"; docker build --no-cache -t "$image" "$WORKDIR" && log "重建完成" || err "重建失败"; }

op_start_instance() {
  local cname="$1" image="$2" pbase="${3:-$PORT_BASE_DEFAULT}"
  ensure_network
  if exists_container "$cname"; then
    if running_container "$cname"; then
      warn "容器已在运行：$cname"; status_of "$cname"; ssh_hint "$cname"; return 0
    fi
    info "启动已存在的容器：$cname"
    docker start "$cname" >/dev/null
    docker network connect "${NET_NAME}" "$cname" >/dev/null 2>&1 || true
    local port; port="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{(index . 0).HostPort}}{{end}}' "$cname")"
    wait_sshd_ready "$cname" "$port" || true
    ensure_home_perm "$cname"; set_random_password "$cname" || true
    if fail2ban_requested "$cname" && ! resume_fail2ban_if_requested "$cname"; then warn "fail2ban 恢复失败，可在安全菜单中手动检查。"; fi
    status_of "$cname"; ssh_hint "$cname"; return 0
  fi
  if ! exists_image "$image"; then op_build_image "$image"; fi
  local port; port="$(pick_port_strict "$pbase" "$MAX_TRIES" || true)"; [[ -z "$port" ]] && { warn "未找到可用端口"; return 1; }
  info "创建并启动容器 $cname (镜像: $image，主机端口: $port)"
  docker run -d --name "$cname" \
    --network "${NET_NAME}" \
    --restart unless-stopped \
    --memory "${DEFAULT_MEM}" --cpus "${DEFAULT_CPUS}" --pids-limit "${DEFAULT_PIDS}" \
    --security-opt no-new-privileges \
    -l devbox.managed=true -l devbox.name="$cname" -l devbox.image="$image" \
    -l devbox.created="$(date -u +%FT%TZ)" -l devbox.port="$port" \
    -p "${port}:22" "$image" /usr/sbin/sshd -D >/dev/null
  wait_sshd_ready "$cname" "$port" || true
  ensure_home_perm "$cname"; set_random_password "$cname" || true
  if fail2ban_requested "$cname" && ! resume_fail2ban_if_requested "$cname"; then warn "fail2ban 恢复失败，可在安全菜单中手动检查。"; fi
  status_of "$cname"; ssh_hint "$cname"
}

op_stop_only() {
  local cname="$1"
  if running_container "$cname"; then docker stop "$cname" >/dev/null && log "已停止容器：$cname"
  elif exists_container "$cname"; then info "容器已是停止状态：$cname"
  else warn "容器不存在：$cname"; fi
}

op_remove_container() {
  local cname="$1"
  if ! exists_container "$cname"; then warn "容器不存在：$cname"; return; fi
  if ! confirm "确定要删除实例 '${cname}'？此操作不可恢复。"; then info "已取消"; return; fi
  docker rm -f "$cname" >/dev/null
  rm -f "$(passfile_of "$cname")"
  docker rm -f "$(pf_name "$cname")" >/dev/null 2>&1 || true
  rm -f "$(pf_meta_file "$cname")" "$(fail2ban_meta_file "$cname")"
  log "已删除容器及其记录：$cname"
}

op_shell_instance() { local cname="$1"; running_container "$cname" && docker exec -it "$cname" zsh || warn "容器未运行：$cname"; }
op_logs_instance() {
  local cname="$1"
  exists_container "$cname" || { warn "容器不存在：$cname"; return 1; }
  while true; do
    clear
    ui_title "日志查看" "$cname"
    ui_caption "提示: 跟随模式下按 Ctrl+C 返回上一级"
    menu_option 1 "Docker stdout/stderr (follow)" "容器标准输出/错误"
    menu_option 2 "SSH auth.log (follow)" "/var/log/auth.log"
    menu_option 3 "Fail2ban 日志 (follow)" "/var/log/fail2ban.log"
    menu_option 4 "SSH auth.log 最近200行"
    menu_option 5 "Fail2ban 最近200行"
    menu_option 0 "返回"
    printf '%s' "$(color '0;37' '选择操作 → ')"; local choice; IFS= read -r choice
    case "$choice" in
      1)
        begin_ignore_int; ( trap - INT; docker logs -f --tail 200 "$cname" ); end_restore_int ;;
      2)
        begin_ignore_int; ( trap - INT; docker exec -u root "$cname" bash -lc 'touch /var/log/auth.log; tail -n 200 -f /var/log/auth.log' ); end_restore_int ;;
      3)
        begin_ignore_int; ( trap - INT; docker exec -u root "$cname" bash -lc '[[ -f /var/log/fail2ban.log ]] || : > /var/log/fail2ban.log; tail -n 200 -f /var/log/fail2ban.log' ); end_restore_int ;;
      4)
        docker exec -u root "$cname" bash -lc '[[ -f /var/log/auth.log ]] && tail -n 200 /var/log/auth.log || echo "(日志不存在)"'; pause_for_enter ;;
      5)
        docker exec -u root "$cname" bash -lc '[[ -f /var/log/fail2ban.log ]] && tail -n 200 /var/log/fail2ban.log || echo "(日志不存在)"'; pause_for_enter ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}
op_rotate_password() { local cname="$1"; running_container "$cname" && set_random_password "$cname" || warn "容器未运行：$cname"; }

# ========== 选择与菜单 ==========
pick_instance_menu() {
  local items; mapfile -t items < <(label_filter || true)
  clear >&2 || true; ui_title "选择实例" >&2
  local i=1; for n in "${items[@]}"; do printf '%s %s\n' "$(color '1;36' "[$i]")" "$(color '1;37' "$n")" >&2; ((i++)); done
  printf '%s\n' "$(color '1;36' '[N]') $(color '1;37' '新建实例')" >&2
  printf '%s\n' "$(color '1;36' '[Q]') $(color '1;37' '返回')" >&2
  printf '%s' "$(color '0;37' '选择编号 / N / Q → ')" >&2
  local sel; IFS= read -r sel
  case "$sel" in
    [Qq]) return 1 ;;
    [Nn]) local name; name="$(ask_field '实例名称' "${CNAME_PREFIX}-$(date +%H%M%S)" '推荐字母、数字与短横线。')"; echo "$name"; return 0 ;;
    *)
      if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#items[@]} )); then echo "${items[$((sel-1))]}"; return 0; fi
      warn "无效选择" 1>&2; return 1 ;;
  esac
}

show_login_guidance() {
  local cname="$1" password="${2:-}" pfile; pfile="$(passfile_of "$cname")"
  ui_block_title "登录凭据"
  ui_kv "用户名" "dev"
  if [[ -n "$password" ]]; then ui_kv "密码" "$password"; else ui_kv "密码" "$(color '0;90' '尚未生成')"; fi
  ui_caption "  密码文件: .devbox/$(basename "$pfile")"
  ui_caption "  (root 登录已禁用, 请使用 dev + sudo)"
}

instance_menu() {
  local cname="$1" image="${2:-$IMAGE_DEFAULT}" pbase="${3:-$PORT_BASE_DEFAULT}"
  while true; do
    clear
    ui_title "实例面板" "$cname"
    local password=""; if exists_container "$cname"; then status_of "$cname"; local pfile; pfile="$(passfile_of "$cname")"; [[ -f "$pfile" ]] && password="$(<"$pfile")"; else warn "容器尚未创建：$cname"; fi
    show_login_guidance "$cname" "$password"; show_forward_summary "$cname"
    if exists_container "$cname"; then ssh_hint "$cname"; fi
    [[ ! -e /dev/null ]] || true
    echo
    menu_option 1 "Build 镜像" "当前镜像：$image"
    menu_option 2 "Start 启动 / 创建" "自动在 ${pbase}, $((pbase+100))... 中寻找可用端口"
    menu_option 3 "Stop 停止容器" "不删除实例"
    menu_option 4 "Shell 进入容器" "打开 zsh 交互会话"
    menu_option 5 "Logs 查看日志" "实时跟踪 200 行"
    menu_option 6 "Rebuild 强制重建镜像" "忽略缓存"
    menu_option 7 "Rotate 旋转随机密码"
    menu_option 8 "Remove 删除容器" "不影响镜像"
    menu_option 9 "Security 安全配置" "Fail2ban：$(fail2ban_menu_hint "$cname")"
    menu_option 10 "Add Port Mapping" "新增代理容器进行端口转发"
    menu_option 11 "Manage Port Mappings" "列出并可删除映射"
    menu_option 0 "返回上级"
    printf '%s' "$(color '0;37' '选择操作 → ')"; local choice; IFS= read -r choice
    case "$choice" in
      1) op_build_image "$image"; pause_for_enter ;;
      2) op_start_instance "$cname" "$image" "$pbase"; pause_for_enter ;;
      3) op_stop_only "$cname"; pause_for_enter ;;
      4) op_shell_instance "$cname" ;;
      5) op_logs_instance "$cname" ;;
      6) op_rebuild_image "$image"; pause_for_enter ;;
      7) op_rotate_password "$cname"; pause_for_enter ;;
      8) op_remove_container "$cname"; pause_for_enter ;;
      9) fail2ban_menu "$cname" ;;
      10) op_add_forward "$cname"; pause_for_enter ;;
      11) op_list_remove_forward "$cname"; pause_for_enter ;;
      0) break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

list_all_status() {
  ui_title "实例总览"
  local names; mapfile -t names < <(label_filter || true)
  if ((${#names[@]}==0)); then ui_caption "暂无已记录的实例。"; return; fi
  for n in "${names[@]}"; do
    local state port ip
    state="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo '-')"
    port="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{(index . 0).HostPort}}{{end}}' "$n" 2>/dev/null || true)"
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n" 2>/dev/null || true)"
    printf '\n%s\n' "$(color '1;37' "  $n")"
    ui_kv "  状态" "$state"; ui_kv "  SSH 端口" "${port:--}"; ui_kv "  内部 IP" "${ip:--}"
  done
}

main_menu() {
  clear
  need_sudo && die_need_sudo
  ui_title "DevBox 控制中心" "管理 / 创建多实例开发环境"
  menu_option 1 "管理或创建实例"
  menu_option 2 "构建默认镜像" "$IMAGE_DEFAULT"
  menu_option 3 "查看所有实例状态"
  menu_option 0 "退出"
  printf '%s' "$(color '0;37' '选择操作 → ')"; local choice; IFS= read -r choice
  case "$choice" in
    1) local pick; pick="$(pick_instance_menu || true)"; [[ -z "${pick:-}" ]] && return; instance_menu "$pick" "$IMAGE_DEFAULT" "$PORT_BASE_DEFAULT" ;;
    2) op_build_image "$IMAGE_DEFAULT"; pause_for_enter ;;
    3) list_all_status; pause_for_enter ;;
    0) exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
}

if [[ "${1:-}" == "cli" ]]; then
  shift
  DEVBOX_ASSUME_YES=1
  export DEVBOX_ASSUME_YES
  run_cli "$@"
  exit $?
fi

while true; do main_menu; done
EOF_DEVBOX

  # 一次性替换占位符
  sed -i \
    -e "s|__IMAGE__|$IMAGE|g" \
    -e "s|__PORTBASE__|$PORT_BASE_DEFAULT|g" \
    -e "s|__MAXTRIES__|$MAX_TRIES|g" \
    -e "s|__NETNAME__|$NET_NAME|g" \
    -e "s|__CNAMEPREFIX__|$CNAME_PREFIX|g" \
    "$WORKDIR/devbox.sh"
  chmod +x "$WORKDIR/devbox.sh"
}

# ========== 启动一个容器（安装期“一键演示”） ==========
wait_sshd_ready_installer() {
  local cname="$1" port="$2"
  info "等待容器 ${cname} 的 SSHD 服务就绪 (端口 ${port})..."
  for _ in {1..60}; do
    if timeout 0.3 bash -lc ":</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      if docker exec -u root "$cname" bash -lc "pgrep -x sshd >/dev/null" >/dev/null 2>&1; then
        log "SSHD 已就绪，可立即连接。"; return 0
      fi
    fi
    sleep 0.5
  done
  warn "SSHD 未在预期时间内就绪（容器可能在后台继续初始化）。"
  return 1
}
set_random_password_installer() {
  local cname="$1"
  local pfile="$META_DIR/${cname}.pass"
  local newpass; newpass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "Dev$(date +%s)")"
  if docker exec -u root "$cname" bash -lc "command -v chpasswd >/dev/null && echo 'dev:${newpass}' | chpasswd"; then
    echo "$newpass" > "$pfile"
    log "容器 dev 用户密码已更新：${newpass}"
    ui_caption "口令亦保存在 $pfile"
  else
    warn "设置随机密码失败，可稍后执行：docker exec -u root ${cname} bash -lc \"echo 'dev:<新密码>' | chpasswd\""
  fi
}
ensure_home_perm_installer() { docker exec -u root "$1" sh -lc 'chown -R $(id -u dev):$(id -g dev) /home/dev' >/dev/null 2>&1 || true; }

start_first_instance() {
  local cname="$1" image="$2" net="$3" base="$4" tries="$5"
  ensure_network "$net"
  local port; port="$(pick_port_strict "$base" "$tries" || true)"
  [[ -z "$port" ]] && { err "未找到可用端口（从 $base 起每次 +100 尝试 $tries 次）。"; return 1; }
  info "创建并启动容器 $cname (镜像: $image，主机端口: $port)"
  docker run -d --name "$cname" \
    --network "$net" \
    --restart unless-stopped \
    --memory "${DEFAULT_MEM:-1g}" --cpus "${DEFAULT_CPUS:-1.0}" --pids-limit "${DEFAULT_PIDS:-256}" \
    --security-opt no-new-privileges \
    -l devbox.managed=true -l devbox.name="$cname" -l devbox.image="$image" \
    -l devbox.created="$(date -u +%FT%TZ)" -l devbox.port="$port" \
    -p "${port}:22" "$image" /usr/sbin/sshd -D >/dev/null
  wait_sshd_ready_installer "$cname" "$port" || true
  ensure_home_perm_installer "$cname"
  set_random_password_installer "$cname" || true

  local state image_used ip_addr
  state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo '-')"
  image_used="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || echo '-')"
  ip_addr="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null || echo '-')"

  ui_caption "实例信息："
  printf "   • 名称：%s\n" "$(color '1;37' "$cname")"
  printf "   • 状态：%s\n" "$(color '1;37' "$state")"
  printf "   • 镜像：%s\n" "$(color '1;37' "$image_used")"
  printf "   • 主机端口：%s\n" "$(color '1;37' "$port")"
  printf "   • 容器 IP：%s\n" "$(color '1;37' "$ip_addr")"
  ui_caption "SSH 示例：ssh dev@<服务器IP> -p ${port}"
  [[ -f "$META_DIR/${cname}.pass" ]] && ui_caption "密码文件：$META_DIR/${cname}.pass"
}

run_self_tests() {
  ui_title "DevBox 自检" "验证关键函数与兼容性检查。"

  local total=0 failures=0
  set +e

  local saved_err_trap
  saved_err_trap="$(trap -p ERR || true)"
  trap - ERR

  local tmpdir
  tmpdir="$(mktemp -d)"
  cleanup_tmp() { [[ -d "$tmpdir" ]] && rm -rf "$tmpdir"; }
  local path_backup="$PATH"
  mkdir -p "$tmpdir/bin"
  PATH="$tmpdir/bin:$PATH"

  cat >"$tmpdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  ps) exit 1 ;;
  ps*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$tmpdir/bin/docker"

  cat >"$tmpdir/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$tmpdir/bin/ss"

  cat >"$tmpdir/bin/timeout" <<'EOF'
#!/usr/bin/env bash
/usr/bin/timeout "$@"
EOF
  chmod +x "$tmpdir/bin/timeout"

  expect_success() {
    local desc="$1"
    shift
    ((total++))
    "$@"
    local status=$?
    if [[ $status -eq 0 ]]; then
      printf '  [PASS] %s\n' "$desc"
    else
      printf '  [FAIL] %s (退出码 %s)\n' "$desc" "$status"
      ((failures++))
    fi
    return 0
  }

  expect_failure() {
    local desc="$1"
    shift
    ((total++))
    "$@"
    local status=$?
    if [[ $status -ne 0 ]]; then
      printf '  [PASS] %s\n' "$desc"
    else
      printf '  [FAIL] %s (意外成功)\n' "$desc"
      ((failures++))
    fi
    return 0
  }

  expect_equals() {
    local desc="$1" expected="$2" actual="$3"
    ((total++))
    if [[ "$expected" == "$actual" ]]; then
      printf '  [PASS] %s\n' "$desc"
    else
      printf '  [FAIL] %s (期望 %s 实际 %s)\n' "$desc" "$expected" "$actual"
      ((failures++))
    fi
  }

  expect_success "validate_port 接受合法端口" validate_port 22
  expect_failure "validate_port 拒绝非法端口" validate_port 70000
  expect_success "validate_container_name 通过合法名称" validate_container_name devbox-01
  expect_failure "validate_container_name 拒绝非法名称" validate_container_name /bad/name

  expect_equals "strip_control_chars 移除控制字符" "abc" "$(strip_control_chars $'a\003b\nc')"

  DEVBOX_RESERVED_HOST_PORTS="40000"
  expect_success "port_in_use_host 对保留端口返回占用" port_in_use_host 40000
  local picked
  picked="$(pick_port_strict 40000 2)"
  expect_equals "pick_port_strict 跳过保留端口" "40100" "$picked"
  unset DEVBOX_RESERVED_HOST_PORTS

  local work_backup="${WORKDIR:-}" meta_backup="${META_DIR:-}" debug_backup="${DEBUG_LOG:-}" tmp_work
  tmp_work="${tmpdir}/work"
  mkdir -p "$tmp_work"
  WORKDIR="$tmp_work"
  META_DIR="$tmp_work/.devbox"
  DEBUG_LOG=""

  expect_success "write_min_dockerfile 生成文件" write_min_dockerfile
  expect_equals "生成 Dockerfile 存在" "1" "$( [[ -f "$WORKDIR/Dockerfile" ]] && echo 1 || echo 0 )"
  echo "FROM scratch" >"$WORKDIR/Dockerfile"
  expect_success "write_min_dockerfile 不覆盖已有文件" write_min_dockerfile
  expect_equals "现有 Dockerfile 保持不变" "FROM scratch" "$(head -n1 "$WORKDIR/Dockerfile")"

  mkdir -p "$tmp_work/custom"
  WORKDIR="$tmp_work/custom"
  cat >"$WORKDIR/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
RUN useradd -m dev && apt-get update && apt-get install -y openssh-server
EXPOSE 22
CMD ["/usr/sbin/sshd","-D"]
EOF
  expect_success "check_dockerfile_compatibility 通过标准 Dockerfile" check_dockerfile_compatibility

  WORKDIR="$work_backup"
  META_DIR="$meta_backup"
  DEBUG_LOG="$debug_backup"

  PATH="$path_backup"
  cleanup_tmp
  unset -f cleanup_tmp
  if [[ -n "$saved_err_trap" ]]; then
    eval "$saved_err_trap"
  else
    trap - ERR
  fi
  set -e

  printf '\n共执行 %d 项检查。\n' "$total"
  if ((failures>0)); then
    err "自检失败，共 ${failures} 项未通过"
    exit 1
  fi

  log "自检通过"
  exit 0
}

# ========== 主流程 ==========
main() {
  ui_title "DevBox 安装助手" "打造优雅的多实例开发容器环境。"
  if ! is_root; then warn "建议以 root 运行本安装脚本（或在命令前加 sudo）。"; fi
  install_docker
  init_prompt
  ui_title "构建与配置" "正在准备基础镜像与管理工具。"
  write_min_dockerfile
  check_dockerfile_compatibility
  build_image
  ensure_network "$NET_NAME"
  write_devbox_script

  if [[ "$AUTO_START" =~ ^[Yy]$ ]]; then
    local cname; cname="${CNAME_PREFIX}-$(date +%H%M%S)"
    start_first_instance "$cname" "$IMAGE" "$NET_NAME" "$PORT_BASE_DEFAULT" "$MAX_TRIES"
  else
    info "已跳过自动启动实例"
  fi

  echo
  log "安装完成"
  ui_caption "接下来可以："
  printf "   • 管理脚本：%s\n" "$(color '1;37' "$WORKDIR/devbox.sh")"
  printf "   • 进入菜单：%s\n" "$(color '1;37' "cd $WORKDIR && ./devbox.sh")"
  printf "   • 端口转发：%s\n" "$(color '1;37' '使用菜单中的 Port Mapping 工具按需开放服务。')"
}

parse_args "$@"

if (( RUN_SELF_TEST )); then
  run_self_tests
  exit 0
fi

main
