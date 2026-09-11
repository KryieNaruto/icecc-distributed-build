#!/usr/bin/env bash
# 有序重启整条 icecc 链路:office 端(scheduler + 编译节点) → dev host 端(提交者,-m 0)。
#
# 顺序严格重要:一个已经连上 scheduler 的提交者,如果在 node 还没登记好之前就连上,
# 会把"当时还没有节点"的判断结果缓存住,后面所有任务都被判成"没有合适主机",
# 静默退化成全部本地编译 —— 且不会报任何错误。所以每一步都要等对应端口真正
# LISTEN/ESTABLISHED 之后,才能进行下一步。
#
# 拓扑(当前只验证了单节点,多节点见 SKILL.md「后续扩展:多机串联」):
#   office 机器的 WSL2 里同时跑:
#     - icecc-scheduler (调度器,整个池子只需要一个)
#     - iceccd -m <核数>  (真正吃 CPU 编译的节点)
#   dev/build host 上只跑:
#     - iceccd -m 0 --no-remote  (提交者:只转发任务/收产物,自己绝不参与编译)
#   两边能用 127.0.0.1:<port> 互相摸到,是因为已有反向隧道把这两个端口做了 -R 转发。
#   本脚本不搭隧道,只负责隧道之上的 icecc 进程编排。
#
# 所有"发到远端 WSL2 执行"的步骤都走同一个安全模式(run_remote 函数):本地先把
# 变量用 %q 转义写成 export 语句,拼上一段完全用单引号 heredoc(<<'REMOTE')引用的
# 静态脚本体,整个当 stdin 喂给 ssh;ssh 命令行本身只插一个 $WSL_DISTRO,不再有
# 第二层引号 —— 这正是用来修掉本项目 icecc-clean-cycle.sh 那个"嵌套引号被吃掉,
# 整条链路静默退化成 0% 分发"的 bug 的写法,请勿改回 ssh host "... bash -c '...'"
# 那种双层引号写法。
#
# 用法:
#   SSH_ALIAS=win-office-ssh WSL_DISTRO=Ubuntu-24.04 \
#   SCHED_PORT=46200 NODE_PORT=45101 NODE_MAXJOBS=24 \
#   ./03-restart-stack.sh
set -uo pipefail

SSH_ALIAS="${SSH_ALIAS:?必须设置 SSH_ALIAS}"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu-24.04}"
NETNAME="${NETNAME:-icecctest}"
SCHED_PORT="${SCHED_PORT:?必须设置 SCHED_PORT}"
NODE_PORT="${NODE_PORT:?必须设置 NODE_PORT}"
NODE_MAXJOBS="${NODE_MAXJOBS:-0}"          # 0 = 让远端脚本用 nproc 自动填
NODE_NAME="${NODE_NAME:-office-wsl}"
REMOTE_BIN_DIR="${REMOTE_BIN_DIR:-}"       # 若远端是源码装到自定义前缀,传 .../usr/sbin:.../usr/bin
LOCAL_ICECC_PREFIX="${LOCAL_ICECC_PREFIX:-$HOME/icecc-prefix}"
SUBMITTER_RUN_DIR="${SUBMITTER_RUN_DIR:-$PWD/icecc-run/submitter}"

sched_hex=$(printf '%04X' "$SCHED_PORT")
node_hex=$(printf '%04X' "$NODE_PORT")

run_remote() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    ssh -o ConnectTimeout=15 "$SSH_ALIAS" "wsl -d $WSL_DISTRO -u root -- bash -s" < "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

echo "### 1. 停掉 office 端旧进程"
run_remote <<'REMOTE'
pkill -9 icecc-scheduler 2>/dev/null
pkill -9 iceccd 2>/dev/null
sleep 1
echo "  已清空"
REMOTE

