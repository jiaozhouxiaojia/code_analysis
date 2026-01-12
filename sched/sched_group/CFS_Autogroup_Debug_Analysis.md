# CFS Autogroup 与组调度交互机制深度分析

## 一、问题描述

在验证 CFS 组调度层级稀释效应时，构造了如下场景：

```
/ (root cgroup)
├── taskA ← nice=0, weight=1024
├── taskC ← nice=0, weight=1024
│
└── test_cgroupA/ ── cpu.weight=100 (默认)
    ├── child_1/  filler_1 (nice=0)
    ├── child_2/  taskB (nice=-19)
    ├── child_3/  filler_3 (nice=0)
    ├── ...
    └── child_10/ filler_10 (nice=0)
```

所有任务绑定到 CPU 0。

**预期结果**：taskA、taskC、test_cgroupA 在 root cfs_rq 上各占 ~33.3%（1:1:1）。

**实际结果**：taskA ≈ 25%，taskC ≈ 25%，test_cgroupA 合计 ≈ 50%（1:1:2）。

## 二、理论分析：为什么预期是 1:1:1

### 权重链路

- **task entity**：nice=0 → `sched_prio_to_weight[20] = 1024` → `scale_load(1024) = 1048576`
- **group entity**：`cpu.weight=100` → `sched_weight_from_cgroup(100) = 1024` → `scale_load(1024) = 1048576` → `tg->shares = 1048576`

二者在内核中的权重完全相同。

### `calc_group_shares()` 在单 CPU 场景下的行为

`kernel/sched/fair.c:3920-3952`：

```c
static long calc_group_shares(struct cfs_rq *cfs_rq)
{
    long tg_weight, tg_shares, load, shares;
    struct task_group *tg = cfs_rq->tg;

    tg_shares = READ_ONCE(tg->shares);                    // 1048576
    load = max(scale_load_down(cfs_rq->load.weight),
               cfs_rq->avg.load_avg);                      // 本 CPU 负载
    tg_weight = atomic_long_read(&tg->load_avg);
    tg_weight -= cfs_rq->tg_load_avg_contrib;
    tg_weight += load;                                      // 单 CPU: tg_weight ≈ load

    shares = (tg_shares * load);
    if (tg_weight)
        shares /= tg_weight;                               // ≈ tg_shares

    return clamp_t(long, shares, MIN_SHARES, tg_shares);   // 上限 tg_shares
}
```

当所有任务绑定同一 CPU 时，`tg->load_avg ≈ tg_load_avg_contrib`，因此：

```
tg_weight = 0 + load = load
shares = tg_shares × load / load = tg_shares = 1048576
```

group entity 权重 = task entity 权重 = 1048576。EEVDF 调度算法对两者一视同仁，理论上应该 1:1:1。

### EEVDF 调度器对 group entity 和 task entity 无差别对待

- `__pick_eevdf()`：选择最早 eligible deadline 的实体，不区分类型
- `entity_eligible()` / `avg_vruntime()`：使用统一的加权平均 vruntime 计算
- `update_deadline()`：vslice = `calc_delta_fair(slice, se)`，同权重同 slice 则 vslice 相同
- `update_curr()`：vruntime 增长率 = `delta_exec × NICE_0_LOAD / weight`，同权重则相同

代码分析无法解释 1:1:2，说明问题出在代码之外——**调度层级结构与预期不符**。

## 三、诊断过程

### 诊断脚本设计

编写 `cfs_group_sched_diag.sh` 脚本，在测试运行期间周期性捕获以下关键数据：

1. `/sys/kernel/debug/sched/debug` — 全量 sched_debug 输出
2. 从 sched_debug 提取每个 cfs_rq 的 `nr_queued`、`load`、`se->load.weight`
3. `/proc/PID/sched` — 每个测试进程的调度实体信息
4. 系统环境：内核版本、`CONFIG_HZ`、`CONFIG_SCHED_AUTOGROUP` 等配置
5. root cgroup 下所有子 cgroup 目录列表

### 关键发现

#### 发现一：root cfs_rq 上只有 2 个实体

```
cfs_rq[0]:/
  .nr_queued         : 2          ← 预期 3，实际只有 2！
  .h_nr_runnable     : 12         ← 层级总数正确（2 + 10）
  .load              : 2097152    ← = 2 × 1048576
```

root cfs_rq 上只有 **2 个** `sched_entity`，而非预期的 3 个（taskA、taskC、test_cgroupA）。

#### 发现二：taskA 和 taskC 被包裹在 autogroup 中

CPU 0 上的所有 cfs_rq 路径：

```
cfs_rq[0]:/test_cgroupA/child_1
cfs_rq[0]:/test_cgroupA/child_2
...
cfs_rq[0]:/test_cgroupA/child_10
cfs_rq[0]:/test_cgroupA
cfs_rq[0]:/autogroup-2961          ← 意外出现的 autogroup！
cfs_rq[0]:/
```

autogroup-2961 的 cfs_rq 数据：

```
cfs_rq[0]:/autogroup-2961
  .nr_queued         : 2           ← taskA 和 taskC 在这里面！
  .h_nr_runnable     : 2
  .load              : 2097152     ← = 2 × 1048576
  .se->load.weight   : 1048576    ← autogroup 的 group entity 权重
  .se->sum_exec_runtime : 1132493.532912  ← 约占 50% 的运行时间
```

#### 发现三：内核启用了 `CONFIG_SCHED_AUTOGROUP`

```
CONFIG_SCHED_AUTOGROUP=y
```

### sched_debug 数据验证

| 实体 | `se->load.weight` | `se->sum_exec_runtime` | 占比 |
|------|-------------------|----------------------|------|
| `/autogroup-2961` group entity | 1048576 | 1132493ms | ~50% |
| `/test_cgroupA` group entity | 1048576 | 16305ms | ~50% |
| taskA（autogroup 内部） | 1048576 | 561ms | ~25% |
| taskC（autogroup 内部） | 1048576 | 560ms | ~25% |

两个 group entity 的权重完全相同（1048576），EEVDF 对它们等量分配，这与 50:50 的结果完全吻合。

## 四、根本原因：`CONFIG_SCHED_AUTOGROUP`

### autogroup 机制概述

`CONFIG_SCHED_AUTOGROUP`（内核文档：`Documentation/admin-guide/cgroup-v1/cgroups.rst`）会自动为每个 TTY 会话创建一个独立的 `task_group`。其目的是改善桌面环境中的交互性——当一个终端在编译代码时，不会影响另一个终端的响应速度。

关键代码（`kernel/sched/autogroup.c`）：

