#!/bin/bash
#
# CFS 组调度 1:1:2 现象诊断脚本
#
# 目的：捕获 sched_debug 数据来定位为什么 cgroupA 获得 2x CPU 时间
#
# 使用：sudo bash cfs_group_sched_diag.sh
# 清理：sudo bash cfs_group_sched_diag.sh cleanup

set -e

TARGET_CPU=0
NUM_CHILD_CGROUPS=10
RUNTIME=30
SAMPLE_INTERVAL=5          # 每隔 N 秒采样一次 sched_debug
CGROUP_ROOT="/sys/fs/cgroup"
TEST_GROUP="$CGROUP_ROOT/test_cgroupA"
DIAG_DIR="/tmp/cfs_diag_$(date +%s)"

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
    echo "[清理] 完成"
}

[ "$1" = "cleanup" ] && { cleanup; exit 0; }

# ========== 前置检查 ==========
[ "$(id -u)" -ne 0 ] && { echo "错误：需要 root 权限"; exit 1; }
mount | grep -q "cgroup2 on $CGROUP_ROOT" || { echo "错误：未检测到 cgroup v2"; exit 1; }
grep -q "cpu" "$CGROUP_ROOT/cgroup.controllers" || { echo "错误：cpu 控制器未启用"; exit 1; }

cleanup 2>/dev/null || true
mkdir -p "$DIAG_DIR"

echo "============================================="
echo " CFS 组调度 1:1:2 诊断"
echo "============================================="
echo ""
echo "  诊断数据输出目录: $DIAG_DIR"
echo "  绑定 CPU: $TARGET_CPU | 运行时长: ${RUNTIME}s"
echo ""

# ========== 步骤0: 系统环境信息 ==========
echo "[步骤0] 收集系统环境信息..."
{
    echo "=== 内核版本 ==="
    uname -r
    echo ""
    echo "=== HZ (CONFIG_HZ) ==="
    grep CONFIG_HZ /boot/config-$(uname -r) 2>/dev/null || zcat /proc/config.gz 2>/dev/null | grep CONFIG_HZ || echo "无法获取"
    echo ""
    echo "=== sched 相关内核配置 ==="
    (cat /boot/config-$(uname -r) 2>/dev/null || zcat /proc/config.gz 2>/dev/null) | grep -E "CONFIG_FAIR_GROUP_SCHED|CONFIG_SCHED_AUTOGROUP|CONFIG_CFS_BANDWIDTH|CONFIG_SCHED_DEBUG" || echo "无法获取"
    echo ""
    echo "=== sched_base_slice ==="
    cat /proc/sys/kernel/sched_base_slice_ns 2>/dev/null || echo "无此文件"
    echo ""
    echo "=== CPU 信息 ==="
    nproc
    echo ""
    echo "=== root cgroup subtree_control ==="
    cat "$CGROUP_ROOT/cgroup.subtree_control"
    echo ""
    echo "=== root cgroup 直接子 cgroup ==="
    ls -la "$CGROUP_ROOT/" | grep "^d"
} > "$DIAG_DIR/system_info.txt" 2>&1
echo "  已保存到 $DIAG_DIR/system_info.txt"

# ========== 步骤1: 创建 cgroup 层级 ==========
echo ""
echo "[步骤1] 创建 cgroup 层级..."
echo "+cpu" > "$CGROUP_ROOT/cgroup.subtree_control"
mkdir -p "$TEST_GROUP"
echo "+cpu" > "$TEST_GROUP/cgroup.subtree_control"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    mkdir -p "$TEST_GROUP/child_$i"
done
echo "  cgroupA cpu.weight=$(cat "$TEST_GROUP/cpu.weight")"
echo "  child_1 cpu.weight=$(cat "$TEST_GROUP/child_1/cpu.weight")"

# ========== 步骤2: 启动进程 ==========
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

# fillers
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    start_busy_loop "filler_$i" $TARGET_CPU 0 "/tmp/cfs_test_pid_filler_$i"
    echo "$(cat /tmp/cfs_test_pid_filler_$i)" > "$TEST_GROUP/child_$i/cgroup.procs"
