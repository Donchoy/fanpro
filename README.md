# ⚡ FanPro

> Beautiful, zero-dependency, real-time CPU/GPU temperature monitoring & aggressive performance-first fan control center for Apple Silicon Macs (M1/M2/M3/M4/M5 series). Compared with macOS's silence-oriented native thermal policy, FanPro intervenes earlier, ramps harder, and holds cooling longer to suppress thermal buildup before throttling can steal sustained performance.
>
> 专为 Apple Silicon (M1/M2/M3/M4/M5 系列) 芯片 Mac 打造的零依赖、实时 CPU/GPU 温度监控与激进性能优先风扇控制终端仪表盘工具。相比 macOS 偏静音取向的原生温控策略，FanPro 更早介入、更强拉升、更久保持散热，在热量堆积触发降频前主动压制核心温度，释放持续性能。

---

![FanPro TUI Screenshot](https://github.com/user-attachments/assets/dabc1c55-d663-4949-84dd-f73ad531f1e6)

---

## 🌟 Features / 功能特性

* **No Mock Data / 零 Mock 数据**：Direct connection to hardware sensors via macOS private APIs (`IOHIDEventSystemClient` & `AppleSMC`).
  直接通过 macOS 私有 API 和 AppleSMC 硬件驱动连接真实传感器，获取百分百真实的硬件数据。
* **Advanced TUI Dashboard / 精美控制台仪表盘**：Provides a real-time, custom HSL color-coded temperature and fan speed visual monitor.
  基于 HSL 热力颜色渐变的实时温度及风扇转速可视化终端。
* **Performance Mode [S] / 自动化性能模式**：
  * **Zero Latency Speed-up**: Automatically increases fan speed immediately when CPU/GPU temperature spikes, avoiding thermal throttling and unlocking maximum performance. (升温零延迟加速，在核心触碰降频墙前强力介入压制温度)
  * **15-Second Hysteresis (Cooling Delay)**: Delays fan ramp-down by a constant 15 seconds to buffer temperature fluctuations, avoiding annoying fan speed oscillations and saving SMC flash write cycles. (降温恒定 15 秒迟滞防抖，平滑减速，防止风扇忽高忽低，极大延长 SMC 硬件寿命)
  * **5% Step Quantization**: Targets speed settings in 5% steps to filter out micro thermal fluctuations. (5% 转速步长量化，杜绝温度微小起伏引发无意义的频繁调速写入)
  * **Thermal Control Rules / 温控变频规则**:
    | Peak Temp ($T_{\text{peak}}$) | Fan Control Target ($Pct$) | Formula & Slope / 推荐公式与斜率 | Design Purpose / 设计目的 |
    | :--- | :--- | :--- | :--- |
    | $T \le 55^\circ\text{C}$ | **System Managed (Auto)** | Auto (0 RPM) | Fully delegates to native macOS control for absolute silence. (交还系统原生托管，实现静音) |
    | $55^\circ\text{C} < T \le 65^\circ\text{C}$ | **Performance 0% – 20%** | $Pct = (T - 55) \times 2$ (Slope: 2%/°C) | Gentle startup to prevent early heat accumulation softly. (低噪平滑起步，温柔阻止热量堆积) |
    | $65^\circ\text{C} < T \le 75^\circ\text{C}$ | **Performance 20% – 50%** | $Pct = 20 + (T - 65) \times 3$ (Slope: 3%/°C) | Linear progression during sustained load. (持续中等负载下平稳递增压制) |
    | $75^\circ\text{C} < T \le 85^\circ\text{C}$ | **Performance 50% – 80%** | $Pct = 50 + (T - 75) \times 3$ (Slope: 3%/°C) | High-efficiency cooling for performance tasks. (高效散热全力保障高负载输出) |
    | $85^\circ\text{C} < T \le 90^\circ\text{C}$ | **Performance 80% – 100%** | $Pct = 80 + (T - 85) \times 4$ (Slope: 4%/°C) | Rapid speed-up near thermal wall buffer. (在逼近核心温度降频墙前的急速响应) |
    | $T > 90^\circ\text{C}$ | **Performance 100% (Max Blast)** | Max Blast (100%) | Max speed override to block thermal throttling. (全速运转，强力防止核心降频) |
* **Adaptive Height Layout / 终端高度与宽度自适应**：Detects terminal size (`winsize`) and automatically collapses panels to prevent scrolling, working just like `top`/`htop`. It dynamically truncates long strings to fit different terminal widths (45 - 70 columns).
  动态检测窗口行数与列数，实现网格与文本自适应折叠、裁剪与截断，绝对不导致终端滚动条拉长，体验与 `top` 一致。
* **Smart Auto-Sudo / 智能免手动提权**：Detects fan availability and root permission on startup. Fanless Macs skip fan-control sudo entirely; Macs with fans can spawn `sudo` for control and gracefully fall back to read-only mode if cancelled.
  启动时自动检测风扇与权限；无风扇设备不会进入风扇控制提权流程，有风扇设备可自动拉起 `sudo`，用户取消时优雅降级为只读监控模式。
* **Safe Exit Guard / 安全退出保障**：On normal exit or SIGINT/SIGTERM, restores fans that were touched by FanPro to system automatic control and reverts Alternate Screen Buffer. Fatal crash signals are re-raised to macOS after resetting their default handlers.
  正常退出或 Ctrl-C/SIGTERM 中断时，会将 FanPro 接管过的风扇交还系统自动托管并恢复终端界面；致命崩溃信号会恢复默认处理器后交回 macOS。

---

## 🛠️ Detailed Architecture & Core Design / 核心架构与详细设计

To ensure enterprise-grade stability and zero-overhead performance, FanPro implements the following advanced engineering architectures:
为了提供工业级的稳定度与零负载的极高运行效率，FanPro 在底层实现了以下先进的设计架构：

### 1. ⚡ Non-Blocking Keyboard Input State Machine / 非阻塞键盘输入状态机
* **English**: Replaced the blocking `readLine` input loops with a non-blocking `poll` state machine (`gInputMode`). Normal mode sleeps until the next refresh deadline, while active input uses a short 100ms timeout so sensor acquisition, fan RPM refresh, and performance cooling keep running while the user types.
* **Chinese**: 彻底摒弃阻断主线程的 `readLine` 输入模式，改为基于 `poll` 的非阻塞键盘输入状态机（`gInputMode`）。普通模式按下一次刷新截止时间休眠，输入框激活时使用 100ms 短轮询，保证用户输入期间温度采集、风扇转速刷新与性能温控仍持续运行。

### 2. 🛡️ Dual-Process Privilege Auto-Downgrade / 双进程提权与优雅只读降级
* **English**: Replaced the destructive `execvp` mechanism with a robust `posix_spawn` + `waitpid` process wrapper. The parent process spawns a privileged child `sudo ./fanpro --is-sudo-child`. If the user cancels the sudo prompt (Ctrl-C) or inputs a wrong password, the parent process catches the non-zero status and automatically downgrades itself to a pure **Read-Only Dashboard** without crashing. Furthermore, it resolves script paths natively via `realpath` systems to support direct execute-and-elevate behavior on uncompiled `.swift` scripts.
* **Chinese**: 放弃了由于单向进程替换导致密码取消时父进程一并暴死的 `execvp` 机制，改用基于 `posix_spawn` 与 `waitpid` 的双进程提权架构。父进程拉起 `sudo ./fanpro --is-sudo-child`；如果用户按 Ctrl-C 取消密码输入，父进程捕获退出状态并**无缝降级为 Read-Only（只读监控）模式**继续拉起终端。同时，在脚本直接执行模式下自动通过 `realpath` 解析物理真实路径，确保提权绝对可靠。

### 3. 🧹 Fully Retained ARC & Zero Leak I/O / 零泄露 I/O 与 ARC 所有权托管
* **English**: Explicitly handles ownership transfer for unofficial Core Foundation APIs like `IOHIDEventSystemClientCopyServices` and `IOHIDServiceClientCopyProperty` by returning `Unmanaged` wrappers and capturing them via `takeRetainedValue()`. This successfully moves unmanaged allocations into Swift ARC, completely eliminating memory leaks in high-frequency monitoring loop iterations.
* **Chinese**: 针对未公开的 Core Foundation 拷贝方法（如获取传感器列表与属性），将接口声明返回值重构为 `Unmanaged`，并在遍历中执行 `takeRetainedValue()` 进行所有权托管转移。这使得所有 CF 资源能完全交由 Swift 的 ARC 自动回收，彻底杜绝了高频循环刷新采样时的物理内存堆泄漏。

### 4. 🧠 Multi-Die Topo-Aware Design / 多 Die 拓扑感知自适应
* **English**: Detects if the host runs a multi-die processor (like the Apple Silicon M Ultra series). It dynamically maps corresponding sensor arrays to Core Groups (Performance, Efficiency, GPU) for each physical Die, preventing core classification errors commonly found in basic hardware wrappers.
* **Chinese**: 自动识别物理芯片拓扑架构（如 M Ultra 系列双 Die 拼接处理器），动态隔离并将对应的传感器映射至各个 Physical Die 的核心群组（如以 `P-Core D0 1`，`P-Core D1 1` 精准标识），彻底消除了多芯片核心混杂与错置的架构缺陷。

### 5. 🩹 Optional Temperature Sampling & Filtering / 传感器可选型采样与容错过滤
* **English**: Rebuilt `ThermalSensor.temperature` into a safe Optional `Int?` structure with short transient-read tolerance. If core sensors are unavailable, Performance Mode holds the previous target instead of ramping down from a fake `0°C`. Aggregated CPU averages and `coolingPeakTemp` isolate CPU/GPU cores to avoid SSD/Battery noise.
* **Chinese**: 将 `ThermalSensor.temperature` 重构为可选型 `Int?` 并加入短暂读取失败容忍。核心传感器不可用时，性能模式保持当前目标而不是按虚假的 `0°C` 降速；CPU 均温与 `coolingPeakTemp` 仅统计 CPU/GPU 核心，规避 SSD 和电池热噪声干扰。

### 6. 🧼 Double-Buffered SMC Cache & String Optimizations / SMC 缓存与渲染性能优化
* **English**: Physical fan speed thresholds (`minRPM` and `maxRPM`) are queried once and cached during initialization, reducing regular SMC hardware I/O read overhead by **2/3**. Furthermore, text substitutions for sensor display names are precompiled and cached as immutable structures during instantiation, avoiding costly String operations inside the TUI draw cycle.
* **Chinese**: 静态物理转速限幅（最小/最大 RPM）仅在程序初始化时执行一次 SMC 查询并缓存，使得每秒周期刷新时的 SMC 读 I/O 开销减少了 **2/3**。此外，所有温度传感器的简称替换都在构造期一次性预编译缓存，规避了 TUI 绘制大循环中高频进行 String 替换带来的垃圾回收与 CPU 计算开销。

### 7. 🚨 Crash-Safe Fail-Safe Mechanisms / 工业级物理与终端崩溃兜底机制
* **English**: Hooks standard execution termination interrupts for graceful cleanup. Fatal Unix signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`) are re-raised with the default handler to avoid unsafe recovery work inside crash context. During normal paths, `cleanExit` restores termios only if raw mode was enabled and restores fan automatic control when FanPro has successfully touched fan state.
* **Chinese**: 对标准终止中断执行正常清理；对段错误、总线错误、非法指令、除零等致命信号，会重新交给系统默认处理，避免在崩溃上下文里做不安全恢复工作。正常退出路径中，`cleanExit` 只在 Raw 模式启用后恢复终端，并且只在 FanPro 确实成功改写过风扇状态后恢复自动托管。

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

#### Permanent Silent Root Permission (High Risk Optional) / 永久免密静默运行（高风险可选）
SetUID root binaries increase the local security impact of any future bug. Prefer the normal sudo prompt unless you fully understand the tradeoff. If you still want full control without typing your password every time, run:

SetUID root 二进制会放大任何潜在 bug 的本地安全影响。除非你完全理解风险，否则建议使用默认 sudo 提示。如果仍想免密运行，可以执行：

```bash
sudo chown root /usr/local/bin/fanpro
sudo chmod u+s /usr/local/bin/fanpro
```

---

## ⌨️ Hotkeys / 快捷键操作

* `A` or `a` - Restore all fans to Automatic system-managed mode. *(Requires Root)* (一键恢复系统默认自动托管风扇，需要 Root 权限)
* `S` or `s` - Enable **Performance Mode** (Automated dynamic speed curves + 15s cooling delay). *(Requires Root)* (开启性能模式，根据温度自适应变频并启用降温防抖，需要 Root 权限)
* `F` or `f` - Set fan target speed in percentage manually (0 - 100%). *(Requires Root)* (输入转速百分比手动控速，需要 Root 权限)
* `I` or `i` - Change the data refresh interval in integer seconds (1s - 10s). (更改数据刷新时间间隔，仅支持 1 到 10 的整数秒)
* `Q` or `q` - Quit the application and restore fans to system default Auto mode. (退出程序并将风扇还给系统默认托管)

---

## 🛡️ Safety & DVFS Independent / 硬件与降频安全保障

1. **Independent of DVFS (Hardware Safety)**: This tool ONLY communicates with standard fan interfaces (`F{id}md` and `F{id}Tg`) in AppleSMC. It **DOES NOT** contain any code that interferes with CPU/GPU voltage, clock frequencies, or safety thermal threshold limits.
   本工具仅通过 AppleSMC 的官方标准风扇接口交互，**绝不干涉** CPU/GPU 核心工作电压、主频控制（DVFS）或修改主控物理温度安全墙。
2. **Firmware Level Protection**: macOS kernel-level thermal protection (Thermal Throttling at ~100°C) and motherboard thermal shutdown protection (Thermal Shutdown at ~110°C) are managed at the lowest hardware levels. Even while FanPro overrides manual speeds, these protection mechanisms should take over if temperature bounds are reached.
   macOS 底层固件级降频保护（约 100°C）和主板物理熔断关机保护（约 110°C）具有最高优先级，无论风扇被设为何种转速，核心一旦触碰红线底层应会执行降频或关机保护。
