#!/usr/bin/env bash
# server-stress 的黑盒回归测试。
# 只调用公开的安全模式，不施加真实压力，不触碰 apt / sudo / SMTP。
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SCRIPT="$ROOT_DIR/server-stress.sh"
TMP_ROOT=""
PASS_COUNT=0
FAIL_COUNT=0
LAST_RC=0
LAST_OUTPUT=""

cleanup() {
    [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM HUP

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %d - %s\n' "$((PASS_COUNT + FAIL_COUNT))" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok %d - %s\n' "$((PASS_COUNT + FAIL_COUNT))" "$1"
    [[ $# -lt 2 || -z "$2" ]] || printf '  %s\n' "$2"
}

assert_true() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected [$expected], got [$actual]"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "missing text: $needle"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "unexpected text: $needle"
    fi
}

invoke() {
    local output rc
    set +e
    output="$($SCRIPT "$@" 2>&1)"
    rc=$?
    set -e
    LAST_RC=$rc
    LAST_OUTPUT="$output"
}

invoke_stdin_with_home() {
    local input="$1"
    shift
    local output_file="$TMP_ROOT/stdin.out"
    set +e
    printf '%s' "$input" | HOME="$TMP_ROOT/home" "$SCRIPT" "$@" >"$output_file" 2>&1
    LAST_RC=${PIPESTATUS[1]}
    set -e
    LAST_OUTPUT="$(<"$output_file")"
}

extract_field() {
    local label="$1" text="$2"
    printf '%s\n' "$text" | while IFS= read -r line; do
        case "$line" in
            "$label"*) printf '%s\n' "${line#"$label"}"; break ;;
        esac
    done
}

if [[ ! -r "$SCRIPT" ]]; then
    printf 'Bail out! main script is not readable: %s\n' "$SCRIPT"
    exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/server-stress-tests.XXXXXXXX")" || exit 1
chmod 700 "$TMP_ROOT"
mkdir -m 700 "$TMP_ROOT/bin" "$TMP_ROOT/runs"

# 让误触发的软件包安装/权限提升在测试里直接失败，而不是真的执行
cat >"$TMP_ROOT/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'TEST FAILURE: apt-get was invoked\n' >&2
exit 97
EOF
cat >"$TMP_ROOT/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'TEST FAILURE: sudo was invoked\n' >&2
exit 98
EOF
chmod 700 "$TMP_ROOT/bin/apt-get" "$TMP_ROOT/bin/sudo"
PATH="$TMP_ROOT/bin:$PATH"
export PATH

printf 'TAP version 13\n'

# ---------------------------------------------------------------------------
# 源码层面的安全护栏：只读源码，不 source，main() 不会在测试 shell 里执行
# ---------------------------------------------------------------------------
assert_true 'main script parses as Bash' bash -n "$SCRIPT"

if grep -nE '(^|[^[:alnum:]_])pkill([[:space:]]|$)' "$SCRIPT" >"$TMP_ROOT/pkill.matches"; then
    fail 'source does not use pkill' "$(<"$TMP_ROOT/pkill.matches")"
else
    pass 'source does not use pkill'
fi
if grep -nE 'fio[^\n]*(--filename(=|[[:space:]])?/dev/|[[:space:]]/dev/)' "$SCRIPT" >"$TMP_ROOT/raw-fio.matches"; then
    fail 'fio has no raw block-device target' "$(<"$TMP_ROOT/raw-fio.matches")"
else
    pass 'fio has no raw block-device target'
fi
if grep -nE '^[[:space:]]*password[[:space:]]*=' "$SCRIPT" >"$TMP_ROOT/password.matches"; then
    fail 'source contains no inline password config key' "$(<"$TMP_ROOT/password.matches")"
else
    pass 'source contains no inline password config key'
fi
if python3 - "$SCRIPT" <<'PY'
import sys

text = open(sys.argv[1], encoding='utf-8').read()
icons = {chr(code) for code in (
    0x2705, 0x274C, 0x26A0, 0x1F525, 0x1F680, 0x1F4BB, 0x1F9E0,
    0x1F4BE, 0x1F3AE, 0x1F527, 0x1F4E7, 0x1F4CA, 0x2699, 0x1F5A5,
    0x1F7E2, 0x1F534, 0x1F7E1)}
raise SystemExit(1 if any(char in text for char in icons) else 0)
PY
then
    pass 'Git CLI and report source contain no decorative icons'
else
    fail 'Git CLI and report source contain no decorative icons'
fi
assert_true 'dependency install performs apt simulation first' grep -Fq 'apt-get --simulate install' "$SCRIPT"
assert_true 'dependency install prevents upgrades' grep -Fq -- '--no-upgrade "${packages[@]}"' "$SCRIPT"
assert_true 'dependency install blocks NVIDIA transactions' grep -Fq \
    'refusing dependency transaction that changes NVIDIA/CUDA packages' "$SCRIPT"
assert_true 'NVIDIA containers retain nvidia-smi hardware detection' grep -Fq \
    'nvidia-smi -L >/dev/null 2>&1' "$SCRIPT"
assert_true 'mixed GPU timeout is not accepted as success' grep -Fq \
    '((gpu_rc == 0)) || rc=1' "$SCRIPT"
assert_true 'GPU critical health guard skips mixed load' grep -Fq \
    '((GPU_DRIVER_UNHEALTHY || GPU_CRITICAL_HEALTH))' "$SCRIPT"

# fio 的 --filename 必须是绝对路径。传相对路径时它只在 --directory 已被解析的
# 情况下才落到测试目录，否则会写到当前工作目录去 —— 那测的就不是目标磁盘了。
if grep -nE -- '--filename=("?\$\(basename|[^"$/])' "$SCRIPT" >"$TMP_ROOT/filename.matches"; then
    fail 'fio test file is always an absolute path' "$(<"$TMP_ROOT/filename.matches")"
else
    pass 'fio test file is always an absolute path'
fi

# 用假的 nvidia-smi 验证 NVML 版本不匹配与可见卡数变化会被阻止。
awk '/^nvidia_health_check\(\) {/,/^}/' "$SCRIPT" >"$TMP_ROOT/nvidia-health-function.sh"
cat >"$TMP_ROOT/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case ${NVIDIA_STUB_MODE:-healthy} in
    mismatch)
        printf '%s\n' 'Failed to initialize NVML: Driver/library version mismatch' >&2
        exit 1
        ;;
    one)
        printf '%s\n' '0, GPU-0000, 595.84'
        ;;
    *)
        printf '%s\n' '0, GPU-0000, 595.84' '1, GPU-0001, 595.84'
        ;;