- 每个 `signal_struct` 关联一个 `autogroup`
- `autogroup` 包含一个 `task_group`，永远以 `root_task_group` 为父级（`autogroup_create()` 中硬编码 `sched_create_group(&root_task_group)`），因此其 group entity 直接出现在 root cfs_rq 上，与顶级 cgroup（如 `test_cgroupA`）平级竞争
- 子进程继承父进程的 autogroup
- 当进程被移入 root cgroup 时，其有效 cpu task_group 变为 `root_task_group`，满足 autogroup 生效条件，`sched_task_group` 被覆盖为 autogroup 的 tg

测试脚本将 taskA/taskC 从 user.slice 移入 root cgroup（`echo PID > /sys/fs/cgroup/cgroup.procs`），**触发 autogroup 覆盖，taskA/taskC 被包裹在同一个 autogroup 的 `group entity` 中**。root cfs_rq 上只剩 2 个实体（autogroup group entity + test_cgroupA group entity），权重 1:1，导致 1:1:2。详见 5.5 autogroup 的覆盖逻辑

### 核心概念：autogroup "分配" vs autogroup "生效"

每个进程有两个相关但独立的字段：

| 字段 | 含义 | 何时设置 |
|------|------|----------|
| `task->signal->autogroup` | autogroup **分配**（`/proc/PID/autogroup` 显示的） | fork 时继承，永远存在 |
| `task->sched_task_group` | **实际**调度所在的 task_group | `sched_change_group()` 动态决定 |

`/proc/PID/autogroup` 显示 `/autogroup-XXXX`，同时 `/proc/PID/cgroup` 显示 `/user.slice/...`——这**不矛盾**。前者只是分配，后者才决定是否生效。

详细对比：

| | autogroup "分配" | autogroup "生效" |
|---|---|---|
| **内核数据结构** | `task->signal->autogroup` | `task->sched_task_group` |
| **含义** | 进程**关联了**哪个 autogroup（潜在的，可能不活跃） | 进程**实际被调度**在哪个 task_group |
| **设置时机** | `setsid()` 创建新 autogroup；`fork()` 时无条件继承 | `sched_change_group()` 在 fork 或 cgroup 迁移时动态决定 |
| **查看方式** | `cat /proc/PID/autogroup` | `sched_debug` 中的 `cfs_rq[N]:/autogroup-XXX` 路径 |
| **是否总是存在** | 是——几乎所有进程都有 autogroup 分配 | 否——只有满足特定条件时才生效 |

**生效条件**：autogroup 的分配要转化为实际的调度行为，必须同时满足：

1. `sysctl_sched_autogroup_enabled == 1`（默认值）
2. 进程的有效 cpu task_group 等于 `&root_task_group`（即进程在 cgroup v2 的 root cgroup 中，或其 cgroup 祖先链上没有启用 cpu 控制器）

**典型场景对比**：

```
场景 A：进程在 /user.slice/user-0.slice/session-XXX.scope

  /proc/PID/autogroup  → /autogroup-3684 nice 0     ← 有分配
  /proc/PID/cgroup     → 0::/user.slice/...
  有效 cpu tg          → user.slice 的 task_group    ← ≠ root_task_group
  task_wants_autogroup → false
  sched_task_group     → user.slice 的 tg            ← autogroup 未生效
  sched_debug          → cfs_rq[N]:/user.slice       ← 没有 autogroup 路径


场景 B：进程被移入 root cgroup (echo PID > /sys/fs/cgroup/cgroup.procs)

  /proc/PID/autogroup  → /autogroup-3684 nice 0     ← 分配不变
  /proc/PID/cgroup     → 0::/
  有效 cpu tg          → &root_task_group            ← == root_task_group
  task_wants_autogroup → true
  sched_task_group     → autogroup-3684 的 tg        ← autogroup 生效！
  sched_debug          → cfs_rq[N]:/autogroup-3684   ← 出现 autogroup 路径
```

这个区分是本次 1:1:2 问题的关键：测试脚本将 taskA/taskC 从 `user.slice` 移入 root cgroup，无意中触发了 autogroup 从"分配"变为"生效"，导致它们被 autogroup 的 group entity 包裹。

### 实际的调度层级

```
root cfs_rq (CPU 0)
│
├── /autogroup-2961 group entity ──── weight=1048576 ── 50% CPU
│   ├── taskA (nice=0, weight=1048576) ─────── 25% CPU
│   └── taskC (nice=0, weight=1048576) ─────── 25% CPU
│
└── /test_cgroupA group entity ─────── weight=1048576 ── 50% CPU
    ├── child_1/filler_1 ──────────────────── 5% CPU
    ├── child_2/taskB ─────────────────────── 5% CPU
    ├── child_3/filler_3 ──────────────────── 5% CPU
    └── ... (共 10 个 child)
```

两个 group entity 权重 1:1，调度器分配 **50:50**。autogroup 内部 taskA 和 taskC 再均分，各得 **25%**。这就是观察到的 25:25:50 = 1:1:2。

## 五、代码级分析

### 5.1 autogroup 的创建与继承

#### 创建：`setsid()` 触发

当进程调用 `setsid()` 成为新会话的 leader 时，创建新 autogroup。

`kernel/sys.c:1296-1298`：

```c
// ksys_setsid() 成功后：
if (err > 0) {
    proc_sid_connector(group_leader);
    sched_autogroup_create_attach(group_leader);  // ← 创建并关联新 autogroup
}
```

`kernel/sched/autogroup.c:195-203`：

```c
void sched_autogroup_create_attach(struct task_struct *p)
{
    struct autogroup *ag = autogroup_create();    // 创建新 autogroup
    autogroup_move_group(p, ag);                   // 关联到进程
    autogroup_kref_put(ag);
}
```

`autogroup_create()` (`kernel/sched/autogroup.c:87-118`) 的关键：

```c
static inline struct autogroup *autogroup_create(void)
{
    struct autogroup *ag = kzalloc_obj(*ag);
    struct task_group *tg;

    tg = sched_create_group(&root_task_group);     // ← 父级固定为 root_task_group
    // ...
    ag->tg = tg;
    tg->autogroup = ag;
    sched_online_group(tg, &root_task_group);      // ← 在调度层级中挂到 root 下
    return ag;
}
```

每个 autogroup 的 task_group **永远**以 `root_task_group` 为父级。这意味着如果 autogroup 生效，其 group entity 出现在 root cfs_rq 上，与 cgroup 创建的 group entity（如 `test_cgroupA`）平级竞争。

#### 为什么 autogroup 的父级永远是 `root_task_group`

这涉及两个调用：

**`sched_create_group(&root_task_group)`** 负责分配资源。它调用 `alloc_fair_sched_group(tg, parent)`（`fair.c:13619`），其中关键在 `init_tg_cfs_entry()`（`fair.c:13712`）：

```c
void init_tg_cfs_entry(tg, cfs_rq, se, cpu, parent_se) {
    if (!parent_se) {
        se->cfs_rq = &rq->cfs;     // 挂到 root cfs_rq
        se->depth = 0;
    } else {
        se->cfs_rq = parent_se->my_q;  // 挂到父级的 cfs_rq
        se->depth = parent_se->depth + 1;
    }
    se->parent = parent_se;
}
```