done

sleep 2   # 等待 PELT 稳定

# ========== 步骤3: 验证 cgroup 归属 ==========
echo ""
echo "[步骤3] 验证 cgroup 归属..."
echo "  taskA  (PID=$TASKA_PID): $(cat /proc/$TASKA_PID/cgroup)"
echo "  taskC  (PID=$TASKC_PID): $(cat /proc/$TASKC_PID/cgroup)"
echo "  taskB  (PID=$TASKB_PID): $(cat /proc/$TASKB_PID/cgroup)"
for i in 1 3 10; do
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    echo "  filler_$i (PID=$FPID): $(cat /proc/$FPID/cgroup)"
done

# ========== 步骤4: 捕获 sched_debug - 关键诊断数据 ==========
echo ""
echo "[步骤4] 捕获 sched_debug 诊断数据..."

capture_sched_debug() {
    local tag=$1
    local outfile="$DIAG_DIR/sched_debug_${tag}.txt"

    # 完整的 sched_debug 输出
    if [ -f /sys/kernel/debug/sched/debug ]; then
        cat /sys/kernel/debug/sched/debug > "$outfile" 2>/dev/null
    elif [ -f /proc/sched_debug ]; then
        cat /proc/sched_debug > "$outfile" 2>/dev/null
    else
        echo "警告：无法读取 sched_debug" > "$outfile"
        return
    fi

    # 提取关键信息
    local summary="$DIAG_DIR/summary_${tag}.txt"
    {
        echo "=== CPU $TARGET_CPU 上的 root cfs_rq ==="
        # 提取 root cfs_rq 的完整段落
        awk "/cfs_rq\[$TARGET_CPU\]:\/$/{found=1} found{print} found && /^$/{exit}" "$outfile"
        echo ""
        echo "=== CPU $TARGET_CPU 上 test_cgroupA 的 cfs_rq ==="
        awk "/cfs_rq\[$TARGET_CPU\]:\/test_cgroupA$/{found=1} found{print} found && /^$/{exit}" "$outfile"
        echo ""
        echo "=== CPU $TARGET_CPU 上所有 cfs_rq 的 se->load.weight ==="
        grep -B2 'se->load.weight' "$outfile" | grep -A1 "cfs_rq\[$TARGET_CPU\]" || echo "(无匹配)"
        echo ""
        echo "=== CPU $TARGET_CPU 上所有 cfs_rq 路径及其 load ==="
        grep -A3 "cfs_rq\[$TARGET_CPU\]:" "$outfile" | grep -E "cfs_rq\[|\.load\s" || echo "(无匹配)"
    } > "$summary" 2>/dev/null
}

capture_sched_debug "initial"
echo "  已捕获初始 sched_debug"

# ========== 步骤5: 捕获 /proc/PID/sched 数据 ==========
echo ""
echo "[步骤5] 捕获各进程的 /proc/PID/sched..."
{
    echo "=== taskA (PID=$TASKA_PID) ==="
    cat /proc/$TASKA_PID/sched 2>/dev/null | head -30
    echo ""
    echo "=== taskC (PID=$TASKC_PID) ==="
    cat /proc/$TASKC_PID/sched 2>/dev/null | head -30
    echo ""
    echo "=== taskB (PID=$TASKB_PID) ==="
    cat /proc/$TASKB_PID/sched 2>/dev/null | head -30
    echo ""
    FPID1=$(cat /tmp/cfs_test_pid_filler_1)
    echo "=== filler_1 (PID=$FPID1) ==="
    cat /proc/$FPID1/sched 2>/dev/null | head -30
} > "$DIAG_DIR/proc_sched.txt" 2>&1

