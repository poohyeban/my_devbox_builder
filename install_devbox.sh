#!/usr/bin/env bash
set -Eeuo pipefail

# ========== 全局配置 ==========
SCRIPT_VERSION="3.0.0"
DEBUG="${DEVBOX_DEBUG:-0}"
DEBUG_LOG=""
AUTO_MODE="${DEVBOX_AUTO:-0}"
# 依赖版本锁定
BASE_IMAGE_DEFAULT="debian:bookworm-slim"
SOCAT_IMAGE_PINNED="alpine/socat:1.7.4.4-r0"

declare -A CONFIG_VALUES=()
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

load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value; do
    key="${key%%#*}"
    key="${key%% }"
    key="${key## }"
    [[ -n "$key" ]] || continue
    value="${value## }"
    value="${value%% }"
    CONFIG_VALUES["$key"]="$value"
  done <"$file"
}

config_get() {
  local key="$1" default="${2:-}"
  if [[ -n "${CONFIG_VALUES[$key]+set}" ]]; then
    printf '%s' "${CONFIG_VALUES[$key]}"
  else
    printf '%s' "$default"
  fi
}

resolve_setting() {
  local key="$1" default_value="$2" env_name="$3"
  local env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return
  fi
  config_get "$key" "$default_value"
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
  DEFAULT_MEM="$(resolve_setting 'MEM' '1g' 'DEVBOX_MEM')"
  DEFAULT_CPUS="$(resolve_setting 'CPUS' '1.0' 'DEVBOX_CPUS')"
  DEFAULT_PIDS="$(resolve_setting 'PIDS' '256' 'DEVBOX_PIDS')"
}
init_prompt_auto() {
  ui_title "DevBox 安装偏好" "已启用自动模式，使用环境变量或默认值完成配置。"

  CONFIG_VALUES=()
  WORKDIR="${DEVBOX_WORKDIR:-/opt/my_dev_box}"
  load_config_file "$WORKDIR/devbox.conf"

  IMAGE_NAME="$(resolve_setting 'IMAGE_NAME' 'acm-lite' 'DEVBOX_IMAGE_NAME')"
  if [[ ! "$IMAGE_NAME" =~ ^[a-z0-9-]+$ ]]; then
    err "环境变量 DEVBOX_IMAGE_NAME 无效（仅限小写字母、数字和短横线）"
    exit 1
  fi
  IMAGE_TAG="$(resolve_setting 'IMAGE_TAG' 'latest' 'DEVBOX_IMAGE_TAG')"
  IMAGE_PREFIX="$IMAGE_NAME"
  DEFAULT_TEMPLATE="$(resolve_setting 'DEFAULT_TEMPLATE' 'debian-bookworm' 'DEVBOX_DEFAULT_TEMPLATE')"
  TEMPLATE_ROOT="$WORKDIR/templates"
  IMAGE="${IMAGE_PREFIX}-${DEFAULT_TEMPLATE}:${IMAGE_TAG}"
  NET_NAME="$(resolve_setting 'NET_NAME' 'devbox-net' 'DEVBOX_NET_NAME')"
  PORT_BASE_DEFAULT="$(resolve_setting 'PORT_BASE' '30022' 'DEVBOX_PORT_BASE')"
  if ! validate_port "$PORT_BASE_DEFAULT"; then
    err "环境变量 DEVBOX_PORT_BASE 必须是有效端口 (1-65535)"
    exit 1
  fi
  MAX_TRIES=80
  CNAME_PREFIX="$(resolve_setting 'CNAME_PREFIX' "$IMAGE_NAME" 'DEVBOX_CNAME_PREFIX')"
  if ! validate_container_name "${CNAME_PREFIX}-test"; then
    err "环境变量 DEVBOX_CNAME_PREFIX 无效，请仅使用字母、数字、点、下划线或短横线"
    exit 1
  fi
  AUTO_START="$(resolve_setting 'AUTO_START' 'n' 'DEVBOX_AUTO_START')"
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
    WORKDIR="$(ask '选择工作目录' '/opt/my_dev_box' '用于保存 Dockerfile、模板与管理脚本。')"
    [[ -d "$WORKDIR" ]] || mkdir -p "$WORKDIR" 2>/dev/null || { warn "无法创建目录"; continue; }
    break
  done
  CONFIG_VALUES=()
  load_config_file "$WORKDIR/devbox.conf"

  local image_name_default="$(resolve_setting 'IMAGE_NAME' 'acm-lite' 'DEVBOX_IMAGE_NAME')"
  while true; do
    IMAGE_NAME="$(ask '镜像名称前缀' "$image_name_default" '用于区分团队或项目，例如 acm-lite。')"
    [[ "$IMAGE_NAME" =~ ^[a-z0-9-]+$ ]] && break
    warn "镜像名前缀只能包含小写字母、数字和短横线"
  done
  IMAGE_PREFIX="$IMAGE_NAME"
  IMAGE_TAG="$(ask '镜像标签' "$(resolve_setting 'IMAGE_TAG' 'latest' 'DEVBOX_IMAGE_TAG')" '用于区分版本，例如 latest 或 2024.04。')"
  NET_NAME="$(ask 'Docker 自定义网络名' "$(resolve_setting 'NET_NAME' 'devbox-net' 'DEVBOX_NET_NAME')" '用于串联实例与端口代理。')"
  while true; do
    PORT_BASE_DEFAULT="$(ask 'SSH 起始端口 (按 100 递增尝试)' "$(resolve_setting 'PORT_BASE' '30022' 'DEVBOX_PORT_BASE')" '若端口被占用，将自动尝试 +100。')"
    validate_port "$PORT_BASE_DEFAULT" && break
    warn "请输入有效端口号 (1-65535)"
  done
  MAX_TRIES=80
  while true; do
    CNAME_PREFIX="$(ask '实例名前缀' "$(resolve_setting 'CNAME_PREFIX' "$IMAGE_NAME" 'DEVBOX_CNAME_PREFIX')" '最终容器名会附带时间戳。')"
    validate_container_name "${CNAME_PREFIX}-test" && break
    warn "名称格式不符合 Docker 命名规范"
  done
  while true; do
    AUTO_START="$(ask '安装结束后立即创建并启动一个容器？(y/n)' "$(resolve_setting 'AUTO_START' 'n' 'DEVBOX_AUTO_START')" '选择 y 将自动创建首个实例。')"
    validate_yes_no "$AUTO_START" && break
    warn "请输入 y 或 n"
  done
  DEFAULT_TEMPLATE="$(resolve_setting 'DEFAULT_TEMPLATE' 'debian-bookworm' 'DEVBOX_DEFAULT_TEMPLATE')"

  ask_init_adv_limits

  IMAGE="${IMAGE_PREFIX}-${DEFAULT_TEMPLATE}:${IMAGE_TAG}"

  echo
  ui_caption "配置预览："
  printf "   • 工作目录：%s\n" "$(color '1;37' "$WORKDIR")"
  printf "   • 默认模板：%s\n" "$(color '1;37' "$DEFAULT_TEMPLATE")"
  printf "   • 镜像命名：%s\n" "$(color '1;37' "$IMAGE")"
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
  mkdir -p -- "$META_DIR"
  TEMPLATE_ROOT="$WORKDIR/templates"

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

# ========== 模板与 Dockerfile ==========
list_template_dirs() {
  local dir
  [[ -d "$TEMPLATE_ROOT" ]] || return 0
  for dir in "$TEMPLATE_ROOT"/*; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
  done | sort
}

ensure_template_assets() {
  mkdir -p "$TEMPLATE_ROOT"
  local tpl_dir="$TEMPLATE_ROOT/$DEFAULT_TEMPLATE"
  mkdir -p "$tpl_dir"

  if [[ ! -f "$tpl_dir/Dockerfile" ]]; then
    log "生成模板 Dockerfile：$tpl_dir/Dockerfile"
    cat >"$tpl_dir/Dockerfile" <<DOCKERFILE
FROM ${BASE_IMAGE_DEFAULT}
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server zsh \
      zsh-autosuggestions zsh-syntax-highlighting \
      ca-certificates locales sudo \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /usr/bin/zsh dev && usermod -aG sudo dev \
 && printf 'dev ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/dev

RUN mkdir -p /var/run/sshd \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config

USER dev
RUN echo '\
autoload -Uz compinit && compinit\n\
zstyle ":completion:*" menu select\n\
[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh\n\
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\n\
' >> /home/dev/.zshrc

USER root
WORKDIR /home/dev
EXPOSE 22
CMD ["/usr/sbin/sshd","-D"]
DOCKERFILE
  else
    info "检测到现有模板 Dockerfile：$tpl_dir/Dockerfile"
  fi

  if [[ ! -f "$tpl_dir/security_setup.sh" ]]; then
    log "生成默认安全脚本：$tpl_dir/security_setup.sh"
    cat >"$tpl_dir/security_setup.sh" <<'SECURITY'
#!/usr/bin/env bash
set -Eeuo pipefail
MODE="${1:-enable}"

enable() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends fail2ban rsyslog

  install -d -m 0755 /etc/fail2ban
  cat >/etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
backend = auto
findtime = 10m
bantime = 1h
maxretry = 5
[sshd]
enabled = true
logpath = /var/log/auth.log
action = %(action_mwl)s
JAIL

  systemctl --quiet daemon-reload 2>/dev/null || true
  systemctl --quiet enable rsyslog 2>/dev/null || true
  systemctl --quiet restart rsyslog 2>/dev/null || rsyslogd

  if systemctl --quiet enable fail2ban 2>/dev/null; then
    systemctl --quiet restart fail2ban
  else
    service fail2ban restart 2>/dev/null || /etc/init.d/fail2ban restart 2>/dev/null || fail2ban-client -x start
  fi
  fail2ban-client status sshd
}

disable() {
  export DEBIAN_FRONTEND=noninteractive
  fail2ban-client -x stop >/dev/null 2>&1 || true
  apt-get purge -y fail2ban || apt-get remove -y fail2ban
  rm -f /etc/fail2ban/jail.local /var/log/fail2ban.log
}

status() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status sshd || fail2ban-client status
  else
    echo "fail2ban 未安装"
  fi
}

case "$MODE" in
  enable) enable ;;
  disable) disable ;;
  status) status ;;
  *) echo "未知模式: $MODE" >&2; exit 1 ;;
esac
SECURITY
    chmod +x "$tpl_dir/security_setup.sh"
  fi

  if [[ ! -f "$tpl_dir/post_create.sh" ]]; then
    log "生成默认初始化脚本：$tpl_dir/post_create.sh"
    cat >"$tpl_dir/post_create.sh" <<'POSTCREATE'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "[post-create] 初始化常用目录..."
install -d -m 0700 /home/dev/.ssh
chown -R dev:dev /home/dev/.ssh
echo "[post-create] 已准备好 dev 用户 SSH 目录"
POSTCREATE
    chmod +x "$tpl_dir/post_create.sh"
  fi
}

check_template_compatibility() {
  local template="$1"
  local dockerfile="$TEMPLATE_ROOT/$template/Dockerfile"
  [[ -f "$dockerfile" ]] || return 0

  local issues=()
  if ! grep -qiE '^[[:space:]]*EXPOSE[[:space:]]+22\b' "$dockerfile"; then
    issues+=("模板 ${template} 未显式暴露 22 端口，SSH 连接可能失败。")
  fi
  if ! grep -qi 'sshd' "$dockerfile"; then
    issues+=("模板 ${template} 的 Dockerfile 未发现 sshd 配置，请确认容器入口可以启动 SSH 服务。")
  fi
  if ! grep -qiE 'useradd|adduser' "$dockerfile"; then
    issues+=("模板 ${template} 建议创建非 root 用户以便脚本配置凭据。")
  fi

  if ((${#issues[@]} == 0)); then
    log_debug "Template compatibility check passed for ${template}"
    return 0
  fi

  if [[ "${AUTO_MODE:-0}" == "1" ]]; then
    err "自动模式下检测到模板 ${template} 存在以下潜在问题："
    local warn_item
    for warn_item in "${issues[@]}"; do
      ui_caption "  - ${warn_item}"
    done
    ui_caption "请修正 Dockerfile 后重试，或在交互模式下确认继续。"
    exit 1
  fi

  warn "检测到模板 ${template} 可能与 DevBox 管理脚本的默认假设不完全匹配："
  local item
  for item in "${issues[@]}"; do
    ui_caption "  - ${item}"
  done
  ui_caption "若模板使用自定义端口或入口，请在安装后通过 devbox.sh 调整。"
  if ! confirm "继续构建该模板吗？" Y; then
    err "用户取消构建以调整模板"
    exit 1
  fi
  return 0
}

choose_default_template_interactive() {
  local templates=()
  mapfile -t templates < <(list_template_dirs)
  if (( ${#templates[@]} == 0 )); then
    templates+=("$DEFAULT_TEMPLATE")
  fi
  local found=0 t
  for t in "${templates[@]}"; do
    if [[ "$t" == "$DEFAULT_TEMPLATE" ]]; then
      found=1
      break
    fi
  done
  if (( found == 0 )); then
    DEFAULT_TEMPLATE="${templates[0]}"
    return
  fi
  if [[ "$AUTO_MODE" == "1" ]]; then
    return
  fi
  if (( ${#templates[@]} <= 1 )); then
    return
  fi
  ui_title "选择默认模板" "检测到多个可用模板，请选择安装结束后常用的默认模板。"
  local idx=1
  for t in "${templates[@]}"; do
    printf '   %s %s\n' "$(color '1;36' "[$idx]")" "$(color '1;37' "$t")"
    ((idx++))
  done
  printf '%s' "$(color '0;37' '输入编号 → ')"
  local choice
  IFS= read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<idx )); then
    DEFAULT_TEMPLATE="${templates[$((choice-1))]}"
  else
    warn "保持默认模板：$DEFAULT_TEMPLATE"
  fi
}

prepare_templates() {
  TEMPLATE_ROOT="${WORKDIR}/templates"
  ensure_template_assets
  choose_default_template_interactive
  IMAGE="${IMAGE_PREFIX}-${DEFAULT_TEMPLATE}:${IMAGE_TAG}"
}

# ========== 镜像构建 ==========
build_image() {
  local template_dir="$TEMPLATE_ROOT/$DEFAULT_TEMPLATE"
  log "开始构建模板 ${DEFAULT_TEMPLATE} 对应镜像: $IMAGE"
  log_debug "Building image with DOCKER_BUILDKIT=1 from ${template_dir}"
  check_disk_space
  progress "正在构建镜像..."
  if [[ "$AUTO_MODE" == "1" && -n "${DEBUG_LOG:-}" ]]; then
    if DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$template_dir" >>"$DEBUG_LOG" 2>&1; then
      progress_done "镜像构建完成: $IMAGE"
      return 0
    fi
  else
    if DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$template_dir"; then
      progress_done "镜像构建完成: $IMAGE"
      return 0
    fi
  fi

  echo
  err "镜像构建失败"
  info "请检查："
  ui_caption "  1. Dockerfile 语法是否正确"
  ui_caption "  2. 网络连接是否正常"
  ui_caption "  3. Docker 磁盘空间是否充足"
  [[ -f "${DEBUG_LOG:-}" ]] && ui_caption "  详细日志: $DEBUG_LOG"
  exit 1
}

# ========== 管理脚本生成 ==========
write_devbox_script() {
  log "生成管理脚本：$WORKDIR/devbox.sh"
  log_debug "Writing devbox.sh with placeholders"

  cat >"$WORKDIR/devbox.sh" <<'EOF_DEVBOX'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="3.0.0"
IMAGE_PREFIX="__IMAGEPREFIX__"
IMAGE_TAG="__IMAGETAG__"
DEFAULT_TEMPLATE="__DEFAULT_TEMPLATE__"
PORT_BASE_DEFAULT="__PORTBASE__"
MAX_TRIES="__MAXTRIES__"
NET_NAME="__NETNAME__"
CNAME_PREFIX="__CNAMEPREFIX__"
SOCAT_IMAGE="__SOCAT_IMAGE__"
DEBUG="${DEVBOX_DEBUG:-0}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="${WORKDIR}/.devbox"
TEMPLATES_DIR="${WORKDIR}/templates"
CONFIG_FILE="${WORKDIR}/devbox.conf"
mkdir -p "${META_DIR}/instances" "${META_DIR}/forwards"

DEFAULT_MEM="${DEVBOX_MEM:-1g}"
DEFAULT_CPUS="${DEVBOX_CPUS:-1.0}"
DEFAULT_PIDS="${DEVBOX_PIDS:-256}"

color() { local code="$1"; shift; printf '\e[%sm%s\e[0m' "$code" "$*"; }
log() { printf "%b  %s\n" "$(color '1;32' 'OK')" "$*"; }
info() { printf "%b  %s\n" "$(color '1;36' 'INFO')" "$*"; }
warn() { printf "%b  %s\n" "$(color '1;33' 'WARN')" "$*"; }
err() { printf "%b  %s\n" "$(color '1;31' 'ERROR')" "$*"; }

DEBUG_LOG=""
setup_debug() {
  if [[ "$DEBUG" == "1" ]]; then
    DEBUG_LOG="${META_DIR}/debug.log"
    exec 3>>"$DEBUG_LOG"
    printf '[DEBUG %(%T)T] session start\n' -1 >&3
  fi
}
log_debug() { [[ "$DEBUG" == "1" ]] && printf '[DEBUG %(%T)T] %s\n' -1 "$*" >&3 || true; }
setup_debug

declare -A CONFIG_VALUES=()
load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value; do
    key="${key%%#*}"
    key="${key%% }"
    key="${key## }"
    [[ -n "$key" ]] || continue
    value="${value## }"
    value="${value%% }"
    CONFIG_VALUES["$key"]="$value"
  done <"$file"
}
config_get() { local key="$1" def="${2:-}"; [[ -n "${CONFIG_VALUES[$key]+x}" ]] && printf '%s' "${CONFIG_VALUES[$key]}" || printf '%s' "$def"; }
resolve_setting() {
  local key="$1" default_value="$2" env_name="$3"
  local env_value="${!env_name:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return
  fi
  config_get "$key" "$default_value"
}

CONFIG_VALUES=()
load_config_file "$CONFIG_FILE"
IMAGE_PREFIX="$(resolve_setting 'IMAGE_NAME' "$IMAGE_PREFIX" 'DEVBOX_IMAGE_NAME')"
IMAGE_TAG="$(resolve_setting 'IMAGE_TAG' "$IMAGE_TAG" 'DEVBOX_IMAGE_TAG')"
DEFAULT_TEMPLATE="$(resolve_setting 'DEFAULT_TEMPLATE' "$DEFAULT_TEMPLATE" 'DEVBOX_DEFAULT_TEMPLATE')"
PORT_BASE_DEFAULT="$(resolve_setting 'PORT_BASE' "$PORT_BASE_DEFAULT" 'DEVBOX_PORT_BASE')"
NET_NAME="$(resolve_setting 'NET_NAME' "$NET_NAME" 'DEVBOX_NET_NAME')"
CNAME_PREFIX="$(resolve_setting 'CNAME_PREFIX' "$CNAME_PREFIX" 'DEVBOX_CNAME_PREFIX')"
DEFAULT_MEM="$(resolve_setting 'MEM' "$DEFAULT_MEM" 'DEVBOX_MEM')"
DEFAULT_CPUS="$(resolve_setting 'CPUS' "$DEFAULT_CPUS" 'DEVBOX_CPUS')"
DEFAULT_PIDS="$(resolve_setting 'PIDS' "$DEFAULT_PIDS" 'DEVBOX_PIDS')"
SOCAT_IMAGE="$(resolve_setting 'SOCAT_IMAGE' "$SOCAT_IMAGE" 'DEVBOX_SOCAT_IMAGE')"

validate_port() { local port="$1"; [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )); }
validate_container_name() { local name="$1"; [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; }

ensure_network() { docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null; }
port_in_use_host() {
  local hp="$1"
  if timeout 0.2 bash -lc ":</dev/tcp/127.0.0.1/${hp}" 2>/dev/null; then return 0; fi
  if command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":${hp}\\b"; then return 0; fi
  if docker ps --format '{{.Ports}}' | grep -qE "0\.0\.0\.0:${hp}->|:${hp}->"; then return 0; fi
  return 1
}
pick_port() {
  local base="$1" tries="$2" try
  for ((i=0;i<tries;i++)); do
    try=$((base+i*100))
    if ! port_in_use_host "$try"; then
      echo "$try"
      return 0
    fi
  done
  return 1
}

available_templates() {
  local dir
  [[ -d "$TEMPLATES_DIR" ]] || return 0
  for dir in "$TEMPLATES_DIR"/*; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
  done | sort
}
template_path() { echo "$TEMPLATES_DIR/$1"; }
template_exists() { [[ -d "$(template_path "$1")" ]]; }
template_security_script() { local path="$(template_path "$1")/security_setup.sh"; [[ -f "$path" ]] && echo "$path"; }
template_post_create_script() { local path="$(template_path "$1")/post_create.sh"; [[ -f "$path" ]] && echo "$path"; }
default_image_for_template() { echo "${IMAGE_PREFIX}-$1:${IMAGE_TAG}"; }

instance_meta_file() { echo "${META_DIR}/instances/$1.env"; }
forward_meta_file() { echo "${META_DIR}/forwards/$1.map"; }
passfile_of() { echo "${META_DIR}/$1.pass"; }
fail2ban_meta_file() { echo "${META_DIR}/$1.security"; }

load_meta() {
  local file="$1"; declare -gA CURRENT_META=()
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value; do
    key="${key%%#*}"; key="${key%% }"; key="${key## }"
    [[ -z "$key" ]] && continue
    CURRENT_META["$key"]="$value"
  done <"$file"
}
write_meta() {
  local file="$1"; shift
  { for kv in "$@"; do printf '%s\n' "$kv"; done; } >"$file"
}

update_meta() {
  local name="$1"; shift
  local file="$(instance_meta_file "$name")"
  load_meta "$file"
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    CURRENT_META["$key"]="$value"
  done
  local out=()
  for key in "${!CURRENT_META[@]}"; do
    out+=("${key}=${CURRENT_META[$key]}")
  done
  write_meta "$file" "${out[@]}"
}

exists_container() { docker ps -a --format '{{.Names}}' | grep -Fqx -- "$1"; }
running_container() { docker ps --format '{{.Names}}' | grep -Fqx -- "$1"; }

wait_sshd_ready() {
  local cname="$1" port="$2"
  info "等待 SSH 服务就绪 (容器: $cname, 端口: $port)"
  for _ in {1..60}; do
    if timeout 0.3 bash -lc ":</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      if docker exec -u root "$cname" bash -lc "pgrep -x sshd >/dev/null" 2>/dev/null; then
        log "SSHD 已就绪"
        return 0
      fi
    fi
    sleep 0.5
  done
  warn "SSHD 未在预期时间内响应"
  return 1
}

set_random_password() {
  local cname="$1" pfile="$(passfile_of "$cname")"
  local newpass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || echo "Dev$(date +%s)")"
  if docker exec -u root "$cname" bash -lc "echo 'dev:${newpass}' | chpasswd" 2>/dev/null; then
    echo "$newpass" >"$pfile"
    chmod 0600 "$pfile"
    log "已更新 dev 用户密码：${newpass}"
    info "密码保存在 .devbox/$(basename "$pfile")"
  else
    warn "设置密码失败，可稍后手动执行 docker exec -u root $cname bash -lc \"echo 'dev:<新密码>' | chpasswd\""
  fi
}

run_template_hook() {
  local cname="$1" template="$2" script_path="$3" action="$4"
  local script="$(template_path "$template")/$script_path"
  if [[ ! -f "$script" ]]; then
    warn "模板 ${template} 未提供 ${script_path}"
    return 1
  fi
  local tmp_file="/tmp/devbox_${script_path}"
  docker cp "$script" "$cname:$tmp_file"
  docker exec -u root "$cname" bash "$tmp_file" "$action"
  docker exec -u root "$cname" rm -f "$tmp_file" >/dev/null 2>&1 || true
  return 0
}

apply_security() {
  local cname="$1" template="$2" mode="${3:-enable}"
  if run_template_hook "$cname" "$template" security_setup.sh "$mode"; then
    case "$mode" in
      enable) log "已在 ${cname} 中执行安全脚本 (模式: ${mode})" ;; 
      disable) log "已在 ${cname} 中禁用安全脚本" ;; 
      status) ;; 
    esac
    return 0
  fi
  return 1
}

post_create() {
  local cname="$1" template="$2"
  run_template_hook "$cname" "$template" post_create.sh "run" || true
}

sync_forward_proxy() {
  local cname="$1" meta_file="$(forward_meta_file "$cname")" proxy_name="devbox-proxy-${cname}"
  docker rm -f "$proxy_name" >/dev/null 2>&1 || true
  [[ -f "$meta_file" ]] || return 0
  local script=""
  while IFS=':' read -r bind host_port container_port; do
    [[ -n "$host_port" ]] || continue
    script+="socat -dd TCP-LISTEN:${host_port},fork,reuseaddr,bind=${bind:-0.0.0.0} TCP:${cname}:${container_port} &\n"
  done <"$meta_file"
  script+="wait"
  docker run -d --name "$proxy_name" --network "$NET_NAME" --restart unless-stopped --security-opt no-new-privileges "$SOCAT_IMAGE" sh -c "$script" >/dev/null
}

forward_add() {
  local cname="$1" host_port="$2" container_port="$3" bind_addr="${4:-127.0.0.1}"
  if ! validate_port "$host_port" || ! validate_port "$container_port"; then
    err "端口号无效"
    return 1
  fi
  if port_in_use_host "$host_port"; then
    err "宿主机端口 ${host_port} 已被占用"
    return 1
  fi
  local meta_file="$(forward_meta_file "$cname")"
  printf '%s:%s:%s\n' "$bind_addr" "$host_port" "$container_port" >>"$meta_file"
  sync_forward_proxy "$cname"
  log "已添加映射 ${bind_addr}:${host_port} → ${cname}:${container_port}"
}

forward_remove() {
  local cname="$1" host_port="$2" container_port="$3" bind_addr="${4:-127.0.0.1}"
  local meta_file="$(forward_meta_file "$cname")"
  [[ -f "$meta_file" ]] || { warn "未记录端口映射"; return 0; }
  awk -F':' -v b="$bind_addr" -v hp="$host_port" -v cp="$container_port" '$1!=b || $2!=hp || $3!=cp' "$meta_file" >"${meta_file}.tmp"
  mv "${meta_file}.tmp" "$meta_file"
  [[ -s "$meta_file" ]] || rm -f "$meta_file"
  sync_forward_proxy "$cname"
  log "已删除映射 ${bind_addr}:${host_port}"
}

forward_list() {
  local cname="$1" meta_file="$(forward_meta_file "$cname")"
  if [[ ! -f "$meta_file" ]]; then
    info "无端口映射"
    return
  fi
  printf '%-16s %-10s %-10s\n' '绑定地址' '主机端口' '容器端口'
  while IFS=':' read -r bind host_port container_port; do
    printf '%-16s %-10s %-10s\n' "$bind" "$host_port" "$container_port"
  done <"$meta_file"
}

start_instance() {
  local cname="$1" template_opt="$2" image_opt="$3" port_base_opt="$4" security_flag="$5" mem_opt="$6" cpus_opt="$7" pids_opt="$8"
  if exists_container "$cname"; then
    if running_container "$cname"; then
      warn "容器 ${cname} 已在运行"
      return 0
    fi
    info "启动已存在的容器 ${cname}"
    docker start "$cname" >/dev/null
    docker network connect "$NET_NAME" "$cname" >/dev/null 2>&1 || true
    local port
    port="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{(index . 0).HostPort}}{{end}}' "$cname" 2>/dev/null || true)"
    wait_sshd_ready "$cname" "$port" || true
    set_random_password "$cname" || true
    load_meta "$(instance_meta_file "$cname")"
    if [[ "${CURRENT_META[security]:-}" == "enabled" ]]; then
      apply_security "$cname" "${CURRENT_META[template]:-$DEFAULT_TEMPLATE}" status || true
    fi
    return 0
  fi

  local template="${template_opt:-$DEFAULT_TEMPLATE}"
  template_exists "$template" || { err "模板不存在：$template"; return 1; }
  local image="${image_opt:-$(default_image_for_template "$template")}";
  local port_base="${port_base_opt:-$PORT_BASE_DEFAULT}"
  validate_port "$port_base" || { err "端口起始值无效"; return 1; }
  local memory="${mem_opt:-$DEFAULT_MEM}"
  local cpus="${cpus_opt:-$DEFAULT_CPUS}"
  local pids="${pids_opt:-$DEFAULT_PIDS}"

  ensure_network
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "镜像 ${image} 不存在，尝试自动构建..."
    DOCKER_BUILDKIT=1 docker build -t "$image" "$(template_path "$template")"
  fi
  local port
  port="$(pick_port "$port_base" "$MAX_TRIES")" || { err "未找到可用端口"; return 1; }

  info "创建容器 ${cname} (模板: ${template}, 镜像: ${image}, 主机端口: ${port})"
  docker run -d --name "$cname" \
    --network "$NET_NAME" \
    --restart unless-stopped \
    --memory "$memory" --cpus "$cpus" --pids-limit "$pids" \
    --security-opt no-new-privileges \
    -l devbox.managed=true -l devbox.template="$template" \
    -p "${port}:22" "$image" /usr/sbin/sshd -D >/dev/null
  wait_sshd_ready "$cname" "$port" || true
  set_random_password "$cname" || true
  post_create "$cname" "$template"
  local security_state="disabled"
  if [[ "$security_flag" == "1" ]]; then
    if apply_security "$cname" "$template" enable; then
      touch "$(fail2ban_meta_file "$cname")"
      security_state="enabled"
    fi
  elif [[ -f "$(fail2ban_meta_file "$cname")" ]]; then
    security_state="enabled"
  fi
  write_meta "$(instance_meta_file "$cname")" \
    "template=$template" \
    "image=$image" \
    "port=$port" \
    "memory=$memory" \
    "cpus=$cpus" \
    "pids=$pids" \
    "created=$(date -u +%FT%TZ)" \
    "security=$security_state"
  info "SSH 示例：ssh dev@<服务器IP> -p ${port}"
}

stop_instance() {
  local cname="$1"
  if running_container "$cname"; then
    docker stop "$cname" >/dev/null
    log "已停止容器 ${cname}"
  else
    warn "容器 ${cname} 未在运行"
  fi
}

remove_instance() {
  local cname="$1"
  docker rm -f "$cname" >/dev/null 2>&1 || warn "容器不存在：$cname"
  rm -f "$(instance_meta_file "$cname")" "$(passfile_of "$cname")" "$(forward_meta_file "$cname")" "$(fail2ban_meta_file "$cname")"
  docker rm -f "devbox-proxy-${cname}" >/dev/null 2>&1 || true
  log "已清理实例 ${cname} 的记录"
}

instance_status() {
  local cname="$1"
  if ! exists_container "$cname"; then
    err "容器不存在：$cname"
    return 1
  fi
  docker ps -a --filter "name=^${cname}$" --format '名称: {{.Names}}\n状态: {{.Status}}\n镜像: {{.Image}}\n端口: {{.Ports}}'
}

rotate_password() {
  local cname="$1"
  running_container "$cname" || { err "容器未运行"; return 1; }
  set_random_password "$cname"
}

ssh_key_add() {
  local cname="$1" key_file="$2" disable_pw="$3"
  running_container "$cname" || { err "容器未运行"; return 1; }
  if [[ -z "$key_file" ]]; then
    key_file="$HOME/.ssh/id_rsa.pub"
  fi
  [[ -f "$key_file" ]] || { err "公钥文件不存在：$key_file"; return 1; }
  local key_content
  key_content="$(cat "$key_file")"
  if [[ -z "$key_content" ]]; then
    err "公钥文件为空"
    return 1
  fi
  docker exec -u root "$cname" bash -lc 'install -d -m 700 /home/dev/.ssh && touch /home/dev/.ssh/authorized_keys && chmod 600 /home/dev/.ssh/authorized_keys && chown -R dev:dev /home/dev/.ssh'
  docker exec -i "$cname" bash -lc 'cat >> /home/dev/.ssh/authorized_keys' <<<"$key_content"
  log "已追加 SSH 公钥"
  if [[ "$disable_pw" == "1" ]]; then
    docker exec -u root "$cname" bash -lc "sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && pkill -HUP sshd"
    log "已禁用密码登录"
  fi
}

fail2ban_enable() {
  local cname="$1"; load_meta "$(instance_meta_file "$cname")"
  local template="${CURRENT_META[template]:-$DEFAULT_TEMPLATE}"
  running_container "$cname" || { err "容器未运行"; return 1; }
  if apply_security "$cname" "$template" enable; then
    touch "$(fail2ban_meta_file "$cname")"
    update_meta "$cname" "security=enabled"
  fi
}
fail2ban_disable() {
  local cname="$1"; load_meta "$(instance_meta_file "$cname")"
  local template="${CURRENT_META[template]:-$DEFAULT_TEMPLATE}"
  running_container "$cname" || { err "容器未运行"; return 1; }
  apply_security "$cname" "$template" disable && { rm -f "$(fail2ban_meta_file "$cname")"; update_meta "$cname" "security=disabled"; }
}
fail2ban_status() {
  local cname="$1"; load_meta "$(instance_meta_file "$cname")"
  local template="${CURRENT_META[template]:-$DEFAULT_TEMPLATE}"
  running_container "$cname" || { err "容器未运行"; return 1; }
  apply_security "$cname" "$template" status || true
}

list_instances() {
  docker ps -a --filter "label=devbox.managed=true" --format '名称: {{.Names}}\n状态: {{.Status}}\n模板: {{.Labels}}\n---'
}

usage() {
  cat <<'HELP'
DevBox 管理工具 v3.0.0

用法:
  ./devbox.sh               # 打开交互式菜单
  ./devbox.sh cli <命令>    # 使用命令行子命令

常用命令:
  cli image build [--template 名称]
  cli instance start <名称> [--template 名称] [--image 镜像] [--port-base 端口] [--enable-fail2ban] [--memory 值] [--cpus 值] [--pids 值]
  cli instance stop <名称>
  cli instance remove <名称>
  cli instance status <名称>
  cli instance password <名称>
  cli instance ssh-key add <名称> [公钥路径] [--disable-password]
  cli fail2ban enable|disable|status <名称>
  cli forward add|remove|list <名称> ...
  cli status
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

cli_image() {
  local action="$1"; shift
  local template="$DEFAULT_TEMPLATE"
  while (($#)); do
    case "$1" in
      --template) template="$2"; shift 2;;
      --) shift; break;;
      *) err "未知参数: $1"; return 1;;
    esac
  done
  template_exists "$template" || { err "模板不存在：$template"; return 1; }
  local image="$(default_image_for_template "$template")"
  case "$action" in
    build)
      info "构建模板 ${template} → 镜像 ${image}"
      DOCKER_BUILDKIT=1 docker build -t "$image" "$(template_path "$template")"
      ;;
    rebuild)
      info "强制重建模板 ${template} → 镜像 ${image}"
      DOCKER_BUILDKIT=1 docker build --no-cache -t "$image" "$(template_path "$template")"
      ;;
    *) err "未知 image 子命令"; return 1;;
  esac
}

cli_instance() {
  local action="$1"; shift
  case "$action" in
    start)
      local name="$1"; shift || true
      local template="" image="" port_base="" mem="" cpus="" pids="" security=0
      while (($#)); do
        case "$1" in
          --template) template="$2"; shift 2;;
          --image) image="$2"; shift 2;;
          --port-base) port_base="$2"; shift 2;;
          --memory) mem="$2"; shift 2;;
          --cpus) cpus="$2"; shift 2;;
          --pids) pids="$2"; shift 2;;
          --enable-fail2ban|--enable-security) security=1; shift;;
          --) shift; break;;
          *) err "未知参数: $1"; return 1;;
        esac
      done
      [[ -n "$name" ]] || { err "需提供实例名称"; return 1; }
      validate_container_name "$name" || { err "实例名称不合法"; return 1; }
      start_instance "$name" "$template" "$image" "$port_base" "$security" "$mem" "$cpus" "$pids"
      ;;
    stop)
      [[ -n "${1:-}" ]] || { err "需提供实例名称"; return 1; }
      stop_instance "$1"
      ;;
    remove)
      [[ -n "${1:-}" ]] || { err "需提供实例名称"; return 1; }
      remove_instance "$1"
      ;;
    status)
      [[ -n "${1:-}" ]] || { err "需提供实例名称"; return 1; }
      instance_status "$1"
      ;;
    password)
      [[ -n "${1:-}" ]] || { err "需提供实例名称"; return 1; }
      rotate_password "$1"
      ;;
    ssh-key)
      case "${1:-}" in
        add)
          shift || true
          local name="$1"; shift || true
          local key_path="" disable_pw=0
          while (($#)); do
            case "$1" in
              --disable-password) disable_pw=1; shift;;
              *) key_path="$1"; shift;;
            esac
          done
          [[ -n "$name" ]] || { err "需提供实例名称"; return 1; }
          ssh_key_add "$name" "$key_path" "$disable_pw"
          ;;
        *) err "未知 ssh-key 子命令"; return 1;;
      esac
      ;;
    *) err "未知 instance 子命令"; return 1;;
  esac
}

cli_fail2ban() {
  local action="$1"; shift
  [[ -n "${1:-}" ]] || { err "需提供实例名称"; return 1; }
  case "$action" in
    enable) fail2ban_enable "$1" ;;
    disable) fail2ban_disable "$1" ;;
    status) fail2ban_status "$1" ;;
    *) err "未知 fail2ban 子命令"; return 1;;
  esac
}

cli_forward() {
  local action="$1"; shift
  case "$action" in
    add)
      forward_add "$1" "$2" "$3" "${4:-127.0.0.1}"
      ;;
    remove)
      forward_remove "$1" "$2" "$3" "${4:-127.0.0.1}"
      ;;
    list)
      forward_list "$1"
      ;;
    *) err "未知 forward 子命令"; return 1;;
  esac
}

cli_status() {
  list_instances
}

if [[ "${1:-}" == "cli" ]]; then
  shift
  case "${1:-}" in
    image) shift; cli_image "$1" "${@:2}" ;;
    instance) shift; cli_instance "$1" "${@:2}" ;;
    fail2ban) shift; cli_fail2ban "$1" "${@:2}" ;;
    forward) shift; cli_forward "$1" "${@:2}" ;;
    status) shift; cli_status ;;
    *) usage; exit 1;;
  esac
  exit 0
fi

main_menu() {
  while true; do
    echo
    printf '%s\n' "$(color '1;37' 'DevBox 控制台 (交互模式)')"
    printf '  %s 启动/创建实例\n' "$(color '1;36' '[1]')"
    printf '  %s 停止实例\n' "$(color '1;36' '[2]')"
    printf '  %s 查看实例状态\n' "$(color '1;36' '[3]')"
    printf '  %s 管理端口映射\n' "$(color '1;36' '[4]')"
    printf '  %s 安全脚本 (Fail2ban 等)\n' "$(color '1;36' '[5]')"
    printf '  %s 管理 SSH 密钥\n' "$(color '1;36' '[6]')"
    printf '  %s 退出\n' "$(color '1;36' '[0]')"
    printf '选择 → '
    local choice
    IFS= read -r choice
    case "$choice" in
      1)
        local templates_list="$(available_templates | tr '\n' ' ')"
        [[ -n "$templates_list" ]] && printf '可用模板：%s\n' "$templates_list"
        printf '实例名称 (默认: %s) → ' "${CNAME_PREFIX}-$(date +%H%M%S)"
        local name
        IFS= read -r name
        name="${name:-${CNAME_PREFIX}-$(date +%H%M%S)}"
        printf '选择模板 (默认: %s) → ' "$DEFAULT_TEMPLATE"
        local template
        IFS= read -r template
        template="${template:-$DEFAULT_TEMPLATE}"
        if [[ -z "$template" || ! -d "$(template_path "$template")" ]]; then
          warn "模板不存在，改用默认模板 $DEFAULT_TEMPLATE"
          template="$DEFAULT_TEMPLATE"
        fi
        printf '内存限制 (默认 %s) → ' "$DEFAULT_MEM"
        local mem
        IFS= read -r mem
        mem="${mem:-$DEFAULT_MEM}"
        printf 'CPU 限制 (默认 %s) → ' "$DEFAULT_CPUS"
        local cpus
        IFS= read -r cpus
        cpus="${cpus:-$DEFAULT_CPUS}"
        printf 'PIDs 限制 (默认 %s) → ' "$DEFAULT_PIDS"
        local pids
        IFS= read -r pids
        pids="${pids:-$DEFAULT_PIDS}"
        printf '是否启用安全脚本? (y/N) → '
        local sec
        IFS= read -r sec
        local security_flag=0
        [[ "$sec" =~ ^[Yy]$ ]] && security_flag=1
        start_instance "$name" "$template" "" "$PORT_BASE_DEFAULT" "$security_flag" "$mem" "$cpus" "$pids"
        ;;
      2)
        printf '实例名称 → '
        local name
        IFS= read -r name
        stop_instance "$name"
        ;;
      3)
        printf '实例名称 → '
        local name
        IFS= read -r name
        instance_status "$name"
        ;;
      4)
        printf '实例名称 → '
        local name
        IFS= read -r name
        printf '操作: [a]添加 [r]移除 [l]查看 → '
        local op
        IFS= read -r op
        case "$op" in
          a|A)
            printf '绑定地址 (默认 127.0.0.1) → '
            local bind
            IFS= read -r bind
            bind="${bind:-127.0.0.1}"
            printf '主机端口 → '
            local hp
            IFS= read -r hp
            printf '容器端口 → '
            local cp
            IFS= read -r cp
            forward_add "$name" "$hp" "$cp" "$bind"
            ;;
          r|R)
            printf '绑定地址 (默认 127.0.0.1) → '
            local bind
            IFS= read -r bind
            bind="${bind:-127.0.0.1}"
            printf '主机端口 → '
            local hp
            IFS= read -r hp
            printf '容器端口 → '
            local cp
            IFS= read -r cp
            forward_remove "$name" "$hp" "$cp" "$bind"
            ;;
          l|L)
            forward_list "$name"
            ;;
          *) warn "未知操作";;
        esac
        ;;
      5)
        printf '实例名称 → '
        local name
        IFS= read -r name
        printf '操作: [e]启用 [d]禁用 [s]查看状态 → '
        local op
        IFS= read -r op
        case "$op" in
          e|E) fail2ban_enable "$name" ;;
          d|D) fail2ban_disable "$name" ;;
          s|S) fail2ban_status "$name" ;;
          *) warn "未知操作" ;;
        esac
        ;;
      6)
        printf '实例名称 → '
        local name
        IFS= read -r name
        printf '公钥路径 (默认 ~/.ssh/id_rsa.pub) → '
        local path
        IFS= read -r path
        printf '是否禁用密码登录? (y/N) → '
        local op
        IFS= read -r op
        ssh_key_add "$name" "$path" $([[ "$op" =~ ^[Yy]$ ]] && echo 1 || echo 0)
        ;;
      0) exit 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}

main_menu

EOF_DEVBOX

  # 一次性替换占位符
  sed -i \
    -e "s|__IMAGEPREFIX__|$IMAGE_PREFIX|g" \
    -e "s|__IMAGETAG__|$IMAGE_TAG|g" \
    -e "s|__DEFAULT_TEMPLATE__|$DEFAULT_TEMPLATE|g" \
    -e "s|__PORTBASE__|$PORT_BASE_DEFAULT|g" \
    -e "s|__MAXTRIES__|$MAX_TRIES|g" \
    -e "s|__NETNAME__|$NET_NAME|g" \
    -e "s|__CNAMEPREFIX__|$CNAME_PREFIX|g" \
    -e "s|__SOCAT_IMAGE__|$SOCAT_IMAGE_PINNED|g" \
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
    -l devbox.managed=true -l devbox.name="$cname" -l devbox.image="$image" -l devbox.template="$DEFAULT_TEMPLATE" \
    -l devbox.created="$(date -u +%FT%TZ)" -l devbox.port="$port" \
    -p "${port}:22" "$image" /usr/sbin/sshd -D >/dev/null
  wait_sshd_ready_installer "$cname" "$port" || true
  ensure_home_perm_installer "$cname"
  set_random_password_installer "$cname" || true
  local post_script="$TEMPLATE_ROOT/$DEFAULT_TEMPLATE/post_create.sh"
  if [[ -f "$post_script" ]]; then
    docker cp "$post_script" "$cname:/tmp/devbox_post_create.sh" >/dev/null 2>&1 || true
    docker exec -u root "$cname" bash "/tmp/devbox_post_create.sh" run >/dev/null 2>&1 || true
    docker exec -u root "$cname" rm -f /tmp/devbox_post_create.sh >/dev/null 2>&1 || true
  fi

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

  local work_backup="${WORKDIR:-}" meta_backup="${META_DIR:-}" debug_backup="${DEBUG_LOG:-}" tpl_backup="${TEMPLATE_ROOT:-}" default_tpl_backup="${DEFAULT_TEMPLATE:-}" image_prefix_backup="${IMAGE_PREFIX:-}" image_tag_backup="${IMAGE_TAG:-}" tmp_work
  tmp_work="${tmpdir}/work"
  mkdir -p "$tmp_work"
  WORKDIR="$tmp_work"
  META_DIR="$tmp_work/.devbox"
  TEMPLATE_ROOT="$WORKDIR/templates"
  DEFAULT_TEMPLATE="selftest"
  IMAGE_PREFIX="selftest"
  IMAGE_TAG="ci"
  DEBUG_LOG=""

  expect_success "ensure_template_assets 创建模板" ensure_template_assets
  expect_equals "默认模板 Dockerfile 已生成" "1" "$( [[ -f "$TEMPLATE_ROOT/$DEFAULT_TEMPLATE/Dockerfile" ]] && echo 1 || echo 0 )"
  expect_success "check_template_compatibility 默认模板通过" check_template_compatibility "$DEFAULT_TEMPLATE"
  echo "FROM scratch" >"$TEMPLATE_ROOT/$DEFAULT_TEMPLATE/Dockerfile"
  ensure_template_assets
  expect_equals "已有 Dockerfile 未被覆盖" "FROM scratch" "$(head -n1 "$TEMPLATE_ROOT/$DEFAULT_TEMPLATE/Dockerfile")"

  WORKDIR="$work_backup"
  META_DIR="$meta_backup"
  TEMPLATE_ROOT="$tpl_backup"
  DEFAULT_TEMPLATE="$default_tpl_backup"
  IMAGE_PREFIX="$image_prefix_backup"
  IMAGE_TAG="$image_tag_backup"
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
  prepare_templates
  check_template_compatibility "$DEFAULT_TEMPLATE"
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
