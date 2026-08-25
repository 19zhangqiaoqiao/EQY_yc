# 更新记录

## 3.1.0

**压测强度**

- 磁盘 fio 默认改用 `libaio`（回退顺序 `io_uring` → `sync`），带队列深度与多 job 并发；3.0 的 `sync` + 队列深度 1 在 NVMe 上压不出真实能力
- 新增 4 秒带宽探测：确认引擎可用，并据此给测试文件定尺，避免文件过大拖过计划时间
- 磁盘测试文件先完整预铺，读测试不再可能读到文件系统空洞
- GPU 负载改为逐轮可逆校验（正向变换 → 显存带宽读取 → 反向变换 → 全量比对），压测过程中的位翻转会被立刻发现
- CPU 启用 `--cpu-method all`，内存启用 `--vm-method all` 与 `--oom-avoid`，按 stress-ng 实际支持情况自动启用

**报告**

- 新增 Word(.docx) 报告，纯标准库生成 OOXML，不依赖第三方包
- 报告新增「被测系统信息」「性能指标」「运行期遥测汇总」三节，包含 fio 带宽/IOPS/平均与 P99 延迟、stress-ng bogo ops、GPU 计算轮次、各阶段 CPU 利用率与峰值温度、可用内存最低点
- 健康计数改为表格呈现，新增 CPU 降频次数与 GPU ECC 计数
- 邮件正文改为可读摘要，附件按 Word、Markdown、归档排序，超限时优先保住 Word 报告
- 新增 `attach_archive` 配置项

**新增选项**

- `--stages` / `--skip-stages`：只跑部分阶段，时长在所选阶段间按权重重新分配
- `--cpu-workers`、`--mem-percent`、`--disk-engine`、`--disk-iodepth`、`--disk-jobs`、`--max-disk-size`
- `--telemetry-interval`、`--report-format`

**缺陷修复**

- 混合阶段内存的 `max(64MiB, ...)` 会绕过安全上限，可用内存极低时反而强行申请；现在如实标记未完成
- 磁盘空间不足时不再让 fio 带 0 字节 size 去跑并误记 `FAIL`，统一记 `INCOMPLETE`
- 遥测改为常驻采样进程，不再每 5 秒新起一个 Python 解释器
- 内核日志计数在 `dmesg` 受限时回退 `journalctl -k`；环形缓冲回卷造成的负差值不再计入
- 删除从未使用的 fio job 文件生成逻辑
- `preflight` 提前退出不再残留临时目录
- 修正 README 里过期的版本号与错误的解压路径

**可维护性**

- 主脚本从一行流展开为分区的多行 bash，关键决策带注释
- 数据采集、汇总、报告渲染拆为 10 个内嵌 Python 助手，仍保持单文件分发
- 测试从 52 项扩到 98 项，新增内嵌助手编译、Word 包结构、阶段选择、归档内容与临时目录清理检查

## 3.0.0

- 报告、邮件标题和正文改为中文
- 磁盘测试文件上限 32GiB，混合 4K 上限 8GiB
- 每个 fio 任务增加硬超时，避免超过计划时间
- 内存继续预留，避免 OOM
- 新增 `status` 查看进度
- 遥测正确记录 MemAvailable / MemFree

## 2.0.0

- 初版分阶段压测、邮件、安全演练