# 打印关键权重信息
echo "  各 task 的 se.load.weight:"
echo "    taskA:    $(grep 'se.load.weight' /proc/$TASKA_PID/sched 2>/dev/null | awk '{print $NF}')"
echo "    taskC:    $(grep 'se.load.weight' /proc/$TASKC_PID/sched 2>/dev/null | awk '{print $NF}')"
echo "    taskB:    $(grep 'se.load.weight' /proc/$TASKB_PID/sched 2>/dev/null | awk '{print $NF}')"
echo "    filler_1: $(grep 'se.load.weight' /proc/$FPID1/sched 2>/dev/null | awk '{print $NF}')"

# ========== 步骤6: 查看 root cfs_rq 的所有实体 ==========
echo ""
echo "[步骤6] 分析 root cfs_rq 上的竞争实体..."
{
    echo "=== root cfs_rq 上的所有 cgroup 及其 group entity 权重 ==="
    echo ""

    SCHED_DEBUG=""
    if [ -f /sys/kernel/debug/sched/debug ]; then
        SCHED_DEBUG="/sys/kernel/debug/sched/debug"
    elif [ -f /proc/sched_debug ]; then
        SCHED_DEBUG="/proc/sched_debug"
    fi

    if [ -n "$SCHED_DEBUG" ]; then
        echo "所有 CPU $TARGET_CPU 上的 cfs_rq:"
        grep "cfs_rq\[$TARGET_CPU\]:" "$SCHED_DEBUG" 2>/dev/null
        echo ""
        echo "注意：每个 cfs_rq[0]:/xxx 代表 root cfs_rq 上有一个 xxx 的 group entity"
        echo "      如果存在 system.slice、user.slice 等，说明还有其他 group entity 参与竞争"
    fi
} > "$DIAG_DIR/root_entities.txt" 2>&1

# 也打印到终端
echo "  root cfs_rq 上的 cfs_rq 路径（每个代表一个 group entity）:"
SCHED_DEBUG=""
if [ -f /sys/kernel/debug/sched/debug ]; then
    SCHED_DEBUG="/sys/kernel/debug/sched/debug"
elif [ -f /proc/sched_debug ]; then
    SCHED_DEBUG="/proc/sched_debug"
fi
if [ -n "$SCHED_DEBUG" ]; then
    grep "cfs_rq\[$TARGET_CPU\]:" "$SCHED_DEBUG" 2>/dev/null | while read line; do
        echo "    $line"
    done
fi

# ========== 步骤7: 查看 systemd cgroup 在 CPU0 上的活动 ==========
echo ""
echo "[步骤7] 检查 systemd cgroup 在 CPU $TARGET_CPU 上的状态..."
{
    echo "=== 所有 cgroup 在 CPU $TARGET_CPU 上的 nr_queued 和 h_nr_runnable ==="
    if [ -n "$SCHED_DEBUG" ]; then
        awk -v cpu=$TARGET_CPU '
        /cfs_rq\['"$TARGET_CPU"'\]:/{path=$0}
        /\.nr_queued/{nr=$NF}
        /\.h_nr_runnable/{hnr=$NF; if(nr+0>0 || hnr+0>0) print path, "nr_queued="nr, "h_nr_runnable="hnr}
        ' "$SCHED_DEBUG" 2>/dev/null
    fi
} > "$DIAG_DIR/cgroup_activity.txt" 2>&1
cat "$DIAG_DIR/cgroup_activity.txt"

# ========== 步骤8: 采集 CPU 时间数据 ==========
echo ""
echo "[步骤8] 运行 ${RUNTIME}s 采集数据..."

get_utime() { awk '{print $14}' /proc/$1/stat 2>/dev/null || echo 0; }

# 采集起始 ticks
TASKA_S=$(get_utime $TASKA_PID)
TASKC_S=$(get_utime $TASKC_PID)
TASKB_S=$(get_utime $TASKB_PID)
declare -A FILLER_S
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FPID=$(cat "/tmp/cfs_test_pid_filler_$i")
    FILLER_S[$i]=$(get_utime $FPID)
done

