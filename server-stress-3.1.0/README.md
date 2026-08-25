# server-stress 3.1

`server-stress` 是面向 Ubuntu/Debian 服务器的整机压力测试与取证脚本。报告为**中文**，同时输出 **Markdown 和 Word(.docx)** 两份，方便直接发给不看 Markdown 的人。

它只执行检查、测试和报告，不调整系统参数、不修复问题，也不会安装 NVIDIA 驱动、CUDA 或其他 NVIDIA 软件包。

> 压力测试会显著占用 CPU、内存、磁盘和（条件满足时）GPU。请先在维护窗口运行 `preflight` 和安全模式，并确认业务、备份与监控状态。

## 3.1 相对 3.0 的变化

**压测强度**

- 磁盘 fio 默认使用 `libaio`（不可用时依次回退 `io_uring`、`sync`），带队列深度和多 job 并发。3.0 用的是队列深度 1 的 `sync`，在 NVMe 上只能压出真实能力的很小一部分。
- 正式测试前先做一次 4 秒带宽探测：既用来确认引擎真的可用，也用来给测试文件定尺，保证文件能在时间预算内铺开，不会因为文件过大让 fio 拖过计划时间。
- 磁盘测试文件会先用 fio 完整预铺一遍，避免读测试读到文件系统空洞、测出虚高的成绩。
- GPU 负载改为每一轮都做「正向变换 → 显存带宽读取 → 反向变换 → 全量图案比对」。变换是可逆的，因此压测过程中任何一次位翻转都会被抓到；3.0 只在开始时校验一次。
- CPU 阶段启用 `--cpu-method all` 轮换算法，内存阶段启用 `--vm-method all` 与 `--oom-avoid`（按 stress-ng 实际支持情况自动启用）。

**报告与结果**

- 新增 Word(.docx) 报告，纯标准库生成 OOXML，被测机不需要联网也不需要装 `python-docx`。
- 报告新增「被测系统信息」「性能指标」「运行期遥测汇总」三节：fio 的带宽/IOPS/平均延迟/P99 延迟、stress-ng 的 bogo ops、GPU 计算轮次与校验错误、各阶段 CPU 利用率与峰值温度、可用内存最低点。3.0 跑完只有通过/失败，看不到任何数字。
- 健康计数从原始 JSON 改成表格呈现，并新增 CPU 降频次数、GPU ECC 可纠正/不可纠正计数。
- 邮件正文本身就是一份可读摘要，附件顺序为 Word、Markdown、证据归档；超出大小上限时从后往前丢，优先保住 Word 报告。

**缺陷修复**

- 混合阶段内存规模原本写成 `max(64MiB, min(...))`，这个 `max` 会把前面的安全上限直接绕过去；现在可用内存不足就如实标记未完成。
- 磁盘可用空间不足时，3.0 会让 fio 带着 0 字节的 size 去跑然后记 `FAIL`，与内存阶段同样情况记 `INCOMPLETE` 的口径不一致，容易造成误判；现在统一为 `INCOMPLETE`。
- 遥测由「每 5 秒新起一个 Python 解释器」改为常驻采样进程，一小时省掉约 700 次进程创建，采样噪声不再打在被测机自己身上。
- 删掉了从未被使用的 fio job 文件生成逻辑。
- 内核日志计数在 `dmesg` 被限制时回退 `journalctl -k`；环形缓冲回卷导致的负数差值不再当成有效数据。
- `preflight` 提前退出时不再残留临时目录。

**可维护性**

- 主脚本从压缩成一行的写法展开为正常多行 bash，按「基础设施 / 安全校验 / 能力探测 / 规模计算 / 负载阶段 / 汇总输出」分区，关键决策都有注释。
- 数据采集、汇总与报告渲染拆成 10 个内嵌 Python 助手，运行时落盘到私有临时目录，结束即删除。脚本仍然是**单文件**，安装方式不变。
- 测试套件从 52 项扩到 98 项，新增内嵌助手语法编译、Word 包结构校验、阶段选择、报告格式开关、归档内容与临时目录清理等检查。

## 安全获取与安装

不要使用 `curl | bash`、`wget | sh` 或任何"下载后直接交给解释器"的方式。应先下载文件和校验和，离线校验，检查内容，再安装。

以下命令中的 URL 和校验和文件名是发布示例，请替换为实际发布值。

