#!/usr/bin/env bash
# 确保 icecc 二进制在 $ICECC_PREFIX 下可用。两条路径都试:
#   1) apt 装系统包(需要 root,最快)
#   2) 源码编译安装到本地前缀(不需要 root,兼容性最好 —— 本项目验证环境就是这么装的)
#
# 幂等:已存在且能跑就直接跳过。
#
# 用法(dev host 本机直接跑):
#   ICECC_PREFIX=$HOME/icecc-prefix ./01-install-icecc.sh
# 用法(灌进办公机 WSL2,从 dev host 用 ssh 发起,避免任何嵌套引号):
#   ssh <alias> "wsl -d <distro> -u root -- bash -s" < 01-install-icecc.sh
set -uo pipefail

ICECC_PREFIX="${ICECC_PREFIX:-$HOME/icecc-prefix}"
ICECC_SRC="${ICECC_SRC:-/tmp/icecream}"
ICECC_GIT="${ICECC_GIT:-https://github.com/icecc/icecream.git}"

if [ -x "$ICECC_PREFIX/usr/sbin/iceccd" ] && [ -x "$ICECC_PREFIX/usr/bin/icecc" ]; then
    echo "已安装: $ICECC_PREFIX (跳过)"
    exit 0
fi

if command -v iceccd >/dev/null 2>&1 && command -v icecc >/dev/null 2>&1; then
    echo "系统 PATH 里已有 icecc/iceccd (跳过): $(command -v iceccd)"
    exit 0
fi

echo "=== 未找到现成安装,开始安装 ==="

if [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
    echo "--- 尝试 apt 安装系统包 icecc ---"
    if apt-get update -qq && apt-get install -y icecc; then
        SYS_BIN=$(command -v iceccd 2>/dev/null || true)
        if [ -n "$SYS_BIN" ]; then
            echo "  apt 安装成功: $SYS_BIN"
            echo "  (系统包已在 PATH 里,后续脚本可以不设 ICECC_PREFIX,直接用系统 icecc/iceccd/icecc-scheduler/icecc-create-env)"
            exit 0
        fi
    fi
    echo "  apt 安装失败或没有 icecc 包,回退到源码编译"
fi

echo "--- 源码编译安装到 $ICECC_PREFIX (不需要 root) ---"
for bin in gcc g++ make autoconf automake libtoolize pkg-config git; do
    command -v "$bin" >/dev/null 2>&1 || { echo "  缺 $bin,请先装好构建工具链再重跑本脚本"; exit 1; }
done
echo "  (还需要开发头文件: libzstd-dev libarchive-dev liblzo2-dev — 缺了 configure 会直接报错并提示缺什么)"

if [ ! -d "$ICECC_SRC" ]; then
    git clone --depth 1 "$ICECC_GIT" "$ICECC_SRC"
fi

cd "$ICECC_SRC"
./autogen.sh
./configure --prefix="$ICECC_PREFIX"
make -j"$(nproc)"
make install

if [ -x "$ICECC_PREFIX/usr/sbin/iceccd" ]; then
    echo "  安装完成: $ICECC_PREFIX"
else
    echo "  安装后仍未找到 iceccd,检查上面的编译日志"
    exit 1
fi
