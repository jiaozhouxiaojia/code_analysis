#!/bin/bash
#
# CFS 组调度全景验证脚本
#
# 场景：
#   root cgroup:  taskA(nice=0), taskC(nice=0)
#   test_cgroupA: 10 个子 cgroup，各有一个任务
#     child_2 中为 taskB(nice=-19)，其余为 filler(nice=0)
#   所有任务绑定同一 CPU
#
# 预期：taskA ≈ taskC ≈ 33.3%, 每个 child 内任务 ≈ 3.3%
#       taskB(nice=-19) 与 filler(nice=0) 获得相同 CPU 时间
#
# 使用：sudo bash cfs_group_sched_verify.sh
# 清理：sudo bash cfs_group_sched_verify.sh cleanup
#
# 注意：脚本会自动禁用 CONFIG_SCHED_AUTOGROUP 以避免干扰。
#       autogroup 会将 root cgroup 中的进程按 TTY 会话分组，
#       导致 taskA/taskC 被包裹在 autogroup 的 group entity 中，
#       产生 1:1:2 而非预期的 1:1:1 结果。
#       详见 CFS_Autogroup_Debug_Analysis.md。
#

set -e

TARGET_CPU=0
NUM_CHILD_CGROUPS=10
RUNTIME=30
CGROUP_ROOT="/sys/fs/cgroup"
TEST_GROUP="$CGROUP_ROOT/test_cgroupA"
AUTOGROUP_SYSCTL="/proc/sys/kernel/sched_autogroup_enabled"

# 保存 autogroup 原始状态，以便恢复
AUTOGROUP_ORIG=""
if [ -f "$AUTOGROUP_SYSCTL" ]; then
    AUTOGROUP_ORIG=$(cat "$AUTOGROUP_SYSCTL")
fi