```bash
mkdir -m 700 server-stress-download
cd server-stress-download
curl --fail --show-error --location --proto '=https' \
  --output server-stress-3.1.0.tar.gz \
  https://downloads.example.com/server-stress/server-stress-3.1.0.tar.gz
curl --fail --show-error --location --proto '=https' \
  --output server-stress-3.1.0.tar.gz.sha256 \
  https://downloads.example.com/server-stress/server-stress-3.1.0.tar.gz.sha256
sha256sum --check server-stress-3.1.0.tar.gz.sha256
tar --list --file server-stress-3.1.0.tar.gz
mkdir extracted
tar --extract --gzip --file server-stress-3.1.0.tar.gz \
  --directory extracted --no-same-owner --no-same-permissions
bash -n extracted/server-stress-3.1.0/server-stress.sh
sudo install -o root -g root -m 0755 \
  extracted/server-stress-3.1.0/server-stress.sh /usr/local/sbin/server-stress
```

校验和文件必须来自可信发布渠道。校验失败时不要解压或执行文件。

从 USB 介质导入时，先识别只读挂载点，复制到本地私有目录再校验，不要从 USB 直接运行脚本：

```bash
USB_MOUNT="/media/$USER/STRESS_USB"
mkdir -m 700 "$HOME/server-stress-import"
cp -- "$USB_MOUNT/server-stress-3.1.0.tar.gz" \
  "$USB_MOUNT/server-stress-3.1.0.tar.gz.sha256" \
  "$HOME/server-stress-import/"
cd "$HOME/server-stress-import"
sha256sum --check server-stress-3.1.0.tar.gz.sha256
```

## 另一台机器怎么用

仓库拉下来就能跑，不需要改脚本：

```bash
git clone https://github.com/19zhangqiaoqiao/EQY_yc.git
cd EQY_yc
bash server-stress.sh                                # 交互输入 ID、收件 QQ 邮箱并开始
```

首次交互运行还会配置 QQ 发件邮箱与 SMTP 授权码；后续运行仅输入任务 ID 和收件 QQ 邮箱。屏幕会显示阶段开始、阶段结论和报告/邮件状态。

QQ 发件邮箱必须在网页端开启 SMTP 服务并生成“授权码”，不能使用 QQ 登录密码。授权码只会保存在当前用户的 `~/.config/server-stress/qq-smtp-auth`，配置目录权限是 `0700`，配置与授权码文件权限均为 `0600`；它们不会进入 Git、日志、报告或证据归档。

非交互自动化仍可以使用完整参数：

```bash
bash server-stress.sh preflight --id host2-pre --no-install-deps
bash server-stress.sh run --id host2-1h --duration 1h --email
bash server-stress.sh status                         # 看进度
```

也可以直接解压发布包：

```bash
tar -xzf server-stress-3.1.0.tar.gz
cd server-stress-3.1.0
bash server-stress.sh run --id host2-1h --duration 1h --email
```

`--email` 需要本机先有 `~/.config/server-stress/smtp.conf`（`init-config` 生成，权限 600）。没有邮件配置也能跑，只是不发信，报告仍然落在运行目录里。

## 快速开始

```bash
server-stress help
server-stress preflight --id dc1-host17-maint-20260824 --no-install-deps
```

安全自检和演练不会产生真实压力，也不会安装依赖，但会完整走通报告与归档流程：

```bash
server-stress run --self-test-safe \
  --id dc1-host17-safe-20260824 --output-dir /var/tmp/server-stress-runs
server-stress run --dry-run \
  --id dc1-host17-dry-20260824 --output-dir /var/tmp/server-stress-runs
```

正式执行前应为每台主机、每个维护窗口使用不同的业务 ID。合法 ID 长度为 1–64，只能包含 ASCII 字母、数字、点、下划线和连字符，首字符必须是字母或数字：

```bash
sudo server-stress run --id dc1-web17-20260824T2200Z
sudo server-stress run --id dc1-db03-ticket-4821
```

即使重复传入同一个 `--id`，脚本也会在时间戳后加入随机 nonce，生成唯一的运行目录和 Run ID，不会覆盖已有证据。

## 时长与默认计划

`--duration` 表示计划压力阶段总时长，接受纯秒数或 `s`、`m`、`h` 后缀（换算后为 60–604800 秒），默认 **3600 秒**。默认分配总和恰好为 3600 秒：