因为 parent 是 `root_task_group`，而 `root_task_group.se[cpu] == NULL`（root 没有 sched_entity），所以 `parent_se == NULL`，于是：

- **`se->cfs_rq = &rq->cfs`** — autogroup 的 group entity 直接挂在每个 CPU 的根 cfs_rq 上
- **`se->depth = 0`** — 深度为 0，与 root 的直接子 cgroup（如 user.slice）同级

**`sched_online_group(tg, &root_task_group)`** 负责建立层级关系（`core.c:9082-9098`）：

```c
void sched_online_group(struct task_group *tg, struct task_group *parent) {
    tg->parent = parent;                                       // parent = &root_task_group
    INIT_LIST_HEAD(&tg->children);
    list_add_rcu(&tg->siblings, &parent->children);            // 挂到 root 的 children 链表
}
```

所以**每个 autogroup 在调度树中都是 root_task_group 的直接子节点**，与 `user.slice`、`system.slice` 等顶级 cgroup 平级。

**对比 cgroup 创建 task_group 的路径**（`core.c:9192-9222`）：

```c
// cpu_cgroup_css_alloc(): cgroup 创建时
tg = sched_create_group(parent);        // parent 是父 cgroup 的 task_group，可以是任意层级

// cpu_cgroup_css_online(): cgroup 上线时
sched_online_group(tg, parent);         // 同样使用父 cgroup 的 task_group
```

cgroup 的 task_group 父级**跟随 cgroup 层级**（user.slice → user-0.slice → session-XXX.scope），而 autogroup 的父级**永远是 root**。

**设计意图**：autogroup 的目标是按 TTY 会话隔离交互任务，让同一终端的进程共享一个调度组，不同终端之间在 root 级别公平竞争。如果 autogroup 的父级跟随进程的 cgroup（如 `user.slice`），其调度权重会被上层 cgroup 的 `cpu.weight` 层层稀释，违背了 autogroup 的初衷——**绕过 cgroup 层级，直接在 root 级别竞争**。

#### autogroup 任务的默认 `sched_task_group` 不是 `root_task_group`

进程的 `sched_task_group` **不是**默认就指向 `root_task_group`。它由 `sched_change_group()` / `sched_cgroup_fork()` 动态决定（详见 5.3 节）：

1. 先根据进程所在 cgroup 通过 `task_css_check()` / `cgroup_e_css_by_mask()` 解析出对应的 `task_group`
2. **只有当这个 tg 恰好是 `&root_task_group` 时**，`task_wants_autogroup()` 才返回 true，用 autogroup 的 tg 覆盖
3. 如果进程在 `user.slice` 中，解析出的 tg 是 `user.slice` 的 task_group（≠ `root_task_group`），autogroup **不会生效**，`sched_task_group` 就是 `user.slice` 的 tg

#### 继承：`fork()` 无条件传递

`kernel/sched/autogroup.c:213-216`：

```c
void sched_autogroup_fork(struct signal_struct *sig)
{
    sig->autogroup = autogroup_task_get(current);  // 继承父进程的 autogroup
}
```

这个继承**不检查**任何条件——不管子进程将来在哪个 cgroup，它都会拿到父进程的 autogroup。这就是为什么 `/proc/PID/autogroup` 几乎所有进程都有值。

### 5.2 `/proc/PID/autogroup` 的显示逻辑

`kernel/sched/autogroup.c:271-284`：

```c
void proc_sched_autogroup_show_task(struct task_struct *p, struct seq_file *m)
{
    struct autogroup *ag = autogroup_task_get(p);  // ← 读取 signal->autogroup

    if (!task_group_is_autogroup(ag->tg))          // 只有 autogroup_default 不显示
        goto out;

    down_read(&ag->lock);
    seq_printf(m, "/autogroup-%ld nice %d\n", ag->id, ag->nice);
    up_read(&ag->lock);

out:
    autogroup_kref_put(ag);
}
```

`autogroup_task_get()` (`kernel/sched/autogroup.c:73-85`)：

```c
static inline struct autogroup *autogroup_task_get(struct task_struct *p)
{
    // ...
    ag = autogroup_kref_get(p->signal->autogroup);  // ← 读取 signal->autogroup
    // ...
    return ag;
}
```

关键：这里读取的是 `p->signal->autogroup`——fork 时继承的分配，**不是** `p->sched_task_group`（实际调度组）。所以 `/proc/PID/autogroup` 显示的只是"这个进程被分配了哪个 autogroup"，而不是"这个进程当前是否在 autogroup 中被调度"。

### 5.3 `sched_change_group()`：调度器的决策入口

进程实际被调度在哪个 task_group，由 `sched_change_group()` 在两个时机决定：

**时机 1：fork 时** (`kernel/sched/core.c:4697-4714`)

```c
int sched_cgroup_fork(struct task_struct *p, struct kernel_clone_args *kargs)
{
    // ...
    struct task_group *tg;
    tg = container_of(kargs->cset->subsys[cpu_cgrp_id],
                      struct task_group, css);       // ① 从 css_set 获取 cpu tg
    tg = autogroup_task_group(p, tg);                // ② autogroup 检查
    p->sched_task_group = tg;                        // ③ 设置实际调度组
    // ...
}
```

**时机 2：cgroup 迁移时** (`kernel/sched/core.c:9136-9156`)

```c
static void sched_change_group(struct task_struct *tsk)
{
    struct task_group *tg;
    tg = container_of(task_css_check(tsk, cpu_cgrp_id, true),
                      struct task_group, css);       // ① 从 css_set 获取 cpu tg
    tg = autogroup_task_group(tsk, tg);              // ② autogroup 检查
    tsk->sched_task_group = tg;                      // ③ 设置实际调度组
    // ...
}
```

两个时机的逻辑完全相同：先从 cgroup 获取 task_group，再检查 autogroup 是否覆盖。

### 5.4 `cgroup.procs` 写入的完整调用链

当执行 `echo $PID > /sys/fs/cgroup/cgroup.procs` 时，内核经历以下调用链：

```
用户态 write()
  ↓
kernfs 层调用 cgroup_procs_write()            [kernel/cgroup/cgroup.c:5403]
  ↓
__cgroup_procs_write()                         [kernel/cgroup/cgroup.c:5358]
  ├── cgroup_procs_write_start()  → 解析 PID，获取 task_struct
  ├── 权限检查
  └── cgroup_attach_task()                     [kernel/cgroup/cgroup.c:3011]
      ├── cgroup_migrate_add_src()  → 记录源 css_set
      ├── cgroup_migrate_prepare_dst()  → 创建目标 css_set
      └── cgroup_migrate()                     [kernel/cgroup/cgroup.c:2988]
          └── cgroup_migrate_execute()         [kernel/cgroup/cgroup.c:2691]
              │
              ├── Phase 2: css_set_move_task()  → 更新 task->cgroups
              │   └── rcu_assign_pointer(task->cgroups, to)  ← cgroup 层面迁移完成
              │
              └── Phase 3: cpu_cgroup_attach()  → 通知调度器
                  └── sched_move_task(task, false)  [kernel/sched/core.c:9165]
                      └── sched_change_group(tsk)   [kernel/sched/core.c:9136]
```

