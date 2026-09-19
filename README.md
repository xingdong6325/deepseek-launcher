# DeepSeek 启动器

一个 Windows 桌面小工具：双击一个图标，选择打开 **DeepSeek 网页版** 或 **DeepSeek Harness（dsh）**，用 Edge 的无边框 `--app` 窗口打开，关掉窗口后自动收尾。

## 功能

- **双入口**：网页版（`chat.deepseek.com`）与 Harness（本地 `http://127.0.0.1:3080`）
- **图形界面**：Windows 原生 WinForms 界面，无控制台黑框
- **自动更新 / 资源修复**：一键 `npm install` 更新或修复 dsh
- **进度条 + 中断保护**（`op.lock`）
- **窗口大小记忆**：记住上次调好的窗口大小，下次从屏幕正中间打开
- **单实例保护**：重复双击图标会把已开窗口叫回来，不会起冲突

## 运行环境

- Windows（Windows PowerShell 5.1 自带，无需额外安装）
- Microsoft Edge（用它的 `--app` 模式开无边框窗口）
- 若要使用 Harness 入口，另需：
  - Node.js（源码里默认路径 `D:\node.exe`）
  - `@deepseek-ai/dsh`（通过「资源修复」自动安装）

## 使用

1. 双击桌面「DeepSeek 启动器」快捷方式
2. 选择「网页版」或「Harness」
3. 关掉浏览器窗口后，启动器自动退出（Harness 服务也会随之停止）

## 文件说明

| 文件 | 说明 |
|---|---|
| `DeepSeekLauncher.ps1` | 启动器全部逻辑（单文件，约 1200 行） |
| `state.example.json` | 状态文件示例（真实运行时的 `state.json` 不含 token，见下） |

## 注意事项

- 运行时会生成 `state.json`（记录窗口大小、上次访问地址等）。**它含本地 token，不要提交到仓库**，已在 `.gitignore` 里排除。
- 源码里的几个绝对路径（`D:\DeepSeekHarness`、`D:\node.exe`）是本机部署路径，换机器部署时改脚本开头 `$Root`、`$NodeExe` 等常量即可。

## 关于窗口记忆（开发笔记）

Edge 的 `--app` 窗口有两个容易踩的坑，这里都已处理：

1. **DPI 两套单位**：读到的窗口大小是物理像素，`--window-size` 收逻辑像素（DIP），150% 缩放的屏上差 1.5 倍，不换算窗口会变大、位置偏移。
2. **单实例吞参数**：同一个 `--user-data-dir` 下若已有 Edge 在跑，新起的进程会把命令行转发给已有实例，`--window-size/--window-position` 在转发中丢失。解决：每个入口用独立的 `--user-data-dir`。
