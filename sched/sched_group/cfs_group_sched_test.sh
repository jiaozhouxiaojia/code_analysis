#!/bin/bash
#
# CFS 组调度层级稀释效应验证脚本
#
# 验证场景：
#   - taskA: root cgroup, nice=0
#   - taskB: 嵌套在两层 cgroup 中, nice=-19
#   - 两个任务绑定到同一 CPU
#   - 预期：taskA 获得远多于 taskB 的 CPU 时间（尽管 taskB nice 值更高）
#
# 使用方法：sudo bash cfs_group_sched_test.sh
# 清理方法：sudo bash cfs_group_sched_test.sh cleanup
#
# 注意：脚本会自动禁用 CONFIG_SCHED_AUTOGROUP 以避免干扰。
#       autogroup 会将 root cgroup 中的进程按 TTY 会话分组，
#       导致调度层级与 cgroup v2 层级不一致。
#       详见 CFS_Autogroup_Debug_Analysis.md。
#

set -e

# ========== 配置 ==========
TARGET_CPU=0                # 绑定的 CPU 编号
NUM_CHILD_CGROUPS=10        # cgroupA 下的子 cgroup 数量
RUNTIME=600                 # 测试运行时长（秒）
CGROUP_ROOT="/sys/fs/cgroup"
TEST_GROUP="$CGROUP_ROOT/test_cgroupA"
AUTOGROUP_SYSCTL="/proc/sys/kernel/sched_autogroup_enabled"

# 保存 autogroup 原始状态，以便恢复
AUTOGROUP_ORIG=""
if [ -f "$AUTOGROUP_SYSCTL" ]; then
    AUTOGROUP_ORIG=$(cat "$AUTOGROUP_SYSCTL")
fi

