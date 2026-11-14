# tmux-notify-jump

[![Syntax](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/syntax.yml)
[![Lint](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/lint.yml)
[![Test](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/test.yml)
[![Quality Gate](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml/badge.svg)](https://github.com/hmgle/tmux-notify-jump/actions/workflows/quality-gate.yml)
[![Release](https://img.shields.io/github/v/release/hmgle/tmux-notify-jump)](https://github.com/hmgle/tmux-notify-jump/releases/latest)

[English](README.md) | **简体中文**

当编码代理完成任务或需要你处理时发出通知，并在点击后返回正确的 tmux pane。支持 Linux、macOS，以及 Codex、Claude Code、Kimi Code、Grok Build、OpenCode、Pi、Step Code 和 omp。你也可以从自己的脚本发送通知。

- **本地桌面：** 点击 **Jump** 返回任务所在的 pane。
- **SSH：** 在 tmux Inbox 中查看待处理任务，再用快捷键跳转。
- **没有 tmux：** 使用 `--focus-only` 把终端窗口置前。

## Demo

https://github.com/user-attachments/assets/9717e123-f016-4c22-b112-eff8ce22f804

## 内容导航

[选择场景](#选择场景) · [安装](#安装) · [接入-agent](#接入-agent) ·
[验证](#验证) · [tmux Inbox](#tmux-inbox) · [配置](#配置) ·
[排障](#排障) · [更新与卸载](#更新与卸载) · [更多文档](#更多文档)

## 选择场景

请安装在**运行代理或任务的机器**上。使用 SSH 时，通常是远程主机；基本
Inbox 流程不需要远程主机上的桌面通知服务。

| 场景 | 默认行为 | 需要安装 |
| --- | --- | --- |
| 本地 Linux/X11 + tmux | 桌面通知带 Jump 操作；后台 pane 的任务也会进入 Inbox | `tmux`、`notify-send`；`xdotool` 用于终端聚焦 |
| 本地 macOS + tmux | 桌面通知；点击后返回 pane | `tmux`、`terminal-notifier`、系统自带 `osascript` |
| SSH 中的代理 + tmux | tmux 消息和 Inbox；默认不弹远程桌面通知 | `tmux`；按下文配置 Inbox |
| Linux/Wayland | 通知和 tmux pane 跳转可用；不能把终端窗口置前 | Linux 通知工具；`xdotool` 不能启用 Wayland 聚焦 |
| 没有 tmux | 桌面通知；点击后聚焦终端，但不会选择 pane | 平台桌面通知工具；使用 `--focus-only` |

所有代理集成都需要 **`jq`**。缺少它时，包装脚本会安静退出，不打断代理。

本地和 SSH 客户端同时连接目标 session 时，默认优先使用 SSH 路由。需要同时
发送到任务主机的桌面时，设置 `TMUX_NOTIFY_REMOTE_MODE=both`。

桌面 Jump 依赖系统通知服务。macOS 的分离通知有时只有一个点击动作，没有
单独的 Dismiss 按钮；需要明确的 Jump/Dismiss 按钮时使用 `--ui dialog`。通过
SSH 使用终端原生弹窗需要本地终端支持；这种弹窗的点击**不会**选择 tmux
pane，详见 [SSH 终端通知](docs/reference.md#terminal-notifications-over-ssh)。

## 安装

### 1. 安装依赖

下面是常见系统的示例，请按发行版替换包名。示例假设已经安装了 `apt` 或
Homebrew。

```bash
# Debian / Ubuntu：本地桌面
sudo apt install git tmux jq libnotify-bin xdotool

# Debian / Ubuntu：远程主机，只使用 Inbox
sudo apt install git tmux jq

# macOS：本地桌面
brew install git tmux jq terminal-notifier
```

按自己的场景选择一条。使用本地弹窗还需要桌面通知服务；想要可搜索的 Inbox
选择器时再安装 `fzf`。自动配置 Claude/Grok 需要 Python 3；配置 Codex 审批
hook 时，如果要检查已有 TOML，则需要 Python 3.11+。运行通知本身不要求
Python。详见[完整依赖说明](docs/reference.md#dependencies)。

### 2. 获取代码并安装

```bash
git clone https://github.com/hmgle/tmux-notify-jump.git
cd tmux-notify-jump
./install.sh --prefix "$HOME/.local" --copy
export PATH="$HOME/.local/bin:$PATH"
command -v tmux-notify-jump
tmux-notify-jump --focus-only --dry-run --title "安装检查" --body "已准备好"
```

默认安装到 `~/.local/bin`。**安装器不会修改 PATH。** 如果该目录还不在
PATH 中，请把 `export PATH=...` 写入 `~/.bashrc` 或 `~/.zshrc`，然后从这个
环境启动代理。

`--copy` 让安装后的脚本不依赖代码目录；请保留代码目录以便更新和卸载。开发
时可以使用 `--symlink`（也是安装器默认模式）：安装的命令会指向代码目录，
所以不能移动或删除该目录。之后的 `./install.sh` 命令都应在该目录运行，并
沿用相同的安装模式和 prefix。

dry-run 只打印设置，不发送通知。接下来选择一个代理集成，或直接按[验证](#验证)
检查独立调用。

## 接入 agent

只选择你实际使用的集成；多个选项可以放在同一次安装命令中。支持修改的已有
配置会先备份；如果安装器跳过或拒绝修改，请阅读输出并按对应指南手动处理。
下表默认安装到 `~/.local/bin`；如果之前安装到其他位置，请追加原来的
`--prefix` 或 `--bindir`。

| Agent | 在代码目录执行 | 此配置默认启用 |
| --- | --- | --- |
| [Codex](docs/integrations.md#codex-cli-integration) | `./install.sh --copy --configure-codex` | 回合完成 |
| [Codex 审批](docs/integrations.md#native-codex-lifecycle-hooks) | `./install.sh --copy --configure-codex --configure-codex-hooks` | 完成 + 请求审批；在 `/hooks` 检查信任 |
| [Claude Code](docs/integrations.md#claude-code-integration) | `./install.sh --copy --configure-claude` | Stop + 权限/空闲提示 |
| [Kimi Code](docs/integrations.md#kimi-code-cli-integration) | `./install.sh --copy --configure-kimi` | 完成、审批、失败回合、后台任务终止 |
| [Grok Build](docs/integrations.md#grok-build-integration) | `./install.sh --copy --configure-grok` | 完成、权限/空闲提示、工具失败 |
| [OpenCode](docs/integrations.md#opencode-integration) | `./install.sh --copy --configure-opencode` | session idle + permission asked |
| [Pi](docs/integrations.md#pi-integration) | `./install.sh --copy --configure-pi` | agent 完全空闲 |
| [Step Code](docs/integrations.md#step-code-integration) | `./install.sh --copy --configure-step` | agent 完全空闲；提示通知需单独开启 |
| [omp](docs/integrations.md#omp-integration) | `./install.sh --copy --configure-omp` | 主 session 停止并空闲 |

配置完成后，请在目标 tmux pane 中**重新启动 agent session**。使用 SSH 时还要
配置 [Inbox 界面](#tmux-inbox)。完成一次简短任务以验证 hook；独立 CLI 测试
不能证明 agent hook 已经生效。

Codex 的 `--configure-codex` 会保留已有的顶层 `notify` 命令，不会覆盖它。审批
hook 需要在 `/hooks` 中完成注册和信任检查。审批事件可能早于自动批准，因此
不一定表示必须人工处理。不要同时为同一任务注册旧版 completion 和原生 `Stop`
通知；原生终端通知和重复提醒的设置见[集成指南](docs/integrations.md)。

## 验证

### 在 tmux 中验证（本地或 SSH）

在想要返回的 pane 中运行：

```bash
(sleep 5; tmux-notify-jump --target "$TMUX_PANE" \
    --title "测试完成" --body "返回原来的 pane" --detach) &
```

等待五秒期间切换到另一个 tmux window，例如按 tmux 前缀键，再按 `c`（默认前缀
是 `Ctrl+b`，`c` 会创建窗口）。

- **本地桌面：** 应看到通知。点击 Jump（macOS 也可能是直接点击通知）后，应
  返回原 pane。如果通知提供 Dismiss，点击它后当前 pane 应保持不变。
- **SSH：** 默认会收到 tmux 消息并产生 Inbox 项目，而不是远程桌面弹窗。配置
  [Inbox](#tmux-inbox) 后按前缀键，再按大写 `N` 返回；未配置界面时可运行
  `tmux-notify-jump --inbox-list` 查看项目。

如果目标 pane 正好是普通客户端当前显示的 pane，任务不会保持为待处理项；请
在延迟测试触发前先切走。

### 没有 tmux 时

```bash
tmux-notify-jump --focus-only --sender-pid "$$" \
    --title "聚焦测试" --body "点击以聚焦此终端" --detach
```

先切换到其他应用，再点击通知。支持窗口聚焦的平台会把终端带回前台；不会发生
pane 跳转。

### 检查配置

```bash
tmux-notify-jump --doctor
```

请在 tmux 中运行以检查服务器。`WARN` 可能只是可选工具或未使用的 agent；
`FAIL` 会以状态码 1 退出，如果服务器不可达，后续检查会停止。doctor 不会发送
通知，也不能验证真实点击行为。没有 tmux 时使用上面的 focus-only 测试。

## tmux Inbox

Inbox 会保存当前没有查看的 pane 的完成和注意事项事件。它在本地和 SSH 中都
可用，即使尚未安装状态栏和快捷键也会开始记录。

在代码目录配置界面：

```bash
./install.sh --copy --configure-tmux
```

然后在**目标 tmux server 中**重新加载配置：

```bash
tmux source-file ~/.tmux.conf
```

如果配置文件不同，请使用真实路径（`--tmux-config /path/to/tmux.conf`）；不需要
重启 server。

- 状态栏显示 `?N`（待处理注意事项）和 `!N`（已完成任务）。
- 按 tmux 前缀键，松开后按**大写 `N`**（`Shift+n`）。默认前缀下就是
  `Ctrl+b`，再按 `Shift+n`；小写 `n` 通常是“下一个 window”。
- 先选择最早的注意事项，再选择最早的完成项，并跳过当前 pane。tmux 3.0+ 在
  已安装确认 hook 时，访问 pane 会确认对应通知。
- 运行 `tmux-notify-jump --inbox-pick` 选择项目。安装 `fzf` 可搜索和预览 pane；
  弹窗需要 tmux 3.2+，旧版本会回退到菜单或列表。

如果大写 `N` 已被占用，请用 `--tmux-key M`（或其他空闲的字母数字键）重新运行
安装器，重新加载配置，再运行 `--doctor`。安装器添加的是 Inbox 区块，不是普通
活动/响铃通知；后者见[tmux 事件 hook](docs/reference.md#tmux-hooks-integration)。
[Inbox 高级行为](docs/reference.md#tmux-inbox)。

## 配置

创建共享 shell 配置文件：

```bash
mkdir -p ~/.config/tmux-notify-jump
# 用编辑器修改 ~/.config/tmux-notify-jump/env
```

例如只加入需要的设置：

```bash
TMUX_NOTIFY_BELL=1                   # 可选：终端响铃，包括 SSH
TMUX_NOTIFY_TERMINAL_METHOD=osc777   # 可选：兼容终端弹出通知
CODEX_NOTIFY_TERMINAL_METHOD=none    # Codex 已发 OSC 时避免重复
```

响铃和 OSC 默认都是关闭的。OSC 要求本地终端支持并启用 OSC 777；它的弹窗
不能跳到来源 pane，应使用 Inbox。响铃/OSC 需要有普通 tmux client 连接，
focus-only 模式不会发送。它们是附加通道，即使 `TMUX_NOTIFY_REMOTE_MODE=suppress`
也不会自动关闭。

| 目标 | 设置或命令 |
| --- | --- |
| 保持默认的本地桌面 + SSH Inbox 路由 | `TMUX_NOTIFY_REMOTE_MODE=tmux`（默认） |
| 在 Inbox 之外增加主机桌面通知 | `TMUX_NOTIFY_REMOTE_MODE=both`（不会把远程桌面通知转发到本地） |
| 只使用主机桌面通知，不保存 Inbox | `TMUX_NOTIFY_REMOTE_MODE=desktop` |
| 使用明确的 Jump/Dismiss 对话框 | `TMUX_NOTIFY_UI=dialog`（Linux 需要 `zenity`、`kdialog` 或 `yad`） |
| 跳 pane 但不把终端窗口置前 | 使用 `--no-activate` |
| 禁用某个 agent 的通知 | 例如 `CLAUDE_NOTIFY_EXCLUDE_EVENTS='*'` |

配置有不同作用域：

| 位置 | 使用者 | 何时生效 |
| --- | --- | --- |
| `~/.config/tmux-notify-jump/env` | shell 通知命令和包装脚本 | 下一次调用；修改 Inbox 初始化设置后需重新加载 tmux 配置 |
| agent 自己的配置 / plugin | agent 的 hook 或扩展加载器 | 重启 agent session，并完成需要的信任检查 |
| agent 进程环境 | `PI_NOTIFY_CMD`、`PI_NOTIFY_HEADLESS` 及 omp/Step 对应选项 | 启动 agent 前导出；TypeScript bridge 不会读取共享 env |
| 命令行参数 | 当前通知命令 | 当前调用；显式参数覆盖对应设置 |

`TMUX_NOTIFY_CONFIG` 可以指定其他共享文件；显式设为空值则跳过文件加载。共享
文件会作为 Bash 读取，其中的赋值可以覆盖继承的环境变量。请保持语法正确，
并为包含空格的值加引号。详见[所有变量和优先级](docs/reference.md#environment-variables)。

## 排障

| 现象 | 先检查 |
| --- | --- |
| `command not found` | 检查 `command -v tmux-notify-jump` 和 PATH；从该 shell 重启 agent。软链接安装要保留代码目录。 |
| SSH 没有通知 | 默认是 tmux 消息/Inbox，不是本地桌面弹窗。配置 Inbox，并从后台 pane 测试。 |
| CLI 测试成功，agent 不通知 | 检查 `jq`、事件过滤器、agent 是否重启，以及 hook 注册/信任；可在共享 env 中启用 `CODEX_NOTIFY_DEBUG=1` 等日志。 |
| 本地没有桌面通知 | 检查平台通知工具、通知权限/勿扰模式和 `--doctor`，再运行 focus-only 测试。 |
| 有通知但没有 Jump | Linux 需要通知服务支持 action（`notify-send -A` / `--wait`）；dialog 模式会提供明确按钮。macOS 可能直接点击通知跳转。 |
| 终端没有置前 | Wayland 不支持聚焦；Linux/X11 需要 `xdotool` 或兼容的 awesome-client；macOS 可能需要 bundle ID。 |
| Inbox 快捷键无效 | 重新加载正确的 tmux 配置，运行 `--doctor` 检查按键是否被占用；使用大写 `N`。 |
| 跳到了错误 pane 或出现重复通知 | 在目标 pane 启动 agent；每类事件只保留一个通知注册，并检查 agent 自带通知。 |

设置 `TMUX_NOTIFY_DEBUG=1` 可记录通知命令日志，默认在
`~/.cache/tmux-notify-jump/debug.log`（或 `XDG_CACHE_HOME` 下）。包装脚本的
日志位置不同，见[集成指南](docs/integrations.md)。使用多个 tmux server 时，
指定 `TMUX_NOTIFY_TMUX_SOCKET` 或 `--tmux-socket`，避免检查错误的 server。
[详细诊断和聚焦排障](docs/reference.md#diagnostics)。

## 更新与卸载

### 更新

在代码目录执行：

```bash
git pull --ff-only
./install.sh --prefix "$HOME/.local" --copy
```

沿用原来的 prefix、安装模式和集成选项（例如 `--configure-pi`），这样复制安装
的 plugin/extension 也会更新。软链接安装会直接读取更新后的代码，但 hook 或
路径改变时仍应重新运行配置。tmux 配置变更后重新加载，启动新的 agent session；
Codex hook 变更后在 `/hooks` 中重新检查。

### 卸载

先删除 agent 中本工具的注册，同时保留其他 hook：

| 集成 | 删除内容 |
| --- | --- |
| Codex | 本工具的顶层 `notify` 和 `hooks.json`/inline hooks 中的对应处理器 |
| Claude / Kimi | 只删除调用本工具包装脚本的 hook 项 |
| Grok | 配置 hooks 目录中的 `tmux-notify-jump.json` |
| OpenCode / Pi / omp | 对应 plugin/extension 目录中的 `tmux-notify-jump.ts` |
| Step | 手动删除 extension，或在卸载命令中加入 `--configure-step` |

默认路径和自定义路径见[集成指南](docs/integrations.md)。`--uninstall` **不会**
自动删除 Codex、Claude、Kimi、Grok、OpenCode、Pi 或 omp 的配置。

如果配置了 Inbox 界面，请在删除安装脚本**之前**从代码目录清理。如果配置了
多个 server，先对其他 server 分别运行
`tmux-notify-jump --tmux-uninit --tmux-socket /path/to/other.sock`；此时可执行
文件必须仍然可用。最后在剩余的目标 tmux server 中运行：

```bash
./install.sh --prefix "$HOME/.local" --uninstall --configure-tmux
```

这会移除标记的 tmux 配置区块、运行中 server 的本工具 Inbox、状态、hook 和
快捷键，**同时删除已安装脚本**。多个 server 时请明确传入
`--tmux-socket /path/to/socket`；清理只作用于指定 server。自定义过时也要传入
原来的 `--tmux-config` / `--bindir`。详见 [Inbox 清理说明](docs/reference.md#tmux-inbox)。

未配置 tmux 时，仅删除安装脚本：

```bash
./install.sh --prefix "$HOME/.local" --uninstall
```

共享 env、备份文件和缓存不会被基础卸载删除；重新安装可能仍会使用它们。确认
自定义位置后，再只删除本工具相关文件。

## 更多文档

中英文 README 覆盖相同的安装和日常使用流程；以下完整集成细节和技术参考为英文。

- [Agent 集成指南](docs/integrations.md)：手动配置、事件过滤、审批提示、profile 和各 agent 日志。
- [英文技术参考](docs/reference.md)：完整 CLI/环境变量、Inbox、BEL/OSC、tmux 兼容性和目标选择。
- [测试与开发](docs/reference.md#tests)：`make check`、测试依赖和仓库结构。
- 执行 `tmux-notify-jump --help` 或 `./install.sh --help` 查看命令帮助。