注意：cgroup 迁移更新了 `task->cgroups`（cgroup 层面的关联），但**完全不触碰** `task->signal->autogroup`（autogroup 分配）。这两个是独立的数据结构，由不同的代码路径管理。

### 5.5 autogroup 的覆盖逻辑

`kernel/sched/autogroup.h:32-42`：

```c
static inline struct task_group *
autogroup_task_group(struct task_struct *p, struct task_group *tg)
{
    extern unsigned int sysctl_sched_autogroup_enabled;
    int enabled = READ_ONCE(sysctl_sched_autogroup_enabled);

    if (enabled && task_wants_autogroup(p, tg))
        return p->signal->autogroup->tg;   // ← 返回 autogroup 的 task_group
    return tg;                               // ← 返回 cgroup 的 task_group
}
```

覆盖发生需要满足两个条件：

**条件 1**：`sysctl_sched_autogroup_enabled == 1`（默认值，`autogroup.c:10`）

**条件 2**：`task_wants_autogroup()` 返回 `true`

`kernel/sched/autogroup.c:131-147`：

```c
bool task_wants_autogroup(struct task_struct *p, struct task_group *tg)
{
    if (tg != &root_task_group)    // ← 只对有效 cpu tg 为 root 的进程生效！
        return false;
    if (p->flags & PF_EXITING)
        return false;
    return true;
}
```

**设计意图**：autogroup 只作用于"无家可归"的进程——那些有效 cpu task_group 为 `root_task_group` 的进程。一旦进程被放入了非 root 的 cgroup（导致有效 cpu tg 不为 root），说明管理员有明确的资源分配意图，autogroup 不应该干预。

#### autogroup 覆盖 `sched_task_group` 的完整条件

autogroup 覆盖需要**同时满足三个条件**：

1. **`sysctl_sched_autogroup_enabled == 1`**（默认值，`autogroup.c:10`）
2. **进程的有效 cpu task_group == `&root_task_group`**（`task_wants_autogroup()` 的核心判断）
3. **进程没有 `PF_EXITING` 标志**（避免访问已释放的 autogroup）

条件 2 是关键。有效 cpu tg 为 `root_task_group` 的情况：

| 场景 | 原因 | 示例 |
|------|------|------|
| 进程被显式移入 root cgroup | `task_css_check()` 直接返回 `root_task_group` | `echo $PID > /sys/fs/cgroup/cgroup.procs`（**本次 1:1:2 的触发场景**） |
| root 的 `subtree_control` 没有启用 cpu | 所有 cgroup 都没有独立的 cpu css，`cgroup_e_css_by_mask()` 回退到 root | autogroup 最初的设计目标场景——没有 cpu cgroup 时按会话分组 |
| 进程的 cgroup 祖先链上无任何一级启用 cpu | 上一种情况的泛化 | 某些自定义 cgroup 配置 |

**反之，autogroup 不会覆盖的情况**：

- 进程在 `user.slice`、`system.slice` 等非 root cgroup 中，且 root 的 `subtree_control` 包含 cpu → 有效 tg ≠ `root_task_group`
- `sched_autogroup_enabled=0` → 功能被全局禁用
- 进程正在退出（`PF_EXITING`）

#### 应用到测试场景：移入 root cgroup

```
echo $TASKA_PID > /sys/fs/cgroup/cgroup.procs

sched_change_group():
  ① task_css_check() → tg = &root_task_group    ← 因为现在在 root cgroup
  ② autogroup_task_group(tsk, tg):
       task_wants_autogroup(): tg == &root_task_group → true
       返回 p->signal->autogroup->tg              ← autogroup 覆盖！
  ③ tsk->sched_task_group = autogroup-2961 的 tg
```

#### 应用到测试场景：移入 test_cgroupA/child_2

```
echo $TASKB_PID > /sys/fs/cgroup/test_cgroupA/child_2/cgroup.procs

sched_change_group():
  ① task_css_check() → tg = child_2 的 task_group  ← 不是 root_task_group
  ② autogroup_task_group(tsk, tg):
       task_wants_autogroup(): tg != &root_task_group → false
       返回 tg（child_2 的 task_group）              ← autogroup 不覆盖
  ③ tsk->sched_task_group = child_2 的 tg
```

### 5.6 `task_css_check()` 与 `subtree_control`：理解有效 cpu css 的解析

上一节中 `task_css_check()` 返回的 task_group 取决于进程所在 cgroup 的**有效 cpu css**。这个"有效"是通过 `cgroup_e_css_by_mask()` 向上查找最近启用了 cpu 控制器的祖先 cgroup 来确定的。

`task_css_check()` (`include/linux/cgroup.h:436`)：

```c
#define task_css_check(task, subsys_id, __c)            \
    task_css_set_check((task), (__c))->subsys[(subsys_id)]
```

css_set 中的 css 通过 `find_existing_css_set()` 计算 (`kernel/cgroup/cgroup.c:1101-1130`)：

```c
static struct css_set *find_existing_css_set(...)
{
    for_each_subsys(ss, i) {
        if (root->subsys_mask & (1UL << i)) {
            template[i] = cgroup_e_css_by_mask(cgrp, ss);  // ← 获取有效 css
        } else {
            template[i] = old_cset->subsys[i];
        }
    }
}
```

`cgroup_e_css_by_mask()` (`kernel/cgroup/cgroup.c:543-562`)——**向上查找最近启用了该控制器的祖先**：

```c
static struct cgroup_subsys_state *cgroup_e_css_by_mask(struct cgroup *cgrp,
                            struct cgroup_subsys *ss)
{
    while (!(cgroup_ss_mask(cgrp) & (1 << ss->id))) {
        cgrp = cgroup_parent(cgrp);            // ← 向上找
        if (!cgrp)
            return NULL;
    }
    return cgroup_css(cgrp, ss);               // 返回该 cgroup 的 css
}
```

`cgroup_ss_mask()` (`kernel/cgroup/cgroup.c:496-510`)——一个 cgroup 启用了哪些控制器，取决于其**父 cgroup** 的 `subtree_ss_mask`：

```c
static u32 cgroup_ss_mask(struct cgroup *cgrp)
{
    struct cgroup *parent = cgroup_parent(cgrp);
    if (parent)
        return parent->subtree_ss_mask;        // ← 看父 cgroup 的 subtree_ss_mask
    return cgrp->root->subsys_mask;            // root cgroup 走特殊路径
}
```