# ========== 清理函数 ==========
cleanup() {
    echo "[清理] 停止所有测试进程..."
    # 杀掉所有由本脚本启动的后台 busy loop
    for pid_file in /tmp/cfs_test_pid_*; do
        [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    done
    sleep 1

    echo "[清理] 删除 cgroup 层级..."
    # 先删子 cgroup，再删父 cgroup
    for i in $(seq 1 $NUM_CHILD_CGROUPS); do
        rmdir "$TEST_GROUP/child_$i" 2>/dev/null || true
    done
    rmdir "$TEST_GROUP" 2>/dev/null || true

    # 恢复 autogroup 原始状态
    if [ -n "$AUTOGROUP_ORIG" ] && [ -f "$AUTOGROUP_SYSCTL" ]; then
        echo "$AUTOGROUP_ORIG" > "$AUTOGROUP_SYSCTL"
        echo "[清理] 已恢复 sched_autogroup_enabled=$AUTOGROUP_ORIG"
    fi

    echo "[清理] 完成"
}

if [ "$1" = "cleanup" ]; then
    cleanup
    exit 0
fi

# ========== 前置检查 ==========
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限运行。请使用 sudo。"
    exit 1
fi

# 检查 cgroup v2
if ! mount | grep -q "cgroup2 on $CGROUP_ROOT"; then
    echo "错误：未检测到 cgroup v2 挂载在 $CGROUP_ROOT"
    exit 1
fi

# 检查 cpu 控制器
if ! grep -q "cpu" "$CGROUP_ROOT/cgroup.controllers"; then
    echo "错误：cpu 控制器未启用"
    exit 1
fi

# 先清理可能残留的上次测试
cleanup 2>/dev/null || true

# ========== 禁用 autogroup ==========
if [ -f "$AUTOGROUP_SYSCTL" ]; then
    CURRENT_AG=$(cat "$AUTOGROUP_SYSCTL")
    if [ "$CURRENT_AG" != "0" ]; then
        echo "[前置] 检测到 sched_autogroup_enabled=$CURRENT_AG，禁用以避免干扰..."
        echo 0 > "$AUTOGROUP_SYSCTL"
        echo "[前置] 已设置 sched_autogroup_enabled=0"
    else
        echo "[前置] sched_autogroup_enabled 已为 0，无需调整"
    fi
else
    echo "[前置] 未找到 $AUTOGROUP_SYSCTL (CONFIG_SCHED_AUTOGROUP 未编译)"
fi

echo "============================================="
echo " CFS 组调度层级稀释效应验证"
echo "============================================="
echo ""
echo "绑定 CPU: $TARGET_CPU | 运行时长: ${RUNTIME}s | 子 cgroup 数: $NUM_CHILD_CGROUPS"
echo ""
echo "cgroup 层级与调度权重："
echo ""
echo "  / (root cgroup)"
echo "  │"
echo "  ├── taskA ← nice=0 ──────────────────── weight=1024"
echo "  │   (直接在 root cfs_rq 上竞争)"
echo "  │"
echo "  └── test_cgroupA/ ───────────────────── cpu.weight=100 (默认)"
echo "      │"
echo "      │   cgroupA 在 root cfs_rq 上作为一个 group sched_entity,"
echo "      │   权重受 cpu.weight=100 封顶, 与 taskA(1024) 竞争处于劣势"
echo "      │"
echo "      ├── child_1/ ────────────────────── cpu.weight=100"
echo "      │   └── filler_1 (nice=0, busy loop)"
echo "      │"
echo "      ├── child_2/ ────────────────────── cpu.weight=100"
echo "      │   └── taskB ← nice=-19 ───────── weight=88761"
echo "      │       (高权重只在 child_2 的 cfs_rq 内部生效)"
echo "      │"
echo "      ├── child_3/ ────────────────────── cpu.weight=100"
echo "      │   └── filler_3 (nice=0, busy loop)"
echo "      │"
echo "      ├── ... (child_4 ~ child_$((NUM_CHILD_CGROUPS-1)))"
echo "      │   └── filler_N (nice=0, busy loop)"
echo "      │"
echo "      └── child_${NUM_CHILD_CGROUPS}/ ──────────────────── cpu.weight=100"
echo "          └── filler_${NUM_CHILD_CGROUPS} (nice=0, busy loop)"
echo ""
echo "  预期 CPU 分配："
echo "    taskA ≈ 1024/(1024+100) ≈ 91%  (root cfs_rq 层面)"
echo "    cgroupA 总共 ≈ 100/(1024+100) ≈ 9%"
echo "      └── taskB 所在 child_2 ≈ 9% × 1/${NUM_CHILD_CGROUPS} ≈ 0.9%"
echo ""

# ========== 步骤1: 创建 cgroup 层级 ==========
echo "[步骤1] 创建 cgroup 层级..."

# 在 root 下启用 cpu 控制器给子 cgroup
echo "+cpu" > "$CGROUP_ROOT/cgroup.subtree_control"

# 创建 cgroupA
mkdir -p "$TEST_GROUP"
echo "+cpu" > "$TEST_GROUP/cgroup.subtree_control"

# 创建子 cgroup
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    mkdir -p "$TEST_GROUP/child_$i"
done

echo "  已创建 $TEST_GROUP 及 $NUM_CHILD_CGROUPS 个子 cgroup"

# 显示默认 weight
echo "  cgroupA cpu.weight: $(cat "$TEST_GROUP/cpu.weight")"
echo "  child_2 cpu.weight: $(cat "$TEST_GROUP/child_2/cpu.weight")"

# ========== 步骤2: 启动 busy loop 进程 ==========
echo ""
echo "[步骤2] 启动测试进程..."

# busy loop 函数：纯 CPU 消耗
start_busy_loop() {
    local name=$1
    local cpu=$2
    local nice_val=$3
    local pid_file=$4

    nice -n "$nice_val" taskset -c "$cpu" bash -c '
        while true; do
            : # 空操作，纯 CPU 消耗
        done
    ' &
    local pid=$!
    echo $pid > "$pid_file"
    echo "  $name: PID=$pid, nice=$nice_val, CPU=$cpu"
}

# taskA: root cgroup, nice=0
start_busy_loop "taskA (root cgroup, nice=0) " $TARGET_CPU 0 /tmp/cfs_test_pid_taskA
TASKA_PID=$(cat /tmp/cfs_test_pid_taskA)
# 显式移入 root cgroup（进程默认继承父进程的 cgroup，通常在 systemd 的 user slice 中）
echo $TASKA_PID > "$CGROUP_ROOT/cgroup.procs"

# taskB: child_2 cgroup, nice=-19
start_busy_loop "taskB (child_2, nice=-19)   " $TARGET_CPU -19 /tmp/cfs_test_pid_taskB
TASKB_PID=$(cat /tmp/cfs_test_pid_taskB)
echo $TASKB_PID > "$TEST_GROUP/child_2/cgroup.procs"

# 在其他子 cgroup 中各放一个 busy loop，模拟"任务数量较多"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue  # child_2 已有 taskB
    start_busy_loop "filler (child_$i)           " $TARGET_CPU 0 "/tmp/cfs_test_pid_filler_$i"
    FILLER_PID=$(cat "/tmp/cfs_test_pid_filler_$i")
    echo $FILLER_PID > "$TEST_GROUP/child_$i/cgroup.procs"
done

# ========== 步骤3: 验证进程实际 cgroup ==========
echo ""
echo "[步骤3] 验证各进程实际 cgroup..."
echo "  taskA (PID=$TASKA_PID): $(cat /proc/$TASKA_PID/cgroup)"
echo "  taskB (PID=$TASKB_PID): $(cat /proc/$TASKB_PID/cgroup)"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    echo "  filler_$i (PID=$FPID): $(cat /proc/$FPID/cgroup)"
done

# ========== 步骤4: 采集 CPU 使用数据 ==========
echo ""
echo "[步骤4] 运行 ${RUNTIME}s 采集数据..."
echo ""

# 记录起始 CPU 时间 (单位: clock ticks, 通常 100Hz)
get_utime() {
    awk '{print $14}' /proc/$1/stat 2>/dev/null || echo 0
}

TASKA_START=$(get_utime $TASKA_PID)
TASKB_START=$(get_utime $TASKB_PID)

sleep "$RUNTIME"

TASKA_END=$(get_utime $TASKA_PID)
TASKB_END=$(get_utime $TASKB_PID)

TASKA_TICKS=$((TASKA_END - TASKA_START))
TASKB_TICKS=$((TASKB_END - TASKB_START))
TOTAL_TICKS=$((TASKA_TICKS + TASKB_TICKS))

if [ "$TOTAL_TICKS" -eq 0 ]; then
    echo "错误：未采集到 CPU 时间数据"
    cleanup
    exit 1
fi

TASKA_PCT=$((TASKA_TICKS * 100 / TOTAL_TICKS))
TASKB_PCT=$((TASKB_TICKS * 100 / TOTAL_TICKS))

# ========== 步骤5: 输出结果 ==========
echo "============================================="
echo " 测试结果"
echo "============================================="
echo ""
printf "  %-35s %8s %8s\n" "进程" "CPU ticks" "占比"
printf "  %-35s %8s %8s\n" "---" "---------" "----"
printf "  %-35s %8d %7d%%\n" "taskA (root cgroup, nice=0)" "$TASKA_TICKS" "$TASKA_PCT"
printf "  %-35s %8d %7d%%\n" "taskB (child_2, nice=-19)" "$TASKB_TICKS" "$TASKB_PCT"
echo ""
echo "  taskA / taskB 比值: $(echo "scale=1; $TASKA_TICKS / ($TASKB_TICKS + 1)" | bc)x"
echo ""

if [ "$TASKA_TICKS" -gt "$TASKB_TICKS" ]; then
    echo "  [验证通过] taskA(nice=0) 获得了远多于 taskB(nice=-19) 的 CPU 时间"
    echo "  这证实了组调度的层级稀释效应："
    echo "    - taskA 在 root cfs_rq 直接竞争，权重 1024"
    echo "    - cgroupA 的 group entity 权重最多 100 (cgroup v2 默认 cpu.weight)"
    echo "    - cgroupA 的份额再均分给 ${NUM_CHILD_CGROUPS} 个子 cgroup"
    echo "    - taskB 的 nice=-19 只在 child_2 内部生效，无法穿透到上层"
else
    echo "  [结果异常] taskB 获得了更多 CPU 时间，请检查环境配置"
fi

echo ""
echo "============================================="
echo " 对照实验：将 taskA 也放入 cgroup 验证"
echo "============================================="
echo ""
echo "  如需进一步验证，可手动运行对照实验："
echo "    # 将 taskA 也放入 child_2，消除层级差异"
echo "    echo $TASKA_PID > $TEST_GROUP/child_2/cgroup.procs"
echo "    # 此时 taskB(nice=-19) 应获得远多于 taskA(nice=0) 的 CPU 时间"
echo ""

# ========== 清理 ==========
cleanup
echo "测试完成。"
