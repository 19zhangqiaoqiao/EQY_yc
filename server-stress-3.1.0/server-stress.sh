#!/usr/bin/env bash
#
# server-stress —— 服务器整机压力测试与取证脚本
#
# 设计原则：
#   1. 只做检查、测试和报告，不改系统参数、不修复问题；
#   2. 绝不安装 NVIDIA 驱动、CUDA 或任何 NVIDIA 软件包；
#   3. 所有负载都有明确的容量上限和硬墙钟超时，避免把被测机压死；
#   4. bash 负责流程、安全校验和负载调度，Python 助手负责采样、汇总和报告渲染。
#
# 结构导航（按顺序阅读即可）：
#   基础设施   log/die/parse_*        —— 参数解析与通用工具
#   安全校验   validate_*/acquire     —— 目录、文件系统、单实例锁
#   能力探测   probe_*                —— stress-ng / fio / GPU 可用能力
#   规模计算   sizes/schedule         —— 内存、磁盘容量与时长分配
#   负载阶段   run_cpu ... run_mixed  —— 五个压测阶段
#   汇总输出   summarize/report/mail  —— 报告、归档、邮件
#   Python助手 write_helpers          —— 内嵌助手脚本（文件末尾）
#
set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly VERSION=3.1.2
readonly PROGRAM=server-stress
readonly DEFAULT_OUT=/var/tmp/server-stress-runs
readonly DEFAULT_DISK=/var/tmp

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------
ID=''
OUT="$DEFAULT_OUT"
DISK_DIR="$DEFAULT_DISK"
CONFIG="${HOME:-/root}/.config/server-stress/smtp.conf"
DURATION=3600
NO_INSTALL=0
DRY=0
SAFE=0
EMAIL=0
REPORT_FORMAT=both          # md | docx | both
TELE_INTERVAL=5             # 遥测采样间隔（秒）
DISK_ENGINE=auto            # auto | libaio | io_uring | sync
DISK_IODEPTH=32
DISK_JOBS=0                 # 0 表示自动（min(4, nproc)）
CPU_WORKERS=0               # 0 表示自动（nproc）
MEM_PERCENT=55              # 预留之后可用内存的使用比例
MAX_DISK_BYTES=$((32 * 1024 * 1024 * 1024))
LAYOUT_BUDGET=60            # 允许用于铺开测试文件的秒数预算

RUN=''
KEY=''
LOCKFD=''
TELE_PID=''
HELPERS=''
START=''
START_EPOCH=0
MEM_BYTES=0
MEM_WORKERS=1
MIXED_MEM_BYTES=0
DISK_BYTES=0
MIXED_DISK_BYTES=0
DISK_SRC=''
DISK_FS=''
DISK_DEV=''
FIO_ENGINE=''
FIO_PROBE_MIBPS=0
SIGNALLED=0
CLEANED=0
MARKER=''
SCRATCH_FILE=''
SCRATCH_DEV=''
SCRATCH_INO=''
GPU_BINARY=''
GPU_BACKEND=auto           # auto | gpu-burn | cuda
INSTALL_GPU_BURN=0
GPU_BACKEND_USED=''
GPU_BURN_MEMORY=90
GPU_DRIVER_UNHEALTHY=0
GPU_CRITICAL_HEALTH=0
NVIDIA_EXPECTED_COUNT=''
NVIDIA_EXPECTED_DRIVER=''
NVIDIA_HEALTH_REASON=''

declare -a ALL_STAGES=(cpu memory disk gpu mixed)
declare -a STAGES=()
declare -a PIDS=()
declare -A WEIGHT=([cpu]=480 [memory]=720 [disk]=720 [gpu]=600 [mixed]=1080)
declare -A SEC=() ACTUAL=() STATUS=() NOTE=() SELECTED=()
declare -A CAP=()           # 探测到的可选能力开关

# ---------------------------------------------------------------------------
# 基础设施
# ---------------------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }

usage() {
    cat <<'EOF'
Usage: server-stress.sh [run|preflight|status|init-config|setup-qq-mail|help|version] [options]

直接执行且在终端中运行时，会交互输入任务 ID、收件 QQ 邮箱；首次还会配置 QQ 发件邮箱。
QQ 发件邮箱必须在网页端开启 SMTP 并使用授权码，不能输入 QQ 登录密码。

通用选项
  --id ID                  任务ID，非交互模式必填；格式 [A-Za-z0-9][A-Za-z0-9._-]{0,63}
  --duration N[s|m|h]      压测总时长，60s..7d（默认 3600s）
  --output-dir DIR         运行目录的私有父目录（默认 /var/tmp/server-stress-runs）
  --disk-dir DIR           已存在的本地可写文件系统目录（默认 /var/tmp）
  --config FILE            SMTP 配置（默认 ~/.config/server-stress/smtp.conf）
  --no-install-deps        不自动安装缺失的标准软件包
  --dry-run                只校验、采集证据并出报告，不施加压力
  --self-test-safe         安全自检模式，不施加压力
  --email                  发送报告与证据归档
  --gpu-backend NAME       GPU 后端：auto | gpu-burn | cuda（默认 auto）
  --install-gpu-burn       缺少 GPU-burn 时从官方仓库下载、编译并缓存
  -h, --help               显示帮助

范围与强度
  --stages LIST            只执行指定阶段，逗号分隔：cpu,memory,disk,gpu,mixed 或 all
  --skip-stages LIST       跳过指定阶段
  --cpu-workers N          CPU 阶段 worker 数（默认逻辑核数）
  --mem-percent N          预留之后可用内存的使用比例，10..80（默认 55）
  --disk-engine ENG        fio 引擎：auto|libaio|io_uring|sync（默认 auto）
  --disk-iodepth N         fio 队列深度，1..1024（默认 32）
  --disk-jobs N            fio 并发 job 数（默认 min(4, 逻辑核数)）
  --max-disk-size SIZE     磁盘测试文件上限，如 32G（默认 32G）
  --telemetry-interval N   遥测采样间隔秒数，1..60（默认 5）

报告
  --report-format FMT      md | docx | both（默认 both）

默认 3600s 计划：CPU 480、内存 720、磁盘 720（4 个等长任务）、GPU 600、混合 1080。
自定义时长按同比例分配；只选部分阶段时，时长在所选阶段之间按权重重新分配。
报告为中文，同时输出 Markdown 与 Word(docx)。除非明确传入 --install-gpu-burn，否则不会下载 GPU-burn 或安装 NVIDIA 软件。
磁盘测试文件受上限约束，每个 fio 任务都有硬墙钟超时。
EOF
}

valid_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

# 解析 60s / 30m / 2h 形式的时长，输出秒数
parse_duration() {
    local raw=$1 n suffix
    [[ $raw =~ ^([0-9]+)([smh]?)$ ]] || return 1
    n=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[2]}
    case $suffix in
        m) n=$((n * 60)) ;;
        h) n=$((n * 3600)) ;;
    esac
    ((n >= 60 && n <= 604800)) || return 1
    printf '%s' "$n"
}

# 解析 512M / 32G / 1T 形式的容量，输出字节数
parse_size() {
    local raw=$1 n unit mult=1
    [[ $raw =~ ^([0-9]+)([KMGTkmgt]?)i?[Bb]?$ ]] || return 1
    n=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
    case ${unit^^} in
        K) mult=1024 ;;
        M) mult=$((1024 ** 2)) ;;
        G) mult=$((1024 ** 3)) ;;
        T) mult=$((1024 ** 4)) ;;
    esac
    printf '%s' $((n * mult))
}

need_int() {
    local name=$1 value=$2 lo=$3 hi=$4
    [[ $value =~ ^[0-9]+$ ]] || die "$name 需要整数"
    ((value >= lo && value <= hi)) || die "$name 超出范围 ${lo}..${hi}"
}

