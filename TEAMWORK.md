# 团队协作指南（TEAMWORK）

> 本仓库多人协作的日常操作说明。首次参与开发请先读完本文再动手。

---

## 一、首次配置（每台机器只做一次）

### 1. 装工具链

```bash
sudo apt install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf git
```

### 2. 配置 git 身份（提交记录会显示你的名字）

```bash
git config --global user.name  "你的GitHub用户名"
git config --global user.email "你的邮箱"
```

### 3. 配 GitHub SSH key（push 必需）

```bash
ssh-keygen -t ed25519          # 一路回车
cat ~/.ssh/id_ed25519.pub      # 复制输出内容
```

到 https://github.com/settings/keys → `New SSH key` → 粘贴保存。
验证：`ssh -T git@github.com` 看到 "successfully authenticated" 即 OK。

### 4. 克隆仓库

```bash
git clone git@github.com:zhu031227/fpga_webserver.git
cd fpga_webserver
```

---

## 二、日常改代码流程（每次都这样）

```bash
git pull                      # ① 先拉取别人最新的改动，避免冲突
# ② ...编辑代码...
git status                    # ③ 看一下改了哪些文件（确认没改错）
git add -A                    # ④ 暂存所有改动
git commit -m "简要说明改了什么"  # ⑤ 打一个版本快照
git push                      # ⑥ 上传到 GitHub
```

**要点**：

- 动手前先 `git pull`，收工前 `git push`——频率越高冲突越少
- `commit -m` 的说明要写清楚，例如 `防火墙: 新增IP黑名单过滤规则表`，不要写 "修改"、"update"
- 每次 commit 就是一个版本，GitHub 仓库页 Commits 标签可查全部历史，谁改的、何时改的、改了哪几行都看得见

---

## 三、分支协作（推荐：别直接改 main）

`main` 分支保持「随时能跑的稳定版」。开发新功能请开分支：

```bash
git checkout -b feature/你的功能名    # 从 main 开出新分支，如 feature/ip-filter
# ...改代码、commit...
git push -u origin feature/你的功能名  # 推自己的分支
```

然后到 GitHub 仓库页 → **Pull requests** → `New pull request` → 选你的分支 → 创建 PR → 由仓库管理员审核合并进 main。

好处：main 永远是好的；你的改动有问题，审核阶段就能发现，不影响别人。

**紧急修复 / 小改动**：直接在 main 上改 + push 也可以，小团队自行权衡。

---

## 四、遇到 push 被拒（冲突）怎么办

两人改了同一个文件的同一处，后 push 的人会被拒绝：

```bash
git pull                      # 拉下来，git 会标记冲突文件
# 打开冲突文件，找 <<<<<<< ======= >>>>>>> 标记，手动保留正确内容，删掉标记
git add -A
git commit -m "解决冲突: xxx"
git push
```

**预防**：改之前 `git pull`；分工时尽量别两人同时改同一个文件。

---

## 五、常用命令速查

| 命令 | 作用 |
|------|------|
| `git pull` | 拉取远端最新代码 |
| `git status` | 查看当前改动了什么 |
| `git log --oneline` | 查看版本历史（一行一条） |
| `git diff` | 查看未提交的具体改动 |
| `git checkout 文件名` | 丢弃某文件未提交的改动（慎用） |
| `git checkout v1.0-whitelist-dev-verified` | 切到已验证稳定版本（只读参考） |
| `git checkout main` | 回到 main 分支 |

---

## 六、工程构建（代码改完怎么跑）

见 README「环境准备」+「Quick Start」章节。三步：

```bash
cd c_build && make                                    # 1. 编译固件
cd ../build_xilinx_xc7a35tfgg484 && ./build_fpga.sh 0001   # 2. 构建 bitstream（自动克隆依赖IP仓库）
# 3. 烧录 + JTAG 加载固件（见 README / 日报）
```

---

## 七、纪律约定

1. **不要**把构建产物提交进仓库（`.gitignore` 已过滤，`git status` 里出现 `out/`、`.bit`、`a.out` 等不要 add）
2. **不要** force push 到 main
3. 改动较大时先在群里说一声，避免重复劳动
4. main 分支保证可构建：push 前至少跑一遍 `cd c_build && make` 确认编译通过