| 阶段 | 默认秒数 | 内容 |
|---|---:|---|
| CPU | 480 | `stress-ng` CPU 满载，轮换计算方法 |
| memory | 720 | 有明确上限的内存负载，带校验 |
| disk | 720 | 四个等长 fio 任务：顺序写、顺序读、4K 随机读、4K 随机读写 7:3 |
| GPU | 600 | 条件满足时运行 CUDA 负载，逐轮可逆校验 |
| mixed | 1080 | CPU / 内存 / 磁盘 /（可用时）GPU 同时加压 |

自定义总时长按上述比例整数分配，余数也会被纳入，报告表格中各阶段秒数之和始终等于 `--duration`。

只跑部分阶段时，时长会在所选阶段之间按同样的权重重新分配，总和仍然等于 `--duration`：

```bash
# 只压磁盘和 CPU，两个阶段吃掉全部 30 分钟
sudo server-stress run --id dc1-web17-io --duration 30m --stages cpu,disk

# 跳过 GPU 和混合阶段
sudo server-stress run --id dc1-web17-nogpu --duration 1h --skip-stages gpu,mixed
```

被跳过的阶段在报告里显示为「未执行」，计划秒数为 0，并且会把总体结论压到「部分通过」——刻意缩小范围的测试不应该被记成整机通过。

## 强度调节

默认值适用于大多数机器，需要时可以调：

| 选项 | 默认 | 说明 |
|---|---|---|
| `--cpu-workers N` | 逻辑核数 | CPU 阶段 worker 数 |
| `--mem-percent N` | 55 | 预留之后可用内存的使用比例，10..80 |
| `--disk-engine ENG` | auto | `auto` / `libaio` / `io_uring` / `sync` |
| `--disk-iodepth N` | 32 | fio 队列深度（`sync` 引擎强制为 1） |
| `--disk-jobs N` | min(4, 逻辑核数) | 随机 IO 的并发 job 数 |
| `--max-disk-size SIZE` | 32G | 磁盘测试文件上限 |
| `--telemetry-interval N` | 5 | 遥测采样间隔秒数 |
| `--report-format FMT` | both | `md` / `docx` / `both` |

```bash
# 高端 NVMe：加大队列深度和并发
sudo server-stress run --id dc1-nvme --duration 1h --disk-iodepth 64 --disk-jobs 8

# 内存吃紧的机器：降低内存占用比例
sudo server-stress run --id dc1-tight --duration 1h --mem-percent 30
```

## 依赖与 NVIDIA 行为

正式运行会检查 `python3`、`stress-ng`、`fio`、`tar`、`gzip`、`flock`、`timeout`、`setsid`、`sha256sum`、`findmnt`。缺失标准依赖时，脚本默认通过 Ubuntu/Debian 的 `apt-get` 自动安装；非 root 用户需要可用的 `sudo`。若不允许修改软件包状态，请使用：

```bash
server-stress preflight --id dc1-web17-preflight --no-install-deps
sudo server-stress run --id dc1-web17-maint --no-install-deps
```

在 `--no-install-deps` 下，正式运行遇到缺失依赖会拒绝继续。`--dry-run` 和 `--self-test-safe` 始终跳过依赖安装。

脚本会自动探测 NVIDIA 设备。只有同时检测到 NVIDIA 硬件和已经存在的 `nvcc` 时，才会编译并运行受时限约束的 GPU 负载；编译先尝试 `-arch=native`，失败则退回默认架构。它绝不安装 NVIDIA 驱动、CUDA 或 NVIDIA/CUDA 软件包。硬件或工具链缺失时 GPU 阶段标记为 `UNTESTED`。

## 磁盘和内存边界

- 内存规模基于 `/proc/meminfo` 的可用内存计算：保留至少 1 GiB 或总内存的 20%（取较大者），剩余可用量中最多使用 `--mem-percent`（默认 55%），并分配给不超过 4 个 worker；混合阶段只使用受控子集。
- 内存阶段安全可分配量不足 128 MiB、混合阶段不足 64 MiB 时，不强行测试，阶段标记为 `INCOMPLETE`。
- 磁盘规模基于 `--disk-dir` 文件系统的可用空间计算：保留至少 2 GiB 或文件系统总量的 10%（取较大者），最多使用可用空间的 25%，再受 `--max-disk-size` 封顶；测试文件还会按探测带宽收敛，保证能在时间预算内铺开。混合阶段的 4K 文件另有 8 GiB 上限。
- 可用空间不足 256 MiB 时磁盘阶段标记为 `INCOMPLETE`，不会去写一个快满的文件系统。
- 脚本只接受经 `findmnt` 验证的现有、本地、可写、非符号链接文件系统目录，拒绝 NFS/CIFS/tmpfs/overlay 等。
- fio 只在 `--disk-dir` 下使用唯一命名的隐藏测试文件，不以裸块设备为目标；临时文件的设备号与 inode 会在删除前复核，确认没被替换过。
- 每个 fio 任务都有独立的硬墙钟超时；超时但已产生有效 IO 仍记为完成。