# ========== 清理 ==========
cleanup() {
    echo "[清理] 停止测试进程..."
    for f in /tmp/cfs_test_pid_*; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
        rm -f "$f"
    done
    sleep 1
    echo "[清理] 删除 cgroup..."
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

[ "$1" = "cleanup" ] && { cleanup; exit 0; }

# ========== 前置检查 ==========
[ "$(id -u)" -ne 0 ] && { echo "错误：需要 root 权限"; exit 1; }
mount | grep -q "cgroup2 on $CGROUP_ROOT" || { echo "错误：未检测到 cgroup v2"; exit 1; }
grep -q "cpu" "$CGROUP_ROOT/cgroup.controllers" || { echo "错误：cpu 控制器未启用"; exit 1; }

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

# ========== 层级图 ==========
echo "============================================="
echo " CFS 组调度全景验证"
echo "============================================="
echo ""
echo "  绑定 CPU: $TARGET_CPU | 运行时长: ${RUNTIME}s"
echo ""
echo "  / (root cgroup)"
echo "  │"
echo "  ├── taskA ← nice=0 ──────────── weight=1024 ── 预期 ~33.3%"
echo "  ├── taskC ← nice=0 ──────────── weight=1024 ── 预期 ~33.3%"
echo "  │"
echo "  └── test_cgroupA/ ───────────── cpu.weight=100 ── 预期 ~33.3% (整体)"
echo "      │"
echo "      ├── child_1/  filler_1 (nice=0)  ──── 预期 ~3.3%"
echo "      ├── child_2/  taskB (nice=-19)   ──── 预期 ~3.3% (nice 被层级稀释!)"
echo "      ├── child_3/  filler_3 (nice=0)  ──── 预期 ~3.3%"
echo "      ├── ...       ...                ──── 预期 ~3.3%"
echo "      └── child_10/ filler_10 (nice=0) ──── 预期 ~3.3%"
echo ""

# ========== 创建 cgroup 层级 ==========
echo "[步骤1] 创建 cgroup 层级..."
echo "+cpu" > "$CGROUP_ROOT/cgroup.subtree_control"
mkdir -p "$TEST_GROUP"
echo "+cpu" > "$TEST_GROUP/cgroup.subtree_control"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    mkdir -p "$TEST_GROUP/child_$i"
done
echo "  cgroupA cpu.weight=$(cat "$TEST_GROUP/cpu.weight"), child cpu.weight=$(cat "$TEST_GROUP/child_1/cpu.weight")"

# ========== 启动进程 ==========
echo ""
echo "[步骤2] 启动测试进程..."

start_busy_loop() {
    local name=$1 cpu=$2 nice_val=$3 pid_file=$4
    nice -n "$nice_val" taskset -c "$cpu" bash -c 'while true; do :; done' &
    echo $! > "$pid_file"
    echo "  $name: PID=$!, nice=$nice_val"
}

# taskA, taskC: root cgroup
start_busy_loop "taskA" $TARGET_CPU 0 /tmp/cfs_test_pid_taskA
start_busy_loop "taskC" $TARGET_CPU 0 /tmp/cfs_test_pid_taskC
TASKA_PID=$(cat /tmp/cfs_test_pid_taskA)
TASKC_PID=$(cat /tmp/cfs_test_pid_taskC)
echo $TASKA_PID > "$CGROUP_ROOT/cgroup.procs"
echo $TASKC_PID > "$CGROUP_ROOT/cgroup.procs"

# taskB: child_2, nice=-19
start_busy_loop "taskB" $TARGET_CPU -19 /tmp/cfs_test_pid_taskB
TASKB_PID=$(cat /tmp/cfs_test_pid_taskB)
echo $TASKB_PID > "$TEST_GROUP/child_2/cgroup.procs"

# fillers: child_1, child_3 ~ child_10
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    start_busy_loop "filler_$i" $TARGET_CPU 0 "/tmp/cfs_test_pid_filler_$i"
    echo "$(cat /tmp/cfs_test_pid_filler_$i)" > "$TEST_GROUP/child_$i/cgroup.procs"
done

# ========== 验证 cgroup ==========
echo ""
echo "[步骤3] 验证 cgroup 归属..."
echo "  taskA  (PID=$TASKA_PID): $(cat /proc/$TASKA_PID/cgroup)"
echo "  taskC  (PID=$TASKC_PID): $(cat /proc/$TASKC_PID/cgroup)"
echo "  taskB  (PID=$TASKB_PID): $(cat /proc/$TASKB_PID/cgroup)"
for i in 1 3 10; do
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    echo "  filler_$i (PID=$FPID): $(cat /proc/$FPID/cgroup)"
done

# ========== 查看内核权重 ==========
echo ""
echo "[步骤4] 内核中的 se.load.weight..."
echo "  taskA:  $(grep 'se.load.weight' /proc/$TASKA_PID/sched | awk '{print $NF}')"
echo "  taskC:  $(grep 'se.load.weight' /proc/$TASKC_PID/sched | awk '{print $NF}')"
echo "  taskB:  $(grep 'se.load.weight' /proc/$TASKB_PID/sched | awk '{print $NF}')"
FPID1=$(cat /tmp/cfs_test_pid_filler_1)
echo "  filler_1: $(grep 'se.load.weight' /proc/$FPID1/sched | awk '{print $NF}')"

# ========== 采集数据 ==========
echo ""
echo "[步骤5] 运行 ${RUNTIME}s 采集数据..."

get_utime() { awk '{print $14}' /proc/$1/stat 2>/dev/null || echo 0; }

# 采集所有进程的起始 ticks
TASKA_S=$(get_utime $TASKA_PID)
TASKC_S=$(get_utime $TASKC_PID)
TASKB_S=$(get_utime $TASKB_PID)
declare -A FILLER_S
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    FILLER_S[$i]=$(get_utime $FPID)
done

sleep "$RUNTIME"

# 采集结束 ticks
TASKA_E=$(get_utime $TASKA_PID)
TASKC_E=$(get_utime $TASKC_PID)
TASKB_E=$(get_utime $TASKB_PID)
declare -A FILLER_E
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    FILLER_E[$i]=$(get_utime $FPID)
done

# 计算
TASKA_T=$((TASKA_E - TASKA_S))
TASKC_T=$((TASKC_E - TASKC_S))
TASKB_T=$((TASKB_E - TASKB_S))
CGROUP_TOTAL=$TASKB_T
declare -A FILLER_T
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FILLER_T[$i]=$((FILLER_E[$i] - FILLER_S[$i]))
    CGROUP_TOTAL=$((CGROUP_TOTAL + FILLER_T[$i]))
done

ALL_TOTAL=$((TASKA_T + TASKC_T + CGROUP_TOTAL))
[ "$ALL_TOTAL" -eq 0 ] && { echo "错误：未采集到数据"; cleanup; exit 1; }

pct() { echo "$((${1} * 1000 / ${2}))" | sed 's/\(.*\)\(.\)$/\1.\2/'; }

# ========== 输出结果 ==========
echo ""
echo "============================================="
echo " 测试结果"
echo "============================================="
echo ""
printf "  %-28s %10s %8s  %s\n" "任务" "ticks" "占比" "位置"
printf "  %-28s %10s %8s  %s\n" "----" "-----" "----" "----"
printf "  %-28s %10d %7s%%  %s\n" "taskA (nice=0)" $TASKA_T "$(pct $TASKA_T $ALL_TOTAL)" "root cgroup"
printf "  %-28s %10d %7s%%  %s\n" "taskC (nice=0)" $TASKC_T "$(pct $TASKC_T $ALL_TOTAL)" "root cgroup"
echo "  ---"
printf "  %-28s %10d %7s%%  %s\n" "taskB (nice=-19)" $TASKB_T "$(pct $TASKB_T $ALL_TOTAL)" "cgroupA/child_2"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    printf "  %-28s %10d %7s%%  %s\n" "filler_$i (nice=0)" ${FILLER_T[$i]} "$(pct ${FILLER_T[$i]} $ALL_TOTAL)" "cgroupA/child_$i"
done
echo "  ---"
printf "  %-28s %10d %7s%%  %s\n" "cgroupA 合计" $CGROUP_TOTAL "$(pct $CGROUP_TOTAL $ALL_TOTAL)" ""

echo ""
echo "============================================="
echo " 分析"
echo "============================================="
echo ""
echo "  第一层 (root cfs_rq):"
echo "    taskA  : $(pct $TASKA_T $ALL_TOTAL)%  (预期 ~33.3%)"
echo "    taskC  : $(pct $TASKC_T $ALL_TOTAL)%  (预期 ~33.3%)"
echo "    cgroupA: $(pct $CGROUP_TOTAL $ALL_TOTAL)%  (预期 ~33.3%)"
echo ""
echo "  第二层 (cgroupA cfs_rq):"
echo "    taskB(nice=-19) : $(pct $TASKB_T $ALL_TOTAL)%"
FPID1_T=${FILLER_T[1]}
echo "    filler_1(nice=0): $(pct $FPID1_T $ALL_TOTAL)%"
echo "    → taskB 与 filler 占比几乎相同 (nice 值被层级稀释)"
echo ""
echo "  关键对比:"
echo "    taskA(nice=0) / taskB(nice=-19) ≈ $(echo "scale=1; $TASKA_T / ($TASKB_T + 1)" | bc)x"
echo "    → nice=0 的任务获得了 nice=-19 任务的 ~10 倍 CPU 时间"
echo ""

# ========== 清理 ==========
cleanup
echo "测试完成。"