esac
EOF
cat >"$TMP_ROOT/bin/modinfo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 700 "$TMP_ROOT/bin/nvidia-smi" "$TMP_ROOT/bin/modinfo"
# shellcheck disable=SC1090
source "$TMP_ROOT/nvidia-health-function.sh"
NVIDIA_EXPECTED_COUNT=''
NVIDIA_EXPECTED_DRIVER=''
NVIDIA_HEALTH_REASON=''
NVIDIA_PROC_VERSION_FILE="$TMP_ROOT/no-nvidia-version"
export NVIDIA_PROC_VERSION_FILE
NVIDIA_STUB_MODE=mismatch
export NVIDIA_STUB_MODE
if nvidia_health_check test "$TMP_ROOT/nvidia-health.log"; then
    fail 'NVML driver/library mismatch is rejected'
else
    assert_eq 'NVML mismatch has a precise reason' 'driver-library-version-mismatch' "$NVIDIA_HEALTH_REASON"
fi
NVIDIA_STUB_MODE=healthy
nvidia_health_check baseline "$TMP_ROOT/nvidia-health.log" ||
    fail 'healthy two-GPU inventory is accepted'
NVIDIA_STUB_MODE=one
if nvidia_health_check changed "$TMP_ROOT/nvidia-health.log"; then
    fail 'GPU inventory change is rejected'
