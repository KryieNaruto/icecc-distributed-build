#!/usr/bin/env bash
# 把一套交叉编译工具链打成 icecc 能用的 env tarball。
#
# 直接用 icecc-create-env 打包出来的东西,对"工具链和它的运行库都在系统标准路径"的
# 本机编译够用;但对交叉工具链(典型例子: Android NDK clang)通常不够 —— 它只会
# 顺着 ldd 把 clang 依赖的动态库带上,并不知道 --sysroot 在哪、clang 内建头
# (lib/clang/<ver>/include) 在哪。解出来的 env 编译时会报
# `fatal error: 'cstdio' file not found`。
#
# 本脚本的做法:
#   1) 先用 icecc-create-env 生成基础 env(带上编译器本身 + 它的 host 运行库)
#   2) 解开,手动把 sysroot 和 clang 内建头拷进去
#   3) 用这个"补全后"的 env 做一次真实交叉编译自检
#   4) 按 icecc 的口径重新算 md5(文件内容变了,原来的 md5 文件名就不对了),重新打包
#
# 用法(以 Android NDK clang 为例,已验证 android-arm64):
#   NDK_TOOLCHAIN=/usr/lib/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64 \
#   CLANG_RESOURCE_VER=19 \
#   ./02-create-toolchain-env.sh [输出目录,默认 ./icecc-env-full]
#
# 如果目标工具链不是 NDK clang(比如别的交叉 gcc):
#   - icecc-create-env 那行的 --clang 换成 --gcc <cc> <cxx>
#   - "补 sysroot" 那一步换成拷贝对应工具链的 sysroot/运行库
#   - CLANG_RESOURCE_VER 是 clang 大版本号(看 <toolchain>/lib/clang/<ver>/),gcc 没有这个概念,可以跳过那一步
set -euo pipefail

ICECC_PREFIX="${ICECC_PREFIX:-$HOME/icecc-prefix}"
NDK_TOOLCHAIN="${NDK_TOOLCHAIN:?必须设置 NDK_TOOLCHAIN,指向 .../toolchains/llvm/prebuilt/linux-x86_64}"
CLANG_RESOURCE_VER="${CLANG_RESOURCE_VER:?必须设置 CLANG_RESOURCE_VER,例如 19(看 $NDK_TOOLCHAIN/lib/clang/ 下的目录名)}"
TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-linux-android30}"
OUT="${1:-./icecc-env-full}"

CW="$ICECC_PREFIX/usr/lib/icecc/compilerwrapper"
[ -x "$ICECC_PREFIX/usr/bin/icecc-create-env" ] || { echo "找不到 icecc-create-env,先跑 01-install-icecc.sh"; exit 1; }

mkdir -p "$OUT"
work=$(mktemp -d /tmp/iceccenv-full-XXXXXX)
trap 'rm -rf "$work"' EXIT

echo "=== 1/4 生成基础 env ==="
cd "$work"
"$ICECC_PREFIX/usr/bin/icecc-create-env" \
    --clang "$NDK_TOOLCHAIN/bin/clang" "$CW" \
    --compression zstd \
    > "$work/create.log" 2>&1 || { echo "icecc-create-env 失败:"; tail -20 "$work/create.log"; exit 1; }

base_tar=$(ls "$work"/*.tar.zst 2>/dev/null | head -1)
[ -n "$base_tar" ] || { echo "未生成 tarball,日志:"; tail -20 "$work/create.log"; exit 1; }
echo "  基础 tarball: $(basename "$base_tar") ($(stat -c%s "$base_tar") 字节)"

echo "=== 2/4 解开并补 sysroot + clang 内建头 ==="
mkdir -p "$work/stage"
tar --zstd -xf "$base_tar" -C "$work/stage"

echo "  补 usr/sysroot/"
mkdir -p "$work/stage/usr/sysroot"
cp -a "$NDK_TOOLCHAIN/sysroot/." "$work/stage/usr/sysroot/"

echo "  补 usr/lib/clang/$CLANG_RESOURCE_VER/include/"
mkdir -p "$work/stage/usr/lib/clang/$CLANG_RESOURCE_VER"
cp -a "$NDK_TOOLCHAIN/lib/clang/$CLANG_RESOURCE_VER/include" "$work/stage/usr/lib/clang/$CLANG_RESOURCE_VER/"

echo "=== 3/4 自检:env 内 clang 能否编交叉目标 ==="
cat > "$work/probe.cpp" <<'EOF'
#include <cstdio>
#include <string>
#include <vector>
int main(){ std::vector<std::string> v{"a"}; std::printf("%s", v[0].c_str()); return 0; }
EOF
if "$work/stage/usr/bin/clang" -target "$TARGET_TRIPLE" -c "$work/probe.cpp" -o "$work/probe.o" 2>"$work/probe.err"; then
    echo "  通过: $(file -b "$work/probe.o")"
else
    echo "  自检失败:"; head -20 "$work/probe.err"; exit 1
fi

echo "=== 4/4 重算 md5 并打包 ==="
cd "$work/stage"
file_list=$(find . -type f -o -type l | sed 's|^\./||' | sort)
md5=$(for f in $file_list; do md5sum "$f"; done | sed -e "s#  .*/#  #" | md5sum | sed -e 's/ .*$//')

out_tar="$OUT/$md5.tar.zst"
tar -ch --numeric-owner -f - $file_list | zstd -q -o "$out_tar"

echo ""
echo "=== 完成 ==="
echo "env 文件: $out_tar"
echo "把这个路径记下来,跑 04-icecc-build.sh 时作为 ENV_TAR 传入。"