#### 应用到实际系统

采集到的系统 `subtree_control` 数据：

```
/sys/fs/cgroup/cgroup.subtree_control:                     cpuset cpu io memory pids
/sys/fs/cgroup/user.slice/cgroup.subtree_control:          memory pids
/sys/fs/cgroup/user.slice/user-0.slice/cgroup.subtree_control: memory pids
```

对于 shell 进程（在 `/user.slice/user-0.slice/session-2625.scope`），追踪 `cgroup_e_css_by_mask()` 的执行：

```
目标：为 session-2625.scope 查找 cpu 控制器的有效 css

① cgroup_ss_mask(session-2625.scope)
   = parent->subtree_ss_mask = user-0.slice 的 = {memory, pids}   ← 不含 cpu，继续向上

② cgroup_ss_mask(user-0.slice)
   = parent->subtree_ss_mask = user.slice 的 = {memory, pids}     ← 不含 cpu，继续向上

③ cgroup_ss_mask(user.slice)
   = parent->subtree_ss_mask = root 的 = {cpuset, cpu, ...}       ← 含 cpu，停止

④ return cgroup_css(user.slice, cpu) → 返回 user.slice 的 cpu css
```

所以 `task_css_check()` 返回 **user.slice 的 cpu css**，对应的 task_group **不是** `root_task_group`。此时 `task_wants_autogroup()` 返回 false，autogroup 不生效。

这就解释了为什么进程在 `user.slice` 中时，虽然 `/proc/PID/autogroup` 有值，但 autogroup 不影响调度。

对比：移入 root cgroup 后，`cgroup_ss_mask(root_cgroup)` 走特殊路径返回 `cgrp->root->subsys_mask`（含 cpu），直接返回 root 的 css，`tg = &root_task_group`，autogroup 生效。

#### `/proc/PID/cgroup` 与有效 cpu task_group 是两个不同的概念

一个常见的困惑是：`cat /proc/PID/cgroup` 返回 `/user.slice/user-0.slice/session-2617.scope`，为什么说有效 cpu task_group 是 `user.slice` 而不是 `session-2617.scope`？

这是因为 **cgroup 成员关系**和**有效 cpu task_group** 是两个不同的概念：

| | 值 | 含义 |
|---|---|---|
| `/proc/PID/cgroup` | `/user.slice/user-0.slice/session-2617.scope` | 进程**在哪个 cgroup 中**（cgroup 成员关系） |
| 有效 cpu task_group | `user.slice` 的 tg | 进程在调度器中**归属哪个 task_group**（由 `cgroup_e_css_by_mask()` 解析） |

`/proc/PID/cgroup` 显示的是进程在 cgroup 树中的**实际位置**——进程确实在 `session-2617.scope` 中。但调度器需要知道的是该进程归属哪个 cpu task_group，这由 `cgroup_e_css_by_mask()` 向上查找得到。

回顾上面的 `cgroup_e_css_by_mask()` 追踪过程：

```
进程所在 cgroup: /user.slice/user-0.slice/session-2617.scope

① session-2617.scope: 父 cgroup(user-0.slice) 的 subtree_control = {memory, pids}
   → 不含 cpu，继续向上

② user-0.slice: 父 cgroup(user.slice) 的 subtree_control = {memory, pids}
   → 不含 cpu，继续向上

③ user.slice: 父 cgroup(root) 的 subtree_control = {cpuset, cpu, io, memory, pids}
   → 含 cpu，停止！

→ 返回 user.slice 的 cpu css → 对应 user.slice 的 task_group
```

关键在于：root 的 `subtree_control` 含 cpu，所以 root **对其直接子 cgroup**（user.slice、system.slice 等）启用了 cpu 控制器——这些子 cgroup 各自拥有独立的 cpu css 和 task_group。但 `user.slice` 的 `subtree_control` **不含** cpu，所以 user.slice 内部的子 cgroup（user-0.slice、session-2617.scope）**没有**自己的 cpu css，它们的有效 cpu css 全部回退到 `user.slice` 级别。

简单说：**进程住在 session-2617.scope，但调度器只看到 user.slice 这一层**。

#### autogroup 任务的 `sched_task_group` 不一定是 autogroup 的 tg

进程的 `sched_task_group` 不是默认就指向 autogroup 创建的 task_group。它由 `sched_change_group()` / `sched_cgroup_fork()` 在两种场景下动态决定：

**场景 A：进程在 root cgroup 中**（或有效 cpu tg == `&root_task_group`）

```
① tg = task_css_check() → &root_task_group
② task_wants_autogroup(): tg == &root_task_group → true
   → 返回 signal->autogroup->tg
③ sched_task_group = autogroup 的 tg   ✅ 是 autogroup
```

**场景 B：进程在非 root cgroup 中**（如 user.slice，大多数进程的典型场景）

```
① tg = task_css_check() → user.slice 的 task_group
② task_wants_autogroup(): tg != &root_task_group → false
   → 返回 tg（user.slice 的 tg）
③ sched_task_group = user.slice 的 tg   ❌ 不是 autogroup
```

**实际上大多数进程属于场景 B**。因为在 systemd 管理的系统中，shell 进程在 `/user.slice/user-XXXX.slice/session-XXXX.scope` 中，fork 出的子进程继承这个 cgroup。如上节分析，`cgroup_e_css_by_mask()` 向上找到 user.slice 级别就停了（因为 root 对 user.slice 启用了 cpu），返回的 tg 是 user.slice 的 task_group，≠ `root_task_group`，所以 autogroup 不生效。

只有当进程被**显式移入 root cgroup**（`echo PID > /sys/fs/cgroup/cgroup.procs`），或者系统没有在 root 的 `subtree_control` 中启用 cpu 控制器时，`sched_task_group` 才会是 autogroup 的 tg。

### 5.7 `sched_debug` vs `/proc/PID/autogroup`：两种不同的信息来源

**`sched_debug` 中的 cfs_rq 路径** (`kernel/sched/debug.c:911`)：

```c
SEQ_printf_task_group_path(m, cfs_rq->tg, "cfs_rq[%d]:%s\n", cpu);
```

打印的是 `cfs_rq->tg`——task_group **实际拥有**的运行队列。

**`sched_debug` 中进程条目的 task_group 路径** (`debug.c:859`)：

```c
SEQ_printf_task_group_path(m, task_group(p), "        %s")
// task_group(p) 返回 p->sched_task_group — 实际调度组
```

**路径打印逻辑** (`debug.c:800-806`)：

```c
static void task_group_path(struct task_group *tg, char *path, int plen)
{
    if (autogroup_path(tg, path, plen))  // 如果是 autogroup 的 tg，打印 /autogroup-XXX
        return;
    cgroup_path(tg->css.cgroup, path, plen);  // 否则打印 cgroup 路径
}
```

