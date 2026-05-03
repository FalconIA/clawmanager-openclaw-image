#!/usr/bin/env bash
# 构建 Dockerfile.openclaw.cn 并推送到 Docker Registry 私服
# 用法：
#   ./docker-build-push.sh                   # 自动读取 VERSION 末行
#   ./docker-build-push.sh v2026.4.15        # 手动指定版本标签
#   DOCKER_USER=admin ./docker-build-push.sh # 覆盖默认用户名

set -euo pipefail

# ── 配置区 ────────────────────────────────────────────────────────────────────
DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"
DOCKER_PROJECT="${DOCKER_PROJECT:-falconia}"
IMAGE_NAME="${IMAGE_NAME:-clawmanager-openclaw-image}"

DOCKER_USER="${DOCKER_USER:-falconia}"
# 密码优先从环境变量读取，避免明文写在脚本里
# 若未设置，会在 docker login 时提示输入
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"

# 多架构（注释掉改回单架构 linux/amd64）
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.openclaw.cn"
BUILD_CONTEXT="${SCRIPT_DIR}"
# ─────────────────────────────────────────────────────────────────────────────

# ── 版本标签解析（优先级与 CI workflow 一致）────────────────────────────────
if [ $# -ge 1 ] && [ -n "$1" ]; then
  VERSION="$1"
elif [ -f "${SCRIPT_DIR}/VERSION" ]; then
  VERSION_LINE="$(grep -v '^[[:space:]]*#' "${SCRIPT_DIR}/VERSION" \
    | sed '/^[[:space:]]*$/d' \
    | tail -n1 \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -n "${VERSION_LINE}" ]; then
    VERSION="${VERSION_LINE}"
  else
    SHORT="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "local")"
    BRANCH="$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    VERSION="${BRANCH}-${SHORT}"
  fi
else
  SHORT="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "local")"
  BRANCH="$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  VERSION="${BRANCH}-${SHORT}"
fi

FULL_IMAGE="${DOCKER_REGISTRY}/${DOCKER_PROJECT}/${IMAGE_NAME}"

echo "========================================="
echo "  Registry : ${DOCKER_REGISTRY}"
echo "  Image    : ${FULL_IMAGE}"
echo "  Tags     : latest, ${VERSION}"
echo "  Platforms: ${PLATFORMS}"
echo "========================================="

# ── Docker 登录 ──────────────────────────────────────────────────────────────
echo "[1/3] Logging in to Docker Registry..."
# Docker Registry 默认使用 HTTP，需要确保 /etc/docker/daemon.json 里已配置 insecure-registries
if [ -n "${DOCKER_PASSWORD}" ]; then
  echo "${DOCKER_PASSWORD}" | docker login "${DOCKER_REGISTRY}" \
    --username "${DOCKER_USER}" --password-stdin
else
  docker login "${DOCKER_REGISTRY}" --username "${DOCKER_USER}"
fi

# ── 确保 Buildx builder 支持多架构 ──────────────────────────────────────────
echo "[2/3] Setting up Buildx builder..."
BUILDER_NAME="multi-arch-builder"
if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
else
  docker buildx use "${BUILDER_NAME}"
fi
docker buildx inspect --bootstrap

# ── 构建 & 推送 ──────────────────────────────────────────────────────────────
echo "[3/3] Building and pushing..."
docker buildx build \
  --progress auto \
  --platform "${PLATFORMS}" \
  --file "${DOCKERFILE}" \
  --tag "${FULL_IMAGE}:latest" \
  --tag "${FULL_IMAGE}:${VERSION}" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.source=local" \
  --cache-from "type=registry,ref=${FULL_IMAGE}:buildcache" \
  --cache-to   "type=registry,ref=${FULL_IMAGE}:buildcache,mode=max" \
  --push \
  "${BUILD_CONTEXT}"

echo ""
echo "Done! Pushed:"
echo "  ${FULL_IMAGE}:latest"
echo "  ${FULL_IMAGE}:${VERSION}"