echo "### 2. office 端起 scheduler,等它 LISTEN"
{
    printf 'export REMOTE_BIN_DIR=%q NETNAME=%q SCHED_PORT=%q SCHED_HEX=%q\n' \
        "$REMOTE_BIN_DIR" "$NETNAME" "$SCHED_PORT" "$sched_hex"
    cat <<'REMOTE'
set -u
[ -n "${REMOTE_BIN_DIR:-}" ] && PATH="$REMOTE_BIN_DIR:$PATH"
setsid nohup icecc-scheduler -n "$NETNAME" -p "$SCHED_PORT" -l /var/log/sched.log \
    >/var/log/sched.stdout 2>&1 </dev/null &
for i in $(seq 1 20); do
    grep -qi ":$SCHED_HEX " /proc/net/tcp 2>/dev/null && { echo "  scheduler LISTEN"; exit 0; }
    sleep 1
done
echo "  scheduler 起动失败,看 /var/log/sched.stdout:"
cat /var/log/sched.stdout
exit 1
REMOTE
} | run_remote
sched_rc=$?
[ "$sched_rc" -eq 0 ] || { echo "!! 中止:office scheduler 没起来"; exit 1; }

echo "### 3. office 端起编译节点,等它 LISTEN"
{
    printf 'export REMOTE_BIN_DIR=%q NETNAME=%q SCHED_PORT=%q NODE_PORT=%q NODE_HEX=%q NODE_NAME=%q NODE_MAXJOBS=%q\n' \
        "$REMOTE_BIN_DIR" "$NETNAME" "$SCHED_PORT" "$NODE_PORT" "$node_hex" "$NODE_NAME" "$NODE_MAXJOBS"
    cat <<'REMOTE'
set -u
[ -n "${REMOTE_BIN_DIR:-}" ] && PATH="$REMOTE_BIN_DIR:$PATH"
mkdir -p /var/cache/icecc
mj="$NODE_MAXJOBS"
[ "$mj" = "0" ] && mj=$(nproc)
setsid nohup iceccd -n "$NETNAME" -s "127.0.0.1:$SCHED_PORT" -m "$mj" -N "$NODE_NAME" \
    -p "$NODE_PORT" -b /var/cache/icecc -l /var/log/iceccd.log \
    >/var/log/iceccd.stdout 2>&1 </dev/null &
for i in $(seq 1 20); do
    grep -qi ":$NODE_HEX " /proc/net/tcp 2>/dev/null && { echo "  node LISTEN (m=$mj)"; exit 0; }
    sleep 1
done
echo "  node 起动失败,看 /var/log/iceccd.stdout:"
cat /var/log/iceccd.stdout
exit 1
REMOTE
} | run_remote
node_rc=$?
[ "$node_rc" -eq 0 ] || { echo "!! 中止:office node 没起来"; exit 1; }

echo "### 4. dev host 端:停旧提交者"
pkill -f "iceccd .*--no-remote.*-s 127.0.0.1:$SCHED_PORT" 2>/dev/null
sleep 1

echo "### 5. dev host 端:起提交者(-m 0,自己绝不编译,这是硬约束不要改),等它连上 scheduler"
mkdir -p "$SUBMITTER_RUN_DIR"
SUBMITTER_BIN="$LOCAL_ICECC_PREFIX/usr/sbin/iceccd"
[ -x "$SUBMITTER_BIN" ] || SUBMITTER_BIN=iceccd
setsid nohup "$SUBMITTER_BIN" -n "$NETNAME" -s "127.0.0.1:$SCHED_PORT" --no-remote \
    -m 0 -N "${NODE_NAME}-submitter" -b "$SUBMITTER_RUN_DIR" \
    > "$SUBMITTER_RUN_DIR/submitter.stdout" 2>&1 < /dev/null &
disown
ok=0
for i in $(seq 1 20); do
    # ss -tn 的列序是 State 在前、地址在后(State Recv-Q Send-Q Local Peer),
    # 匹配顺序不能反,反了就永远匹配不上(哪怕连接其实已经建立)。
    ss -tn 2>/dev/null | grep -q "ESTAB.*:$SCHED_PORT " && { ok=1; break; }
    sleep 1
done
if [ "$ok" -ne 1 ]; then
    echo "!! 中止:submitter 没连上,看 $SUBMITTER_RUN_DIR/submitter.stdout"
    cat "$SUBMITTER_RUN_DIR/submitter.stdout" 2>/dev/null
    exit 1
fi
echo "  submitter 已连上 scheduler"

echo ""
echo "### 全部就绪"
echo "  scheduler   : $SSH_ALIAS WSL2 :$SCHED_PORT"
echo "  编译节点    : $SSH_ALIAS WSL2 :$NODE_PORT"
echo "  dev host    : submitter -m 0 已连上"
echo ""
echo "下一步:04-icecc-build.sh 发起真正的构建。"