**`/proc/PID/autogroup`** 读取的是 `p->signal->autogroup`（见 5.2 节）。

对比总结：

| 信息来源 | 读取的字段 | 含义 |
|----------|-----------|------|
| `sched_debug` cfs_rq 路径 | `cfs_rq->tg` | task_group **实际拥有**的运行队列 |
| `sched_debug` 进程条目 | `p->sched_task_group` | 进程**实际被调度**在哪个 task_group |
| `/proc/PID/autogroup` | `p->signal->autogroup` | 进程**被分配**了哪个 autogroup（可能不活跃） |

> **⚠️ 重要：三个层级视图及其查看方式**
>
> | 层级 | 查看方式 | 示例 | 含义 |
> |------|---------|------|------|
> | **cgroup 层级** | `cat /proc/PID/cgroup` | `0::/user.slice/user-0.slice/session-2617.scope` | 进程在 cgroup 树中的**实际位置** |
> | **调度层级** | `cat /sys/kernel/debug/sched/debug` | `cfs_rq[0]:/autogroup-2961` 或 `cfs_rq[0]:/user.slice` | 调度器**实际使用**的 task_group 层级 |
> | **autogroup 分配** | `cat /proc/PID/autogroup` | `/autogroup-3684 nice 0` | `signal->autogroup` 的分配关系（**不代表调度器实际行为**） |
>
> **这三者不一定一致！**
> - 进程的 cgroup 是 `/user.slice/user-0.slice/session-2617.scope`，但调度层级可能只到 `/user.slice`（因为 `user.slice` 的 `subtree_control` 没有启用 cpu，`cgroup_e_css_by_mask()` 向上回退到 `user.slice`）
>
> **定位调度问题时，必须以 `sched_debug` 为准，`/proc/PID/cgroup` 和 `/proc/PID/autogroup` 都不能反映调度器的真实行为。**

### 5.8 完整数据流：从 fork 到最终调度位置

```
setsid() (shell 启动时)
  └── sched_autogroup_create_attach()
      └── autogroup_create()
          └── tg = sched_create_group(&root_task_group)  ← 创建 autogroup 的 tg
          └── sched_online_group(tg, &root_task_group)   ← 挂到 root 下
      └── autogroup_move_group(shell, ag)
          └── shell->signal->autogroup = ag              ← shell 关联此 autogroup

fork(shell → child)
  │
  ├── sched_autogroup_fork()
  │   └── child->signal->autogroup = shell->signal->autogroup  ← 继承 autogroup 分配
  │       （此时 /proc/child/autogroup 已有值，但可能不生效）
  │
  └── sched_cgroup_fork()
      ├── tg = css_set->subsys[cpu_cgrp_id] 对应的 task_group
      │   └── 子进程继承父进程的 css_set → tg = user.slice 的 tg
      ├── tg = autogroup_task_group(child, tg)
      │   └── task_wants_autogroup(): user.slice tg ≠ &root_task_group → false
      │   └── 返回 user.slice 的 tg（autogroup 不生效）
      └── child->sched_task_group = user.slice 的 tg
          （子进程在 user.slice 的 cfs_rq 上调度）

echo $child_pid > /sys/fs/cgroup/cgroup.procs  （移入 root cgroup）
  └── cgroup_migrate_execute()
      ├── css_set_move_task() → 更新 child->cgroups 为 root 的 css_set
      │   （注意：signal->autogroup 不受影响）
      └── cpu_cgroup_attach() → sched_move_task()
          └── sched_change_group()
              ├── tg = task_css_check() → &root_task_group  ← 现在在 root cgroup
              ├── tg = autogroup_task_group(child, tg)
              │   └── task_wants_autogroup(): tg == &root_task_group → true
              │   └── 返回 child->signal->autogroup->tg    ← autogroup 生效！
              └── child->sched_task_group = autogroup 的 tg
                  （子进程转移到 autogroup 的 cfs_rq 上调度）
```

### 5.9 三个层级体系的关系

```
  ① cgroup v2 层级                ② autogroup 分配              ③ 调度器 task_group 层级
  (task->cgroups)                 (signal->autogroup)           (sched_task_group)
  ========================        =====================         ==========================

  / (root)                        autogroup-3684                root_task_group
  ├── user.slice/                   (所有从该 shell fork         ├── user.slice (tg)
  │   └── user-0.slice/              的进程都有此分配)           │   └── 进程在此调度
  │       └── session-2625.scope/                                │       (当进程在 user.slice 中)
  │           └── 进程在此          autogroup-MMMM               │
  │                                   (其他 shell 会话)          ├── autogroup-3684 (tg)
  ├── system.slice/                                              │   └── 进程在此调度
  │   └── sshd.service/                                          │       (当进程被移入 root cgroup)
  └── test_cgroupA/                                              │
      └── child_N/                                               ├── test_cgroupA (tg)
                                                                 │   └── child_N (tg)
                                                                 └── system.slice (tg)

  ①和③的关系：                    ②和③的关系：
  进程的 cgroup 决定了             ②只是"备选"，只有当①解析出的
  ③中的初始候选 tg                tg == &root_task_group 时，②才覆盖③
```

## 六、实验验证

在目标机器（kernel 7.0.0-rc2+, `CONFIG_SCHED_AUTOGROUP=y`, `sched_autogroup_enabled=1`）上验证。

### 实验 1：busy loop 留在 user.slice（不移动 cgroup）

```bash
$ taskset -c 0 bash -c 'while true; do :; done' &
$ cat /proc/$BGPID/cgroup
0::/user.slice/user-0.slice/session-2625.scope
$ cat /proc/$BGPID/autogroup
/autogroup-3684 nice 0                          ← signal->autogroup 有值

# sched_debug 中 CPU 0 的 cfs_rq 路径：
cfs_rq[0]:/user.slice                           ← sched_task_group = user.slice 的 tg
cfs_rq[0]:/
# 没有 /autogroup-3684 出现！autogroup 未生效
```

进程有 autogroup 分配，但调度器将其放在 user.slice 的 cfs_rq 中。因为 user.slice 的 task_group ≠ `&root_task_group`，`task_wants_autogroup()` 返回 false。

### 实验 2：将同一 busy loop 移入 root cgroup

```bash
$ echo $BGPID > /sys/fs/cgroup/cgroup.procs
$ cat /proc/$BGPID/cgroup
0::/                                             ← 已移入 root cgroup
$ cat /proc/$BGPID/autogroup
/autogroup-3684 nice 0                          ← signal->autogroup 没变

# sched_debug 中 CPU 0 的 cfs_rq 路径：
cfs_rq[0]:/autogroup-3684                       ← autogroup 生效了！
cfs_rq[0]:/
# user.slice 的 cfs_rq 消失了（该 CPU 上无活跃任务）
```

