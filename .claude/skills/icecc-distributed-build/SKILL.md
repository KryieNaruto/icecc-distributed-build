---
name: icecc-distributed-build
description: Use when you need to speed up a large C/C++ build (including Android NDK cross-compiles) by offloading compile jobs to an idle office Windows machine's CPU over an existing reverse SSH tunnel, using Icecream (icecc). Covers bootstrapping a brand-new dev/build server + a brand-new office compute node, dispatching a build so translation units get distributed, and collecting the linked artifacts back on the dev server. Multi-office-machine pooling is documented but deferred/untested.
---

# 用办公 Windows 算力分布式编译 C/C++（icecc）

## 这是什么

把 dev/build 服务器（下称 **dev host**）上的一次 C/C++ 编译，通过 [icecc](https://github.com/icecc/icecream) 把每个翻译单元（`.cpp → .o`）派给一台闲置的办公 Windows 机器（下称 **office 机**，经 WSL2 提供 Linux 编译环境）去编译，`.o` 编完传回 dev host，dev host 做最终链接，产出 `.so` / `.a` / 可执行文件。

已用真实的 Krita 5.2.16（Android arm64，3210 条编译边）验证：**100% 的编译单元** 被分发到 office 机，dev host 本机编译数为 0，构建正常 `ninja exit=0`，产出 184 个 `.so`。

## 前提条件（本 skill 不负责搭建，只负责验证 + 之上的编排）

1. **office 机已装好 WSL2**（建议 Ubuntu），且你能从 dev host 通过某个 SSH alias 摸到它：`ssh <alias> "wsl -d <distro> -u root -- true"`。
2. **office 机到 dev host 之间已有一条反向 SSH 隧道**，由 office 机主动向 dev host 拨出（因为通常是 dev host 在 NAT/防火墙后面，office 机能出网但 dev host 联不进office 网）。这条隧道基础设施本身（例如公司内部的 UGEE 隧道工具）不属于本 skill 范围，**但本 skill 要求它已经／能够为每一对 (scheduler 端口, node 端口) 做 `-R` 反向端口转发**，使得 dev host 本地的 `127.0.0.1:<port>` 直接可达 office 机 WSL2 内的对应端口。
3. 给这台新 office 机分配两个 **全局唯一** 的端口号：`SCHED_PORT`（调度器）、`NODE_PORT`（编译节点）。唯一，是因为反向隧道下所有 office 机在 icecc 眼里地址都是 `127.0.0.1`——见下面「为什么架构长这样」——端口号是唯一能区分它们的东西。

用 `scripts/00-check-tunnel.sh` 验证第 1 条（只读，不改动任何东西）：

```bash
SSH_ALIAS=win-office-ssh WSL_DISTRO=Ubuntu-24.04 ./scripts/00-check-tunnel.sh
```

## 架构：为什么 dev host 不编译，office 机既跑调度器又编译

```
                     反向隧道（office 机主动拨出，已有基础设施）
  ┌─────────────────┐  <==== -R SCHED_PORT ====>  ┌───────────────────────────┐
  │   dev/build host │  <==== -R NODE_PORT  ====>  │  office 机 WSL2            │
  │                   │                             │                            │
  │  iceccd           │                             │  icecc-scheduler (:SCHED)  │
  │   -m 0            │ ---- 127.0.0.1:SCHED ----> │  iceccd -m <核数> (:NODE)  │
  │   --no-remote     │ <--- 127.0.0.1:NODE  ----- │  （真正吃 CPU 编译的地方） │
  │  （提交者/最终    │                             │                            │
  │   链接都在这）    │                             │                            │
  └─────────────────┘                             └───────────────────────────┘
```

- **scheduler 必须放在能被 dev host 反向隧道摸到的一侧**——也就是 office 机——因为 dev host 大概率无法暴露一个让 office 机主动连进来的端口（这正是需要反向隧道的原因）。所以第一台纳入池子的 office 机同时兼任调度器。
- **dev host 只跑一个 `iceccd -m 0 --no-remote`**，角色是「提交者」：预处理源码、把任务甩给 scheduler、收编译结果、最后做链接。`-m 0` 是硬约束，删掉它编译会静默退化，见下面故障排查表第 3 条。
- **反向隧道让所有 office 机的地址都显示成 `127.0.0.1`**（scheduler/client 拿到的是 TCP `accept()` 的对端地址，隧道另一端永远是本地回环），所以 icecc 的地址判断逻辑会犯迷糊——这是本 skill 两个「必需环境变量/参数」的根源，不是隧道搭错了。

## 第一部分：新机器配对时的一次性搭建

### 1A. 两侧都要有 icecc 二进制

在 dev host 和 office 机 WSL2 内都跑一遍（幂等，已装好会直接跳过）：

```bash
# dev host 本机：
ICECC_PREFIX=$HOME/icecc-prefix ./scripts/01-install-icecc.sh

# office 机 WSL2（从 dev host 发起，避免任何嵌套引号——这是本 skill 所有远程调用的标准写法）：
ssh <alias> "wsl -d <distro> -u root -- bash -s" < ./scripts/01-install-icecc.sh
```

### 1B. 打包目标工具链的 icecc env

如果目标是本机编译（gcc/clang 都在标准路径），`icecc-create-env --gcc /usr/bin/gcc /usr/bin/g++` 或 `--clang` 直接够用。

**如果是交叉编译**（本 skill 已验证的场景：Android NDK clang），原生 `icecc-create-env` 打包不全——它只会顺 `ldd` 带上编译器自身依赖的动态库，不知道 `--sysroot` 在哪、clang 内建头（`lib/clang/<ver>/include`）在哪，解出来的 env 编译时会报 `fatal error: 'cstdio' file not found`。用 `scripts/02-create-toolchain-env.sh`，它在基础 env 之上手动补齐 sysroot + 内建头，并做一次真实交叉编译自检：

```bash
NDK_TOOLCHAIN=/usr/lib/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64 \
CLANG_RESOURCE_VER=19 \
./scripts/02-create-toolchain-env.sh ./icecc-env-full
```

产出一个 `<md5>.tar.zst`，记下路径，后面当 `ENV_TAR` 用。

## 第二部分：接到编译任务，开始分发

### 2. 起停整条链路

用 `scripts/03-restart-stack.sh` 做**有序**重启：office 端 scheduler → office 端 node → dev host 端 submitter，每一步都等对应端口真正 LISTEN/ESTABLISHED 才进行下一步。

```bash
SSH_ALIAS=win-office-ssh WSL_DISTRO=Ubuntu-24.04 \
SCHED_PORT=46200 NODE_PORT=45101 NODE_MAXJOBS=24 \
./scripts/03-restart-stack.sh
```

**顺序为什么这么严格**：一个已经连上 scheduler 的提交者，如果在 node 还没登记好之前就先连上，会把「当时还没有节点」的判断结果缓存住——后面所有任务都被判成「没有合适主机」，**静默退化成 100% 本地编译，且不会报任何错误**。这是本项目实际踩过的坑（重启 scheduler 忘了等 node 重新登记，整条链路无声无息地全跑回本地）。

### 3. 把目标工程接入 icecc

在目标工程的 CMake 配置命令里加两个 launcher flag（对任何 CMake+Ninja/Make 工程都适用，不改代码，只改配置命令）：

```
-DCMAKE_C_COMPILER_LAUNCHER=icecc -DCMAKE_CXX_COMPILER_LAUNCHER=icecc
```

（非 CMake 工程：把 `CC`/`CXX` 换成 `"icecc gcc"` / `"icecc g++"` 之类的组合，思路一样——让每次编译调用先过一遍 `icecc` 这层壳。）

### 4. 跑构建，读分发报告

`04-icecc-build.sh` 只负责 icecc 那一层，**不会帮你激活目标工程自己的构建环境**——如果工程本来就需要先 `source env` / 设 `LD_LIBRARY_PATH` 才能跑（例如 Krita 依赖 `krita-ci-env` 生成的 `env` 脚本来让 `msgfmt` 等工具找到自己的运行库），照常先做这一步，跟平时手动构建一模一样；忘了这步会看到跟 icecc/分发完全无关的报错（本 skill 验证时就现场踩了一次：本地 `msgfmt: error while loading shared libraries: libgettextsrc-0.21.so`，纯粹是没 source 环境，跟分发率无关，分发报告依然是 100%）。

用 `scripts/04-icecc-build.sh`，它负责设好全部必需的 icecc 环境变量、跑你给的构建命令、构建完打印分发报告：

```bash
ENV_TAR=./icecc-env-full/<md5>.tar.zst \
ICECC_CC=/path/to/clang ICECC_CXX=/path/to/clang++ \
./scripts/04-icecc-build.sh <build_dir> -- ninja -k 0 -j 24
```

**两个必需的东西，缺一个都会静默退化（不报错，只是全跑本地）：**

| 必需项 | 作用 | 不设会怎样 |
|---|---|---|
| `ICECC_TEST_REMOTEBUILD=1`（脚本已内置） | 反向隧道下 scheduler 报给 client 的节点地址永远是 `127.0.0.1`，icecc 客户端默认把这当成「scheduler 让我自己编译」，这个变量强制它按 scheduler 真实分配的端口走远程 | 0% 分发（本项目实测：不加=0/16，加了=16/16） |
| office 端 `-m 0` 提交者 | 让 scheduler 找不到本地空槽时**排队等 office 节点**，而不是把任务甩回本地 | 约 30-40% 的任务被瞬时的调度决策固化成本地编译（源码依据：`daemon/main.cpp` 里 `--no-remote` 会强制 `daemon_port=0`，`is_eligible_ever` 要求 `m_maxJobs>0` 才会把提交者纳入"可以本地扛"的候选） |

## 第三部分：办公机编完，回传并集中链接

这一步**不需要额外操作**——它是 icecc 本来的工作方式，只需要理解：icecc 只接管「预处理后的源码 → 编译成 `.o`」这一段，`.o` 编完由 office 机传回 dev host；**链接永远发生在 dev host 本地**（ninja/make 在拿到所有需要的 `.o` 后自动触发链接规则，不需要额外配置）。

`04-icecc-build.sh` 跑完会自动列出本次新产出的 `.so`/`.a`（用一个时间戳 marker 文件 + `find -newer` 找出来），这就是最终产物清单。如果目标产物是可执行文件而不是库，把脚本里 `find` 的 `-name '*.so' -o -name '*.a'` 换成你需要的 pattern。

## 故障排查表

| 症状 | 根因 | 修复 |
|---|---|---|
| 分发率 0%，`asking for host to use` 后直接 `building myself, but telling localhost` | 没设 `ICECC_TEST_REMOTEBUILD=1`；反向隧道下节点地址显示为 `127.0.0.1`，被 icecc 误判为本地 | 用 `04-icecc-build.sh`（已内置）或手动 `export ICECC_TEST_REMOTEBUILD=1` |
| 分发率长期卡在 60%~70%，忽高忽低 | dev host 的提交者用了非 0 的 `-m`（有空槽），scheduler 一旦瞬时找不到 office 节点就把任务甩给提交者本地编，而不是排队等 | 确认提交者是 `-m 0`（`03-restart-stack.sh` 已硬编码），不要为了"顺便也用上 dev host 的核"而调大它 |
| 分发率突然从高变成 0，且没有任何报错 | 重启过 scheduler 或 node，但提交者是在 node 重新登记**之前**连上的，缓存了旧的"无可用节点"判断 | 用 `03-restart-stack.sh` 的严格顺序重启（office scheduler → office node → dev host 提交者），不要单独重启某一环 |
| 交叉编译报 `fatal error: 'cstdio' file not found` | 直接用 `icecc-create-env` 打包交叉工具链，env 里没有 sysroot / clang 内建头 | 用 `02-create-toolchain-env.sh`，会自动补齐并做真实编译自检 |
| Android 链接期报 `undefined symbol: process_vm_readv` / `__write_chk` 等 | ECM/NDK 工具链把 `-DANDROID_PLATFORM=xx` 静默忽略并按更低的 API level 编译；目标 API 低于依赖库预编译时用的 API | 改用 `-DCMAKE_ANDROID_API=<正确值>`（不是 `ANDROID_PLATFORM`），且要跟依赖库预编译时用的 API 一致 |
| 在 `ssh alias "wsl ... -- bash -c '...'"` 这种写法下，变量没展开或整条链路莫名其妙全跑本地 | 双层引号嵌套被吃掉，实际执行的命令跟你以为的不一样 | 参考 `03-restart-stack.sh` 里 `run_remote` 的写法：本地变量用 `printf '%q'` 转成 `export` 语句 + 单引号 heredoc(`<<'REMOTE'`)拼在一起整体通过 stdin 喂给 `ssh ... "wsl ... -- bash -s"`，命令行本身不再有第二层引号 |
| 对 `ssh <alias> "wsl ... -- echo xxx"` 的输出用 `grep -q '^xxx$'` 之类的行尾锚定匹配，在脚本文件/`bash -c` 里跑总是判失败，但把同一条命令直接粘贴到终端跑却是好的 | 经这条 Windows OpenSSH → `wsl.exe` 链路转出来的文本行尾是 `\r\n`，`$` 锚点匹配不到 `\r` 前面；而在某些终端/宿主环境里换行会被隐式规整掉，看起来"直接跑"是好的，一旦换成纯管道读取就露出来了。本 skill 已在 `00-check-tunnel.sh` 里踩过这个坑并修了 | 凡是要对这条链路上 ssh 拿到的文本做行首/行尾锚定匹配，先 `tr -d '\r'` 再 `grep`；或者干脆不用 `^...$` 锚定，只用子串匹配 |
| 用 `ss -tn \| grep ":$PORT .*ESTAB"` 判断连接是否建立，实测明明连上了却一直判失败 | `ss -tn` 的列序是 `State Recv-Q Send-Q Local Peer`，`ESTAB` 排在地址**前面**，`":$PORT .*ESTAB"` 这个匹配顺序反了，永远不可能匹配上 | 反过来写成 `"ESTAB.*:$PORT "`（`03-restart-stack.sh` 已修） |
| 办公机 CPU 占用看起来没涨，但构建正常跑完了 | 这恰恰是分发生效的证据——dev host 提交者是 `-m 0`，真正吃 CPU 的编译全在 office 机上；dev host 本机只做轻量的预处理/收发/链接 | 不是异常。去 office 机 WSL2 里用 `ps -eo pcpu,comm \| grep clang` 或 `uptime` 直接看它的 CPU |

## 后续扩展：多机串联（暂缓，未测试）

当前只验证了 **单台 office 机**。要接入第二台，最省事的思路（未验证，供后续参考）：

- 沿用现有 scheduler（跑在第一台 office 机上），第二台机器只需要：
  1. 装 icecc（`01-install-icecc.sh`）；
  2. 分配一个新的、全局唯一的 `NODE_PORT`（例如 45102），并在隧道配置里为它加一条新的 `-R` 转发；
  3. **它的 iceccd 需要能连到第一台机器的 scheduler**——如果两台 office 机之间没有直连网络（大概率没有，各自只跟 dev host 有隧道），需要 dev host 反过来帮忙转发（比如再加一条 `-L`，把第二台机器对 scheduler 端口的连接请求经 dev host 转发回第一台机器）。这一段网络拓扑需要专门设计和测试，不在本次范围内。
- 更彻底的重构方向：把 **scheduler 挪到 dev host 上**，每台 office 机只需要各自 `-R` 一个 node 端口回 dev host，同时用一条 `-L` 把 dev host 的 scheduler 端口正向映射进自己的 WSL2——这样 N 台机器接入是完全对称、独立的操作，互相不需要知道对方存在。架构上更干净，但需要改造现有隧道配置（目前是纯 `-R`），**留待后续**。

多机验证完成后，`03-restart-stack.sh` 需要扩展成接受一个 `(alias, wsl_distro, node_port, maxjobs)` 的列表并逐个起 node，而不是像现在这样硬编码单节点。

## 附录：本次验证用的真实数字

- 目标：Krita 5.2.16，Android arm64，3210 条编译边，2516 个目标文件。
- 依赖前缀：Qt 5.15.7 + KF5（krita-ci-env），决定了必须用 Krita 5.2.x 而非 6.x。
- 交叉工具链：Android NDK r28（`clang`），目标 API level 24（必须跟依赖库预编译时的 API 一致，见故障排查表）。
- 结果：`ninja exit=0`，**2514/2514（100%）编译单元分发到 office 机**，dev host 本地编译数 0，产出 184 个 `.so`。