else
    assert_eq 'GPU inventory change has a precise reason' 'inventory-changed' "$NVIDIA_HEALTH_REASON"
fi
rm -f -- "$TMP_ROOT/bin/nvidia-smi" "$TMP_ROOT/bin/modinfo"

# 模拟 apt 计划触碰 libnvidia；保护逻辑必须在真实安装前退出。
{
    awk '/^packages_for_commands\(\) {/,/^}/' "$SCRIPT"
    awk '/^install_deps\(\) {/,/^}/' "$SCRIPT"
} >"$TMP_ROOT/dependency-functions.sh"
cat >"$TMP_ROOT/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' update '*) exit 0 ;;
    *' --simulate '*) printf '%s\n' 'Inst libnvidia-compute-595 (595.91 Ubuntu:stable)'; exit 0 ;;
    *) printf 'unsafe\n' >"${APT_ACTUAL_MARKER:?}"; exit 0 ;;
esac
EOF
chmod 700 "$TMP_ROOT/bin/apt-get"
set +e
apt_output="$(
    export APT_ACTUAL_MARKER="$TMP_ROOT/apt-actual"
    DRY=0 SAFE=0 NO_INSTALL=0
    missing() { printf 'fio\n'; }
    log() { printf '%s\n' "$*" >&2; }
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
    sudo() { "$@"; }
    source "$TMP_ROOT/dependency-functions.sh"
    install_deps 2>&1
)"
apt_rc=$?
set -e
assert_eq 'apt NVIDIA transaction is rejected' '2' "$apt_rc"
assert_contains 'apt rejection explains NVIDIA protection' "$apt_output" 'refusing dependency transaction'
assert_true 'apt rejection occurs before real installation' test ! -e "$TMP_ROOT/apt-actual"
rm -f -- "$TMP_ROOT/bin/apt-get"