移入 root cgroup 后，`task_css_check()` 返回 `&root_task_group`，`task_wants_autogroup()` 返回 true，autogroup 接管调度。

### 实验 3：root cfs_rq 详情

```
cfs_rq[0]:/
  .nr_queued                     : 1            ← root cfs_rq 上只有 1 个 sched_entity
  .h_nr_runnable                 : 1
  .load                          : 1048576      ← = 1 × 1048576 (autogroup 的 group entity)
```

root cfs_rq 上只有 autogroup-3684 的 group entity（权重 1048576），进程作为 task entity 在 autogroup 内部的 cfs_rq 上。

## 七、解决方案

### 方案一：禁用 autogroup（推荐用于测试）

```bash
# 运行时禁用
echo 0 > /proc/sys/kernel/sched_autogroup_enabled

# 验证
cat /proc/sys/kernel/sched_autogroup_enabled
# 输出 0
```

禁用后，taskA 和 taskC 将直接作为 root cfs_rq 上的 task entity 参与调度，不再被 autogroup 包裹。此时 root cfs_rq 上有 3 个实体（taskA、taskC、test_cgroupA），预期得到 1:1:1。

### 方案二：将 taskA 和 taskC 放入独立 cgroup

```bash
mkdir -p /sys/fs/cgroup/test_tasks
echo $TASKA_PID > /sys/fs/cgroup/test_tasks/cgroup.procs
echo $TASKC_PID > /sys/fs/cgroup/test_tasks/cgroup.procs
```

将它们放入非 root 的 cgroup 后，cgroup 的 task_group 将优先于 autogroup。

### 方案三：编译内核时禁用 `CONFIG_SCHED_AUTOGROUP`

```
CONFIG_SCHED_AUTOGROUP=n
```

彻底消除 autogroup 对调度实验的干扰。

## 八、经验总结

1. **调度器的 task_group 层级不等同于 cgroup v2 层级**。autogroup 会在 cgroup 层级之上叠加额外的分组，特别是对 root cgroup 中的进程。

2. **`/proc/PID/autogroup` 有值不等于 autogroup 在生效**。`signal->autogroup`（分配）和 `sched_task_group`（实际调度组）是两个独立的数据结构。只有当进程的有效 cpu task_group 等于 `&root_task_group` 时，autogroup 才从"分配"变为"生效"。

3. **sched_debug 是定位调度行为异常的关键工具**。`nr_queued` 和 `se->load.weight` 直接反映调度器的实际决策依据，比理论推导更可靠。

4. **`CONFIG_SCHED_AUTOGROUP` 对调度实验有显著影响**。在做 CFS/EEVDF 调度行为验证时，应首先检查并禁用 autogroup，排除干扰。

5. **`subtree_control` 决定了 cpu 控制器的有效范围**。`user.slice` 的 `subtree_control` 不含 `cpu`，导致其子 cgroup 的有效 cpu css 回退到 `user.slice` 级别，而非 root 级别——这使得 autogroup 对 `user.slice` 中的进程不生效。

6. **定位方法论**：
   - 从代码分析建立理论预期
   - 用 sched_debug 捕获实际运行时数据
   - 对比理论与实际，找出不一致点（本例中 `nr_queued=2` 而非 3）
   - 追踪不一致点的来源（autogroup 的额外 task_group 层级）

## 附录：原始测试脚本（触发 1:1:2 问题的版本）

以下是触发 autogroup 干扰、产生 1:1:2 异常结果的原始测试脚本。该脚本**没有**禁用 `sched_autogroup_enabled`，导致 `taskA` 和 `taskC` 被移入 root cgroup 后被 autogroup 包裹。

### 脚本一：`cfs_group_sched_test.sh`（层级稀释效应验证）

```bash
#!/bin/bash
#
# CFS 组调度层级稀释效应验证脚本（原始版本 — 未处理 autogroup）
#
# ⚠️ 问题：此脚本在 CONFIG_SCHED_AUTOGROUP=y 的内核上运行时，
#    taskA 会被 autogroup 包裹，导致调度层级与预期不符。
#    修复版本已添加 autogroup 禁用逻辑。

set -e

TARGET_CPU=0
NUM_CHILD_CGROUPS=10
RUNTIME=600
CGROUP_ROOT="/sys/fs/cgroup"
TEST_GROUP="$CGROUP_ROOT/test_cgroupA"

cleanup() {
    for pid_file in /tmp/cfs_test_pid_*; do
        [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    done
    sleep 1
    for i in $(seq 1 $NUM_CHILD_CGROUPS); do
        rmdir "$TEST_GROUP/child_$i" 2>/dev/null || true
    done
    rmdir "$TEST_GROUP" 2>/dev/null || true
}

[ "$1" = "cleanup" ] && { cleanup; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo "错误：需要 root 权限"; exit 1; }
cleanup 2>/dev/null || true

echo "+cpu" > "$CGROUP_ROOT/cgroup.subtree_control"
mkdir -p "$TEST_GROUP"
echo "+cpu" > "$TEST_GROUP/cgroup.subtree_control"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    mkdir -p "$TEST_GROUP/child_$i"
done

start_busy_loop() {
    local name=$1 cpu=$2 nice_val=$3 pid_file=$4
    nice -n "$nice_val" taskset -c "$cpu" bash -c 'while true; do :; done' &
    echo $! > "$pid_file"
    echo "  $name: PID=$!, nice=$nice_val"
}

start_busy_loop "taskA" $TARGET_CPU 0 /tmp/cfs_test_pid_taskA
TASKA_PID=$(cat /tmp/cfs_test_pid_taskA)
# ⚠️ 问题所在：将进程移入 root cgroup 后，autogroup 会覆盖调度层级
echo $TASKA_PID > "$CGROUP_ROOT/cgroup.procs"

start_busy_loop "taskB" $TARGET_CPU -19 /tmp/cfs_test_pid_taskB
TASKB_PID=$(cat /tmp/cfs_test_pid_taskB)
echo $TASKB_PID > "$TEST_GROUP/child_2/cgroup.procs"

for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    start_busy_loop "filler_$i" $TARGET_CPU 0 "/tmp/cfs_test_pid_filler_$i"
    echo "$(cat /tmp/cfs_test_pid_filler_$i)" > "$TEST_GROUP/child_$i/cgroup.procs"
done

get_utime() { awk '{print $14}' /proc/$1/stat 2>/dev/null || echo 0; }

TASKA_START=$(get_utime $TASKA_PID)
TASKB_START=$(get_utime $TASKB_PID)
sleep "$RUNTIME"
TASKA_END=$(get_utime $TASKA_PID)
TASKB_END=$(get_utime $TASKB_PID)

TASKA_TICKS=$((TASKA_END - TASKA_START))
TASKB_TICKS=$((TASKB_END - TASKB_START))
TOTAL_TICKS=$((TASKA_TICKS + TASKB_TICKS))
printf "  %-35s %8d %7d%%\n" "taskA (root cgroup, nice=0)" "$TASKA_TICKS" "$((TASKA_TICKS * 100 / TOTAL_TICKS))"
printf "  %-35s %8d %7d%%\n" "taskB (child_2, nice=-19)" "$TASKB_TICKS" "$((TASKB_TICKS * 100 / TOTAL_TICKS))"

cleanup
```

