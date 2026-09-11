#!/usr/bin/env bash
# 检查:从当前(dev/build)主机能否经反向隧道摸到目标办公机器的 WSL2。
# 这一步只做只读探测,不启动/不修改任何东西。
#
# 用法:
#   SSH_ALIAS=win-office-ssh WSL_DISTRO=Ubuntu-24.04 ./00-check-tunnel.sh
set -uo pipefail

SSH_ALIAS="${SSH_ALIAS:?必须设置 SSH_ALIAS,例如 win-office-ssh(参见 ~/.ssh/config)}"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu-24.04}"

echo "=== 1. SSH 能否连上 $SSH_ALIAS ==="
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_ALIAS" "echo ok" 2>/tmp/00-ssh.err | tr -d '\r' | grep -q '^ok$'; then
    echo "  OK"
else
    echo "  FAIL — 看 /tmp/00-ssh.err:"
    cat /tmp/00-ssh.err
    exit 1
fi

echo "=== 2. WSL 发行版 $WSL_DISTRO 能否执行命令 ==="
if ssh -o ConnectTimeout=10 "$SSH_ALIAS" "wsl -d $WSL_DISTRO -u root -- echo wsl-ok" 2>/tmp/00-wsl.err | tr -d '\r' | grep -q '^wsl-ok$'; then
    echo "  OK"
else
    echo "  FAIL — 看 /tmp/00-wsl.err:"
    cat /tmp/00-wsl.err
    exit 1
fi

echo "=== 3. WSL2 内网络与核数 ==="
ssh -o ConnectTimeout=10 "$SSH_ALIAS" "wsl -d $WSL_DISTRO -u root -- bash -s" <<'EOF'
echo "  nproc        : $(nproc)"
echo "  mem free     : $(free -h | awk 'NR==2{print $7}')"
echo "  disk free(/) : $(df -h / | awk 'NR==2{print $4}')"
EOF

echo ""
echo "=== 结论 ==="
echo "隧道链路健康。下一步:决定这台机器用什么 NETNAME / SCHED_PORT / NODE_PORT,"
echo "并确认这两个端口已经在隧道配置里做了 -R 反向转发(隧道基础设施本身不在本 skill 范围内维护)。"