# 内嵌的 Python 助手运行时才落盘、结束即删除，所以从源码里提取出来单独编译
if python3 "$SCRIPT_DIR/extract-helpers.py" "$SCRIPT" "$TMP_ROOT/helpers" >"$TMP_ROOT/helpers.list" 2>&1; then
    helper_count="$(wc -l <"$TMP_ROOT/helpers.list" | tr -d '[:space:]')"
    pass "embedded Python helpers extracted ($helper_count)"
    if python3 -m py_compile "$TMP_ROOT"/helpers/*.py 2>"$TMP_ROOT/compile.err"; then
        pass 'embedded Python helpers compile'
    else
        fail 'embedded Python helpers compile' "$(<"$TMP_ROOT/compile.err")"
    fi
else
    fail 'embedded Python helpers extracted' "$(<"$TMP_ROOT/helpers.list")"
    fail 'embedded Python helpers compile' 'extraction failed'
fi

# GPU 阶段的 Xid 只能改判 GPU；此前通过的 CPU、内存和磁盘必须保持 PASS。
HEALTH_FIXTURE="$TMP_ROOT/health-attribution"
mkdir -p -- "$HEALTH_FIXTURE/raw" "$HEALTH_FIXTURE/telemetry" "$HEALTH_FIXTURE/work"
printf '{}\n' >"$HEALTH_FIXTURE/work/context.json"
printf '{}\n' >"$HEALTH_FIXTURE/environment.json"
cat >"$HEALTH_FIXTURE/results.tsv" <<'EOF'
cpu	PASS	10	10	cpu ok
memory	PASS	10	10	memory ok
disk	PASS	10	10	disk ok
gpu	PASS	10	10	gpu process exited zero
mixed	INCOMPLETE	10	0	skipped after GPU fault
EOF
printf '{"boot_id":"boot-a","xid":0}\n' >"$HEALTH_FIXTURE/health-gpu-before.json"
printf '{"boot_id":"boot-a","xid":1}\n' >"$HEALTH_FIXTURE/health-gpu-after.json"
printf '{"boot_id":"boot-a","xid":0}\n' >"$HEALTH_FIXTURE/health-run-before.json"
printf '{"boot_id":"boot-a","xid":1}\n' >"$HEALTH_FIXTURE/health-run-after.json"
awk '/^critical_health_delta\(\) {/,/^}/' "$SCRIPT" >"$TMP_ROOT/critical-health-function.sh"
# shellcheck disable=SC1090
source "$TMP_ROOT/critical-health-function.sh"
RUN="$HEALTH_FIXTURE"
assert_eq 'GPU Xid is detected before mixed stage starts' 'xid+1' "$(critical_health_delta gpu)"
if python3 "$TMP_ROOT/helpers/summarize.py" "$HEALTH_FIXTURE" >/dev/null 2>&1 &&
        python3 - "$HEALTH_FIXTURE/results.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    result = json.load(handle)
stages = {item['stage']: item for item in result['stages']}
assert result['overall'] == 'FAIL'
assert stages['cpu']['status'] == 'PASS'
assert stages['memory']['status'] == 'PASS'
assert stages['disk']['status'] == 'PASS'
assert stages['gpu']['status'] == 'FAIL'
PY
then
    pass 'GPU critical health fault is attributed only to GPU stage'
else
    fail 'GPU critical health fault is attributed only to GPU stage'
fi

# ---------------------------------------------------------------------------
# 参数校验：非法输入必须在创建运行目录或启动负载之前就被拒绝
# ---------------------------------------------------------------------------
invalid_ids=(
    '../escape'
    '/absolute'
    '-leading-dash'
    'contains space'
    'contains/slash'
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abc'
)
for bad_id in "${invalid_ids[@]}"; do
    invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id "$bad_id"
    assert_eq "invalid ID is rejected: $bad_id" '2' "$LAST_RC"
    assert_contains "invalid ID reports validation error: $bad_id" "$LAST_OUTPUT" 'invalid ID'
done

invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id opt-check --stages bogus
assert_eq 'unknown stage is rejected' '2' "$LAST_RC"
assert_contains 'unknown stage names the offender' "$LAST_OUTPUT" 'bogus'

# 混入一个非法阶段名时，合法部分不能被静默接受
invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id opt-check --stages cpu,bogus
assert_eq 'partially valid stage list is rejected' '2' "$LAST_RC"

for bad_option in '--mem-percent 99' '--disk-iodepth 0' '--telemetry-interval 61' '--report-format pdf' '--disk-engine nvme' '--gpu-backend opencl'; do
    # shellcheck disable=SC2086
    invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id opt-check $bad_option
    assert_eq "out-of-range option is rejected: $bad_option" '2' "$LAST_RC"
done

invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id opt-check --gpu-backend cuda --install-gpu-burn
assert_eq 'GPU-burn install is rejected with CUDA-only backend' '2' "$LAST_RC"

if grep -Fq 'if ((INSTALL_GPU_BURN)) && install_gpu_burn' "$SCRIPT"; then
    pass 'GPU-burn download requires explicit install option'
else
    fail 'GPU-burn download requires explicit install option'
fi
if grep -Fq -- '-tc -m "${GPU_BURN_MEMORY}%"' "$SCRIPT"; then
    pass 'GPU-burn uses Tensor Core and bounded memory load'
else
    fail 'GPU-burn uses Tensor Core and bounded memory load'
fi

invoke run --self-test-safe --no-install-deps --output-dir "$TMP_ROOT/runs" --id opt-check --duration 59
assert_eq 'too-short duration is rejected' '2' "$LAST_RC"

# ---------------------------------------------------------------------------
# 一次安全模式运行：验证时长分配、报告、Word 文档、归档与凭据不外泄
# ---------------------------------------------------------------------------
CREDENTIAL_SENTINEL='DoNotLeak_ServerStress_9f31c7'
export SERVER_STRESS_SMTP_PASSWORD="$CREDENTIAL_SENTINEL"
invoke run --self-test-safe --no-install-deps \
    --output-dir "$TMP_ROOT/runs" --id repeated-safe-id --duration 61
assert_eq 'self-test-safe returns PARTIAL status code' '2' "$LAST_RC"
assert_contains 'self-test-safe reports safe partial result' "$LAST_OUTPUT" 'Status: PARTIAL'
if [[ "$LAST_OUTPUT" == *'TEST FAILURE: apt-get was invoked'* || "$LAST_OUTPUT" == *'TEST FAILURE: sudo was invoked'* ]]; then
    fail 'safe run invokes neither apt nor sudo' 'an escalation/package-manager stub was reached'
else
    pass 'safe run invokes neither apt nor sudo'
fi

RUN_ID_1="$(extract_field 'Run ID: ' "$LAST_OUTPUT")"
REPORT_1="$(extract_field 'Report: ' "$LAST_OUTPUT")"
WORD_1="$(extract_field 'Word: ' "$LAST_OUTPUT")"
ARCHIVE_1="$(extract_field 'Archive: ' "$LAST_OUTPUT")"
RUN_DIR_1="$(dirname "$REPORT_1")"

assert_true 'safe report exists and is nonempty' test -s "$REPORT_1"
assert_true 'safe Word report exists and is nonempty' test -s "$WORD_1"
assert_true 'safe archive exists and is nonempty' test -s "$ARCHIVE_1"
assert_contains 'report exposes requested total duration' "$(<"$REPORT_1")" '**计划时长（秒）:** `61`'
assert_contains 'report title is Chinese' "$(<"$REPORT_1")" '服务器整机压力测试报告'
assert_contains 'report includes performance section' "$(<"$REPORT_1")" '四、性能指标'
assert_contains 'report includes telemetry section' "$(<"$REPORT_1")" '五、运行期遥测汇总'
assert_contains 'report includes health counter table' "$(<"$REPORT_1")" '六、健康计数差值'
assert_not_contains 'report leaves no unformatted placeholder' "$(<"$REPORT_1")" '%s'
invoke version
assert_contains 'version reports 3.1.2' "$LAST_OUTPUT" '3.1.2'

stage_sum="$(python3 - "$REPORT_1" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding='utf-8').read()
rows = re.findall(r'^\| (cpu|memory|disk|gpu|mixed) \| ([0-9]+) \|', text, re.M)
print(sum(int(seconds) for _stage, seconds in rows) if len(rows) == 5 else 'bad')
PY
)"
assert_eq 'stage durations visible in report sum to requested duration' '61' "$stage_sum"

# Word 报告必须是结构合法的 OOXML 包，否则 Word/WPS 打不开
docx_check="$(python3 - "$WORD_1" <<'PY'
import sys
import xml.etree.ElementTree as ET
import zipfile

required = {'[Content_Types].xml', '_rels/.rels', 'word/document.xml',
            'word/styles.xml', 'word/_rels/document.xml.rels'}
try:
    with zipfile.ZipFile(sys.argv[1]) as zf:
        if zf.testzip() is not None:
            raise SystemExit('bad zip')
        names = set(zf.namelist())
        if not required.issubset(names):
            raise SystemExit('missing parts: %s' % ', '.join(sorted(required - names)))
        for name in names:
            if name.endswith(('.xml', '.rels')):
                ET.fromstring(zf.read(name))
        body = zf.read('word/document.xml').decode('utf-8')
    if '<w:tbl>' not in body:
        raise SystemExit('no table in document')
    print('OK')
except SystemExit as exc:
    print(exc)
except Exception as exc:
    print('error: %s' % exc)
PY
)"
assert_eq 'Word report is a structurally valid OOXML package' 'OK' "$docx_check"

# 邮件正文要能独立看懂：不看附件也知道结论
assert_true 'email body exists' test -s "$RUN_DIR_1/email-body.txt"
assert_contains 'email body carries the verdict' "$(<"$RUN_DIR_1/email-body.txt")" '总体结论'

for artifact in metadata.json results.json performance.json telemetry-summary.json \
    health-summary.json environment.json results.tsv; do
    assert_true "machine-readable artifact exists: $artifact" test -s "$RUN_DIR_1/$artifact"
done
assert_true 'every JSON artifact parses' python3 -c '
import glob
import json
import sys
for path in glob.glob(sys.argv[1] + "/*.json"):
    with open(path, encoding="utf-8") as f:
        json.load(f)
' "$RUN_DIR_1"

if tar -tzf "$ARCHIVE_1" >"$TMP_ROOT/archive.list" 2>"$TMP_ROOT/archive.err"; then
    pass 'safe evidence archive is readable'
else
    fail 'safe evidence archive is readable' "$(<"$TMP_ROOT/archive.err")"
fi
assert_true 'archive contains Markdown report' grep -Eq '^(\./)?report-.*\.md$' "$TMP_ROOT/archive.list"
assert_true 'archive contains Word report' grep -Eq '^(\./)?report-.*\.docx$' "$TMP_ROOT/archive.list"
assert_true 'archive contains checksum manifest' grep -Eq '^(\./)?manifest\.sha256$' "$TMP_ROOT/archive.list"
if grep -Eq '^(\./)?work/' "$TMP_ROOT/archive.list"; then
    fail 'archive excludes the private work directory' 'work/ was archived'
else
    pass 'archive excludes the private work directory'
fi

mkdir -m 700 "$TMP_ROOT/unpacked"
if tar -xzf "$ARCHIVE_1" -C "$TMP_ROOT/unpacked" &&
   (cd "$TMP_ROOT/unpacked" && sha256sum --check manifest.sha256 >"$TMP_ROOT/checksum.out" 2>&1); then
    pass 'archive checksum manifest verifies'
else
    fail 'archive checksum manifest verifies' "$(<"$TMP_ROOT/checksum.out")"
fi

if grep -RIlF -- "$CREDENTIAL_SENTINEL" "$TMP_ROOT/runs" >"$TMP_ROOT/secret.matches"; then
    fail 'artifacts contain no credential strings' "$(<"$TMP_ROOT/secret.matches")"
else
    pass 'artifacts contain no credential strings'
fi
unset SERVER_STRESS_SMTP_PASSWORD

# 运行结束后不应留下 helper 临时目录
leftover="$(find "$TMP_ROOT/runs" -maxdepth 1 -name '.helpers.*' | wc -l | tr -d '[:space:]')"
assert_eq 'helper scratch directory is cleaned up' '0' "$leftover"

# ---------------------------------------------------------------------------
# 阶段选择与报告格式
# ---------------------------------------------------------------------------
invoke run --dry-run --no-install-deps --output-dir "$TMP_ROOT/runs" \
    --id scoped --duration 120 --stages cpu,disk
assert_eq 'scoped run returns PARTIAL status code' '2' "$LAST_RC"
SCOPED_REPORT="$(extract_field 'Report: ' "$LAST_OUTPUT")"
scoped_sum="$(python3 - "$SCOPED_REPORT" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding='utf-8').read()
rows = dict((stage, int(seconds)) for stage, seconds
            in re.findall(r'^\| (cpu|memory|disk|gpu|mixed) \| ([0-9]+) \|', text, re.M))
skipped = [stage for stage in ('memory', 'gpu', 'mixed') if rows.get(stage) != 0]
print('%d %s' % (sum(rows.values()), ','.join(skipped) or 'none'))
PY
)"
assert_eq 'selected stages absorb the whole duration' '120 none' "$scoped_sum"

invoke run --dry-run --no-install-deps --output-dir "$TMP_ROOT/runs" \
    --id skipped --duration 60 --skip-stages gpu,mixed
assert_eq 'skip-stages run returns PARTIAL status code' '2' "$LAST_RC"
assert_contains 'skip-stages still reports a run' "$LAST_OUTPUT" 'Run ID: '

invoke run --dry-run --no-install-deps --output-dir "$TMP_ROOT/runs" \
    --id mdonly --duration 60 --report-format md
MD_ONLY_REPORT="$(extract_field 'Report: ' "$LAST_OUTPUT")"
assert_true 'md-only format still writes Markdown' test -s "$MD_ONLY_REPORT"
assert_not_contains 'md-only format writes no Word file' "$LAST_OUTPUT" 'Word: '

invoke run --dry-run --no-install-deps --output-dir "$TMP_ROOT/runs" \
    --id docxonly --duration 60 --report-format docx
DOCX_ONLY="$(extract_field 'Word: ' "$LAST_OUTPUT")"
assert_true 'docx-only format writes the Word file' test -s "$DOCX_ONLY"
assert_not_contains 'docx-only format writes no Markdown file' "$LAST_OUTPUT" 'Report: '

# 复用同一个业务 ID 时，运行目录和 Run ID 必须仍然唯一
invoke run --dry-run --no-install-deps \
    --output-dir "$TMP_ROOT/runs" --id repeated-safe-id --duration 60
assert_eq 'dry-run returns PARTIAL status code' '2' "$LAST_RC"
RUN_ID_2="$(extract_field 'Run ID: ' "$LAST_OUTPUT")"
if [[ -n "$RUN_ID_1" && -n "$RUN_ID_2" && "$RUN_ID_1" != "$RUN_ID_2" ]]; then
    pass 'same custom ID produces unique run IDs'
else
    fail 'same custom ID produces unique run IDs' "first=[$RUN_ID_1], second=[$RUN_ID_2]"
fi
run_dir_count="$(find "$TMP_ROOT/runs" -mindepth 1 -maxdepth 1 -type d -name 'repeated-safe-id-*' | wc -l | tr -d '[:space:]')"
assert_eq 'same custom ID preserves both run directories' '2' "$run_dir_count"

# preflight 只做预检，不产生运行目录
invoke preflight --no-install-deps --output-dir "$TMP_ROOT/runs" --id pre-check --duration 600
assert_eq 'preflight succeeds' '0' "$LAST_RC"
assert_contains 'preflight reports memory sizing' "$LAST_OUTPUT" 'memory_bytes:'
assert_contains 'preflight reports disk sizing' "$LAST_OUTPUT" 'disk_bytes_cap:'
assert_contains 'preflight reports the stage plan' "$LAST_OUTPUT" 'plan_cpu_seconds:'
pre_dirs="$(find "$TMP_ROOT/runs" -mindepth 1 -maxdepth 1 -type d -name 'pre-check-*' | wc -l | tr -d '[:space:]')"
assert_eq 'preflight creates no run directory' '0' "$pre_dirs"

invoke preflight --no-install-deps --output-dir "$TMP_ROOT/runs" --id pre-mail --email
assert_eq 'preflight rejects --email' '2' "$LAST_RC"

invoke status --output-dir "$TMP_ROOT/runs"
assert_eq 'status reads the progress file' '0' "$LAST_RC"

# ---------------------------------------------------------------------------
# init-config：生成私有且不含明文密码的配置，且拒绝覆盖
# ---------------------------------------------------------------------------
CONFIG="$TMP_ROOT/config/smtp.ini"
invoke init-config --config "$CONFIG"
assert_eq 'init-config succeeds for a new path' '0' "$LAST_RC"
assert_true 'init-config creates configuration' test -f "$CONFIG"
config_mode="$(stat -c '%a' "$CONFIG" 2>/dev/null || printf missing)"
assert_eq 'init-config sets mode 0600' '600' "$config_mode"
for key in host port security username from to password_env password_file timeout \
    max_attachment_bytes attach_archive; do
    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG"; then
        pass "init-config includes $key"
    else
        fail "init-config includes $key" 'required SMTP key is absent'
    fi
done
if grep -Eq '^[[:space:]]*(password|pass|secret)[[:space:]]*=' "$CONFIG"; then
    fail 'generated config has no inline secret key' 'password/pass/secret key found'
else
    pass 'generated config has no inline secret key'
fi
invoke init-config --config "$CONFIG"
assert_eq 'init-config refuses to overwrite' '2' "$LAST_RC"
assert_contains 'init-config explains overwrite refusal' "$LAST_OUTPUT" 'config path must be absolute and new'

# QQ 首次配置：授权码应写入独立私有文件，配置必须固定 SSL SMTP 参数，
# 且授权码不能出现在配置或命令输出中。
QQ_SENTINEL='QQSMTPAuth_8c2a7e'
invoke_stdin_with_home $'sender@qq.com\n'"$QQ_SENTINEL"$'\n' setup-qq-mail
assert_eq 'QQ setup succeeds with hidden authorization code input' '0' "$LAST_RC"
QQ_CONFIG="$TMP_ROOT/home/.config/server-stress/smtp.conf"
QQ_AUTH="$TMP_ROOT/home/.config/server-stress/qq-smtp-auth"
assert_true 'QQ setup creates private SMTP config' test -f "$QQ_CONFIG"
assert_true 'QQ setup creates separate authorization file' test -f "$QQ_AUTH"
assert_eq 'QQ config mode is 0600' '600' "$(stat -c '%a' "$QQ_CONFIG")"
assert_eq 'QQ authorization file mode is 0600' '600' "$(stat -c '%a' "$QQ_AUTH")"
assert_contains 'QQ config uses official SSL endpoint' "$(<"$QQ_CONFIG")" 'host = smtp.qq.com'
assert_contains 'QQ config uses SSL port' "$(<"$QQ_CONFIG")" 'port = 465'
assert_contains 'QQ config stores password in separate file' "$(<"$QQ_CONFIG")" "password_file = $QQ_AUTH"
assert_not_contains 'QQ authorization code is not in SMTP config' "$(<"$QQ_CONFIG")" "$QQ_SENTINEL"
assert_not_contains 'QQ authorization code is not printed' "$LAST_OUTPUT" "$QQ_SENTINEL"
assert_eq 'QQ authorization file contains entered code' "$QQ_SENTINEL" "$(<"$QQ_AUTH")"
invoke_stdin_with_home $'sender@qq.com\n'"$QQ_SENTINEL"$'\n' setup-qq-mail
assert_eq 'QQ setup refuses to overwrite saved credentials' '2' "$LAST_RC"
rm -rf -- "$TMP_ROOT/home"

# 权限过宽的配置必须在 Python/smtplib 发起连接之前就被拒绝；下面的主机名永远不会被访问
BAD_CONFIG="$TMP_ROOT/config/insecure.ini"
cat >"$BAD_CONFIG" <<'EOF'
[smtp]
host = smtp.invalid
port = 587
security = starttls
username =
from = sender@example.invalid
to = receiver@example.invalid
password_env =
password_file =
timeout = 1
max_attachment_bytes = 1048576
EOF
chmod 644 "$BAD_CONFIG"
invoke run --self-test-safe --no-install-deps --email \
    --output-dir "$TMP_ROOT/mail-runs" --id permission-check --duration 60 \
    --config "$BAD_CONFIG"
assert_eq 'email configuration failure returns dedicated nonzero code' '3' "$LAST_RC"
assert_contains 'insecure config is rejected for permissions' "$LAST_OUTPUT" 'mode 0400/0600'
if find "$TMP_ROOT/mail-runs" -type f -name 'email-*.log' -print -quit 2>/dev/null | grep -q .; then
    fail 'permission rejection occurs before SMTP client execution' 'an SMTP client log was created'
else
    pass 'permission rejection occurs before SMTP client execution'
fi

printf '1..%d\n' "$((PASS_COUNT + FAIL_COUNT))"
printf '# %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