### 脚本二：`cfs_group_sched_verify.sh`（全景验证，触发 1:1:2 的版本）

```bash
#!/bin/bash
#
# CFS 组调度全景验证脚本（原始版本 — 未处理 autogroup）
#
# ⚠️ 实际结果：taskA ≈ 25%, taskC ≈ 25%, cgroupA ≈ 50% (1:1:2)
#    原因：autogroup 将 taskA 和 taskC 包裹在同一 group entity 中

set -e

TARGET_CPU=0
NUM_CHILD_CGROUPS=10
RUNTIME=30
CGROUP_ROOT="/sys/fs/cgroup"
TEST_GROUP="$CGROUP_ROOT/test_cgroupA"

cleanup() {
    for f in /tmp/cfs_test_pid_*; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
        rm -f "$f"
    done
    sleep 1
    for i in $(seq 1 $NUM_CHILD_CGROUPS); do
        rmdir "$TEST_GROUP/child_$i" 2>/dev/null || true
    done
    rmdir "$TEST_GROUP" 2>/dev/null || true
}

[ "$1" = "cleanup" ] && { cleanup; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo "错误：需要 root 权限"; exit 1; }
cleanup 2>/dev/null || true

echo "+cpu" > "$CGROUP_ROOT/cgroup.subtree_control"
mkdir -p "$TEST_GROUP"
echo "+cpu" > "$TEST_GROUP/cgroup.subtree_control"
for i in $(seq 1 $NUM_CHILD_CGROUPS); do mkdir -p "$TEST_GROUP/child_$i"; done

start_busy_loop() {
    local name=$1 cpu=$2 nice_val=$3 pid_file=$4
    nice -n "$nice_val" taskset -c "$cpu" bash -c 'while true; do :; done' &
    echo $! > "$pid_file"
}

start_busy_loop "taskA" $TARGET_CPU 0 /tmp/cfs_test_pid_taskA
start_busy_loop "taskC" $TARGET_CPU 0 /tmp/cfs_test_pid_taskC
TASKA_PID=$(cat /tmp/cfs_test_pid_taskA)
TASKC_PID=$(cat /tmp/cfs_test_pid_taskC)
# ⚠️ 问题所在：移入 root cgroup → autogroup 覆盖 → taskA/taskC 被包裹
echo $TASKA_PID > "$CGROUP_ROOT/cgroup.procs"
echo $TASKC_PID > "$CGROUP_ROOT/cgroup.procs"

start_busy_loop "taskB" $TARGET_CPU -19 /tmp/cfs_test_pid_taskB
echo "$(cat /tmp/cfs_test_pid_taskB)" > "$TEST_GROUP/child_2/cgroup.procs"

for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    start_busy_loop "filler_$i" $TARGET_CPU 0 "/tmp/cfs_test_pid_filler_$i"
    echo "$(cat /tmp/cfs_test_pid_filler_$i)" > "$TEST_GROUP/child_$i/cgroup.procs"
done

get_utime() { awk '{print $14}' /proc/$1/stat 2>/dev/null || echo 0; }

TASKA_S=$(get_utime $TASKA_PID); TASKC_S=$(get_utime $TASKC_PID)
TASKB_S=$(get_utime $(cat /tmp/cfs_test_pid_taskB))
declare -A FILLER_S
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FILLER_S[$i]=$(get_utime $(cat "/tmp/cfs_test_pid_filler_$i"))
done

sleep "$RUNTIME"

TASKA_E=$(get_utime $TASKA_PID); TASKC_E=$(get_utime $TASKC_PID)
TASKB_E=$(get_utime $(cat /tmp/cfs_test_pid_taskB))
declare -A FILLER_E
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FILLER_E[$i]=$(get_utime $(cat "/tmp/cfs_test_pid_filler_$i"))
done

TASKA_T=$((TASKA_E - TASKA_S)); TASKC_T=$((TASKC_E - TASKC_S))
TASKB_T=$((TASKB_E - TASKB_S)); CGROUP_TOTAL=$TASKB_T
declare -A FILLER_T
for i in $(seq 1 $NUM_CHILD_CGROUPS); do
    [ "$i" -eq 2 ] && continue
    FILLER_T[$i]=$((FILLER_E[$i] - FILLER_S[$i]))
    CGROUP_TOTAL=$((CGROUP_TOTAL + FILLER_T[$i]))
done

ALL_TOTAL=$((TASKA_T + TASKC_T + CGROUP_TOTAL))
pct() { echo "$((${1} * 1000 / ${2}))" | sed 's/\(.*\)\(.\)$/\1.\2/'; }

printf "  %-28s %10d %7s%%\n" "taskA (nice=0)" $TASKA_T "$(pct $TASKA_T $ALL_TOTAL)"
printf "  %-28s %10d %7s%%\n" "taskC (nice=0)" $TASKC_T "$(pct $TASKC_T $ALL_TOTAL)"
printf "  %-28s %10d %7s%%\n" "cgroupA 合计" $CGROUP_TOTAL "$(pct $CGROUP_TOTAL $ALL_TOTAL)"
echo "  实际比例: taskA:taskC:cgroupA ≈ 1:1:2 (预期 1:1:1)"

cleanup
```

### 脚本的 autogroup 触发路径

```
脚本 fork 出 taskA/taskC
  └── 继承 shell 的 cgroup: /user.slice/user-0.slice/session-XXXX.scope
  └── 继承 shell 的 autogroup: autogroup-NNNN (signal->autogroup)
      │
      ▼
echo $PID > /sys/fs/cgroup/cgroup.procs
  └── cgroup 层面: 进程迁入 root cgroup (/)
  └── 调度器层面: sched_change_group() 被调用
      ├── task_css_check() → tg = &root_task_group ← 因为现在在 root cgroup
      └── autogroup_task_group(tsk, tg)
          └── task_wants_autogroup(): tg == &root_task_group → true
              └── 返回 signal->autogroup->tg  ← autogroup 覆盖！
```

如果进程**不被移入 root cgroup**（留在 user.slice 中），则：

```
task_css_check() → tg = user.slice 的 task_group ← 因为 user.slice 有 cpu css
autogroup_task_group(tsk, tg)
  └── task_wants_autogroup(): tg != &root_task_group → false
      └── 返回 tg (user.slice 的 task_group) ← autogroup 不覆盖
```
