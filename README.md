# ⚡ FanPro

> Beautiful, zero-dependency, real-time CPU/GPU temperature monitoring & smart fan control center for Apple Silicon Macs (M1/M2/M3/M4/M5 series). Written completely in Swift.
>
> 专为 Apple Silicon (M1/M2/M3/M4/M5 系列) 芯片 Mac 打造的零依赖、实时 CPU/GPU 温度监控与风扇智能控制终端仪表盘工具。完全使用 Swift 编写。

---

![FanPro TUI Screenshot](https://github.com/user-attachments/assets/8af074d7-1764-42c9-9a7d-1544e4d583a9)

---

## 🌟 Features / 功能特性

* **No Mock Data / 零 Mock 数据**：Direct connection to hardware sensors via macOS private APIs (`IOHIDEventSystemClient` & `AppleSMC`).
  直接通过 macOS 私有 API 和 AppleSMC 硬件驱动连接真实传感器，获取百分百真实的硬件数据。
* **Advanced TUI Dashboard / 精美控制台仪表盘**：Provides a real-time, custom HSL color-coded temperature and fan speed visual monitor.
  基于 HSL 热力颜色渐变的实时温度及风扇转速可视化终端。
* **Smart Cooling Mode [S] / 自动化智能激进散热模式**：
  * **Zero Latency Speed-up**: Automatically increases fan speed immediately when CPU/GPU temperature spikes, avoiding thermal throttling and unlocking maximum performance. (升温零延迟加速，在核心触碰降频墙前强力介入压制温度)
  * **10-Second Hysteresis (Cooling Delay)**: Delays fan ramp-down by a constant 10 seconds to buffer temperature fluctuations, avoiding annoying fan speed oscillations and saving SMC flash write cycles. (降温恒定 10 秒迟滞防抖，平滑减速，防止风扇忽大忽小，极大延长 SMC 硬件寿命)
  * **5% Step Quantization**: Targets speed settings in 5% steps to filter out micro thermal fluctuations. (5% 转速步长量化，杜绝温度微小起伏引发无意义的频繁调速写入)
  * **Thermal Control Rules / 温控变频规则**:
    | Peak Temp ($T_{\text{peak}}$) | Fan Control Target ($Pct$) | Design Purpose / 设计目的 |
    | :--- | :--- | :--- |
    | $T \le 55^\circ\text{C}$ | **System Managed (Auto)** | Fully delegates to native macOS control for absolute silence. (交还系统原生托管，防积灰与噪音) |
    | $55^\circ\text{C} < T \le 70^\circ\text{C}$ | **Smart 30% – 50%** | $Pct = 30 + \frac{T - 55}{15} \times 20$ (低噪介入，从源头上阻止热量堆积) |
    | $70^\circ\text{C} < T \le 85^\circ\text{C}$ | **Smart 50% – 90%** | $Pct = 50 + \frac{T - 70}{15} \times 40$ (强力压制持续高负载核心，释放主频) |
    | $T > 85^\circ\text{C}$ | **Smart 100% (Max Blast)** | Directly overrides to maximum speed to prevent thermal throttling. (全速拉满，在逼近降频墙前强行压回) |
* **Adaptive Height Layout / 终端高度自适应**：Detects terminal height (`winsize`) and automatically collapses panels to prevent scrolling, working just like `top`/`htop`.
  动态检测窗口行数，自适应网格折叠与裁剪，末尾无多余换行，绝对不导致终端滚动条拉长，体验与 `top` 一致。
* **Smart Auto-Sudo / 智能免手动提权**：Detects root permission on startup; if run as a normal user, it automatically spawns `sudo` for fan control and gracefully falls back to read-only mode if cancelled.
  启动时自动检测并自拉起 `sudo` 请求权限；如果用户取消输入密码，则优雅降级为只读监控模式。
* **Safe Exit Guard / 安全退出保障**：Restores all fans to system default automatic control and reverts Alternate Screen Buffer immediately upon exit (or SIGINT/SIGTERM/SIGSEGV).
  退出、被 Ctrl-C 中断或突发异常闪退时，立即将风扇交还系统默认托管并退回原终端界面，保障系统安全。

---

## 🚀 Installation & Global Run / 安装与全局运行

To install it globally so you can simply type `fanpro` in any directory to open it:

为了将其安装为全局工具，让你能够在任何路径下直接输入 `fanpro` 运行它：

### 1. Installation / 安装步骤

Run the following commands in your terminal / 在终端运行以下命令：

```bash
# Clone or enter the project directory / 进入项目目录
cd fanpro

# Compile the project with optimization / 编译优化项目
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

* `A` or `a` - Restore all fans to Automatic system-managed mode. *(Requires Root)* (一键恢复系统默认自动托管风扇，需要 Root 权限)
* `S` or `s` - Enable **Smart Cooling Mode** (Automated dynamic speed curves + 10s cooling delay). *(Requires Root)* (开启自动化智能散热模式，根据温度自适应变频并启用降温防抖，需要 Root 权限)
* `F` or `f` - Set fan target speed in percentage manually (0 - 100%). *(Requires Root)* (输入转速百分比手动控速，需要 Root 权限)
* `I` or `i` - Change the refresh interval in integer seconds (1s - 10s). (更改屏幕刷新时间间隔，仅支持 1 到 10 的整数秒)
* `Q` or `q` - Quit the application and restore fans to system default Auto mode. (退出程序并将风扇还给系统默认托管)

---

## 🛡️ Safety & DVFS Independent / 硬件与降频安全保障

1. **Independent of DVFS (Hardware Safety)**: This tool ONLY communicates with standard fan interfaces (`F{id}md` and `F{id}Tg`) in AppleSMC. It **DOES NOT** contain any code that interferes with CPU/GPU voltage, clock frequencies, or safety thermal threshold limits.
   本工具仅通过 AppleSMC 的官方标准风扇接口交互，**绝不干涉** CPU/GPU 核心工作电压、主频控制（DVFS）或修改主控物理温度安全墙。
2. **Firmware Level Protection**: macOS kernel-level thermal protection (Thermal Throttling at ~100°C) and motherboard thermal shutdown protection (Thermal Shutdown at ~110°C) are managed at the lowest hardware levels. Even while FanPro overrides manual speeds, these protection mechanisms will forcefully take over if temperature bounds are reached, guaranteeing absolute hardware safety.
   macOS 底层固件级降频保护（约 100°C）和主板物理熔断关机保护（约 110°C）具有最高优先级，无论风扇被设为何种转速，核心一旦触碰红线底层将强制执行降频或关机，硬件绝对安全。