这些边界降低资源耗尽风险，但不能消除压力测试风险。仍需选择维护窗口并持续监控。

**精简置备（thin provisioning）注意**：容量计算基于文件系统自己报告的可用空间。在精简置备的 SAN/LUN、虚拟机磁盘或 WSL 这类环境里，文件系统报告的可用空间可能远大于底层实际可用空间，写满会导致宿主侧写失败。这类机器上请用 `--max-disk-size` 明确限制，例如 `--max-disk-size 4G`。

## 报告

每次运行生成两份报告，内容完全一致：

- `report-<Run-ID>.docx`：Word 文档，可直接双击打开或转发，有标题层级、彩色结论和表格；
- `report-<Run-ID>.md`：Markdown，便于进版本库或贴到工单系统。

报告结构：

1. 测试概述 —— 任务 ID、主机、总体结论、起止时间、计划与实际耗时、执行范围
2. 被测系统信息 —— 厂商型号、序列号、BIOS、操作系统、CPU、内存、磁盘目录与文件系统、GPU 列表
3. 测试结果 —— 各阶段计划秒数、实际秒数、结论、说明
4. 性能指标 —— stress-ng bogo ops、fio 带宽/IOPS/延迟、GPU 计算轮次与校验错误
5. 运行期遥测汇总 —— 各阶段 CPU 利用率、负载峰值、可用内存最低点、最高温度、GPU 峰值温度
6. 健康计数差值 —— EDAC、MCE、AER、OOM、Xid、NVMe、CPU 降频、GPU ECC
7. 资源分配与安全边界 —— 实际使用的容量和 fio 配置
8. 说明 —— 证据位置、免责范围、结论口径

Word 报告用标准库直接生成 OOXML，不依赖第三方 Python 包，被测机不需要联网。

## SMTP/TLS 配置

生成新配置（不会覆盖已有文件）：

```bash
server-stress init-config --config "$HOME/.config/server-stress/smtp.conf"
chmod 600 "$HOME/.config/server-stress/smtp.conf"
```

也可以复制仓库中的示例：

```bash
install -D -m 0600 server-stress.conf.example \
  "$HOME/.config/server-stress/smtp.conf"
```

配置格式：

```ini
[smtp]
host = smtp.example.com
port = 587
security = starttls
username = stress-reports@example.com
from = stress-reports@example.com
to = operations@example.com
password_env = SERVER_STRESS_SMTP_PASSWORD
password_file =
timeout = 30
max_attachment_bytes = 26214400
attach_archive = true
```

- `security` 只能为 `starttls` 或 `ssl`，TLS 证书使用系统信任库校验。
- 密码不得作为命令行参数，也不得直接写入配置。只能二选一：在 `password_env` 中填写环境变量**名称**，或在 `password_file` 中填写密码文件路径。
- SMTP 配置必须是非符号链接的普通文件，权限为 `0600`（只读配置也可使用 `0400`）。密码文件同样如此。
- `max_attachment_bytes` 限制附件总大小。超限时按 Word、Markdown、证据归档的优先级从后往前丢弃，被丢掉的附件名会写进邮件正文，文件仍保留在被测机上。
- `attach_archive = false` 时不附证据归档，只发两份报告，适合归档动辄几十 MB 的场景。
- 示例文件不含真实秘密。不要把真实配置或密码文件提交到版本控制。

环境变量方式（避免密码进入 shell 历史）：

```bash
read -r -s -p 'SMTP password: ' SERVER_STRESS_SMTP_PASSWORD; printf '\n'
export SERVER_STRESS_SMTP_PASSWORD
sudo --preserve-env=SERVER_STRESS_SMTP_PASSWORD \
  server-stress run --id dc1-web17-mail --email \
  --config "$HOME/.config/server-stress/smtp.conf"
unset SERVER_STRESS_SMTP_PASSWORD
```

### QQ 邮箱交互式配置

直接执行仓库根目录的 `bash server-stress.sh` 时，脚本会询问任务 ID、收件 QQ 邮箱；首次使用还会询问发件 QQ 邮箱与隐藏输入的 SMTP 授权码，并自动生成安全配置：

