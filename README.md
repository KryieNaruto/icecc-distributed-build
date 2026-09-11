# icecc-distributed-build

用 [icecc](https://github.com/icecc/icecream) 把 C/C++（含 Android NDK 交叉编译）的编译单元，经已有的反向 SSH 隧道，分发到一台闲置的办公 Windows 机器（WSL2）上编译，产物回传后在本机集中链接。

已用真实的 Krita 5.2.16（Android arm64，3210 条编译边）验证：**100% 的编译单元被分发到办公机**，本机编译数为 0。

## 怎么用

这是一个 [Claude Code Skill](https://docs.claude.com/claude-code)。把本仓库整体（或至少 `.claude/skills/icecc-distributed-build/` 这一份）放到你的项目根目录下：

```bash
git clone <本仓库地址> icecc-distributed-build
cp -r icecc-distributed-build/.claude ./.claude   # 合并到你自己项目的 .claude/ 下
```

打开 Claude Code 会话，让它按 `.claude/skills/icecc-distributed-build/SKILL.md` 里的步骤走；或者直接手动跑 `scripts/` 下的脚本（都是普通 bash，不依赖 Claude Code 也能跑，参数说明见每个脚本头部注释）。

完整流程、架构原理、每一步为什么这么设计、以及一份真实踩过的坑的故障排查表，都在 [`SKILL.md`](.claude/skills/icecc-distributed-build/SKILL.md) 里，从头读一遍再动手。

## 现状

- 单台办公机验证通过，端到端跑通（分发 + 回传 + 集中链接）。
- 多机串联（把好几台办公机的算力并到一个池子里）**还没做，也没验证**，`SKILL.md` 里「后续扩展」一节记了两条候选思路，欢迎接着填。
- 所有脚本都在真实环境里跑过、不是只过了语法检查；跑的过程中现场抓到过两个"设计时看着对、一跑就露馅"的 bug，也记进了故障排查表，供参考。
