#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$ROOT_DIR"

bash install_devbox.sh --self-test

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    cleanup() {
      if command -v docker >/dev/null 2>&1; then
        local __devbox_ci_names=()
        mapfile -t __devbox_ci_names < <(docker ps -a --format '{{.Names}}' | grep '^devbox-ci' || true)
        if ((${#__devbox_ci_names[@]} > 0)); then
          docker rm -f "${__devbox_ci_names[@]}" >/dev/null 2>&1 || true
        fi
        docker network rm devbox-ci-net >/dev/null 2>&1 || true
        docker image rm devbox-ci:test >/dev/null 2>&1 || true
      fi
      rm -rf "$tmpdir"
    }
    trap cleanup EXIT
    DEVBOX_WORKDIR="$tmpdir/work" \
    DEVBOX_IMAGE_NAME="devbox-ci" \
    DEVBOX_IMAGE_TAG="test" \
    DEVBOX_NET_NAME="devbox-ci-net" \
    DEVBOX_PORT_BASE=36022 \
    DEVBOX_CNAME_PREFIX="devbox-ci" \
    DEVBOX_AUTO_START="n" \
    DEVBOX_AUTO=1 \
      bash install_devbox.sh --auto

    pushd "$tmpdir/work" >/dev/null
    ./devbox.sh cli image build "devbox-ci:test"
    ./devbox.sh cli instance start devbox-ci --image devbox-ci:test --port-base 36022 --enable-fail2ban
    ./devbox.sh cli instance status devbox-ci
    ./devbox.sh cli fail2ban status devbox-ci
    ./devbox.sh cli instance password devbox-ci
    if [[ ! -f .devbox/devbox-ci.pass ]]; then
      echo "[ERROR] 未生成密码文件" >&2
      exit 1
    fi
    ./devbox.sh cli forward add devbox-ci 36080 8080
    ./devbox.sh cli forward list devbox-ci
    ./devbox.sh cli forward remove devbox-ci 36080 8080
    ./devbox.sh cli fail2ban disable devbox-ci
    ./devbox.sh cli status
    ./devbox.sh cli instance stop devbox-ci
    ./devbox.sh cli instance remove devbox-ci
    popd >/dev/null
  else
    echo "[WARN] Docker 守护进程不可用，跳过集成测试。" >&2
  fi
else
  echo "[WARN] 未检测到 docker CLI，跳过集成测试。" >&2
fi