```bash
bash server-stress.sh
```

QQ 邮箱网页端必须先开启 SMTP 服务。输入的是 QQ 邮箱生成的“授权码”，不是 QQ 登录密码。授权码独立保存为 `~/.config/server-stress/qq-smtp-auth`，SMTP 配置保存为 `~/.config/server-stress/smtp.conf`；目录权限为 `0700`，两个文件权限均为 `0600`。需要更换发件 QQ 邮箱时，先安全删除这两个私有文件，再运行：

```bash
rm -f ~/.config/server-stress/smtp.conf ~/.config/server-stress/qq-smtp-auth
bash server-stress.sh setup-qq-mail
```

密码文件方式：

```bash
install -m 0600 /dev/null "$HOME/.config/server-stress/smtp.password"
read -r -s -p 'SMTP password: ' SMTP_SECRET; printf '\n'
printf '%s\n' "$SMTP_SECRET" >"$HOME/.config/server-stress/smtp.password"
unset SMTP_SECRET
```

然后清空 `password_env`，把 `password_file` 设为该文件的绝对路径。

发送邮件失败不会删除本地报告和归档。邮件错误写入 `raw/email-<Run-ID>.log` 和标准错误，但最终退出码仍由测试总体状态决定；自动化应同时检查输出与邮件日志，不要假设存在独立的邮件失败码。

## 状态、产物与退出码

运行期间可以随时查看进度：

```bash
server-stress status
```

进度文件包含当前阶段、状态、已用秒数、计划秒数和完成百分比，以及已完成阶段的结论。

每个运行目录默认为 `/var/tmp/server-stress-runs/<唯一 Run-ID>/`，权限私有。主要产物：

- `report-<Run-ID>.docx`、`report-<Run-ID>.md`：Word 与 Markdown 报告；
- `archive-<Run-ID>.tar.gz`(+`.sha256`)：证据归档，不含私有工作目录；
- `manifest.sha256`：归档内证据的 SHA-256 清单；
- `metadata.json`、`results.json`、`results.tsv`：运行元数据与阶段结论；
- `performance.json`：fio / stress-ng / GPU 性能指标；
- `telemetry-summary.json`：各阶段遥测统计；
- `environment.json`：被测机环境信息；
- `health-*.json`、`health-summary.json`：阶段前后健康计数与差值；
- `email-body.txt`：邮件正文摘要；
- `raw/`：阶段日志、fio JSON、stress-ng YAML；
- `telemetry/`：各阶段遥测 CSV；
- `snapshots/`：`lscpu`、`lsblk`、`sensors`、`dmidecode`、`nvidia-smi -q` 等环境快照；
- `work/`：运行所需的私有工作文件，不纳入归档。

阶段状态含义：

- `PASS`：负载成功完成；
- `FAIL`：已执行的负载返回失败，或临时文件校验失败；
- `INCOMPLETE`：因安全容量、演练模式或范围不完整而没有完成真实测试；
- `UNTESTED`：不具备适用硬件或现成工具链，例如 NVIDIA/nvcc 不可用；
- `SKIPPED`：按 `--stages` / `--skip-stages` 未执行。

总体状态口径：任一阶段 `FAIL` 或关键健康计数恶化为 `FAIL`；存在 `INCOMPLETE` / `UNTESTED` / `SKIPPED` 为 `PARTIAL`；只有非关键健康告警为 `PASS WITH WARNINGS`；其余为 `PASS`。

| 退出码 | 含义 |
|---:|---|
| 0 | 总体 `PASS` 或 `PASS WITH WARNINGS` |
| 1 | 总体 `FAIL` |
| 2 | 用法/参数/前置条件错误，或总体 `PARTIAL` |
| 130 | 收到中断信号（例如 Ctrl-C）；子进程和受控临时文件会被清理 |

收到 `INT`、`TERM` 或 `HUP` 时，脚本会终止其跟踪的工作负载进程组并清理受控临时文件。不要依赖中断运行获得完整报告；先检查运行目录中的现有日志，再以新的唯一 `--id` 重新执行。

## 测试

测试套件只调用公开的安全模式，不施加真实压力，不触碰 apt/sudo/SMTP：

```bash
bash -n tests/test-server-stress.sh
bash tests/test-server-stress.sh
```

98 项检查覆盖参数校验、时长分配、阶段选择、报告与 Word 包结构、归档内容与校验清单、凭据不外泄、临时目录清理，以及内嵌 Python 助手的语法编译。
