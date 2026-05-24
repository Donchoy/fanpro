# FanPro 🌡️

> Beautiful, zero-dependency, real-time CPU/GPU temperature monitoring & manual fan speed control dashboard for Apple Silicon Macs (M1/M2/M3/M4/M5 series). Written completely in Swift.
>
> 专为 Apple Silicon (M1/M2/M3/M4/M5 系列) 芯片 Mac 打造的零依赖、实时 CPU/GPU 温度监控与风扇手动控制终端仪表盘工具。完全使用 Swift 编写。

---

## 🌟 Features / 功能特性

* **No Mock Data / 零 Mock 数据**：Direct connection to hardware sensors via macOS private APIs (`IOHIDEventSystemClient` & `AppleSMC`).
  直接通过 macOS 私有 API 和 AppleSMC 硬件驱动连接真实传感器，获取百分百真实的硬件数据。
* **Advanced TUI Dashboard / 精美控制台仪表盘**：Provides a real-time, custom HSL color-coded temperature and fan speed visual monitor.
  基于 HSL 热力颜色渐变的实时温度及风扇转速可视化终端。
* **Adaptive Height Layout / 终端高度自适应**：Detects terminal height (`winsize`) and automatically collapses panels to prevent scrolling, working just like `top`/`htop`.
  动态检测窗口行数，自适应网格折叠与裁剪，末尾无多余换行，绝对不导致终端滚动条拉长，体验与 `top` 一致。
* **Smart Auto-Sudo / 智能免手动提权**：Detects root permission on startup; if run as a normal user, it automatically spawns `sudo` for fan control and gracefully falls back to read-only mode if cancelled.
  启动时自动检测并自拉起 `sudo` 请求权限；如果用户取消输入密码，则优雅降级为只读监控模式。
* **Safe Exit Guard / 安全退出保障**：Restores all fans to automatic system control and reverts Alternate Screen Buffer immediately upon exit (or SIGINT/SIGTERM).
  退出或被 Ctrl-C 强制终止时，立即将风扇交还系统托管并退回原终端界面，不留任何痕迹。

---

## 🚀 Quick Start / 快速安装与全局运行

To install it globally so you can simply type `fanpro` in any directory to open it:

为了将其安装为全局工具，让你能够在任何路径下直接输入 `fanpro` 运行它：

### 1. Installation / 安装步骤

Run the following commands in your terminal / 在终端运行以下命令：

```bash
# Clone or enter the project directory / 进入项目目录
cd ~/Documents/antigravity/FanPro

# Compile the project / 编译项目
swiftc -O fanpro.swift -o fanpro

# Move to public path for global execution / 拷贝至系统公共路径以支持全局调用
sudo cp fanpro /usr/local/bin/
```

### 2. Run / 运行

Now, you can open your terminal and simply type:

现在，你可以打开任意终端窗口，直接输入下述命令启动：

```bash
fanpro
```

*(Note: The terminal will prompt for your macOS password to acquire the root permission needed to change fan speeds. If you press Ctrl-C to cancel password input, it will fall back to **Read-Only** mode.)*

*(注：终端会自动提示输入 macOS 密码以获取风扇写入权限。若你在密码提示中按 Ctrl-C 取消输入，程序将自动以**只读模式**继续运行。)*

#### Read-Only Bypass / 强制只读启动
If you do not want to trigger the password prompt at all:

如果你完全不想触发 `sudo` 密码提示弹窗：

```bash
fanpro --readonly
```

#### Permanent Silent Root Permission (Optional) / 永久免密静默运行（可选）
If you do not want to input your password every time but still want full control, run this command once to enable `SetUID`:

如果你想以后每次直接输入 `fanpro` 即可静默提权且不需要输密码，可以执行一次以下命令开启 `SetUID`：

```bash
sudo chown root /usr/local/bin/fanpro
sudo chmod u+s /usr/local/bin/fanpro
```

---

## ⌨️ Hotkeys / 快捷键操作

* `Q` or `q` - Quit the application and restore fans to Auto mode. (退出程序并将风扇还给系统托管)
* `I` or `i` - Change the refresh interval (0.1s - 10.0s). (更改刷新时间间隔)
* `F` or `f` - Set fan target speed in percentage (0 - 100%). *(Requires Root)* (输入转速百分比手动控速，需要 Root 权限)
* `A` or `a` - Restore all fans to Automatic system-managed mode. *(Requires Root)* (一键恢复系统自动托管风扇，需要 Root 权限)

---

## 🛠️ Build from Source / 源码编译与开发

If you want to modify the source code, you can compile the Swift file directly using:

如果你想自行修改源码，可以直接使用 swift 编译器重新构建：

```bash
swiftc -O fanpro.swift -o fanpro
```
