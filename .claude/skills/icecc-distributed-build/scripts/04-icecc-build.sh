#!/usr/bin/env bash
# 把 icecc 接到一次具体的构建上:设好必需的环境变量,跑调用方给的构建命令,
# 构建完打印"分发报告"(多少个任务真被发到了办公机),并列出新产出的 .so/.a。
#
# 必需的环境变量(这是本 skill 全部教训的浓缩,少一个都会静默退化 —— 不会报错,
# 只是全部偷偷在 dev host 本地编完,产物看起来完全正常。见 SKILL.md 故障排查表):
#   ENV_TAR (必需)         — 02-create-toolchain-env.sh 产出的 env tarball
#   ICECC_CC / ICECC_CXX   — 交叉编译时必须指到真实编译器绝对路径(本机编译可不设)
#   ICECC_PREFIX           — icecc 客户端安装位置,默认 $HOME/icecc-prefix
#
# 脚本内部固定设置(不需要调用方操心,但必须懂为什么):
#   ICECC_TEST_REMOTEBUILD=1 — 没有它,反向隧道场景下 icecc 客户端会把 scheduler
#     报出来的 "127.0.0.1:<真实端口>" 当成"scheduler 让我自己编译",100% 本地。
#     (根因见 icecc 源码 client/remote.cpp 的 maybe_build_local())
#
# 用法:
#   ENV_TAR=.../icecc-env-full/xxx.tar.zst \
#   ICECC_CC=/path/to/clang ICECC_CXX=/path/to/clang++ \
#   ./04-icecc-build.sh <build_dir> -- <build_command...>
#
# 例(已用 -DCMAKE_C_COMPILER_LAUNCHER=icecc -DCMAKE_CXX_COMPILER_LAUNCHER=icecc 配置好的 Ninja 工程):
#   ENV_TAR=./icecc-env-full/xxx.tar.zst \
#   ICECC_CC=$NDK/bin/clang ICECC_CXX=$NDK/bin/clang++ \
#   ./04-icecc-build.sh build-android-arm64 -- ninja -k 0 -j 24
set -uo pipefail

ENV_TAR="${ENV_TAR:?必须设置 ENV_TAR}"
ICECC_PREFIX="${ICECC_PREFIX:-$HOME/icecc-prefix}"
ICECC_CC="${ICECC_CC:-}"
ICECC_CXX="${ICECC_CXX:-}"

BUILD_DIR="${1:-}"
[ -n "$BUILD_DIR" ] || { echo "用法: $0 <build_dir> -- <build_command...>"; exit 1; }
shift
[ "${1:-}" = "--" ] || { echo "用法: $0 <build_dir> -- <build_command...>"; exit 1; }
shift
[ "$#" -ge 1 ] || { echo "没给构建命令"; exit 1; }
[ -d "$BUILD_DIR" ] || { echo "构建目录不存在: $BUILD_DIR"; exit 1; }
[ -f "$ENV_TAR" ] || { echo "env tarball 不存在: $ENV_TAR"; exit 1; }

ICECC_LOG="$BUILD_DIR/.icecc-debug.log"
BUILD_LOG="$BUILD_DIR/.build.log"
MARKER="$BUILD_DIR/.icecc-build-marker"

export PATH="$ICECC_PREFIX/usr/bin:$PATH"
export ICECC_VERSION="$ENV_TAR"
[ -n "$ICECC_CC" ] && export ICECC_CC
[ -n "$ICECC_CXX" ] && export ICECC_CXX
export ICECC_DEBUG=debug
export ICECC_LOGFILE="$ICECC_LOG"
export ICECC_TEST_REMOTEBUILD=1

echo "=== preflight ==="
command -v icecc >/dev/null 2>&1 && echo "  icecc 客户端: $(command -v icecc)" || { echo "  找不到 icecc 客户端(检查 ICECC_PREFIX/PATH)"; exit 1; }
echo "  ICECC_VERSION=$ICECC_VERSION"
echo "  ICECC_TEST_REMOTEBUILD=$ICECC_TEST_REMOTEBUILD"
: > "$ICECC_LOG"
touch "$MARKER"

echo ""
echo "=== 构建开始: $* (于 $BUILD_DIR) ==="
( cd "$BUILD_DIR" && "$@" ) > "$BUILD_LOG" 2>&1
build_rc=$?
echo "=== 构建结束,退出码=$build_rc (完整日志: $BUILD_LOG) ==="
[ "$build_rc" -ne 0 ] && tail -40 "$BUILD_LOG"

echo ""
echo "=== 分发报告 ==="
awk '
  /^ICECC\[[0-9]+\]/ {
    pid=$1; sub(/^ICECC\[/,"",pid); sub(/\].*/,"",pid)
    if ($0 ~ /Have to use host/) remote[pid]=1
    if ($0 ~ /building myself/) local[pid]=1
    seen[pid]=1
  }
  END {
    r=0; l=0; u=0
    for (p in seen) { if (remote[p]) r++; else if (local[p]) l++; else u++ }
    total=r+l
    printf "  远程(办公机): %d\n  本地(dev host): %d\n  未分类日志片段: %d\n", r, l, u
    if (total>0) printf "  分发率: %.1f%%\n", r*100.0/total
    if (l>0) print "  !! 有本地回退 —— 见 SKILL.md 故障排查表(通常是 submitter 的 -m 没设成 0,或节点瞬时被判不合格)"
  }' "$ICECC_LOG"

echo "  --- 用到的节点 ---"
grep -o 'Have to use host [0-9.]*:[0-9]*' "$ICECC_LOG" 2>/dev/null | sort | uniq -c

echo ""
echo "=== 产物(本次构建新产出的 .so / .a) ==="
find "$BUILD_DIR" -type f \( -name '*.so' -o -name '*.a' \) -newer "$MARKER" 2>/dev/null | while read -r f; do
    printf "  %10s  %s\n" "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"
done
rm -f "$MARKER"

exit "$build_rc"