need() { (($# > 1)) && [[ -n ${2:-} ]] || die "$1 requires a value"; }

valid_qq_email() {
    [[ $1 =~ ^[A-Za-z0-9._%+-]+@qq\.com$ ]]
}

# 阶段说明里给人看的容量，别在报告里堆一串裸字节
human_bytes() {
    local bytes=$1
    if ((bytes >= 1024 ** 3)); then
        printf '%s.%sGiB' $((bytes / 1024 ** 3)) $((bytes % (1024 ** 3) * 10 / 1024 ** 3))
    elif ((bytes >= 1024 ** 2)); then
        printf '%sMiB' $((bytes / 1024 ** 2))
    else
        printf '%s字节' "$bytes"
    fi
}

parse_stage_list() {
    local list=$1 item found stage
    local -a items=()
    IFS=',' read -r -a items <<<"$list"
    for item in ${items[@]+"${items[@]}"}; do
        [[ -n $item ]] || continue
        found=0
        for stage in "${ALL_STAGES[@]}"; do
            if [[ $item == "$stage" ]]; then
                found=1
                printf '%s\n' "$stage"
            fi
        done
        ((found)) || die "unknown stage: $item"
    done
}

parse() {
    local requested='' skipped='' s
    while (($#)); do
        case $1 in
            --id) need "$@"; ID=$2; shift 2 ;;
            --duration)
                need "$@"
                DURATION=$(parse_duration "$2") || die 'invalid --duration (use 60s..604800s, or m/h)'
                shift 2 ;;
            --output-dir) need "$@"; OUT=$2; shift 2 ;;
            --disk-dir) need "$@"; DISK_DIR=$2; shift 2 ;;
            --config) need "$@"; CONFIG=$2; shift 2 ;;
            --gpu-backend)
                need "$@"
                case $2 in auto|gpu-burn|cuda) GPU_BACKEND=$2 ;; *) die 'invalid --gpu-backend (use auto|gpu-burn|cuda)' ;; esac
                shift 2
                ;;
            --install-gpu-burn) INSTALL_GPU_BURN=1; shift ;;
            --stages) need "$@"; requested=$2; shift 2 ;;
            --skip-stages) need "$@"; skipped=$2; shift 2 ;;
            --cpu-workers) need "$@"; need_int --cpu-workers "$2" 1 4096; CPU_WORKERS=$2; shift 2 ;;
            --mem-percent) need "$@"; need_int --mem-percent "$2" 10 80; MEM_PERCENT=$2; shift 2 ;;
            --disk-engine)
                need "$@"
                case $2 in auto|libaio|io_uring|sync) DISK_ENGINE=$2 ;; *) die 'invalid --disk-engine' ;; esac
                shift 2 ;;
            --disk-iodepth) need "$@"; need_int --disk-iodepth "$2" 1 1024; DISK_IODEPTH=$2; shift 2 ;;
            --disk-jobs) need "$@"; need_int --disk-jobs "$2" 1 256; DISK_JOBS=$2; shift 2 ;;
            --max-disk-size)
                need "$@"
                MAX_DISK_BYTES=$(parse_size "$2") || die 'invalid --max-disk-size'
                ((MAX_DISK_BYTES >= 256 * 1024 * 1024)) || die '--max-disk-size must be at least 256M'
                shift 2 ;;
            --telemetry-interval) need "$@"; need_int --telemetry-interval "$2" 1 60; TELE_INTERVAL=$2; shift 2 ;;
            --report-format)
                need "$@"
                case $2 in md|docx|both) REPORT_FORMAT=$2 ;; *) die 'invalid --report-format' ;; esac
                shift 2 ;;
            --no-install-deps) NO_INSTALL=1; shift ;;
            --dry-run) DRY=1; shift ;;
            --self-test-safe) SAFE=1; shift ;;
            --email) EMAIL=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; (($# == 0)) || die 'unexpected arguments' ;;
            *) die "unknown option: $1" ;;
        esac
    done

    if ((INSTALL_GPU_BURN)) && [[ $GPU_BACKEND == cuda ]]; then
        die '--install-gpu-burn cannot be used with --gpu-backend cuda'
    fi

    # 阶段选择：先取 --stages（缺省全选），再挖掉 --skip-stages。
    # 命令替换在子 shell 里执行，非法阶段名必须靠退出码兜住，否则会被静默忽略。
    local resolved
    if [[ -z $requested || $requested == all ]]; then
        for s in "${ALL_STAGES[@]}"; do SELECTED[$s]=1; done
    else
        resolved=$(parse_stage_list "$requested") || die "invalid --stages: $requested"
        for s in $resolved; do SELECTED[$s]=1; done
    fi
    if [[ -n $skipped ]]; then
        resolved=$(parse_stage_list "$skipped") || die "invalid --skip-stages: $skipped"
        for s in $resolved; do SELECTED[$s]=0; done
    fi
    STAGES=()
    for s in "${ALL_STAGES[@]}"; do
        [[ ${SELECTED[$s]:-0} == 1 ]] && STAGES+=("$s")
    done
    ((${#STAGES[@]})) || die 'no stage selected'
}

# ---------------------------------------------------------------------------
# 安全校验
# ---------------------------------------------------------------------------
find_parent() {
    local p=$1
    while [[ ! -e $p && $p != / ]]; do p=$(dirname -- "$p"); done
    printf '%s' "$p"
}

validate_base() {
    [[ $OUT == /* && $CONFIG == /* ]] || die 'output-dir and config must be absolute'
    [[ ! -L $OUT ]] || die '--output-dir must not be a symlink'

    local parent
    parent=$(find_parent "$OUT")
    [[ -d $parent && ! -L $parent && -w $parent ]] || die '--output-dir parent must be a writable non-symlink directory'

    if [[ -z $ID ]]; then
        if [[ -t 0 ]]; then
            read -r -p 'Enter run ID: ' ID
        else
            die '--id is required in noninteractive mode'
        fi
    fi
    valid_id "$ID" || die 'invalid ID; expected [A-Za-z0-9][A-Za-z0-9._-]{0,63}'
    [[ $ID != . && $ID != .. && $ID != -* ]] || die 'unsafe ID'
}

# 磁盘目录必须是真实存在的本地可写文件系统，且不是符号链接、网络盘或内存盘
validate_disk() {
    [[ -d $DISK_DIR && ! -L $DISK_DIR ]] || die '--disk-dir must be an existing non-symlink directory'

    local real
    real=$(realpath -e -- "$DISK_DIR") || die 'cannot canonicalize --disk-dir'
    [[ -d $real && -w $real ]] || die '--disk-dir is not writable'
    DISK_DIR=$real

    command -v findmnt >/dev/null || die 'findmnt is required to validate disk filesystem'
    DISK_FS=$(findmnt -T "$DISK_DIR" -no FSTYPE 2>/dev/null || true)
    DISK_SRC=$(findmnt -T "$DISK_DIR" -no SOURCE 2>/dev/null || true)
    local opts
    opts=$(findmnt -T "$DISK_DIR" -no OPTIONS 2>/dev/null || true)

    case "$DISK_FS" in
        nfs*|cifs|smb*|sshfs|fuse.*|proc|sysfs|tmpfs|devtmpfs|overlay|squashfs)
            die "--disk-dir filesystem is not approved: $DISK_FS" ;;
    esac
    if [[ $DISK_SRC != /dev/* ]] &&
       [[ $DISK_FS != ext* && $DISK_FS != xfs && $DISK_FS != btrfs && $DISK_FS != zfs && $DISK_FS != f2fs && $DISK_FS != jfs ]]; then
        die 'cannot establish local disk filesystem'
    fi
    [[ ,$opts, != *,ro,* ]] || die '--disk-dir filesystem is read-only'

    # 解析出块设备名，供 /proc/diskstats 采样使用
    if [[ $DISK_SRC == /dev/* ]]; then
        DISK_DEV=$(basename -- "$(realpath -e -- "$DISK_SRC" 2>/dev/null || printf '%s' "$DISK_SRC")")
    fi

    # 写一个 marker 确认目录确实可写，并确认它的 device/inode 不会被人换掉
    local marker="$DISK_DIR/.server-stress-marker-${UID:-0}-$$-$RANDOM"
    [[ ! -e $marker && ! -L $marker ]] || die 'scratch marker collision'
    (umask 077; set -o noclobber; : >"$marker")
    local d1 i1 d2 i2
    read -r d1 i1 < <(stat -c '%d %i' "$marker")
    read -r d2 i2 < <(stat -c '%d %i' "$marker")
    [[ $d1 == "$d2" && $i1 == "$i2" && ! -L $marker ]] || die 'scratch marker identity changed'
    rm -f -- "$marker"
}

acquire() {
    mkdir -p -- "$OUT"
    chmod 700 "$OUT"
    local lock="$OUT/.server-stress.host.lock"
    [[ ! -L $lock ]] || die 'host lock must not be a symlink'
    exec {LOCKFD}>"$lock" || die 'cannot open host lock'
    flock -n "$LOCKFD" || die 'another run holds host lock'
    HELPERS=$(mktemp -d "$OUT/.helpers.XXXXXXXX")
    chmod 700 "$HELPERS"
    write_helpers
    # 从拿到锁和临时目录开始就挂清理钩子，preflight 提前退出也不会留垃圾
    trap cleanup EXIT
    trap signal INT TERM HUP
}

missing() {
    local c
    for c in python3 stress-ng fio tar gzip flock timeout setsid sha256sum findmnt; do
        command -v "$c" >/dev/null || printf '%s\n' "$c"
    done
}

packages_for_commands() {
    local command
    while IFS= read -r command; do
        case $command in
            python3) printf 'python3\n' ;;
            stress-ng) printf 'stress-ng\n' ;;
            fio) printf 'fio\n' ;;
            tar) printf 'tar\n' ;;
            gzip) printf 'gzip\n' ;;
            flock|setsid|findmnt) printf 'util-linux\n' ;;
            timeout|sha256sum) printf 'coreutils\n' ;;
            *) die "no package mapping for required command: $command" ;;
        esac
    done | awk '!seen[$0]++'
}

install_deps() {
    local -a lacking packages
    mapfile -t lacking < <(missing)
    ((${#lacking[@]} == 0)) && return 0
    log "Missing tools: ${lacking[*]}"

    if ((DRY || SAFE || NO_INSTALL)); then
        ((NO_INSTALL)) || log 'safe mode: installation skipped'
        return 0
    fi
    command -v apt-get >/dev/null || die apt-get-unavailable

    local -a sudo_prefix=()
    ((EUID)) && sudo_prefix=(sudo)
    mapfile -t packages < <(printf '%s\n' "${lacking[@]}" | packages_for_commands)
    ((${#packages[@]})) || die 'no packages selected for missing tools'
    "${sudo_prefix[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update
    local transaction
    transaction=$("${sudo_prefix[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get --simulate install --no-install-recommends --no-upgrade "${packages[@]}") ||
        die 'apt dependency simulation failed'
    if grep -Eiq '^(Inst|Remv|Conf)[[:space:]].*(nvidia|cuda|libnvidia)' <<<"$transaction"; then
        log "$transaction"
        die 'refusing dependency transaction that changes NVIDIA/CUDA packages; update drivers separately and reboot first'
    fi
    "${sudo_prefix[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends --no-upgrade "${packages[@]}"
}

# ---------------------------------------------------------------------------
# 能力探测：不同发行版上的 stress-ng / fio 选项差异很大，先问清楚再用
# ---------------------------------------------------------------------------
probe_stress_ng() {
    CAP[sng_yaml]=0
    CAP[sng_oom_avoid]=0
    CAP[sng_cpu_method]=0
    CAP[sng_vm_method]=0
    CAP[sng_times]=0
    command -v stress-ng >/dev/null || return 0

    local help
    help=$(stress-ng --help 2>&1 || true)
    [[ $help == *'--yaml'* ]] && CAP[sng_yaml]=1
    [[ $help == *'--oom-avoid'* ]] && CAP[sng_oom_avoid]=1
    [[ $help == *'--cpu-method'* ]] && CAP[sng_cpu_method]=1
    [[ $help == *'--vm-method'* ]] && CAP[sng_vm_method]=1
    [[ $help == *'--times'* ]] && CAP[sng_times]=1
    return 0
}

# 选定 fio 引擎，并用一次短促的顺序写探测出可用带宽。
# 带宽有两个用途：给测试文件定尺（保证铺开时间可控），以及给报告一个基线。
ensure_disk_engine() {
    [[ -z $FIO_ENGINE ]] || return 0
    command -v fio >/dev/null || { FIO_ENGINE=sync; return 0; }

    local -a candidates=()
    if [[ $DISK_ENGINE == auto ]]; then
        local listed
        listed=$(fio --enghelp 2>/dev/null || true)
        [[ $listed == *libaio* ]] && candidates+=(libaio)
        [[ $listed == *io_uring* ]] && candidates+=(io_uring)
        candidates+=(sync)
    else
        candidates=("$DISK_ENGINE")
        [[ $DISK_ENGINE == sync ]] || candidates+=(sync)
    fi

    local engine probe="$DISK_DIR/.server-stress-probe-$$-$RANDOM.tmp"
    for engine in "${candidates[@]}"; do
        rm -f -- "$probe"
        local depth=$DISK_IODEPTH
        [[ $engine == sync ]] && depth=1
        if timeout --signal=TERM --kill-after=5s 30s fio \
                --name=engine-probe --rw=write --bs=1M --size=256M --runtime=4 --time_based=1 \
                --ioengine="$engine" --iodepth="$depth" --direct=1 --group_reporting=1 \
                --filename="$probe" --output-format=json \
                >"$HELPERS/engine-probe.json" 2>"$HELPERS/engine-probe.err"; then
            if python3 "$HELPERS/fiocheck.py" "$HELPERS/engine-probe.json" >/dev/null 2>&1; then
                FIO_ENGINE=$engine
                FIO_PROBE_MIBPS=$(python3 "$HELPERS/fiocheck.py" --bw-mibps "$HELPERS/engine-probe.json" 2>/dev/null || printf '0')
                break
            fi
        fi
    done
    rm -f -- "$probe"
    [[ -n $FIO_ENGINE ]] || FIO_ENGINE=sync
    [[ $FIO_PROBE_MIBPS =~ ^[0-9]+$ ]] || FIO_PROBE_MIBPS=0
    return 0
}

nvidia_present() {
    if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
        return 0
    fi
    if [[ -d /proc/driver/nvidia/gpus ]] && compgen -G '/proc/driver/nvidia/gpus/*' >/dev/null; then
        return 0
    fi
    command -v lspci >/dev/null &&
        lspci -Dn 2>/dev/null | grep -Eqi '^[0-9a-f:.]+[[:space:]]+030[02]:[[:space:]]+10de:'
}

nvidia_health_check() {
    local label=$1 logfile=$2 output count driver loaded='' ondisk='' detail
    local proc_version=${NVIDIA_PROC_VERSION_FILE:-/proc/driver/nvidia/version}
    NVIDIA_HEALTH_REASON=''
    if ! command -v nvidia-smi >/dev/null; then
        NVIDIA_HEALTH_REASON=nvidia-smi-not-found
        printf 'nvidia_health label=%s status=FAIL reason=nvidia-smi-not-found\n' "$label" >>"$logfile"
        return 1
    fi
    if ! output=$(timeout 15s nvidia-smi \
            --query-gpu=index,uuid,driver_version --format=csv,noheader,nounits 2>&1); then
        detail=$(tr '\r\n' '  ' <<<"$output")
        NVIDIA_HEALTH_REASON=nvml-query-failed
        [[ $output == *'Driver/library version mismatch'* ]] &&
            NVIDIA_HEALTH_REASON=driver-library-version-mismatch
        printf 'nvidia_health label=%s status=FAIL reason=%s detail=%q\n' \
            "$label" "$NVIDIA_HEALTH_REASON" "$detail" >>"$logfile"
        return 1
    fi
    count=$(grep -cve '^[[:space:]]*$' <<<"$output")
    driver=$(awk -F, 'NR==1 {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}' <<<"$output")
    [[ $count =~ ^[1-9][0-9]*$ && $driver =~ ^[0-9.]+$ ]] || {
        NVIDIA_HEALTH_REASON=invalid-nvml-output
        printf 'nvidia_health label=%s status=FAIL reason=invalid-nvml-output\n' "$label" >>"$logfile"
        return 1
    }
    if [[ -r $proc_version ]]; then
        loaded=$(sed -nE 's/.*Kernel Module[[:space:]]+([0-9.]+).*/\1/p' \
            "$proc_version" | head -n 1)
    fi
    if command -v modinfo >/dev/null; then
        ondisk=$(modinfo -F version nvidia 2>/dev/null | head -n 1 || true)
    fi
    printf 'nvidia_health label=%s status=PASS count=%s driver=%s loaded_module=%s disk_module=%s\n' \
        "$label" "$count" "$driver" "${loaded:-NA}" "${ondisk:-NA}" >>"$logfile"

    if [[ -n $loaded && $loaded != "$driver" ]]; then
        NVIDIA_HEALTH_REASON=driver-loaded-module-mismatch
        printf 'nvidia_health label=%s status=FAIL reason=driver-loaded-module-mismatch\n' \
            "$label" >>"$logfile"
        return 1
    fi
    if [[ -n $loaded && -n $ondisk && $loaded != "$ondisk" ]]; then
        NVIDIA_HEALTH_REASON=loaded-disk-module-mismatch
        printf 'nvidia_health label=%s status=FAIL reason=loaded-disk-module-mismatch reboot_required=1\n' \
            "$label" >>"$logfile"
        return 1
    fi
    if [[ -z $NVIDIA_EXPECTED_COUNT ]]; then
        NVIDIA_EXPECTED_COUNT=$count
        NVIDIA_EXPECTED_DRIVER=$driver
    elif [[ $count != "$NVIDIA_EXPECTED_COUNT" || $driver != "$NVIDIA_EXPECTED_DRIVER" ]]; then
        NVIDIA_HEALTH_REASON=inventory-changed
        printf 'nvidia_health label=%s status=FAIL reason=inventory-changed expected_count=%s expected_driver=%s\n' \
            "$label" "$NVIDIA_EXPECTED_COUNT" "$NVIDIA_EXPECTED_DRIVER" >>"$logfile"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 规模计算与时长分配
# ---------------------------------------------------------------------------
sizes() {
    read -r MEM_BYTES MEM_WORKERS MIXED_MEM_BYTES DISK_BYTES MIXED_DISK_BYTES < <(
        python3 "$HELPERS/sizing.py" "$DISK_DIR" "$MEM_PERCENT" "$MAX_DISK_BYTES"
    )
}

# 磁盘测试文件定尺：既要大到打穿页缓存，也要小到能在预算时间内铺开
size_disk_file() {
    local cap=$DISK_BYTES
    ((cap > 0)) || return 0
    if ((FIO_PROBE_MIBPS > 0)); then
        local by_budget=$((FIO_PROBE_MIBPS * 1024 * 1024 * LAYOUT_BUDGET))
        ((by_budget < 1024 * 1024 * 1024)) && by_budget=$((1024 * 1024 * 1024))
        ((cap > by_budget)) && cap=$by_budget
    fi
    DISK_BYTES=$((cap / (4 * 1024 * 1024) * (4 * 1024 * 1024)))
    ((MIXED_DISK_BYTES > DISK_BYTES)) && MIXED_DISK_BYTES=$DISK_BYTES
    return 0
}

# 按权重把总时长分配给所选阶段；余数补给小数部分最大的阶段，保证求和恰好等于总时长
schedule() {
    local s total=$DURATION weight_sum=0 assigned=0
    for s in "${ALL_STAGES[@]}"; do SEC[$s]=0; done
    for s in "${STAGES[@]}"; do weight_sum=$((weight_sum + WEIGHT[$s])); done

    for s in "${STAGES[@]}"; do
        SEC[$s]=$((total * WEIGHT[$s] / weight_sum))
        assigned=$((assigned + SEC[$s]))
    done

    local remainder=$((total - assigned))
    local -A awarded=()
    while ((remainder > 0)); do
        local best='' best_num=-1 num
        for s in "${STAGES[@]}"; do
            [[ ${awarded[$s]:-0} == 1 ]] && continue
            num=$(((total * WEIGHT[$s]) % weight_sum))
            if ((num > best_num)); then
                best=$s
                best_num=$num
            fi
        done
        [[ -n $best ]] || break
        SEC[$best]=$((SEC[$best] + 1))
        awarded[$best]=1
        remainder=$((remainder - 1))
    done
}

newrun() {
    local attempt
    for attempt in {1..8}; do
        KEY="${ID}-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
        if mkdir -m700 "$OUT/$KEY" 2>/dev/null; then
            RUN="$OUT/$KEY"
            break
        fi
    done
    [[ -n $RUN ]] || die 'cannot create unique run directory'
    mkdir -m700 "$RUN/raw" "$RUN/snapshots" "$RUN/telemetry" "$RUN/work"
}

track() { PIDS+=("$1"); }

cleanup() {
    local rc=$? p dev ino
    ((CLEANED)) && return $rc
    CLEANED=1
    trap - EXIT INT TERM HUP

    [[ -n ${TELE_PID:-} ]] && kill "$TELE_PID" 2>/dev/null || true
    if ((${#PIDS[@]})); then
        for p in "${PIDS[@]}"; do
            [[ $p =~ ^[0-9]+$ ]] || continue
            kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
        done
        sleep 1
        for p in "${PIDS[@]}"; do
            [[ $p =~ ^[0-9]+$ ]] || continue
            kill -KILL -- "-$p" 2>/dev/null || true
            wait "$p" 2>/dev/null || true
        done
    fi

    # 只删自己创建、且 device/inode 没被换过的临时文件
    if [[ -n ${SCRATCH_FILE:-} && -f $SCRATCH_FILE && ! -L $SCRATCH_FILE ]]; then
        read -r dev ino < <(stat -c '%d %i' "$SCRATCH_FILE" 2>/dev/null || true)
        if [[ $dev == "$SCRATCH_DEV" && $ino == "$SCRATCH_INO" ]]; then
            rm -f -- "$SCRATCH_FILE"
        else
            log 'scratch identity changed; refusing cleanup'
        fi
    fi
    [[ -n ${MARKER:-} && -f $MARKER && ! -L $MARKER ]] && rm -f -- "$MARKER"
    [[ -n ${HELPERS:-} && -d $HELPERS && $HELPERS == */.helpers.* ]] && rm -rf -- "$HELPERS"
    exit $rc
}

signal() { SIGNALLED=1; exit 130; }

# ---------------------------------------------------------------------------
# 证据采集：环境快照、健康计数、遥测
# ---------------------------------------------------------------------------
snapshots() {
    local dir="$RUN/snapshots"
    python3 "$HELPERS/env.py" "$RUN/environment.json" "$DISK_DIR" "$DISK_SRC" "$DISK_FS" 2>/dev/null || true

    # 这些命令在部分机器上不存在或需要 root，失败一律忽略，不影响压测
    local -a probes=(
        "lscpu:lscpu"
        "lsblk:lsblk -O"
        "meminfo:cat /proc/meminfo"
        "mounts:findmnt -A"
        "sensors:sensors"
        "dmidecode:dmidecode -t system -t bios -t memory"
        "nvidia-smi:nvidia-smi -q"
        "nvme-list:nvme list"
    )
    local entry name cmd
    for entry in "${probes[@]}"; do
        name=${entry%%:*}
        cmd=${entry#*:}
        timeout 20s bash -c "$cmd" >"$dir/$name.txt" 2>&1 || true
        [[ -s $dir/$name.txt ]] || rm -f -- "$dir/$name.txt"
    done
}

health() {
    local phase=$1
    python3 "$HELPERS/health.py" "$RUN/health-${phase}.json" "$phase" || true
}

critical_health_delta() {
    local phase=$1
    python3 - "$RUN/health-${phase}-before.json" "$RUN/health-${phase}-after.json" <<'PY'
import json
import sys

bad = ('oom', 'edac_ue', 'xid', 'nvme_media', 'aer_uncorrected',
       'gpu_ecc_uncorrected')

def load(path):
    try:
        with open(path, encoding='utf-8') as handle:
            return json.load(handle)
    except Exception:
        return {}

before, after = load(sys.argv[1]), load(sys.argv[2])
items = []
if before.get('boot_id') != after.get('boot_id'):
    items.append('boot_id_changed')
for key in bad:
    start, end = before.get(key), after.get(key)
    if isinstance(start, int) and isinstance(end, int) and end > start:
        items.append('%s+%d' % (key, end - start))
print(','.join(items))
PY
}

starttele() {
    local phase=$1
    local guard=$((${SEC[$phase]:-0} + 300))
    setsid python3 "$HELPERS/telemetry.py" \
        "$RUN/telemetry/${phase}.csv" "$TELE_INTERVAL" "$guard" "$DISK_DEV" >>"$RUN/raw/telemetry.log" 2>&1 &
    TELE_PID=$!
    track "$TELE_PID"
}

stoptele() {
    if [[ -n ${TELE_PID:-} ]]; then
        kill "$TELE_PID" 2>/dev/null || true
        wait "$TELE_PID" 2>/dev/null || true
    fi
    TELE_PID=''
}

progress() {
    local stage=$1 state=${2:-running}
    [[ -n ${RUN:-} ]] || return 0
    local now elapsed=0 planned=$DURATION
    now=$(date -u +%s)
    ((START_EPOCH)) && elapsed=$((now - START_EPOCH))
    {
        printf 'run=%s\nphase=%s\nstate=%s\nutc=%s\nelapsed_seconds=%s\nplanned_seconds=%s\n' \
            "$KEY" "$stage" "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$planned"
        if ((planned > 0)); then
            printf 'planned_progress_percent=%s\n' $((elapsed * 100 / planned > 100 ? 100 : elapsed * 100 / planned))
        fi
        [[ -f $RUN/results.tsv ]] && cat "$RUN/results.tsv"
    } >"$RUN/progress.txt"
    cp -f "$RUN/progress.txt" "$OUT/current-status.txt" 2>/dev/null || true
}

result() {
    local stage=$1 status=$2 detail=$3
    STATUS[$stage]=$status
    NOTE[$stage]=$detail
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$stage" "$status" "${SEC[$stage]:-0}" "${ACTUAL[$stage]:-0}" "$detail" >>"$RUN/results.tsv"
    progress "$stage" "$status"
    printf '[%s] %s：%s（实际 %s 秒）\n' \
        "${stage^^}" "$status" "$detail" "${ACTUAL[$stage]:-0}"
}

# 统一的“带组超时”执行器：进程组独立，超时先 TERM 再 KILL
run_cmd() {
    local logfile=$1 budget=$2
    shift 2
    setsid timeout --signal=TERM --kill-after=10s "$((budget + 20))s" "$@" >>"$logfile" 2>&1 &
    local pid=$!
    track "$pid"
    wait "$pid"
}

stage_start() {
    local stage=$1
    ACTUAL[$stage]=$(date -u +%s)
    printf '\n[%s] 开始：计划 %s 秒（总进度 %s%%）\n' \
        "${stage^^}" "${SEC[$stage]:-0}" \
        "$(( START_EPOCH ? (($(date -u +%s) - START_EPOCH) * 100 / DURATION) : 0 ))"
    progress "$stage" running
    health "$stage-before"
    starttele "$stage"
}

stage_end() {
    local stage=$1
    stoptele
    health "$stage-after"
    ACTUAL[$stage]=$(($(date -u +%s) - ${ACTUAL[$stage]:-0}))
}

# 演练/安全模式下的占位阶段：走完全部报告流程，但不施加压力
safe_stage() {
    local stage=$1
    stage_start "$stage"
    printf 'safe_mode=true\nplanned_seconds=%s\n' "${SEC[$stage]:-0}" >"$RUN/raw/$stage.log"
    sleep 0.05
    stage_end "$stage"
    result "$stage" INCOMPLETE '安全模式：只走通校验与报告流程，未施加压力'
}

# ---------------------------------------------------------------------------
# CPU 阶段
# ---------------------------------------------------------------------------
run_cpu() {
    local stage=cpu
    if ((DRY || SAFE)); then safe_stage "$stage"; return; fi

    local workers=${CPU_WORKERS}
    ((workers == 0)) && workers=$(nproc)

    local -a args=(--cpu "$workers" --cpu-load 100 --timeout "${SEC[$stage]}s" --metrics-brief --verify)
    [[ ${CAP[sng_cpu_method]} == 1 ]] && args+=(--cpu-method all)
    [[ ${CAP[sng_times]} == 1 ]] && args+=(--times)
    [[ ${CAP[sng_yaml]} == 1 ]] && args+=(--yaml "$RUN/raw/cpu.yaml")

    stage_start "$stage"
    if run_cmd "$RUN/raw/cpu.log" "${SEC[$stage]}" stress-ng "${args[@]}"; then
        stage_end "$stage"
        result "$stage" PASS "CPU满载完成，${workers}个worker"
    else
        stage_end "$stage"
        result "$stage" FAIL 'CPU压测失败'
    fi
}

# ---------------------------------------------------------------------------
# 内存阶段
# ---------------------------------------------------------------------------
run_memory() {
    local stage=memory
    if ((DRY || SAFE)); then safe_stage "$stage"; return; fi

    local per=0
    ((MEM_WORKERS > 0)) && per=$((MEM_BYTES / MEM_WORKERS))
    if ((per < 128 * 1024 * 1024)); then
        stage_start "$stage"
        stage_end "$stage"
        result "$stage" INCOMPLETE '预留后可用内存不足，跳过以免OOM'
        return
    fi

    local -a args=(--vm "$MEM_WORKERS" --vm-bytes "$per" --vm-keep --timeout "${SEC[$stage]}s" --metrics-brief --verify)
    [[ ${CAP[sng_vm_method]} == 1 ]] && args+=(--vm-method all)
    [[ ${CAP[sng_oom_avoid]} == 1 ]] && args+=(--oom-avoid)
    [[ ${CAP[sng_times]} == 1 ]] && args+=(--times)
    [[ ${CAP[sng_yaml]} == 1 ]] && args+=(--yaml "$RUN/raw/memory.yaml")

    stage_start "$stage"
    if run_cmd "$RUN/raw/memory.log" "${SEC[$stage]}" stress-ng "${args[@]}"; then
        stage_end "$stage"
        result "$stage" PASS "${MEM_WORKERS}个worker各$(human_bytes "$per")，已预留防OOM"
    else
        stage_end "$stage"
        result "$stage" FAIL '内存压测失败'
    fi
}

# ---------------------------------------------------------------------------
# 磁盘阶段
# ---------------------------------------------------------------------------
scratch_open() {
    local path=$1
    [[ ! -e $path && ! -L $path ]] || return 1
    (umask 077; set -o noclobber; : >"$path")
    SCRATCH_FILE=$path
    read -r SCRATCH_DEV SCRATCH_INO < <(stat -c '%d %i' "$path")
    return 0
}

# 关闭前确认 device/inode 未被替换，避免删到别人的文件
scratch_close() {
    local dev ino rc=0
    if [[ -f $SCRATCH_FILE && ! -L $SCRATCH_FILE ]]; then
        read -r dev ino < <(stat -c '%d %i' "$SCRATCH_FILE" 2>/dev/null || true)
        if [[ $dev == "$SCRATCH_DEV" && $ino == "$SCRATCH_INO" ]]; then
            rm -f -- "$SCRATCH_FILE"
        else
            rc=1
        fi
    else
        rc=1
    fi
    SCRATCH_FILE=''
    return $rc
}

# 测试文件一律用绝对路径交给 fio。
# fio 的 --filename 只有在 --directory 已经解析过的情况下才会被拼到该目录下，
# 依赖参数顺序很容易把测试文件写到当前工作目录去，所以这里干脆不用 --directory。
fio_common_args() {
    local depth=$DISK_IODEPTH
    [[ $FIO_ENGINE == sync ]] && depth=1
    printf '%s\n' \
        "--ioengine=$FIO_ENGINE" "--iodepth=$depth" "--direct=1" "--randrepeat=0" \
        "--group_reporting=1" "--percentile_list=95.0:99.0:99.9" "--output-format=json"
}

# 预铺测试文件：让后续读测试读到真实数据，而不是文件系统的空洞
fio_layout() {
    local logfile=$1
    local budget=$((LAYOUT_BUDGET * 3 + 60))
    local -a common
    mapfile -t common < <(fio_common_args)
    printf 'layout start bytes=%s engine=%s budget=%ss\n' "$DISK_BYTES" "$FIO_ENGINE" "$budget" >>"$logfile"
    if timeout --signal=TERM --kill-after=15s "${budget}s" fio \
            --name=layout --rw=write --bs=1M --size="$DISK_BYTES" --create_only=1 \
            --filename="$SCRATCH_FILE" "${common[@]}" >"$RUN/raw/disk-layout.json" 2>>"$logfile"; then
        printf 'layout ok\n' >>"$logfile"
        return 0
    fi
    printf 'layout incomplete (继续测试，读任务可能覆盖不到全部区域)\n' >>"$logfile"
    return 0
}

run_disk() {
    local stage=disk
    if ((DRY || SAFE)); then safe_stage "$stage"; return; fi

    stage_start "$stage"

    # 先确认容量够用再去做引擎探测，避免在快满的文件系统上还写探测文件
    if ((DISK_BYTES < 256 * 1024 * 1024)); then
        stage_end "$stage"
        result "$stage" INCOMPLETE '预留后可用磁盘空间不足，跳过以免写满文件系统'
        return
    fi
    ensure_disk_engine
    size_disk_file
    if ! scratch_open "$DISK_DIR/.server-stress-$KEY.data"; then
        stage_end "$stage"
        result "$stage" INCOMPLETE '磁盘临时文件冲突'
        return
    fi

    local logfile="$RUN/raw/disk.log" prefix="$RUN/raw/disk"
    : >"$logfile"
    printf 'engine=%s iodepth=%s jobs=%s probe_mibps=%s size_bytes=%s\n' \
        "$FIO_ENGINE" "$DISK_IODEPTH" "$(disk_jobs)" "$FIO_PROBE_MIBPS" "$DISK_BYTES" >>"$logfile"
    fio_layout "$logfile"

    # 四个任务：顺序写、顺序读、4K 随机读、4K 随机读写 7:3
    local -a names=(seqwrite seqread randread randrw7030)
    local -a rws=(write read randread randrw)
    local -a bss=(1M 1M 4k 4k)
    local -a jobs=(1 1 "$(disk_jobs)" "$(disk_jobs)")
    local slice=$((SEC[$stage] / 4)) extra=$((SEC[$stage] % 4))
    local -a common
    mapfile -t common < <(fio_common_args)

    local i rc=0 secs exit_code ramp
    for i in {0..3}; do
        secs=$((slice + (i < extra ? 1 : 0)))
        if ((secs <= 0)); then rc=1; continue; fi
        ramp=0
        ((secs >= 40)) && ramp=5

        set +e
        timeout --signal=TERM --kill-after=10s "$((secs + 45))s" fio \
            --name="${names[$i]}" --rw="${rws[$i]}" --rwmixread=70 --bs="${bss[$i]}" \
            --numjobs="${jobs[$i]}" --runtime="$secs" --time_based=1 --ramp_time="$ramp" \
            --size="$DISK_BYTES" --filename="$SCRATCH_FILE" \
            "${common[@]}" >"$prefix-${names[$i]}.json" 2>>"$logfile"
        exit_code=$?
        set -e

        # 被墙钟超时打断但已经产生有效 IO，同样算完成
        if ((exit_code == 0)) ||
           { ((exit_code == 124 || exit_code == 137 || exit_code == 143)) &&
             python3 "$HELPERS/fiocheck.py" "$prefix-${names[$i]}.json" >/dev/null 2>&1; }; then
            printf '%s ok exit=%s seconds=%s\n' "${names[$i]}" "$exit_code" "$secs" >>"$logfile"
        else
            rc=1
            printf '%s fail exit=%s seconds=%s\n' "${names[$i]}" "$exit_code" "$secs" >>"$logfile"
        fi
    done

    # 测试文件必须真的被写过。如果它还是 0 字节，说明 IO 落到了别的地方，
    # 那么上面那些漂亮的带宽数字测的就不是这块盘。
    local written
    written=$(stat -c %s "$SCRATCH_FILE" 2>/dev/null || printf 0)
    if ((written == 0)); then
        rc=1
        printf 'scratch file was never written; IO 没有落在 --disk-dir 上\n' >>"$logfile"
    fi
    scratch_close || { rc=1; printf 'scratch identity/cleanup check failed\n' >>"$logfile"; }
    stage_end "$stage"

    if ((rc == 0)); then
        result "$stage" PASS "顺序/随机读写完成，引擎${FIO_ENGINE}，测试文件$(human_bytes "$DISK_BYTES")"
    else
        result "$stage" FAIL '磁盘fio输出、IO或临时文件校验失败'
    fi
}

disk_jobs() {
    local n=$DISK_JOBS
    if ((n == 0)); then
        n=$(nproc)
        ((n > 4)) && n=4
    fi
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# GPU 阶段
# ---------------------------------------------------------------------------
write_cuda_source() {
    cat >"$RUN/work/gpu_stress.cu" <<'EOF'
// GPU 压测：整数变换 + 显存带宽负载，并且每一轮都做可逆校验。
// 变换 f(v) = rotl(v,5) ^ K 是可逆的，正向 R 轮之后再反向 R 轮应当回到原始图案；
// 只要中途出现位翻转（显存/ECC/供电问题），校验就会报错，而不是只在一开始查一次。
#include <cuda_runtime.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#define CU(x) do { \
    cudaError_t e = (x); \
    if (e != cudaSuccess) { \
        std::fprintf(stderr, "gpu=%d cuda_error=%s call=%s\n", d, cudaGetErrorString(e), #x); \
        failed = 1; \
        return; \
    } \
} while (0)

static const unsigned KEY = 0xa5a5a5a5u;
static const unsigned SEED = 0x9e3779b9u;
static const int ROUNDS = 128;

__device__ __forceinline__ unsigned fwd(unsigned v) { return ((v << 5) | (v >> 27)) ^ KEY; }
__device__ __forceinline__ unsigned inv(unsigned v) { unsigned t = v ^ KEY; return (t >> 5) | (t << 27); }

__global__ void fill(unsigned *x, size_t n)
{
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += (size_t)blockDim.x * gridDim.x)
        x[i] = SEED ^ (unsigned)i;
}

__global__ void mix(unsigned *x, size_t n, int rounds, int forward)
{
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += (size_t)blockDim.x * gridDim.x) {
        unsigned v = x[i];
        if (forward)
            for (int q = 0; q < rounds; q++) v = fwd(v);
        else
            for (int q = 0; q < rounds; q++) v = inv(v);
        x[i] = v;
    }
}

__global__ void check(unsigned *x, size_t n, unsigned *bad)
{
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += (size_t)blockDim.x * gridDim.x)
        if (x[i] != (SEED ^ (unsigned)i)) atomicAdd(bad, 1u);
}

// 显存带宽负载：大步长读写，制造真实的访存压力
__global__ void bandwidth(unsigned *x, size_t n, unsigned *sink)
{
    unsigned acc = 0;
    for (size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x; i < n; i += (size_t)blockDim.x * gridDim.x)
        acc ^= x[i];
    if (acc == 0xffffffffu) atomicAdd(sink, 1u);
}

void one(int d, int sec, std::atomic<int> &failed)
{
    CU(cudaSetDevice(d));
    cudaDeviceProp p{};
    CU(cudaGetDeviceProperties(&p, d));

    size_t freeBytes = 0, totalBytes = 0;
    CU(cudaMemGetInfo(&freeBytes, &totalBytes));

    // 最多用 60% 空闲显存，且至少给驱动/其他进程留 1GiB
    size_t cap = freeBytes * 60 / 100;
    size_t reserved = freeBytes > 1024ULL * 1024 * 1024 ? freeBytes - 1024ULL * 1024 * 1024 : 0;
    size_t b = cap < reserved ? cap : reserved;
    if (b < 64ULL * 1024 * 1024) {
        std::fprintf(stderr, "gpu=%d status=FAIL reason=reserve\n", d);
        failed = 1;
        return;
    }

    size_t n = b / sizeof(unsigned);
    unsigned *x = nullptr, *bad = nullptr, *sink = nullptr;
    CU(cudaMalloc(&x, b));
    CU(cudaMalloc(&bad, sizeof(unsigned)));
    CU(cudaMalloc(&sink, sizeof(unsigned)));
    CU(cudaMemset(bad, 0, sizeof(unsigned)));
    CU(cudaMemset(sink, 0, sizeof(unsigned)));

    int blocks = p.multiProcessorCount * 16, threads = 256;
    fill<<<blocks, threads>>>(x, n);
    CU(cudaGetLastError());
    CU(cudaDeviceSynchronize());
    check<<<blocks, threads>>>(x, n, bad);
    CU(cudaGetLastError());
    CU(cudaDeviceSynchronize());

    unsigned hostBad = 0;
    CU(cudaMemcpy(&hostBad, bad, sizeof(hostBad), cudaMemcpyDeviceToHost));
    if (hostBad) {
        std::fprintf(stderr, "gpu=%d status=FAIL pattern_errors=%u\n", d, hostBad);
        failed = 1;
        cudaFree(sink);
        cudaFree(bad);
        cudaFree(x);
        return;
    }
    std::printf("gpu=%d name=%s bytes=%zu reserve_bytes=%zu status=RUNNING\n", d, p.name, b, freeBytes - b);
    std::fflush(stdout);

    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(sec);
    unsigned long long sweeps = 0;
    unsigned long long verifyErrors = 0;
    while (std::chrono::steady_clock::now() < end) {
        mix<<<blocks, threads>>>(x, n, ROUNDS, 1);
        CU(cudaGetLastError());
        bandwidth<<<blocks, threads>>>(x, n, sink);
        CU(cudaGetLastError());
        mix<<<blocks, threads>>>(x, n, ROUNDS, 0);
        CU(cudaGetLastError());
        CU(cudaMemset(bad, 0, sizeof(unsigned)));
        check<<<blocks, threads>>>(x, n, bad);
        CU(cudaGetLastError());
        CU(cudaDeviceSynchronize());
        CU(cudaMemcpy(&hostBad, bad, sizeof(hostBad), cudaMemcpyDeviceToHost));
        if (hostBad) {
            verifyErrors += hostBad;
            std::fprintf(stderr, "gpu=%d sweep=%llu verify_errors=%u\n", d, sweeps, hostBad);
            failed = 1;
            break;
        }
        ++sweeps;
    }

    CU(cudaFree(sink));
    CU(cudaFree(bad));
    CU(cudaFree(x));
    std::printf("gpu=%d status=%s verify_errors=%llu compute_sweeps=%llu bytes=%zu\n",
                d, verifyErrors ? "FAIL" : "PASS", verifyErrors, sweeps, b);
    std::fflush(stdout);
}

int main(int ac, char **av)
{
    if (ac != 2) return 2;
    int sec = std::atoi(av[1]), n = 0;
    if (sec < 1 || cudaGetDeviceCount(&n) != cudaSuccess || n < 1) return 3;
    std::atomic<int> failed{0};
    std::vector<std::thread> ts;
    for (int d = 0; d < n; d++) ts.emplace_back(one, d, sec, std::ref(failed));
    for (auto &t : ts) t.join();
    return failed ? 9 : 0;
}
EOF
    chmod 600 "$RUN/work/gpu_stress.cu"
}

compile_cuda() {
    local logfile=$1 out="$RUN/work/gpu_stress"
    {
        printf 'nvcc_path=%s\n' "$(command -v nvcc)"
        nvcc --version
        sha256sum "$RUN/work/gpu_stress.cu"
    } >>"$logfile" 2>&1

    # 先试 -arch=native（nvcc >= 11.5），失败再退回默认架构
    local -a attempts=("-O3 -std=c++14 -arch=native -Xcompiler=-pthread" "-O3 -std=c++14 -Xcompiler=-pthread")
    local flags
    for flags in "${attempts[@]}"; do
        # shellcheck disable=SC2086
        if nvcc $flags "$RUN/work/gpu_stress.cu" -o "$out" >>"$logfile" 2>&1; then
            printf 'nvcc_flags=%s\n' "$flags" >>"$logfile"
            [[ -x $out && ! -L $out ]] || return 1
            GPU_BINARY=$out
            return 0
        fi
    done
    return 1
}

gpu_burn_cache_dir() {
    printf '%s' "${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/server-stress/gpu-burn"
}

find_gpu_burn() {
    local candidate
    for candidate in "$(command -v gpu_burn 2>/dev/null || true)" "$(gpu_burn_cache_dir)/gpu_burn"; do
        [[ -n $candidate && -x $candidate && ! -L $candidate ]] || continue
        GPU_BINARY=$candidate
        return 0
    done
    return 1
}

gpu_compute_capability() {
    local cap
    cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:].')
    [[ $cap =~ ^[0-9]{2,3}$ ]] || return 1
    printf '%s' "$cap"
}

install_gpu_burn() {
    local cache source cap revision
    cache=$(gpu_burn_cache_dir)
    source="$cache/source"
    for command in git make nvcc gcc g++; do
        command -v "$command" >/dev/null ||
            { log "GPU-burn requires $command; install it first, then retry."; return 1; }
    done
    cap=$(gpu_compute_capability) ||
        { log 'cannot detect NVIDIA compute capability for GPU-burn build'; return 1; }
    mkdir -p -- "$cache"
    chmod 700 "$cache"
    if [[ ! -d $source/.git ]]; then
        rm -rf -- "$source"
        log 'Downloading GPU-burn from official wilicc/gpu-burn repository...'
        git clone --depth 1 https://github.com/wilicc/gpu-burn.git "$source" || return 1
    fi
    revision=$(git -C "$source" rev-parse HEAD 2>/dev/null || printf unknown)
    {
        printf 'gpu_burn_source=wilicc/gpu-burn\n'
        printf 'gpu_burn_revision=%s\n' "$revision"
        printf 'gpu_burn_compute=%s\n' "$cap"
        printf 'gpu_burn_memory_percent=%s\n' "$GPU_BURN_MEMORY"
    } >>"$1"
    (cd "$source" && make clean && make "COMPUTE=$cap") >>"$1" 2>&1 || return 1
    [[ -x $source/gpu_burn && ! -L $source/gpu_burn ]] || return 1
    install -m 700 "$source/gpu_burn" "$cache/gpu_burn"
    GPU_BINARY="$cache/gpu_burn"
}

prepare_gpu_backend() {
    local logfile=$1
    GPU_BINARY=''
    GPU_BACKEND_USED=''
    if [[ $GPU_BACKEND != cuda ]]; then
        if find_gpu_burn; then
            GPU_BACKEND_USED=gpu-burn
            printf 'gpu_backend=gpu-burn binary=%s memory_percent=%s tensor_cores=try\n' \
                "$GPU_BINARY" "$GPU_BURN_MEMORY" >>"$logfile"
            return 0
        fi
        if ((INSTALL_GPU_BURN)) && install_gpu_burn "$logfile"; then
            GPU_BACKEND_USED=gpu-burn
            return 0
        fi
        printf 'gpu_burn_unavailable=1 install_requested=%s\n' "$INSTALL_GPU_BURN" >>"$logfile"
        [[ $GPU_BACKEND == auto ]] || return 1
        log 'GPU-burn is unavailable; falling back to the built-in CUDA verifier.'
    fi
    command -v nvcc >/dev/null ||
        { printf 'cuda_unavailable=nvcc-not-found\n' >>"$logfile"; return 1; }
    command -v gcc >/dev/null ||
        { printf 'cuda_unavailable=gcc-not-found\n' >>"$logfile"; return 1; }
    write_cuda_source
    compile_cuda "$logfile" || return 1
    GPU_BACKEND_USED=cuda
}

run_gpu_workload() {
    local logfile=$1 seconds=$2
    local -a command
    case $GPU_BACKEND_USED in
        gpu-burn)
            command=("$GPU_BINARY" -tc -m "${GPU_BURN_MEMORY}%" "$seconds")
            ;;
        cuda)
            command=("$GPU_BINARY" "$seconds")
            ;;
        *) return 1 ;;
    esac

    setsid timeout --signal=TERM --kill-after=10s "$((seconds + 20))s" \
        "${command[@]}" >>"$logfile" 2>&1 &
    local pid=$! rc
    track "$pid"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        kill -0 "$pid" 2>/dev/null || break
        if ! nvidia_health_check gpu-runtime "$logfile"; then
            GPU_DRIVER_UNHEALTHY=1
            printf 'gpu_guard action=terminate reason=%s\n' "$NVIDIA_HEALTH_REASON" >>"$logfile"
            kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            set +e
            wait "$pid"
            set -e
            return 125
        fi
    done
    set +e
    wait "$pid"
    rc=$?
    set -e
    return "$rc"
}

run_gpu() {
    local stage=gpu
    if ((DRY || SAFE)); then safe_stage "$stage"; return; fi

    stage_start "$stage"
    local logfile="$RUN/raw/gpu.log"
    : >"$logfile"

    if ! nvidia_present; then
        stage_end "$stage"
        result "$stage" UNTESTED '未检测到NVIDIA设备'
        return
    fi
    if ! nvidia_health_check gpu-before "$logfile"; then
        GPU_DRIVER_UNHEALTHY=1
        stage_end "$stage"
        result "$stage" FAIL "NVIDIA驱动栈不可用（$NVIDIA_HEALTH_REASON），未启动GPU压力"
        return
    fi

    local workload_ok=0
    if prepare_gpu_backend "$logfile"; then
        if [[ $GPU_BACKEND_USED == gpu-burn && ${SEC[$stage]} -ge 30 ]]; then
            if run_gpu_workload "$logfile" 10; then
                if ! nvidia_health_check gpu-after-probe "$logfile"; then
                    GPU_DRIVER_UNHEALTHY=1
                elif run_gpu_workload "$logfile" "$((${SEC[$stage]} - 10))"; then
                    workload_ok=1
                fi
            fi
        elif run_gpu_workload "$logfile" "${SEC[$stage]}"; then
            workload_ok=1
        fi
    fi

    local failure_reason=${NVIDIA_HEALTH_REASON:-}
    local driver_ok=1
    if ! nvidia_health_check gpu-after "$logfile"; then
        GPU_DRIVER_UNHEALTHY=1
        driver_ok=0
        failure_reason=$NVIDIA_HEALTH_REASON
    fi
    stage_end "$stage"
    local critical
    critical=$(critical_health_delta "$stage")
    if [[ -n $critical ]]; then
        GPU_CRITICAL_HEALTH=1
        workload_ok=0
        printf 'gpu_guard critical_health=%s action=skip-mixed\n' "$critical" >>"$logfile"
    fi
    if ((workload_ok && driver_ok)); then
        printf 'gpu_backend=%s status=PASS\n' "$GPU_BACKEND_USED" >>"$logfile"
        if [[ $GPU_BACKEND_USED == gpu-burn ]]; then
            result "$stage" PASS 'GPU-burn Tensor Core 高负载与错误校验通过'
        else
            result "$stage" PASS '全部可见GPU并发计算与逐轮可逆校验通过'
        fi
    else
        if [[ -n $critical ]]; then
            result "$stage" FAIL "GPU阶段出现关键健康异常（$critical），已停止后续混合压测"
        elif ((GPU_DRIVER_UNHEALTHY)); then
            result "$stage" FAIL "GPU压力期间NVIDIA驱动异常（${failure_reason:-runtime-failure}），已终止负载"
        else
            result "$stage" FAIL 'GPU-burn/CUDA 构建、压测或校验失败；NVIDIA驱动仍可访问'
        fi
    fi
}

# ---------------------------------------------------------------------------
# 混合阶段：CPU / 内存 / 磁盘 /（可用时）GPU 同时加压
# ---------------------------------------------------------------------------
run_mixed() {
    local stage=mixed
    if ((DRY || SAFE)); then safe_stage "$stage"; return; fi

    local logfile="$RUN/raw/mixed.log"
    : >"$logfile"
    if ((GPU_DRIVER_UNHEALTHY || GPU_CRITICAL_HEALTH)); then
        stage_start "$stage"
        printf 'mixed_skipped=1 reason=gpu-health-guard\n' >>"$logfile"
        stage_end "$stage"
        result "$stage" INCOMPLETE 'GPU驱动或关键健康计数异常，为保护系统未执行混合负载'
        return
    fi
    if [[ ${STATUS[gpu]:-UNTESTED} == PASS ]] &&
            ! nvidia_health_check mixed-before "$logfile"; then
        GPU_DRIVER_UNHEALTHY=1
        stage_start "$stage"
        stage_end "$stage"
        result "$stage" INCOMPLETE "NVIDIA驱动状态变化（$NVIDIA_HEALTH_REASON），未执行混合负载"
        return
    fi

    sizes                    # 重新采样一次可用内存，避免沿用前面阶段的旧值
    if ((DISK_BYTES >= 256 * 1024 * 1024)); then
        ensure_disk_engine
        size_disk_file
    fi
    stage_start "$stage"

    local cpu_workers
    cpu_workers=$(nproc)
    ((cpu_workers > 4)) && cpu_workers=4

    local do_mem=1 do_disk=1
    ((MIXED_MEM_BYTES >= 64 * 1024 * 1024)) || do_mem=0
    ((MIXED_DISK_BYTES >= 64 * 1024 * 1024)) || do_disk=0

    if ((do_disk)) && ! scratch_open "$DISK_DIR/.server-stress-$KEY.mixed"; then
        stage_end "$stage"
        result "$stage" INCOMPLETE '混合阶段临时文件冲突'
        return
    fi

    local rc=0 partial=0 pid_cpu pid_mem='' pid_fio='' pid_gpu='' gpu_scope=unavailable
    local -a missing_scope=()

    local -a cpu_args=(--cpu "$cpu_workers" --timeout "${SEC[$stage]}s" --metrics-brief)
    [[ ${CAP[sng_yaml]} == 1 ]] && cpu_args+=(--yaml "$RUN/raw/mixed-cpu.yaml")
    setsid stress-ng "${cpu_args[@]}" >>"$logfile" 2>&1 &
    pid_cpu=$!
    track "$pid_cpu"

    if ((do_mem)); then
        local -a mem_args=(--vm 1 --vm-bytes "$MIXED_MEM_BYTES" --vm-keep --timeout "${SEC[$stage]}s" --metrics-brief)
        [[ ${CAP[sng_oom_avoid]} == 1 ]] && mem_args+=(--oom-avoid)
        [[ ${CAP[sng_yaml]} == 1 ]] && mem_args+=(--yaml "$RUN/raw/mixed-memory.yaml")
        setsid stress-ng "${mem_args[@]}" >>"$logfile" 2>&1 &
        pid_mem=$!
        track "$pid_mem"
    else
        partial=1
        missing_scope+=(内存)
        printf 'memory skipped: 可用内存不足 64MiB\n' >>"$logfile"
    fi

    if ((do_disk)); then
        local -a common
        mapfile -t common < <(fio_common_args)
        setsid timeout --signal=TERM --kill-after=15s "$((SEC[$stage] + 60))s" fio \
            --name=mixed-randrw --rw=randrw --rwmixread=70 --bs=4k --numjobs="$(disk_jobs)" \
            --runtime="${SEC[$stage]}" --time_based=1 --size="$MIXED_DISK_BYTES" \
            --filename="$SCRATCH_FILE" "${common[@]}" \
            >"$RUN/raw/mixed-fio.json" 2>>"$logfile" &
        pid_fio=$!
        track "$pid_fio"
    else
        partial=1
        missing_scope+=(磁盘)
        printf 'disk skipped: 可用磁盘空间不足 64MiB\n' >>"$logfile"
    fi

    if [[ ${STATUS[gpu]:-UNTESTED} == PASS && -n $GPU_BINARY && -x $GPU_BINARY && ! -L $GPU_BINARY ]]; then
        if [[ $GPU_BACKEND_USED == gpu-burn ]]; then
            setsid timeout --signal=TERM --kill-after=10s "$((SEC[$stage] + 20))s" \
                "$GPU_BINARY" -tc -m "${GPU_BURN_MEMORY}%" "${SEC[$stage]}" >>"$logfile" 2>&1 &
        else
            setsid timeout --signal=TERM --kill-after=10s "$((SEC[$stage] + 20))s" \
                "$GPU_BINARY" "${SEC[$stage]}" >>"$logfile" 2>&1 &
        fi
        pid_gpu=$!
        track "$pid_gpu"
        gpu_scope="all-visible/$GPU_BACKEND_USED"
    else
        partial=1
        missing_scope+=(GPU)
    fi

    wait "$pid_cpu" || rc=1
    if [[ -n $pid_mem ]]; then
        wait "$pid_mem" || rc=1
    fi
    if [[ -n $pid_fio ]]; then
        set +e
        wait "$pid_fio"
        local fio_rc=$?
        set -e
        if ((fio_rc == 0)) ||
           { ((fio_rc == 124 || fio_rc == 137 || fio_rc == 143)) &&
             python3 "$HELPERS/fiocheck.py" "$RUN/raw/mixed-fio.json" >/dev/null 2>&1; }; then
            printf 'fio ok exit=%s size=%s\n' "$fio_rc" "$MIXED_DISK_BYTES" >>"$logfile"
        else
            printf 'fio fail exit=%s\n' "$fio_rc" >>"$logfile"
            rc=1
        fi
    fi
    if [[ -n $pid_gpu ]]; then
        set +e
        wait "$pid_gpu"
        local gpu_rc=$?
        set -e
        ((gpu_rc == 0)) || rc=1
        if ! nvidia_health_check mixed-after "$logfile"; then
            GPU_DRIVER_UNHEALTHY=1
            rc=1
        fi
    fi

    if ((do_disk)); then
        local written
        written=$(stat -c %s "$SCRATCH_FILE" 2>/dev/null || printf 0)
        if ((written == 0)); then
            rc=1
            printf 'scratch file was never written; IO 没有落在 --disk-dir 上\n' >>"$logfile"
        fi
        scratch_close || { rc=1; printf 'scratch identity/cleanup check failed\n' >>"$logfile"; }
    fi
    stage_end "$stage"

    printf 'scope cpu_workers=%s memory_bytes=%s disk_bytes=%s engine=%s gpu=%s\n' \
        "$cpu_workers" "$MIXED_MEM_BYTES" "$MIXED_DISK_BYTES" "$FIO_ENGINE" "$gpu_scope" >>"$logfile"

    if ((rc)); then
        result "$stage" FAIL '混合阶段CPU/内存/磁盘/GPU子进程或临时文件校验失败'
    elif ((partial)); then
        local absent
        absent=$(IFS=/; printf '%s' "${missing_scope[*]-}")
        result "$stage" INCOMPLETE "并发完成，但${absent:-部分范围}不在测试范围内"
    else
        result "$stage" PASS "CPU/受限内存/磁盘fio/全部可见GPU并发完成（混合磁盘$(human_bytes "$MIXED_DISK_BYTES")）"
    fi
}

# ---------------------------------------------------------------------------
# 汇总、报告、归档、邮件
# ---------------------------------------------------------------------------
write_context() {
    local s
    local -a kv=(
        "run_key=$KEY" "id=$ID" "version=$VERSION" "started_utc=$START"
        "duration_seconds=$DURATION" "disk_dir=$DISK_DIR" "disk_source=$DISK_SRC"
        "disk_fs=$DISK_FS" "disk_dev=$DISK_DEV" "memory_bytes=$MEM_BYTES"
        "memory_workers=$MEM_WORKERS" "mixed_memory_bytes=$MIXED_MEM_BYTES"
        "disk_bytes=$DISK_BYTES" "mixed_disk_bytes=$MIXED_DISK_BYTES"
        "fio_engine=${FIO_ENGINE:-none}" "fio_iodepth=$DISK_IODEPTH" "fio_jobs=$(disk_jobs)"
        "fio_probe_mibps=$FIO_PROBE_MIBPS" "mem_percent=$MEM_PERCENT"
        "max_disk_bytes=$MAX_DISK_BYTES" "telemetry_interval=$TELE_INTERVAL"
        "cpu_workers=$CPU_WORKERS" "safe_mode=$((DRY || SAFE ? 1 : 0))"
        "signalled=$SIGNALLED"
    )
    for s in "${ALL_STAGES[@]}"; do
        kv+=("selected_$s=${SELECTED[$s]:-0}")
    done
    python3 "$HELPERS/mkjson.py" "$RUN/work/context.json" "${kv[@]}"
}

summarize() {
    write_context
    python3 "$HELPERS/summarize.py" "$RUN"
}

report() {
    local md='-' docx='-'
    [[ $REPORT_FORMAT == md || $REPORT_FORMAT == both ]] && md="$RUN/report-$KEY.md"
    [[ $REPORT_FORMAT == docx || $REPORT_FORMAT == both ]] && docx="$RUN/report-$KEY.docx"
    python3 "$HELPERS/report.py" "$RUN" "$md" "$docx" || die 'report generation failed'
}

archive() {
    local ar="$RUN/archive-$KEY.tar.gz" tmp inv
    tmp=$(mktemp "$OUT/.archive.XXXXXXXX")
    inv=$(mktemp "$OUT/.inventory.XXXXXXXX")
    (
        cd "$RUN"
        find raw telemetry snapshots -type f ! -name 'email-*' -print0 2>/dev/null
        find . -maxdepth 1 -type f \( \
            -name 'health-*.json' -o -name metadata.json -o -name results.json \
            -o -name results.tsv -o -name environment.json -o -name performance.json \
            -o -name telemetry-summary.json -o -name 'report-*.md' -o -name 'report-*.docx' \
            \) -print0
    ) | sort -zu >"$inv"

    python3 "$HELPERS/checkmembers.py" "$RUN" "$inv"
    (
        cd "$RUN"
        xargs -0 sha256sum <"$inv" >manifest.sha256
        { cat "$inv"; printf './manifest.sha256\0'; } | tar --null -T - -czf "$tmp"
    )
    tar -tzf "$tmp" >/dev/null
    mv "$tmp" "$ar"
    sha256sum "$ar" >"$ar.sha256"
    rm -f "$inv"
    chmod 600 "$ar" "$ar.sha256"
    printf '%s' "$ar"
}

config_check() {
    local p=$1
    [[ -f $p && ! -L $p ]] || return 1
    [[ $(stat -c %a "$p") =~ ^(400|600)$ ]] || return 1
    [[ $(stat -c %u "$p") -eq $EUID ]]
}

sendmail_report() {
    local archive_path=$1 overall=$2 logfile="$RUN/raw/email-$KEY.log"
    if ! config_check "$CONFIG"; then
        log 'email config must be owned by caller, regular, non-symlink, mode 0400/0600'
        return 1
    fi
    printf '\n正在发送 Word 报告到收件邮箱…\n'
    if python3 "$HELPERS/mailer.py" "$CONFIG" "$RUN" "$archive_path" "$overall" >"$logfile" 2>&1; then
        printf '邮件已发送成功。\n'
        return 0
    fi
    log "邮件发送失败；详情见 $logfile"
    return 1
}

setup_qq_mail() {
    local config_dir auth_file sender auth
    config_dir=$(dirname -- "$CONFIG")
    auth_file="$config_dir/qq-smtp-auth"

    [[ $CONFIG == /* ]] || die 'SMTP configuration path must be absolute'
    [[ ! -e $CONFIG && ! -L $CONFIG ]] || die "SMTP config already exists: $CONFIG"
    [[ ! -e $auth_file && ! -L $auth_file ]] || die "QQ SMTP authorization file already exists: $auth_file"

    printf '\n首次使用需要配置 QQ 发件邮箱。\n'
    printf '请先在 QQ 邮箱网页端开启 SMTP 服务并取得“授权码”；不要输入 QQ 登录密码。\n'
    while :; do
        read -r -p '发件 QQ 邮箱：' sender
        valid_qq_email "$sender" && break
        printf '请输入有效的 QQ 邮箱，例如 name@qq.com。\n' >&2
    done
    while :; do
        read -r -s -p 'QQ SMTP 授权码（隐藏输入）：' auth
        printf '\n'
        [[ -n $auth && ${#auth} -le 128 && $auth != *$'\n'* && $auth != *$'\r'* ]] && break
        printf '授权码不能为空。\n' >&2
    done

    mkdir -p -- "$config_dir"
    chmod 700 "$config_dir"
    (
        umask 077
        printf '%s\n' "$auth" >"$auth_file"
        cat >"$CONFIG" <<EOF
[smtp]
host = smtp.qq.com
port = 465
security = ssl
username = $sender
from = $sender
to = $sender
password_env =
password_file = $auth_file
timeout = 30
max_attachment_bytes = 26214400
attach_archive = true
EOF
    )
    unset auth
    chmod 600 "$auth_file" "$CONFIG"
    printf 'QQ 邮件配置已保存到 %s（授权码单独保存，权限 600）。\n' "$config_dir"
}

set_qq_recipient() {
    local recipient=$1 temp
    valid_qq_email "$recipient" || die 'recipient must be a valid QQ email address'
    config_check "$CONFIG" || die 'QQ SMTP config is missing or insecure; run setup-qq-mail first'

    temp=$(mktemp "${CONFIG}.XXXXXXXX") || die 'cannot create temporary SMTP config'
    chmod 600 "$temp"
    awk -v recipient="$recipient" '
        BEGIN { updated = 0 }
        /^\[smtp\]$/ { in_smtp = 1 }
        in_smtp && /^[[:space:]]*to[[:space:]]*=/ {
            print "to = " recipient
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) exit 10
        }
    ' "$CONFIG" >"$temp" || {
        rm -f -- "$temp"
        die 'cannot update SMTP recipient'
    }
    mv -f -- "$temp" "$CONFIG"
    chmod 600 "$CONFIG"
}

init_config() {
    local p=$CONFIG
    while (($#)); do
        case $1 in
            --config) need "$@"; p=$2; shift 2 ;;
            -h|--help) printf 'Usage: server-stress.sh init-config [--config FILE]\n'; return ;;
            *) die "unknown option $1" ;;
        esac
    done
    [[ $p == /* && ! -e $p ]] || die 'config path must be absolute and new'
    mkdir -p "$(dirname "$p")"
    chmod 700 "$(dirname "$p")"
    (
        umask 077
        cat >"$p" <<'EOF'
[smtp]
host = smtp.example.com
port = 587
security = starttls
username = reports@example.com
from = reports@example.com
to = operations@example.com
password_env = SERVER_STRESS_SMTP_PASSWORD
password_file =
timeout = 30
max_attachment_bytes = 26214400
attach_archive = true
EOF
    )
    chmod 600 "$p"
    printf 'Created %s\n' "$p"
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
preflight() {
    validate_base
    validate_disk
    acquire
    install_deps
    probe_stress_ng
    sizes
    schedule

    local -a lacking
    mapfile -t lacking < <(missing)

    printf 'ID: %s\nduration_seconds: %s\nstages: %s\ndisk_dir: %s\ndisk_fs: %s\n' \
        "$ID" "$DURATION" "${STAGES[*]}" "$DISK_DIR" "${DISK_FS:-unknown}"
    printf 'memory_bytes: %s\nmemory_workers: %s\nmixed_memory_bytes: %s\n' \
        "$MEM_BYTES" "$MEM_WORKERS" "$MIXED_MEM_BYTES"
    printf 'disk_bytes_cap: %s\nmixed_disk_bytes: %s\n' "$DISK_BYTES" "$MIXED_DISK_BYTES"
    local s
    for s in "${STAGES[@]}"; do printf 'plan_%s_seconds: %s\n' "$s" "${SEC[$s]}"; done
    if ((${#lacking[@]})); then
        printf 'missing_required: %s\n' "${lacking[*]}"
    else
        printf 'missing_required: none\n'
    fi

    if ((SAFE)); then
        valid_id 'A.good-1' || return 1
        ! valid_id '../bad' || return 1
        [[ $(parse_duration 2h) == 7200 ]] || return 1
        [[ $(parse_size 32G) == $((32 * 1024 ** 3)) ]] || return 1
        printf 'self_test_safe: PASS\n'
    fi
    ((!NO_INSTALL || ${#lacking[@]} == 0 || DRY || SAFE))
}

runall() {
    validate_base
    validate_disk
    acquire
    install_deps
    probe_stress_ng

    local -a lacking
    mapfile -t lacking < <(missing)
    ((${#lacking[@]} == 0 || DRY || SAFE)) || die "missing required tools: ${lacking[*]}"

    sizes
    schedule
    newrun

    START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    START_EPOCH=$(date -u +%s)
    : >"$RUN/results.tsv"
    progress init running
    snapshots
    health run-before

    local s
    for s in "${ALL_STAGES[@]}"; do
        if [[ ${SELECTED[$s]:-0} != 1 ]]; then
            STATUS[$s]=SKIPPED
            ACTUAL[$s]=0
            result "$s" SKIPPED '按 --stages/--skip-stages 未执行'
            continue
        fi
        "run_$s"
    done

    health run-after
    local overall
    overall=$(summarize)
    report
    local archive_path
    archive_path=$(archive)
    local mail_rc=0
    if ((EMAIL)); then
        sendmail_report "$archive_path" "$overall" || mail_rc=$?
    fi
    [[ -n ${MARKER:-} ]] && rm -f -- "$MARKER"
    progress done "$overall"

    printf 'Run ID: %s\nStatus: %s\n' "$KEY" "$overall"
    [[ -f $RUN/report-$KEY.md ]] && printf 'Report: %s\n' "$RUN/report-$KEY.md"
    [[ -f $RUN/report-$KEY.docx ]] && printf 'Word: %s\n' "$RUN/report-$KEY.docx"
    printf 'Archive: %s\n' "$archive_path"

    # 压测报告不能因为邮件没送达而被误认为“工作完成”。
    ((mail_rc == 0)) || return 3
    case $overall in
        FAIL) return 1 ;;
        PARTIAL) return 2 ;;
        *) return 0 ;;
    esac
}

show_status() {
    local f="$OUT/current-status.txt"
    if [[ -f $f && ! -L $f ]]; then
        cat "$f"
    else
        printf '当前没有进度文件。默认目录: %s\n' "$OUT"
    fi
}

interactive_run() {
    local recipient
    [[ -t 0 && -t 1 ]] || die '无参数交互模式需要终端；自动化请使用 run --id ... --email'

    parse
    printf '\n服务器整机压力测试 %s\n' "$VERSION"
    printf '默认计划时长：%s 秒；Ctrl-C 可安全终止当前任务。\n\n' "$DURATION"
    while :; do
        read -r -p '任务 ID：' ID
        valid_id "$ID" && break
        printf 'ID 只能包含字母、数字、点、下划线和连字符，且首字符必须是字母或数字。\n' >&2
    done
    while :; do
        read -r -p '收件 QQ 邮箱：' recipient
        valid_qq_email "$recipient" && break
        printf '请输入有效 QQ 邮箱，例如 123456@qq.com。\n' >&2
    done

    if [[ ! -e $CONFIG && ! -L $CONFIG ]]; then
        setup_qq_mail
    fi
    set_qq_recipient "$recipient"
    EMAIL=1
    printf '\n任务 %s 将完成全量压测，报告会发往 %s。\n' "$ID" "$recipient"
    runall
}

main() {
    (($#)) || { interactive_run; return; }
    local cmd=$1
    shift
    case $cmd in
        run) parse "$@"; runall ;;
        preflight) parse "$@"; ((EMAIL == 0)) || die '--email only applies to run'; preflight ;;
        status) parse "$@"; show_status ;;
        init-config) init_config "$@" ;;
        setup-qq-mail) setup_qq_mail ;;
        help|-h|--help) usage ;;
        version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
        *) die "unknown subcommand: $cmd" ;;
    esac
}

# ---------------------------------------------------------------------------
# 内嵌 Python 助手
#
# bash 负责流程与安全，数据采集/汇总/渲染交给 Python。助手写在私有临时目录里，
# 运行结束随之删除；它们不进证据归档，归档里只有结果数据。
# ---------------------------------------------------------------------------
write_helpers() {
    write_helper_mkjson
    write_helper_fiocheck
    write_helper_sizing
    write_helper_env
    write_helper_health
    write_helper_telemetry
    write_helper_summarize
    write_helper_report
    write_helper_mailer
    write_helper_checkmembers
    chmod 600 "$HELPERS"/*.py
}

write_helper_mkjson() {
    cat >"$HELPERS/mkjson.py" <<'PY'
#!/usr/bin/env python3
"""把 key=value 参数写成 JSON，交给后续助手读取，避免 shell 里手工拼 JSON。"""
import json
import sys


def coerce(text):
    if text.lstrip('-').isdigit():
        return int(text)
    return text


def main():
    out = sys.argv[1]
    data = {}
    for item in sys.argv[2:]:
        key, _, value = item.partition('=')
        data[key] = coerce(value)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, sort_keys=True, indent=2)


main()
PY
}

write_helper_fiocheck() {
    cat >"$HELPERS/fiocheck.py" <<'PY'
#!/usr/bin/env python3
"""校验 fio JSON 是否代表一次有效的 IO；--bw-mibps 时额外打印聚合带宽。"""
import json
import sys


def load(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    start = text.find('{')
    if start < 0:
        raise SystemExit(1)
    return json.loads(text[start:])


def main():
    args = sys.argv[1:]
    want_bw = False
    if args and args[0] == '--bw-mibps':
        want_bw = True
        args = args[1:]
    if not args:
        raise SystemExit(1)

    try:
        doc = load(args[0])
    except Exception:
        raise SystemExit(1)

    jobs = doc.get('jobs') or []
    if not jobs or jobs[0].get('error', 1) != 0:
        raise SystemExit(1)
    read = jobs[0].get('read', {})
    write = jobs[0].get('write', {})
    if read.get('io_bytes', 0) + write.get('io_bytes', 0) <= 0:
        raise SystemExit(1)
    if want_bw:
        bw = read.get('bw_bytes', 0) + write.get('bw_bytes', 0)
        print(int(bw // (1024 * 1024)))


main()
PY
}

write_helper_sizing() {
    cat >"$HELPERS/sizing.py" <<'PY'
#!/usr/bin/env python3
"""计算防 OOM 的内存规模与不写满文件系统的磁盘规模。

内存：先预留 max(1GiB, 20% 总内存)，剩余可用量最多用 mem_percent%，最多 4 个 worker。
磁盘：先预留 max(2GiB, 10% 文件系统总量)，最多用可用空间的 25%，再受上限约束。
不安全时一律返回 0，由调用方把阶段标成 INCOMPLETE，而不是硬着头皮压下去。
"""
import os
import sys

ALIGN = 4 * 1024 * 1024


def align(value):
    return max(0, value) // ALIGN * ALIGN


def meminfo():
    values = {}
    try:
        with open('/proc/meminfo', encoding='utf-8') as f:
            for line in f:
                parts = line.replace(':', '').split()
                if len(parts) > 1 and parts[1].isdigit():
                    values[parts[0]] = int(parts[1]) * 1024
    except OSError:
        pass
    return values


def numa_nodes():
    try:
        names = os.listdir('/sys/devices/system/node')
    except OSError:
        return 1
    return max(1, len([x for x in names if x.startswith('node') and x[4:].isdigit()]))


def main():
    disk_dir, mem_percent, max_disk = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

    info = meminfo()
    available = info.get('MemAvailable', 0)
    total = info.get('MemTotal', 0)
    reserve = max(1024 ** 3, total // 5)
    workers = max(1, min(4, numa_nodes(), os.cpu_count() or 1))
    usable = max(0, available - reserve)

    per_worker = align((usable * mem_percent // 100) // workers)
    memory = per_worker * workers

    # 混合阶段只用受控子集，且绝不超过当前真实可用量
    mixed_memory = align(min(memory // 2, usable // 3))
    if mixed_memory < 64 * 1024 * 1024:
        mixed_memory = 0

    try:
        stat = os.statvfs(disk_dir)
        free = stat.f_bavail * stat.f_frsize
        total_fs = stat.f_blocks * stat.f_frsize
    except OSError:
        free = total_fs = 0
    reserve_fs = max(2 * 1024 ** 3, total_fs // 10)
    disk = min(free * 25 // 100, max(0, free - reserve_fs), max_disk)
    disk = align(disk)
    mixed_disk = align(min(disk, 8 * 1024 ** 3))

    print(memory, workers, mixed_memory, disk, mixed_disk)


main()
PY
}

write_helper_env() {
    cat >"$HELPERS/env.py" <<'PY'
#!/usr/bin/env python3
"""采集被测机环境信息，供报告的“被测系统信息”一节使用。"""
import json
import os
import platform
import re
import socket
import subprocess
import sys


def run(args, timeout=15):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return ''
    if done.returncode != 0:
        return ''
    return done.stdout.strip()


def read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def cpu_model():
    for line in read('/proc/cpuinfo').splitlines():
        if line.lower().startswith('model name'):
            return line.split(':', 1)[1].strip()
    return 'unknown'


def mem_total_bytes():
    match = re.search(r'^MemTotal:\s+(\d+)', read('/proc/meminfo'), re.M)
    return int(match.group(1)) * 1024 if match else 0


def distro():
    match = re.search(r'^PRETTY_NAME="?([^"\n]+)"?', read('/etc/os-release'), re.M)
    return match.group(1) if match else 'unknown'


def sockets():
    text = run(['lscpu'])
    match = re.search(r'^Socket\(s\):\s+(\d+)', text, re.M)
    return int(match.group(1)) if match else 0


def gpus():
    text = run(['nvidia-smi', '--query-gpu=index,name,memory.total,driver_version',
                '--format=csv,noheader'])
    items = []
    for line in text.splitlines():
        parts = [x.strip() for x in line.split(',')]
        if len(parts) >= 4:
            items.append({'index': parts[0], 'name': parts[1],
                          'memory_total': parts[2], 'driver': parts[3]})
    return items


def main():
    out, disk_dir = sys.argv[1], sys.argv[2]
    disk_source = sys.argv[3] if len(sys.argv) > 3 else ''
    disk_fs = sys.argv[4] if len(sys.argv) > 4 else ''

    data = {
        'host': socket.getfqdn(),
        'kernel': platform.release(),
        'distro': distro(),
        'architecture': platform.machine(),
        'cpu_model': cpu_model(),
        'cpu_logical': os.cpu_count() or 0,
        'cpu_sockets': sockets(),
        'memory_total_bytes': mem_total_bytes(),
        'boot_id': read('/proc/sys/kernel/random/boot_id').strip() or 'NA',
        'disk_dir': disk_dir,
        'disk_source': disk_source,
        'disk_fs': disk_fs,
        'gpus': gpus(),
        'product': run(['dmidecode', '-s', 'system-product-name']),
        'manufacturer': run(['dmidecode', '-s', 'system-manufacturer']),
        'serial': run(['dmidecode', '-s', 'system-serial-number']),
        'bios_version': run(['dmidecode', '-s', 'bios-version']),
    }
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, sort_keys=True, indent=2)


main()
PY
}

write_helper_health() {
    cat >"$HELPERS/health.py" <<'PY'
#!/usr/bin/env python3
"""阶段前后的硬件健康计数快照：EDAC、内核日志关键字、CPU 降频、GPU ECC。

拿不到的计数记为 null，报告里如实显示，不猜。
"""
import glob
import json
import os
import re
import subprocess
import sys
import time


def read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def edac_count(pattern):
    total = 0
    for root, _dirs, files in os.walk('/sys/devices/system/edac/mc'):
        for name in files:
            if re.search(pattern, name, re.I):
                try:
                    total += int(read(os.path.join(root, name)).strip())
                except ValueError:
                    pass
    return total


def kernel_log():
    """内核日志正文：优先 dmesg，被限制时退回 journalctl -k。"""
    for args in (['dmesg', '--color=never'], ['journalctl', '-k', '--no-pager', '-b']):
        try:
            done = subprocess.run(args, capture_output=True, text=True, timeout=30)
        except Exception:
            continue
        if done.returncode == 0 and done.stdout:
            return done.stdout
    return None


def throttle_total():
    total = 0
    found = False
    for path in glob.glob('/sys/devices/system/cpu/cpu*/thermal_throttle/*_throttle_count'):
        try:
            total += int(read(path).strip())
            found = True
        except ValueError:
            pass
    return total if found else None


def gpu_ecc():
    """GPU ECC 累计错误；没有 nvidia-smi 或不支持 ECC 时返回 null。"""
    try:
        done = subprocess.run(
            ['nvidia-smi',
             '--query-gpu=ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total',
             '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=15)
    except Exception:
        return None, None
    if done.returncode != 0:
        return None, None
    corrected = uncorrected = 0
    seen = False
    for line in done.stdout.strip().splitlines():
        parts = [x.strip() for x in line.split(',')]
        if len(parts) < 2:
            continue
        for index, target in ((0, 'c'), (1, 'u')):
            if not parts[index].isdigit():
                continue
            seen = True
            if target == 'c':
                corrected += int(parts[index])
            else:
                uncorrected += int(parts[index])
    return (corrected, uncorrected) if seen else (None, None)


def main():
    out, phase = sys.argv[1], sys.argv[2]
    log = kernel_log()

    def kcount(pattern):
        if log is None:
            return None
        return len(re.findall(pattern, log, re.I))

    corrected, uncorrected = gpu_ecc()
    data = {
        'phase': phase,
        'utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'boot_id': read('/proc/sys/kernel/random/boot_id').strip() or 'NA',
        'edac_ce': edac_count('ce_count'),
        'edac_ue': edac_count('ue_count'),
        'cpu_throttle': throttle_total(),
        'gpu_ecc_corrected': corrected,
        'gpu_ecc_uncorrected': uncorrected,
        'oom': kcount(r'out of memory|oom-killer'),
        'mce': kcount(r'\bMCE\b|machine check'),
        'aer_corrected': kcount(r'AER.*corrected'),
        'aer_uncorrected': kcount(r'AER.*(uncorrected|fatal)'),
        'xid': kcount(r'NVRM: Xid'),
        'nvme_media': kcount(r'nvme.*(media|critical|uncorrect)'),
    }
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, sort_keys=True, indent=2)


main()
PY
}

write_helper_telemetry() {
    cat >"$HELPERS/telemetry.py" <<'PY'
#!/usr/bin/env python3
"""常驻遥测采样器。

3.0 版每 5 秒新起一个 Python 解释器，一小时约 720 次进程创建，噪声打在被测机自己身上。
这里改成一个常驻进程按固定间隔采样，并做漂移校正，让采样点落在整齐的时间栅格上。
"""
import glob
import signal
import subprocess
import sys
import time

COLUMNS = ['utc', 'elapsed_s', 'load1', 'cpu_util_pct', 'mem_available_kb', 'mem_free_kb',
           'swap_free_kb', 'temp_max_c', 'cpu_throttle', 'disk_read_mibps', 'disk_write_mibps',
           'gpu_util_max_pct', 'gpu_temp_max_c', 'gpu_power_sum_w']

STOP = False
GPU_FAILURES = 0


def on_signal(_signum, _frame):
    global STOP
    STOP = True


def read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def cpu_totals():
    line = read('/proc/stat').split('\n', 1)[0].split()
    if len(line) < 5 or line[0] != 'cpu':
        return None
    try:
        values = [int(x) for x in line[1:]]
    except ValueError:
        return None
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def meminfo():
    data = {}
    for line in read('/proc/meminfo').splitlines():
        parts = line.replace(':', '').split()
        if len(parts) > 1 and parts[1].isdigit():
            data[parts[0]] = int(parts[1])
    return data


def temp_max():
    best = None
    for path in glob.glob('/sys/class/hwmon/hwmon*/temp*_input'):
        try:
            value = int(read(path).strip()) / 1000.0
        except ValueError:
            continue
        if 0 < value < 150 and (best is None or value > best):
            best = value
    return best


def throttle_total():
    total = 0
    found = False
    for path in glob.glob('/sys/devices/system/cpu/cpu*/thermal_throttle/*_throttle_count'):
        try:
            total += int(read(path).strip())
            found = True
        except ValueError:
            pass
    return total if found else None


def disk_bytes(dev):
    if not dev:
        return None
    for line in read('/proc/diskstats').splitlines():
        parts = line.split()
        if len(parts) >= 10 and parts[2] == dev:
            try:
                return int(parts[5]) * 512, int(parts[9]) * 512
            except ValueError:
                return None
    return None


def gpu_sample():
    global GPU_FAILURES
    if GPU_FAILURES >= 3:
        return None
    try:
        done = subprocess.run(
            ['nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,power.draw',
             '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=5)
        if done.returncode != 0:
            raise RuntimeError('nvidia-smi failed')
    except Exception:
        GPU_FAILURES += 1
        return None

    util = temp = None
    power = 0.0
    seen_power = False
    for line in done.stdout.strip().splitlines():
        parts = [x.strip() for x in line.split(',')]
        if len(parts) < 3:
            continue
        try:
            value = float(parts[0])
            util = value if util is None else max(util, value)
        except ValueError:
            pass
        try:
            value = float(parts[1])
            temp = value if temp is None else max(temp, value)
        except ValueError:
            pass
        try:
            power += float(parts[2])
            seen_power = True
        except ValueError:
            pass
    return util, temp, (power if seen_power else None)


def fmt(value, digits=1):
    if value is None:
        return 'NA'
    if isinstance(value, float):
        return ('%%.%df' % digits) % value
    return str(value)


def main():
    out, interval, max_seconds, dev = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    started = time.time()
    previous_cpu = cpu_totals()
    previous_disk = disk_bytes(dev)
    previous_at = started

    with open(out, 'w', encoding='utf-8') as handle:
        handle.write(','.join(COLUMNS) + '\n')
        handle.flush()
        index = 0
        while not STOP:
            index += 1
            target = started + index * interval
            while not STOP and time.time() < target:
                time.sleep(min(0.5, max(0.0, target - time.time())))
            if STOP:
                break
            now = time.time()
            if now - started > max_seconds:
                break

            gap = max(1e-6, now - previous_at)
            current_cpu = cpu_totals()
            util = None
            if current_cpu and previous_cpu:
                total_delta = current_cpu[0] - previous_cpu[0]
                idle_delta = current_cpu[1] - previous_cpu[1]
                if total_delta > 0:
                    util = max(0.0, min(100.0, 100.0 * (total_delta - idle_delta) / total_delta))
            previous_cpu = current_cpu or previous_cpu

            current_disk = disk_bytes(dev)
            read_rate = write_rate = None
            if current_disk and previous_disk:
                read_rate = max(0.0, (current_disk[0] - previous_disk[0]) / gap / (1024 * 1024))
                write_rate = max(0.0, (current_disk[1] - previous_disk[1]) / gap / (1024 * 1024))
            previous_disk = current_disk or previous_disk
            previous_at = now

            mem = meminfo()
            load1 = (read('/proc/loadavg').split() or ['NA'])[0]
            gpu = gpu_sample()
            row = [
                time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now)),
                fmt(int(now - started)),
                load1 or 'NA',
                fmt(util),
                fmt(mem.get('MemAvailable')),
                fmt(mem.get('MemFree')),
                fmt(mem.get('SwapFree')),
                fmt(temp_max()),
                fmt(throttle_total()),
                fmt(read_rate),
                fmt(write_rate),
                fmt(gpu[0]) if gpu else 'NA',
                fmt(gpu[1]) if gpu else 'NA',
                fmt(gpu[2]) if gpu else 'NA',
            ]
            handle.write(','.join(row) + '\n')
            handle.flush()


main()
PY
}

write_helper_checkmembers() {
    cat >"$HELPERS/checkmembers.py" <<'PY'
#!/usr/bin/env python3
"""归档前确认每个成员都是运行目录内的普通文件，拒绝符号链接或越界路径。"""
import os
import stat
import sys


def main():
    root = os.path.realpath(sys.argv[1])
    with open(sys.argv[2], 'rb') as f:
        entries = f.read().split(b'\0')
    for raw in filter(None, entries):
        path = os.path.realpath(os.path.join(root, os.fsdecode(raw)))
        info = os.lstat(path)
        if not path.startswith(root + os.sep) or not stat.S_ISREG(info.st_mode):
            raise SystemExit('unsafe archive member')


main()
PY
}

write_helper_summarize() {
    cat >"$HELPERS/summarize.py" <<'PY'
#!/usr/bin/env python3
"""把原始产物汇总成机器可读结果，并在标准输出打印总体结论。

产出：
  health-summary.json     阶段前后的健康计数差值与判定
  performance.json        fio / stress-ng / GPU 的性能指标
  telemetry-summary.json  每个阶段的遥测统计（峰值温度、最低可用内存等）
  metadata.json           运行元数据
  results.json            阶段结论 + 上述汇总的索引
"""
import csv
import glob
import json
import os
import re
import sys
import time

STAGES = ('cpu', 'memory', 'disk', 'gpu', 'mixed')
# 这些计数一旦增长就判失败：不可纠正错误、OOM、GPU Xid 等
BAD_KEYS = ('oom', 'edac_ue', 'xid', 'nvme_media', 'aer_uncorrected', 'gpu_ecc_uncorrected')
# 这些计数增长记告警：可纠正错误、机器检查异常、CPU 降频
WARN_KEYS = ('edac_ce', 'aer_corrected', 'mce', 'cpu_throttle', 'gpu_ecc_corrected')
TELEMETRY_COLUMNS = ('cpu_util_pct', 'load1', 'mem_available_kb', 'mem_free_kb', 'temp_max_c',
                     'disk_read_mibps', 'disk_write_mibps', 'gpu_util_max_pct',
                     'gpu_temp_max_c', 'gpu_power_sum_w', 'cpu_throttle')


def load_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {} if default is None else default


def read_text(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def write_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, sort_keys=True, indent=2)


# --------------------------------------------------------------------------
# 健康计数差值
# --------------------------------------------------------------------------
def health_summary(run):
    deltas = {}
    verdict = 'PASS'
    warnings = []
    notes = []
    critical_by_phase = {}

    for phase in list(STAGES) + ['run']:
        before = load_json('%s/health-%s-before.json' % (run, phase))
        after = load_json('%s/health-%s-after.json' % (run, phase))
        if not before and not after:
            continue

        delta = {}
        for key in sorted(set(before) | set(after)):
            if key in ('phase', 'utc'):
                continue
            if key == 'boot_id':
                delta[key] = {'before': before.get(key, 'NA'),
                              'after': after.get(key, 'NA'),
                              'changed': before.get(key) != after.get(key)}
                continue
            start, end = before.get(key), after.get(key)
            if isinstance(start, int) and isinstance(end, int):
                diff = end - start
                if diff < 0:
                    # 内核日志环形缓冲回卷会让计数变小，这种情况按 0 处理并留痕
                    notes.append('%s:%s 计数回退，内核日志缓冲可能已回卷，按 0 计' % (phase, key))
                    diff = 0
                delta[key] = diff
            else:
                delta[key] = None
        deltas[phase] = delta

        critical = []
        if delta.get('boot_id', {}).get('changed'):
            verdict = 'FAIL'
            critical.append('boot_id_changed')
        for key in BAD_KEYS:
            if isinstance(delta.get(key), int) and delta[key] > 0:
                verdict = 'FAIL'
                critical.append('%s+%d' % (key, delta[key]))
        if critical:
            critical_by_phase[phase] = critical
        if phase != 'run':
            for key in WARN_KEYS:
                if isinstance(delta.get(key), int) and delta[key] > 0:
                    warnings.append('%s:%s+%d' % (phase, key, delta[key]))

    return {'health_deltas': deltas, 'health_verdict': verdict,
            'critical_by_phase': critical_by_phase,
            'warnings': warnings, 'notes': notes}


# --------------------------------------------------------------------------
# fio 性能指标
# --------------------------------------------------------------------------
def load_fio(path):
    text = read_text(path)
    start = text.find('{')
    if start < 0:
        return None
    try:
        return json.loads(text[start:])
    except Exception:
        return None


def fio_side(data):
    if not data or data.get('io_bytes', 0) <= 0:
        return None
    clat = data.get('clat_ns') or {}
    percentile = clat.get('percentile') or {}
    p99 = percentile.get('99.000000') or percentile.get('99.000000000')
    return {
        'iops': round(float(data.get('iops', 0.0)), 1),
        'mibps': round(float(data.get('bw_bytes', 0)) / (1024 * 1024), 1),
        'lat_avg_us': round(float(clat.get('mean', 0.0)) / 1000.0, 1),
        'lat_p99_us': round(float(p99) / 1000.0, 1) if p99 else None,
        'io_bytes': int(data.get('io_bytes', 0)),
    }


# 报告里按实际执行顺序列出磁盘任务，而不是按文件名字母序
FIO_ORDER = ('disk-seqwrite.json', 'disk-seqread.json', 'disk-randread.json',
             'disk-randrw7030.json', 'mixed-fio.json')


def fio_metrics(run):
    items = []
    paths = glob.glob('%s/raw/disk-*.json' % run) + glob.glob('%s/raw/mixed-fio.json' % run)
    order = dict((name, index) for index, name in enumerate(FIO_ORDER))
    paths.sort(key=lambda p: (order.get(os.path.basename(p), len(FIO_ORDER)), p))
    for path in paths:
        base = os.path.basename(path)
        if base == 'disk-layout.json':
            continue
        doc = load_fio(path)
        if not doc:
            continue
        jobs = doc.get('jobs') or []
        if not jobs:
            continue
        job = jobs[0]
        options = dict(doc.get('global options') or {})
        options.update(job.get('job options') or job.get('job_options') or {})
        items.append({
            'name': job.get('jobname') or base,
            'source': base,
            'rw': options.get('rw', ''),
            'bs': options.get('bs', ''),
            'iodepth': options.get('iodepth', ''),
            'numjobs': options.get('numjobs', '1'),
            'engine': options.get('ioengine', ''),
            'runtime_ms': job.get('job_runtime', 0),
            'read': fio_side(job.get('read')),
            'write': fio_side(job.get('write')),
        })
    return items


# --------------------------------------------------------------------------
# stress-ng 指标：优先 YAML，缺失时回退到 metrics-brief 文本
# --------------------------------------------------------------------------
def sng_from_yaml(path):
    text = read_text(path)
    if not text:
        return []
    rows = []
    for block in re.split(r'\n\s*-\s+stressor:', text)[1:]:
        name = block.strip().split('\n', 1)[0].strip()

        def number(key, source=block):
            match = re.search(r'^\s*%s:\s*([0-9.eE+-]+)' % re.escape(key), source, re.M)
            return float(match.group(1)) if match else None

        rows.append({'stressor': name,
                     'bogo_ops': number('bogo-ops'),
                     'bogo_ops_per_sec_real': number('bogo-ops-per-second-real-time'),
                     'bogo_ops_per_sec_cpu': number('bogo-ops-per-second-usr-sys-time')})
    return rows


def sng_from_log(path):
    rows = []
    pattern = re.compile(r'\[\d+\]\s+(\S+)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$')
    for line in read_text(path).splitlines():
        match = pattern.search(line)
        if match:
            rows.append({'stressor': match.group(1),
                         'bogo_ops': float(match.group(2)),
                         'bogo_ops_per_sec_real': float(match.group(6)),
                         'bogo_ops_per_sec_cpu': float(match.group(7))})
    return rows


def sng_metrics(run):
    result = {}
    for stage, yaml_name, log_name in (('cpu', 'cpu.yaml', 'cpu.log'),
                                       ('memory', 'memory.yaml', 'memory.log'),
                                       ('mixed-cpu', 'mixed-cpu.yaml', 'mixed.log'),
                                       ('mixed-memory', 'mixed-memory.yaml', 'mixed.log')):
        rows = sng_from_yaml('%s/raw/%s' % (run, yaml_name))
        if not rows:
            rows = sng_from_log('%s/raw/%s' % (run, log_name))
        if rows:
            result[stage] = rows
    return result


# --------------------------------------------------------------------------
# GPU 指标
# --------------------------------------------------------------------------
def gpu_metrics(run):
    text = read_text('%s/raw/gpu.log' % run) + '\n' + read_text('%s/raw/mixed.log' % run)
    names = {}
    for match in re.finditer(r'gpu=(\d+)\s+name=(.+?)\s+bytes=(\d+)\s+reserve_bytes=(\d+)\s+status=RUNNING', text):
        names[match.group(1)] = match.group(2)

    items = []
    seen = set()
    pattern = r'gpu=(\d+)\s+status=(\w+)\s+verify_errors=(\d+)\s+compute_sweeps=(\d+)\s+bytes=(\d+)'
    for match in re.finditer(pattern, text):
        key = (match.group(1), match.group(4))
        if key in seen:
            continue
        seen.add(key)
        items.append({'index': match.group(1),
                      'name': names.get(match.group(1), 'unknown'),
                      'backend': 'cuda',
                      'status': match.group(2),
                      'verify_errors': int(match.group(3)),
                      'compute_sweeps': int(match.group(4)),
                      'bytes': int(match.group(5))})
    for match in re.finditer(r'gpu_backend=(gpu-burn)\s+status=(PASS|FAIL)', text):
        items.append({'index': 'all',
                      'name': 'GPU-burn Tensor Core',
                      'backend': match.group(1),
                      'status': match.group(2),
                      'verify_errors': 0,
                      'compute_sweeps': 0,
                      'bytes': 0})
    return items


def nvidia_health_metrics(run):
    text = read_text('%s/raw/gpu.log' % run) + '\n' + read_text('%s/raw/mixed.log' % run)
    records = {}
    for line in text.splitlines():
        if not line.startswith('nvidia_health '):
            continue
        values = dict(re.findall(r'(\w+)=([^\s]+)', line))
        label = values.get('label', 'unknown')
        record = records.setdefault(label, {'label': label})
        record.update(values)
        if values.get('status') == 'FAIL':
            record['status'] = 'FAIL'
    return list(records.values())


# --------------------------------------------------------------------------
# 遥测统计
# --------------------------------------------------------------------------
def telemetry_summary(run):
    result = {}
    for path in sorted(glob.glob('%s/telemetry/*.csv' % run)):
        stage = os.path.basename(path)[:-4]
        try:
            with open(path, newline='', encoding='utf-8', errors='replace') as f:
                rows = list(csv.DictReader(f))
        except OSError:
            continue
        if not rows:
            continue
        stats = {'samples': len(rows)}
        for column in TELEMETRY_COLUMNS:
            values = []
            for row in rows:
                raw = (row.get(column) or '').strip()
                if raw in ('', 'NA'):
                    continue
                try:
                    values.append(float(raw))
                except ValueError:
                    pass
            if values:
                stats[column] = {'min': round(min(values), 1),
                                 'max': round(max(values), 1),
                                 'avg': round(sum(values) / len(values), 1)}
        result[stage] = stats
    return result


# --------------------------------------------------------------------------
# 阶段结论与总体判定
# --------------------------------------------------------------------------
def read_results(run):
    rows = {}
    path = '%s/results.tsv' % run
    try:
        with open(path, newline='', encoding='utf-8') as f:
            for parts in csv.reader(f, delimiter='\t'):
                if len(parts) >= 5:
                    rows[parts[0]] = {'stage': parts[0], 'status': parts[1],
                                      'planned_seconds': int(parts[2]),
                                      'actual_seconds': int(parts[3]),
                                      'detail': parts[4]}
    except OSError:
        pass
    return rows


def overall_verdict(rows, health):
    statuses = [rows.get(stage, {}).get('status', 'INCOMPLETE') for stage in STAGES]
    if 'FAIL' in statuses:
        return 'FAIL'
    if health.get('health_verdict') == 'FAIL':
        return 'FAIL'
    if any(s in ('INCOMPLETE', 'UNTESTED', 'SKIPPED') for s in statuses):
        return 'PARTIAL'
    if health.get('warnings'):
        return 'PASS WITH WARNINGS'
    return 'PASS'


def main():
    run = sys.argv[1]
    context = load_json('%s/work/context.json' % run)
    environment = load_json('%s/environment.json' % run)

    health = health_summary(run)
    write_json('%s/health-summary.json' % run, health)

    performance = {'fio': fio_metrics(run), 'stress_ng': sng_metrics(run),
                   'gpu': gpu_metrics(run), 'nvidia_health': nvidia_health_metrics(run)}
    write_json('%s/performance.json' % run, performance)

    telemetry = telemetry_summary(run)
    write_json('%s/telemetry-summary.json' % run, telemetry)

    rows = read_results(run)
    # 关键健康异常只归属到发生异常的阶段。run 级汇总仍会让总体结论失败，
    # 但不会把此前已经完成且健康的 CPU、内存、磁盘阶段全部误改为失败。
    critical_by_phase = health.get('critical_by_phase') or {}
    with open('%s/results.tsv' % run, 'a', encoding='utf-8') as f:
        for stage in STAGES:
            critical = critical_by_phase.get(stage) or []
            row = rows.get(stage)
            if critical and row and row['status'] == 'PASS':
                row['status'] = 'FAIL'
                row['detail'] = row['detail'] + '；本阶段关键健康异常：' + ','.join(critical)
                f.write('\t'.join([stage, 'FAIL', str(row['planned_seconds']),
                                   str(row['actual_seconds']), row['detail']]) + '\n')

    overall = overall_verdict(rows, health)
    actual_total = sum(rows.get(stage, {}).get('actual_seconds', 0) for stage in STAGES)

    metadata = dict(context)
    metadata.update({
        'host': environment.get('host', 'unknown'),
        'kernel': environment.get('kernel', 'unknown'),
        'boot_id': environment.get('boot_id', 'NA'),
        'finished_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'actual_seconds': actual_total,
        'overall': overall,
    })
    write_json('%s/metadata.json' % run, metadata)

    write_json('%s/results.json' % run, {
        'overall': overall,
        'stages': [rows.get(stage, {'stage': stage, 'status': 'INCOMPLETE',
                                    'planned_seconds': 0, 'actual_seconds': 0,
                                    'detail': '无记录'}) for stage in STAGES],
        'health': health,
    })
    print(overall)


main()
PY
}

write_helper_report() {
    cat >"$HELPERS/report.py" <<'PY'
#!/usr/bin/env python3
"""生成中文报告：Markdown + Word(docx)，另外写一份可直接阅读的邮件正文。

docx 用标准库拼 OOXML（zip + XML），不依赖第三方包 —— 被测服务器通常没有外网，
也不该为了出报告去装 python-docx。两种格式渲染同一份内容模型，不会各写一套。
"""
import json
import os
import sys
import time
import zipfile
from xml.sax.saxutils import escape

STAGES = ('cpu', 'memory', 'disk', 'gpu', 'mixed')
STAGE_CN = {'cpu': 'CPU', 'memory': '内存', 'disk': '磁盘', 'gpu': 'GPU', 'mixed': '混合满载'}
STATUS_CN = {'PASS': '通过', 'FAIL': '失败', 'INCOMPLETE': '未完成', 'UNTESTED': '未测',
             'SKIPPED': '未执行', 'PARTIAL': '部分通过', 'PASS WITH WARNINGS': '通过（有告警）'}
STATUS_STYLE = {'PASS': 'ok', 'FAIL': 'bad', 'INCOMPLETE': 'warn', 'UNTESTED': 'warn',
                'SKIPPED': 'warn', 'PARTIAL': 'warn', 'PASS WITH WARNINGS': 'warn'}
HEALTH_CN = {
    'edac_ce': '内存可纠正错误(EDAC CE)',
    'edac_ue': '内存不可纠正错误(EDAC UE)',
    'cpu_throttle': 'CPU降频次数',
    'gpu_ecc_corrected': 'GPU ECC可纠正',
    'gpu_ecc_uncorrected': 'GPU ECC不可纠正',
    'oom': '内核OOM记录',
    'mce': '机器检查异常(MCE)',
    'aer_corrected': 'PCIe AER可纠正',
    'aer_uncorrected': 'PCIe AER不可纠正',
    'xid': 'NVIDIA Xid错误',
    'nvme_media': 'NVMe介质/严重告警',
}


# --------------------------------------------------------------------------
# 通用工具
# --------------------------------------------------------------------------
def load_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {} if default is None else default


def human_bytes(value):
    try:
        value = float(value)
    except (TypeError, ValueError):
        return 'NA'
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if value < 1024 or unit == 'TiB':
            return '%.1f %s' % (value, unit) if unit != 'B' else '%d B' % value
        value /= 1024
    return 'NA'


def human_seconds(value):
    try:
        total = int(value)
    except (TypeError, ValueError):
        return 'NA'
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    if hours:
        return '%d小时%d分%d秒' % (hours, minutes, seconds)
    if minutes:
        return '%d分%d秒' % (minutes, seconds)
    return '%d秒' % seconds


def stat_of(telemetry, stage, column, field):
    entry = (telemetry.get(stage) or {}).get(column)
    if not entry:
        return None
    return entry.get(field)


def show(value, suffix='', digits=1):
    if value is None:
        return 'NA'
    if isinstance(value, float):
        return ('%%.%df%%s' % digits) % (value, suffix)
    return '%s%s' % (value, suffix)


# --------------------------------------------------------------------------
# 内容模型：两种格式共用
# --------------------------------------------------------------------------
def build(run):
    metadata = load_json('%s/metadata.json' % run)
    results = load_json('%s/results.json' % run)
    environment = load_json('%s/environment.json' % run)
    performance = load_json('%s/performance.json' % run)
    telemetry = load_json('%s/telemetry-summary.json' % run)
    health = results.get('health') or load_json('%s/health-summary.json' % run)

    overall = results.get('overall', 'INCOMPLETE')
    blocks = [('title', '服务器整机压力测试报告 — %s' % metadata.get('run_key', 'unknown'))]

    # 一、测试概述
    scope = [STAGE_CN[s] for s in STAGES if metadata.get('selected_%s' % s) == 1]
    blocks.append(('h1', '一、测试概述'))
    blocks.append(('kv', [
        ('任务ID', metadata.get('id', 'NA')),
        ('主机', metadata.get('host', 'NA')),
        ('脚本版本', metadata.get('version', 'NA')),
        ('总体结论', STATUS_CN.get(overall, overall)),
        ('开始时间UTC', metadata.get('started_utc', 'NA')),
        ('结束时间UTC', metadata.get('finished_utc', 'NA')),
        ('计划时长（秒）', metadata.get('duration_seconds', 'NA')),
        ('实际压测耗时', human_seconds(metadata.get('actual_seconds'))),
        ('执行范围', '、'.join(scope) if scope else 'NA'),
    ]))
    if metadata.get('safe_mode') == 1:
        blocks.append(('p', '本次为演练/安全模式：完整走通校验与报告流程，但没有施加真实压力。'))

    # 二、被测系统信息
    blocks.append(('h1', '二、被测系统信息'))
    vendor = ' '.join(x for x in (environment.get('manufacturer'), environment.get('product')) if x)
    rows = [
        ('主机名', environment.get('host', 'NA')),
        ('厂商/型号', vendor or 'NA'),
        ('序列号', environment.get('serial') or 'NA'),
        ('BIOS版本', environment.get('bios_version') or 'NA'),
        ('操作系统', environment.get('distro', 'NA')),
        ('内核', environment.get('kernel', 'NA')),
        ('CPU型号', environment.get('cpu_model', 'NA')),
        ('CPU逻辑核数', environment.get('cpu_logical', 'NA')),
        ('CPU插槽数', environment.get('cpu_sockets', 'NA')),
        ('内存总量', human_bytes(environment.get('memory_total_bytes'))),
        ('磁盘测试目录', '%s（%s，%s）' % (metadata.get('disk_dir', 'NA'),
                                          metadata.get('disk_fs') or 'unknown',
                                          metadata.get('disk_source') or 'unknown')),
    ]
    gpus = environment.get('gpus') or []
    if gpus:
        rows.append(('GPU', '%d张：%s（驱动 %s）' % (
            len(gpus), '、'.join(sorted({g.get('name', '?') for g in gpus})),
            gpus[0].get('driver', 'NA'))))
    else:
        rows.append(('GPU', '未检测到NVIDIA设备'))
    blocks.append(('kv', rows))

    # 三、测试结果
    blocks.append(('h1', '三、测试结果'))
    table_rows = []
    for stage in STAGES:
        row = next((x for x in results.get('stages', []) if x.get('stage') == stage), None) or {}
        status = row.get('status', 'INCOMPLETE')
        table_rows.append([
            stage,
            str(row.get('planned_seconds', 0)),
            str(row.get('actual_seconds', 0)),
            {'text': STATUS_CN.get(status, status), 'style': STATUS_STYLE.get(status, 'warn')},
            '%s：%s' % (STAGE_CN[stage], str(row.get('detail', '')).replace('|', '/')),
        ])
    blocks.append(('table', {
        'header': ['Stage', '计划秒数', '实际秒数', '结论', '说明'],
        'align': ['l', 'r', 'r', 'c', 'l'],
        'widths': [10, 9, 9, 10, 40],
        'rows': table_rows,
    }))

    # 四、性能指标
    blocks.append(('h1', '四、性能指标'))
    sng = performance.get('stress_ng') or {}
    sng_rows = []
    for key, label in (('cpu', 'CPU阶段'), ('memory', '内存阶段'),
                       ('mixed-cpu', '混合阶段CPU'), ('mixed-memory', '混合阶段内存')):
        for item in sng.get(key) or []:
            sng_rows.append([label, item.get('stressor', 'NA'),
                             show(item.get('bogo_ops'), digits=0),
                             show(item.get('bogo_ops_per_sec_real')),
                             show(item.get('bogo_ops_per_sec_cpu'))])
    blocks.append(('h2', '4.1 CPU 与内存（stress-ng）'))
    if sng_rows:
        blocks.append(('table', {
            'header': ['阶段', '压力源', '总操作数', '操作数/秒(墙钟)', '操作数/秒(CPU时间)'],
            'align': ['l', 'l', 'r', 'r', 'r'],
            'widths': [14, 14, 16, 18, 18],
            'rows': sng_rows,
        }))
    else:
        blocks.append(('p', '没有采集到 stress-ng 指标（阶段未执行或未产生指标输出）。'))

    blocks.append(('h2', '4.2 磁盘（fio）'))
    fio_rows = []
    for item in performance.get('fio') or []:
        for side, side_cn in (('read', '读'), ('write', '写')):
            data = item.get(side)
            if not data:
                continue
            fio_rows.append([
                item.get('name', 'NA'), side_cn,
                '%s/%s/qd%s/j%s' % (item.get('engine', 'NA'), item.get('bs', 'NA'),
                                    item.get('iodepth', 'NA'), item.get('numjobs', 'NA')),
                show(data.get('mibps')), show(data.get('iops')),
                show(data.get('lat_avg_us')), show(data.get('lat_p99_us')),
            ])
    if fio_rows:
        blocks.append(('table', {
            'header': ['任务', '方向', '引擎/块/队列/并发', '带宽MiB/s', 'IOPS', '平均延迟us', 'P99延迟us'],
            'align': ['l', 'c', 'l', 'r', 'r', 'r', 'r'],
            'widths': [14, 7, 20, 12, 12, 12, 12],
            'rows': fio_rows,
        }))
        blocks.append(('p', '引擎、队列深度与并发 job 数由脚本按机器实际能力选定；顺序任务用 1MiB 块，'
                            '随机任务用 4KiB 块，随机读写按读 70% / 写 30% 混合。'))
    else:
        blocks.append(('p', '没有采集到 fio 指标（磁盘阶段未执行或未产生有效 IO）。'))

    blocks.append(('h2', '4.3 GPU'))
    nvidia_rows = []
    for item in performance.get('nvidia_health') or []:
        nvidia_rows.append([
            item.get('label', 'NA'), item.get('status', 'NA'), item.get('count', 'NA'),
            item.get('driver', 'NA'), item.get('loaded_module', 'NA'),
            item.get('disk_module', 'NA'), item.get('reason', ''),
        ])
    if nvidia_rows:
        blocks.append(('table', {
            'header': ['检查点', '状态', '卡数', '驱动', '已加载模块', '磁盘模块', '异常原因'],
            'align': ['l', 'c', 'r', 'l', 'l', 'l', 'l'],
            'widths': [18, 9, 7, 12, 14, 14, 22],
            'rows': nvidia_rows,
        }))
        blocks.append(('p', '若出现 driver-library-version-mismatch 或 loaded-disk-module-mismatch，'
                            '应先统一 NVIDIA 驱动组件并重启；本工具不会自动重载或修改驱动。'))
    gpu_rows = []
    for item in performance.get('gpu') or []:
        memory = human_bytes(item.get('bytes')) if item.get('bytes') else 'GPU-burn 自管'
        gpu_rows.append([item.get('index', 'NA'), item.get('name', 'NA'), item.get('backend', 'cuda'),
                         {'text': STATUS_CN.get(item.get('status'), item.get('status', 'NA')),
                          'style': STATUS_STYLE.get(item.get('status'), 'warn')},
                         str(item.get('compute_sweeps', 0)),
                         str(item.get('verify_errors', 0)),
                         memory])
    if gpu_rows:
        blocks.append(('table', {
            'header': ['卡号', '型号', '后端', '结论', '计算轮次', '校验错误', '占用显存'],
            'align': ['c', 'l', 'l', 'c', 'r', 'r', 'r'],
            'widths': [7, 22, 14, 10, 12, 12, 14],
            'rows': gpu_rows,
        }))
        blocks.append(('p', 'GPU-burn 后端使用 Tensor Core 矩阵负载与校验，目标是持续高 GPU 利用率；'
                            'CUDA 后端每轮做正向变换、显存带宽读取、反向变换与全量图案比对。'))
    else:
        blocks.append(('p', '没有 GPU 指标（无 NVIDIA 设备、GPU-burn/CUDA 工具链不可用，或该阶段未执行）。'))

    # 五、运行期遥测汇总
    blocks.append(('h1', '五、运行期遥测汇总'))
    tele_rows = []
    for stage in STAGES:
        if stage not in telemetry:
            continue
        tele_rows.append([
            stage,
            str((telemetry.get(stage) or {}).get('samples', 0)),
            show(stat_of(telemetry, stage, 'cpu_util_pct', 'avg'), '%'),
            show(stat_of(telemetry, stage, 'cpu_util_pct', 'max'), '%'),
            show(stat_of(telemetry, stage, 'load1', 'max')),
            human_bytes((stat_of(telemetry, stage, 'mem_available_kb', 'min') or 0) * 1024),
            show(stat_of(telemetry, stage, 'temp_max_c', 'max'), '℃'),
            show(stat_of(telemetry, stage, 'gpu_temp_max_c', 'max'), '℃'),
        ])
    if tele_rows:
        blocks.append(('table', {
            'header': ['Stage', '采样点', 'CPU均值', 'CPU峰值', '负载峰值', '可用内存最低', '最高温度', 'GPU最高温'],
            'align': ['l', 'r', 'r', 'r', 'r', 'r', 'r', 'r'],
            'widths': [10, 8, 10, 10, 10, 14, 10, 10],
            'rows': tele_rows,
        }))
        blocks.append(('p', '采样间隔 %s 秒，明细见证据归档中的 telemetry/*.csv。温度取自 hwmon，'
                            '部分机型不暴露传感器时记为 NA。' % metadata.get('telemetry_interval', 'NA')))
    else:
        blocks.append(('p', '没有遥测数据。'))

    # 六、健康计数差值
    blocks.append(('h1', '六、健康计数差值'))
    deltas = health.get('health_deltas') or {}
    keys = [k for k in HEALTH_CN if any(k in (deltas.get(s) or {}) for s in list(STAGES) + ['run'])]
    if keys:
        header = ['计数项'] + [STAGE_CN[s] for s in STAGES if s in deltas] + (['整机'] if 'run' in deltas else [])
        phases = [s for s in STAGES if s in deltas] + (['run'] if 'run' in deltas else [])
        health_rows = []
        for key in keys:
            row = [HEALTH_CN[key]]
            for phase in phases:
                value = (deltas.get(phase) or {}).get(key)
                if value is None:
                    row.append('NA')
                elif isinstance(value, int) and value > 0:
                    row.append({'text': '+%d' % value, 'style': 'bad' if key in
                                ('edac_ue', 'oom', 'xid', 'nvme_media', 'aer_uncorrected',
                                 'gpu_ecc_uncorrected') else 'warn'})
                else:
                    row.append('0')
            health_rows.append(row)
        blocks.append(('table', {
            'header': header,
            'align': ['l'] + ['r'] * (len(header) - 1),
            'widths': [24] + [10] * (len(header) - 1),
            'rows': health_rows,
        }))

    boot_changed = any((deltas.get(p) or {}).get('boot_id', {}).get('changed') for p in deltas)
    blocks.append(('kv', [
        ('健康判定', STATUS_CN.get(health.get('health_verdict'), health.get('health_verdict', 'NA'))),
        ('boot_id 是否变化', '是（期间发生重启）' if boot_changed else '否'),
        ('告警项', '、'.join(health.get('warnings') or []) or '无'),
    ]))
    for note in health.get('notes') or []:
        blocks.append(('p', '说明：%s' % note))
    blocks.append(('p', '差值为阶段结束值减去阶段开始值。无法读取的计数记为 NA，不做推测。'))

    # 七、资源分配与安全边界
    blocks.append(('h1', '七、资源分配与安全边界'))
    blocks.append(('kv', [
        ('内存压测规模', '%s 个worker，合计 %s' % (metadata.get('memory_workers', 'NA'),
                                                  human_bytes(metadata.get('memory_bytes')))),
        ('混合阶段内存', human_bytes(metadata.get('mixed_memory_bytes'))),
        ('内存使用比例', '预留 max(1GiB, 20%%总内存) 之后使用 %s%%' % metadata.get('mem_percent', 'NA')),
        ('磁盘测试文件', '%s（上限 %s）' % (human_bytes(metadata.get('disk_bytes')),
                                          human_bytes(metadata.get('max_disk_bytes')))),
        ('混合阶段磁盘', human_bytes(metadata.get('mixed_disk_bytes'))),
        ('fio 配置', '引擎 %s，队列深度 %s，并发 %s，探测带宽 %s MiB/s' % (
            '未探测' if metadata.get('fio_engine') in (None, 'none') else metadata.get('fio_engine'),
            metadata.get('fio_iodepth', 'NA'), metadata.get('fio_jobs', 'NA'),
            metadata.get('fio_probe_mibps', 'NA'))),
    ]))
    blocks.append(('p', '内存先预留 max(1GiB, 20% 总内存)，剩余可用量只用一部分，并限制 worker 数量，'
                        '目的是压满而不触发 OOM。磁盘先预留 max(2GiB, 10% 文件系统总量)，最多用可用空间的 25%，'
                        '再受文件上限约束；测试文件大小还会按探测带宽收敛，保证能在预算时间内铺开，'
                        '不会出现文件太大导致 fio 超过计划时间的情况。每个 fio 任务都有独立的硬墙钟超时。'))

    # 八、说明
    blocks.append(('h1', '八、说明'))
    blocks.append(('p', '原始日志、fio JSON、遥测 CSV、环境快照与健康计数已作为证据保留在运行目录，'
                        '并打包进 archive-*.tar.gz，附 manifest.sha256 校验清单。'))
    blocks.append(('p', '本脚本只做测试与报告，不调整系统参数、不修复问题，也从不安装 NVIDIA 驱动、'
                        'CUDA 或任何 NVIDIA 软件包。GPU 阶段优先使用 GPU-burn，并在运行前后持续检查 NVML、'
                        '驱动模块版本和可见 GPU 数量；异常时终止 GPU 负载。'))
    blocks.append(('p', '结论口径：任一阶段失败或关键健康计数恶化为「失败」；关键异常只改判实际发生异常的'
                        '阶段，不会连带改写此前已通过阶段；存在未完成/未测/未执行为'
                        '「部分通过」；只有非关键健康告警为「通过（有告警）」；其余为「通过」。'))
    blocks.append(('p', '报告生成时间：%s（UTC）' % time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())))
    return blocks, metadata, results, performance


# --------------------------------------------------------------------------
# Markdown 渲染
# --------------------------------------------------------------------------
def cell_text(cell):
    return cell['text'] if isinstance(cell, dict) else str(cell)


def render_markdown(blocks):
    out = []
    for kind, payload in blocks:
        if kind == 'title':
            out.append('# %s\n' % payload)
        elif kind == 'h1':
            out.append('## %s\n' % payload)
        elif kind == 'h2':
            out.append('### %s\n' % payload)
        elif kind == 'p':
            out.append('%s\n' % payload)
        elif kind == 'kv':
            for key, value in payload:
                out.append('- **%s:** `%s`' % (key, value))
            out.append('')
        elif kind == 'table':
            header = payload['header']
            align = payload.get('align') or ['l'] * len(header)
            marks = {'l': '---', 'c': ':---:', 'r': '---:'}
            out.append('| ' + ' | '.join(header) + ' |')
            out.append('|' + '|'.join(marks.get(a, '---') for a in align) + '|')
            for row in payload['rows']:
                cells = []
                for cell in row:
                    text = cell_text(cell)
                    if isinstance(cell, dict):
                        text = '**%s**' % text
                    cells.append(text)
                out.append('| ' + ' | '.join(cells) + ' |')
            out.append('')
        elif kind == 'code':
            out.append('```\n%s\n```\n' % payload)
    return '\n'.join(out).rstrip() + '\n'


# --------------------------------------------------------------------------
# Word(docx) 渲染：标准库直接拼 OOXML
# --------------------------------------------------------------------------
NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
COLOR = {'ok': '2E7D32', 'bad': 'C62828', 'warn': 'B26A00'}
TOTAL_WIDTH = 9200


def run_xml(text, bold=False, color=None, mono=False, size=None):
    props = []
    if mono:
        props.append('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/>')
    if bold:
        props.append('<w:b/>')
    if color:
        props.append('<w:color w:val="%s"/>' % color)
    if size:
        props.append('<w:sz w:val="%d"/><w:szCs w:val="%d"/>' % (size, size))
    prefix = '<w:rPr>%s</w:rPr>' % ''.join(props) if props else ''
    return '<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r>' % (prefix, escape(text))


def para_xml(runs, style=None, align=None, shade=None, spacing_before=None):
    props = []
    if style:
        props.append('<w:pStyle w:val="%s"/>' % style)
    if shade:
        props.append('<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % shade)
    if align:
        props.append('<w:jc w:val="%s"/>' % align)
    if spacing_before:
        props.append('<w:spacing w:before="%d"/>' % spacing_before)
    prefix = '<w:pPr>%s</w:pPr>' % ''.join(props) if props else ''
    return '<w:p>%s%s</w:p>' % (prefix, ''.join(runs))


def cell_xml(cell, width, align, header=False):
    text = cell_text(cell)
    style = cell.get('style') if isinstance(cell, dict) else None
    color = COLOR.get(style)
    jc = {'l': 'left', 'c': 'center', 'r': 'right'}.get(align, 'left')
    shade = 'DCE6F1' if header else None
    props = ['<w:tcW w:w="%d" w:type="dxa"/>' % width,
             '<w:vAlign w:val="center"/>']
    if shade:
        props.append('<w:shd w:val="clear" w:color="auto" w:fill="%s"/>' % shade)
    body = para_xml([run_xml(text, bold=header or bool(color), color=color)],
                    style='TableText', align=jc)
    return '<w:tc><w:tcPr>%s</w:tcPr>%s</w:tc>' % (''.join(props), body)


def table_xml(payload):
    header = payload['header']
    align = payload.get('align') or ['l'] * len(header)
    weights = payload.get('widths') or [1] * len(header)
    total = float(sum(weights)) or 1.0
    widths = [max(600, int(TOTAL_WIDTH * w / total)) for w in weights]

    borders = ''.join('<w:%s w:val="single" w:sz="4" w:space="0" w:color="9BB0C4"/>' % side
                      for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
    parts = ['<w:tbl><w:tblPr><w:tblW w:w="%d" w:type="dxa"/><w:tblBorders>%s</w:tblBorders>'
             '<w:tblLayout w:type="fixed"/></w:tblPr>' % (TOTAL_WIDTH, borders)]
    parts.append('<w:tblGrid>%s</w:tblGrid>'
                 % ''.join('<w:gridCol w:w="%d"/>' % w for w in widths))

    parts.append('<w:tr><w:trPr><w:tblHeader/></w:trPr>%s</w:tr>'
                 % ''.join(cell_xml(header[i], widths[i], align[i], header=True)
                           for i in range(len(header))))
    for row in payload['rows']:
        cells = []
        for index in range(len(header)):
            cell = row[index] if index < len(row) else ''
            cells.append(cell_xml(cell, widths[index], align[index]))
        parts.append('<w:tr>%s</w:tr>' % ''.join(cells))
    parts.append('</w:tbl>')
    parts.append(para_xml([], style='Gap'))
    return ''.join(parts)


STYLES_XML = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles %s>
  <w:docDefaults>
    <w:rPrDefault><w:rPr>
      <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="\u5b8b\u4f53" w:cs="Calibri"/>
      <w:sz w:val="21"/><w:szCs w:val="21"/>
    </w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr>
      <w:spacing w:after="100" w:line="300" w:lineRule="auto"/>
    </w:pPr></w:pPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/><w:qFormat/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>
    <w:pPr><w:spacing w:before="0" w:after="240"/><w:jc w:val="center"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="\u5fae\u8f6f\u96c5\u9ed1"/>
      <w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/>
    <w:pPr><w:outlineLvl w:val="0"/><w:spacing w:before="280" w:after="120"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="\u5fae\u8f6f\u96c5\u9ed1"/>
      <w:b/><w:sz w:val="30"/><w:szCs w:val="30"/><w:color w:val="1F3864"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>
    <w:pPr><w:outlineLvl w:val="1"/><w:spacing w:before="200" w:after="100"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="\u5fae\u8f6f\u96c5\u9ed1"/>
      <w:b/><w:sz w:val="25"/><w:szCs w:val="25"/><w:color w:val="1F3864"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Bullet">
    <w:name w:val="Bullet"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:ind w:left="360" w:hanging="180"/><w:spacing w:after="40"/></w:pPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="TableText">
    <w:name w:val="Table Text"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr>
    <w:rPr><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Gap">
    <w:name w:val="Gap"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="0" w:after="0" w:line="120" w:lineRule="auto"/></w:pPr>
    <w:rPr><w:sz w:val="8"/><w:szCs w:val="8"/></w:rPr>
  </w:style>
</w:styles>
''' % NS

CONTENT_TYPES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'''

ROOT_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'''

DOC_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'''

APP_XML = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
 xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
<Application>server-stress</Application>
</Properties>
'''


def core_xml(title):
    stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<cp:coreProperties '
            'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            '<dc:title>%s</dc:title><dc:creator>server-stress</dc:creator>'
            '<cp:lastModifiedBy>server-stress</cp:lastModifiedBy>'
            '<dcterms:created xsi:type="dcterms:W3CDTF">%s</dcterms:created>'
            '<dcterms:modified xsi:type="dcterms:W3CDTF">%s</dcterms:modified>'
            '</cp:coreProperties>' % (escape(title), stamp, stamp))


def render_docx(blocks, path):
    body = []
    title = 'server-stress report'
    for kind, payload in blocks:
        if kind == 'title':
            title = payload
            body.append(para_xml([run_xml(payload)], style='Title'))
        elif kind == 'h1':
            body.append(para_xml([run_xml(payload)], style='Heading1'))
        elif kind == 'h2':
            body.append(para_xml([run_xml(payload)], style='Heading2'))
        elif kind == 'p':
            body.append(para_xml([run_xml(payload)]))
        elif kind == 'kv':
            for key, value in payload:
                body.append(para_xml([run_xml('• '), run_xml('%s：' % key, bold=True),
                                      run_xml(str(value))], style='Bullet'))
        elif kind == 'table':
            body.append(table_xml(payload))
        elif kind == 'code':
            for line in str(payload).splitlines() or ['']:
                body.append(para_xml([run_xml(line, mono=True, size=18)], shade='F2F2F2'))

    section = ('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
               '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
               'w:header="851" w:footer="992" w:gutter="0"/></w:sectPr>')
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                '<w:document %s><w:body>%s%s</w:body></w:document>'
                % (NS, ''.join(body), section))

    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.writestr('[Content_Types].xml', CONTENT_TYPES)
        zf.writestr('_rels/.rels', ROOT_RELS)
        zf.writestr('docProps/core.xml', core_xml(title))
        zf.writestr('docProps/app.xml', APP_XML)
        zf.writestr('word/_rels/document.xml.rels', DOC_RELS)
        zf.writestr('word/styles.xml', STYLES_XML)
        zf.writestr('word/document.xml', document)
    os.chmod(path, 0o600)


# --------------------------------------------------------------------------
# 邮件正文：让不看附件的人也能看懂结论
# --------------------------------------------------------------------------
def render_email_body(metadata, results, performance):
    overall = results.get('overall', 'INCOMPLETE')
    lines = [
        '服务器整机压力测试结果',
        '',
        '任务ID: %s' % metadata.get('id', 'NA'),
        '主机: %s' % metadata.get('host', 'NA'),
        '运行标识: %s' % metadata.get('run_key', 'NA'),
        '总体结论: %s' % STATUS_CN.get(overall, overall),
        '计划时长: %s' % human_seconds(metadata.get('duration_seconds')),
        '实际压测耗时: %s' % human_seconds(metadata.get('actual_seconds')),
        '开始(UTC): %s' % metadata.get('started_utc', 'NA'),
        '结束(UTC): %s' % metadata.get('finished_utc', 'NA'),
        '',
        '各阶段结论:',
    ]
    for row in results.get('stages', []):
        status = row.get('status', 'NA')
        lines.append('  %-7s %-6s 计划%ss 实际%ss  %s'
                     % (row.get('stage', 'NA'), STATUS_CN.get(status, status),
                        row.get('planned_seconds', 0), row.get('actual_seconds', 0),
                        row.get('detail', '')))

    fio = performance.get('fio') or []
    if fio:
        lines += ['', '磁盘性能摘要:']
        for item in fio:
            for side, side_cn in (('read', '读'), ('write', '写')):
                data = item.get(side)
                if data:
                    lines.append('  %-12s %s %8.1f MiB/s  %10.1f IOPS  P99 %s us'
                                 % (item.get('name', 'NA'), side_cn, data.get('mibps') or 0.0,
                                    data.get('iops') or 0.0,
                                    data.get('lat_p99_us') if data.get('lat_p99_us') is not None else 'NA'))

    health = results.get('health') or {}
    lines += ['', '健康判定: %s' % STATUS_CN.get(health.get('health_verdict'),
                                                 health.get('health_verdict', 'NA'))]
    if health.get('warnings'):
        lines.append('告警项: %s' % '、'.join(health['warnings']))

    lines += ['', '附件包含 Word 报告（.docx，可直接双击打开）、Markdown 报告与证据归档。',
              '本次测试只做检查与报告，未修改系统配置。']
    return '\n'.join(lines) + '\n'


def main():
    run, md_path, docx_path = sys.argv[1], sys.argv[2], sys.argv[3]
    blocks, metadata, results, performance = build(run)

    if md_path != '-':
        with open(md_path, 'w', encoding='utf-8') as f:
            f.write(render_markdown(blocks))
        os.chmod(md_path, 0o600)
    if docx_path != '-':
        render_docx(blocks, docx_path)

    body_path = '%s/email-body.txt' % run
    with open(body_path, 'w', encoding='utf-8') as f:
        f.write(render_email_body(metadata, results, performance))
    os.chmod(body_path, 0o600)


main()
PY
}

write_helper_mailer() {
    cat >"$HELPERS/mailer.py" <<'PY'
#!/usr/bin/env python3
"""按配置发送报告邮件。

安全约束：密码只能来自环境变量名或权限受控的密码文件，不接受写在配置里；
配置与密码文件必须是调用者拥有的普通文件，权限 0400/0600，且不跟随符号链接。
附件顺序为 Word、Markdown、证据归档；超出大小上限时从后往前丢，优先保住 Word 报告。
"""
import configparser
import json
import os
import smtplib
import ssl
import stat
import sys
from email.message import EmailMessage
from pathlib import Path

ALLOWED_KEYS = {'host', 'port', 'security', 'username', 'from', 'to', 'password_env',
                'password_file', 'timeout', 'max_attachment_bytes', 'attach_archive'}
STATUS_CN = {'PASS': '通过', 'FAIL': '失败', 'INCOMPLETE': '未完成', 'UNTESTED': '未测',
             'SKIPPED': '未执行', 'PARTIAL': '部分通过', 'PASS WITH WARNINGS': '通过（有告警）'}


def open_private(path):
    """打开一个必须由调用者拥有、权限受限、且不是符号链接的普通文件。"""
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode)
            or stat.S_IMODE(info.st_mode) not in (0o400, 0o600)
            or info.st_uid != os.geteuid()):
        os.close(fd)
        raise SystemExit('invalid ownership/type/mode: %s' % path)
    return fd


def load_config(path):
    fd = open_private(path)
    parser = configparser.ConfigParser(interpolation=None)
    with os.fdopen(fd, encoding='utf-8') as f:
        parser.read_file(f)
    section = parser['smtp']
    if set(section) - ALLOWED_KEYS:
        raise SystemExit('unknown or forbidden config keys')
    return section


def resolve_password(section):
    env_name = section.get('password_env', '').strip()
    file_path = section.get('password_file', '').strip()
    if bool(env_name) == bool(file_path):
        raise SystemExit('configure exactly one password_env or password_file')
    if env_name:
        secret = os.environ.get(env_name)
        if not secret:
            raise SystemExit('password environment variable unavailable')
        return secret
    fd = open_private(str(Path(file_path).expanduser()))
    with os.fdopen(fd, encoding='utf-8') as f:
        secret = f.read().rstrip('\r\n')
    if not secret:
        raise SystemExit('empty SMTP password')
    return secret


def pick_attachments(run, archive, limit, attach_archive):
    candidates = []
    for path in sorted(Path(run).glob('report-*.docx')):
        candidates.append((path, 'application',
                           'vnd.openxmlformats-officedocument.wordprocessingml.document'))
    for path in sorted(Path(run).glob('report-*.md')):
        candidates.append((path, 'text', 'markdown'))
    if attach_archive and archive and os.path.exists(archive):
        candidates.append((Path(archive), 'application', 'gzip'))

    chosen = []
    total = 0
    dropped = []
    for path, maintype, subtype in candidates:
        size = path.stat().st_size
        if total + size > limit:
            dropped.append(path.name)
            continue
        chosen.append((path, maintype, subtype))
        total += size
    return chosen, dropped


def main():
    config_path, run, archive, overall = sys.argv[1:5]
    section = load_config(config_path)
    secret = resolve_password(section)

    with open(os.path.join(run, 'metadata.json'), encoding='utf-8') as f:
        metadata = json.load(f)
    body_path = os.path.join(run, 'email-body.txt')
    with open(body_path, encoding='utf-8') as f:
        body = f.read()

    limit = section.getint('max_attachment_bytes', fallback=25 * 1024 * 1024)
    attach_archive = section.getboolean('attach_archive', fallback=True)
    attachments, dropped = pick_attachments(run, archive, limit, attach_archive)
    if not attachments:
        raise SystemExit('no attachment fits max_attachment_bytes')
    if dropped:
        body += '\n未随邮件发送的附件（超出大小限制，仍保留在被测机运行目录）：%s\n' % '、'.join(dropped)

    message = EmailMessage()
    message['Subject'] = '[整机压测][%s][%s] %s %s' % (
        metadata.get('id', 'NA'), STATUS_CN.get(overall, overall),
        metadata.get('host', 'NA'), metadata.get('finished_utc', ''))
    message['From'] = section['from']
    message['To'] = section['to']
    message.set_content(body)
    for path, maintype, subtype in attachments:
        message.add_attachment(path.read_bytes(), maintype=maintype, subtype=subtype,
                               filename=path.name)

    context = ssl.create_default_context()
    mode = section.get('security', 'starttls').lower()
    host = section['host']
    port = section.getint('port')
    timeout = section.getfloat('timeout', fallback=30)

    client = (smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
              if mode == 'ssl' else smtplib.SMTP(host, port, timeout=timeout))
    try:
        client.ehlo()
        if mode == 'starttls':
            client.starttls(context=context)
            client.ehlo()
        elif mode != 'ssl':
            raise SystemExit('security must be ssl or starttls')
        client.login(section.get('username', ''), secret)
        refused = client.send_message(message)
        if refused:
            raise SystemExit('one or more SMTP recipients refused')
        print('sent attachments: %s' % ', '.join(p.name for p, _m, _s in attachments))
    finally:
        try:
            client.quit()
        except Exception:
            client.close()


main()
PY
}

main "$@"