# 周期性采集 sched_debug
SAMPLE=0
ELAPSED=0
while [ "$ELAPSED" -lt "$RUNTIME" ]; do
    sleep_time=$SAMPLE_INTERVAL
    if [ $((ELAPSED + sleep_time)) -gt "$RUNTIME" ]; then
        sleep_time=$((RUNTIME - ELAPSED))
    fi
    sleep "$sleep_time"
    ELAPSED=$((ELAPSED + sleep_time))
    SAMPLE=$((SAMPLE + 1))
    capture_sched_debug "sample_${SAMPLE}_${ELAPSED}s"
    echo "  [${ELAPSED}s] 已采样 sched_debug #$SAMPLE"
done

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

# ========== 步骤9: 输出结果 ==========
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
echo " 关键分析数据（从 sched_debug 提取）"
echo "============================================="
echo ""

# 从最后一次 sched_debug 采样中提取 group entity 权重
LAST_SAMPLE="$DIAG_DIR/sched_debug_sample_${SAMPLE}_${ELAPSED}s.txt"
if [ -f "$LAST_SAMPLE" ]; then
    echo "  [A] root cfs_rq (CPU $TARGET_CPU) 的 load.weight:"
    awk "/cfs_rq\[$TARGET_CPU\]:\/$/{found=1} found && /\.load\s/{print \"     \", \$0; found=0}" "$LAST_SAMPLE"
    echo ""
    echo "  [B] root cfs_rq 上的 nr_queued:"
    awk "/cfs_rq\[$TARGET_CPU\]:\/$/{found=1} found && /nr_queued/{print \"     \", \$0; found=0}" "$LAST_SAMPLE"
    echo ""
    echo "  [C] test_cgroupA 的 group entity 权重 (se->load.weight):"
    awk "/cfs_rq\[$TARGET_CPU\]:\/test_cgroupA$/{found=1} found && /se->load.weight/{print \"     \", \$0; found=0}" "$LAST_SAMPLE"
    echo ""
    echo "  [D] 所有 CPU $TARGET_CPU 上有活动的 cfs_rq:"
    awk -v cpu=$TARGET_CPU '
    /cfs_rq\['"$TARGET_CPU"'\]:/{path=$0; next}
    /\.nr_queued/{nr=$NF; next}
    /se->load.weight/{
        weight=$NF
        if(nr+0 > 0) printf "      %-50s nr_queued=%-3s se->load.weight=%s\n", path, nr, weight
    }
    ' "$LAST_SAMPLE" 2>/dev/null
    echo ""
    echo "  [E] test_cgroupA cfs_rq 的详细信息:"
    awk "/cfs_rq\[$TARGET_CPU\]:\/test_cgroupA$/{found=1} found{print \"     \", \$0} found && /se->avg.runnable_avg/{found=0}" "$LAST_SAMPLE"
    echo ""
    echo "  [F] root cfs_rq 的详细信息:"
    awk "/cfs_rq\[$TARGET_CPU\]:\/$/{found=1} found{print \"     \", \$0} found && /^$/{found=0}" "$LAST_SAMPLE" | head -30
fi

echo ""
echo "============================================="
echo " 诊断要点"
echo "============================================="
echo ""
echo "  1. 检查 [C]: test_cgroupA 的 se->load.weight 是否 = 1048576"
echo "     如果不等，说明 calc_group_shares() 返回了非预期值"
echo ""
echo "  2. 检查 [D]: root cfs_rq 上是否有 3 个以上的活跃 group entity"
echo "     如果有 system.slice/user.slice 等，说明有额外竞争者"
echo ""
echo "  3. 检查 [B]: root cfs_rq 的 nr_queued 是否 = 3"
echo "     如果 > 3，说明有其他实体参与调度"
echo ""
echo "  4. 如果 weight 正确且只有 3 个实体，说明问题出在 EEVDF 的行为上"
echo ""
echo "  完整诊断数据目录: $DIAG_DIR"
echo "  请将 $DIAG_DIR/summary_sample_*_*.txt 的内容发给我分析"
echo ""

# ========== 清理 ==========
cleanup
echo "诊断完成。"
