# CFS 组调度导致高优先级任务反而获得更少 CPU 时间的分析

## 问题场景

在一个 20 CPU、使能 cgroup 的系统上：

- **taskA**：位于 root cgroup，nice=0，fair 调度类
- **taskB**：位于 cgroupA 下某个子 cgroup 中，nice=-19，fair 调度类
- cgroupA 下有 10+ 个子 cgroup，任务数量较多
- 观察到 taskA 和 taskB 在同一 CPU 上均为 runnable 时，长时间都是 taskA 在 running

**结论：这是组调度的层级化 shares 分配机制导致的。nice 值只在同一个 cfs_rq 内生效，taskB 的高优先级被层级稀释了。**

## 层级结构

```
root cfs_rq (CPU X 的根运行队列)
├── taskA 的 sched_entity  (nice=0, weight=1024)
└── cgroupA 的 group sched_entity (shares=1024, 默认值)
    ├── child_cgroup_1 的 group entity (shares=1024)
    ├── child_cgroup_2 的 group entity (shares=1024)
    │   └── taskB (nice=-19, weight=88761)
    ├── child_cgroup_3 的 group entity (shares=1024)
    └── ... (共 10+ 个子 cgroup)
```

## 核心原因分析

### 一、调度是逐层进行的

CFS 组调度中，每个 cgroup 在其父级的 cfs_rq 上有一个 `sched_entity` 代表整个组。调度器在每一层 cfs_rq 上独立选择最优实体，**子 cgroup 内部的任务优先级无法穿透到上层**。

层级遍历宏（`kernel/sched/fair.c:307-308`）：

```c
#define for_each_sched_entity(se) \
    for (; se; se = se->parent)
```

`sched_entity` 通过 `parent` 指针和 `my_q` 字段建立层级关系（`include/linux/sched.h:604-608`）：

```c
struct sched_entity *parent;   // 父级实体
struct cfs_rq *cfs_rq;        // 本实体所在的运行队列
struct cfs_rq *my_q;          // 本实体拥有的运行队列（仅 group entity 非 NULL）
```

### 二、第一层竞争：root cfs_rq

在 root cfs_rq 上，调度器看到的竞争实体：

| 实体 | 权重 |
|------|------|
| taskA (nice=0) | **1024** (NICE_0_LOAD) |
| cgroupA 的 group entity | **最多 1024**（受 `tg->shares` 封顶） |

二者权重几乎 1:1，各分约 **50%** 的 CPU 时间。

#### cgroup 默认 shares 值

创建 cgroup 时，shares 默认为 `NICE_0_LOAD`（`kernel/sched/fair.c:13632`）：

```c
tg->shares = NICE_0_LOAD;   // 默认值 1024
```

`NICE_0_LOAD` 定义（`kernel/sched/sched.h:175`）：

```c
#define NICE_0_LOAD  (1L << NICE_0_LOAD_SHIFT)  // = 1024
```

#### group entity 权重计算

`calc_group_shares()`（`kernel/sched/fair.c:3920-3952`）决定了 group entity 在其父级 cfs_rq 上的权重：

```c
static long calc_group_shares(struct cfs_rq *cfs_rq)
{
    long tg_weight, tg_shares, load, shares;
    struct task_group *tg = cfs_rq->tg;

    tg_shares = READ_ONCE(tg->shares);           // cgroupA 的 shares，默认 1024

    load = max(scale_load_down(cfs_rq->load.weight),
               cfs_rq->avg.load_avg);            // 本 cfs_rq 上的负载

    tg_weight = atomic_long_read(&tg->load_avg); // 该 task_group 在所有 CPU 上的总负载

    tg_weight -= cfs_rq->tg_load_avg_contrib;
    tg_weight += load;

    shares = (tg_shares * load);                 // 按比例分配
    if (tg_weight)
        shares /= tg_weight;                     // 归一化

    return clamp_t(long, shares, MIN_SHARES, tg_shares);  // 上限为 tg_shares!
}
```

**关键：`clamp_t` 的上限是 `tg_shares`。** 无论 cgroupA 内部任务的 nice 值多高，cgroupA 的 group entity 权重最多也就是 `tg->shares`（默认 1024）。taskB 的 nice=-19 对应的 88761 权重完全无法体现到这一层。

#### 权重动态更新

`update_cfs_group()`（`kernel/sched/fair.c:3958-3973`）周期性地更新 group entity 权重：

```c
static void update_cfs_group(struct sched_entity *se)
{
    struct cfs_rq *gcfs_rq = group_cfs_rq(se);  // 获取 se->my_q
    long shares;

    if (!gcfs_rq || !gcfs_rq->load.weight)
        return;

    shares = calc_group_shares(gcfs_rq);         // 计算新权重
    if (unlikely(se->load.weight != shares))
        reweight_entity(cfs_rq_of(se), se, shares); // 更新权重
}
```

### 三、第二层竞争：cgroupA 的 cfs_rq

cgroupA 获得的 ~50% CPU 时间，在其 10+ 个子 cgroup 的 group entity 之间分配。每个子 cgroup 的 shares 默认都是 1024，大致均分。

taskB 所在的子 cgroup 约分到 cgroupA 时间的 **1/10**。

### 四、第三层：taskB 在自己 cgroup 的 cfs_rq

taskB 的 nice=-19 对应权重 88761，**只在其所在的 cfs_rq 内部生效**。如果该 cgroup 内只有 taskB，它确实拿到了该 cgroup 的全部份额——但这个份额本身已经很小了。

### 五、vruntime 的权重缩放

vruntime 的增长速率由 `calc_delta_fair()`（`kernel/sched/fair.c:290-296`）决定：

```c
static inline u64 calc_delta_fair(u64 delta, struct sched_entity *se)
{
    if (unlikely(se->load.weight != NICE_0_LOAD))
        delta = __calc_delta(delta, NICE_0_LOAD, &se->load);
    return delta;
}
```

vruntime 增长公式：`vruntime += 实际运行时间 × (NICE_0_LOAD / weight)`

但此处的 `weight` 是实体在**其所在 cfs_rq** 上的权重，不是全局权重。taskB 的 88761 权重只影响它在自己 cgroup 的 cfs_rq 上的 vruntime 增速，对 root cfs_rq 层面的调度完全没有影响。

### 六、pick_next_entity 的逐层选择

`pick_next_entity()`（`kernel/sched/fair.c:5473-5486`）在每层 cfs_rq 上独立选择：

```c
static struct sched_entity *
pick_next_entity(struct rq *rq, struct cfs_rq *cfs_rq)
{
    struct sched_entity *se;

    se = pick_eevdf(cfs_rq);   // EEVDF 算法选择最优实体
    if (se->sched_delayed) {
        dequeue_entities(rq, se, DEQUEUE_SLEEP | DEQUEUE_DELAYED);
        return NULL;
    }
    return se;
}
```

在 root cfs_rq 上，调度器在 taskA 的 sched_entity 和 cgroupA 的 group sched_entity 之间选择。两者权重相当，因此 taskA 获得约 50% 的时间。只有当 cgroupA 的 group entity 被选中时，才会进入 cgroupA 的 cfs_rq 继续向下选择，最终才有可能调度到 taskB。

## 有效 CPU 份额计算

```
taskB 有效比例 ≈ (cgroupA 在 root 的份额) × (子 cgroup 在 cgroupA 的份额) × (taskB 在子 cgroup 的份额)
             ≈ 1024/(1024+1024) × 1/10 × ~100%
             ≈ 50% × 10% × 100%
             ≈ 5%

taskA 有效比例 ≈ 1024/(1024+1024)
             ≈ 50%
```

**taskA 获得的 CPU 时间约为 taskB 的 10 倍**，尽管 taskB 的 nice 值 (-19) 远高于 taskA (0)。

## 相关数据结构

### task_group（`kernel/sched/sched.h:474-527`）

```c
struct task_group {
    struct sched_entity **se;     // 每个 CPU 上代表本组的调度实体
    struct cfs_rq **cfs_rq;       // 每个 CPU 上本组拥有的运行队列
    unsigned long shares;          // cpu.shares 权重值（默认 NICE_0_LOAD）
    struct task_group *parent;     // 父 task_group
    // ...
};
```

### 层级初始化（`kernel/sched/fair.c:13712-13741`）

```c
// init_tg_cfs_entry() 建立层级关系
if (!parent) {
    se->cfs_rq = &rq->cfs;        // 根组实体在 CPU 的主 cfs_rq 上
    se->depth = 0;
} else {
    se->cfs_rq = parent->my_q;    // 子组实体在父组的 my_q 上
    se->depth = parent->depth + 1;
}
se->my_q = cfs_rq;                // 本实体拥有自己的 cfs_rq
se->parent = parent;              // 指向父实体
update_load_set(&se->load, NICE_0_LOAD);  // 初始权重
```

## 同一 cgroup 在不同 CPU 上的权重分配

前面的分析都聚焦在**单个 CPU 上的层级竞争**。但一个 cgroup 的 `tg->shares`（或 cgroup v2 的 `cpu.weight`）是一个**全局配额**，需要在该 cgroup 有任务运行的所有 CPU 之间按比例分配。本章分析这个跨 CPU 的权重分配机制。

### 一、问题：一份 shares 如何分给多个 CPU？

假设 cgroupA 的 `tg->shares = 1024`，它的任务分布在 CPU0、CPU3、CPU7 上。那么 cgroupA 在每个 CPU 上的 group `sched_entity` 权重分别是多少？

答案是：**按各 CPU 上的负载占比，按比例瓜分 `tg->shares`**。

```
CPU0 上 cgroupA 的 group entity 权重 = tg->shares × (CPU0 上的负载 / 所有 CPU 上的总负载)
CPU3 上 cgroupA 的 group entity 权重 = tg->shares × (CPU3 上的负载 / 所有 CPU 上的总负载)
CPU7 上 cgroupA 的 group entity 权重 = tg->shares × (CPU7 上的负载 / 所有 CPU 上的总负载)
```

所有 CPU 上的权重之和 ≤ `tg->shares`。

### 二、核心公式推导

内核代码（`kernel/sched/fair.c:3846-3919`）中有详细的注释，记录了公式的演进过程：

**理想公式（精确但昂贵）：**

```
ge->load.weight = tg->weight × grq->load.weight / Σ(grq->load.weight)
```

这需要遍历所有 CPU 求和，开销太大。

**实际使用的近似公式：**

```
ge->load.weight = tg->weight × grq->avg.load_avg / tg->load_avg
```

其中：
- `tg->weight`：cgroup 配置的总 shares（如 1024）
- `grq->avg.load_avg`：本 CPU 上该 cgroup 的 cfs_rq 的 PELT 负载均值
- `tg->load_avg`：该 cgroup 在**所有 CPU** 上的负载均值之和（原子变量，各 CPU 增量更新）

**最终实现的修正公式（处理边界情况）：**

```
ge->load.weight = tg->weight × load / (tg->load_avg - grq->tg_load_avg_contrib + load)
```

其中 `load = max(scale_load_down(grq->load.weight), grq->avg.load_avg)`，取瞬时负载和 PELT 均值的较大者，确保新入队的任务能立即获得合理权重（PELT 需要时间收敛）。

### 三、`calc_group_shares()` 逐行分析

`kernel/sched/fair.c:3920-3952`：

```c
static long calc_group_shares(struct cfs_rq *cfs_rq)
{
    long tg_weight, tg_shares, load, shares;
    struct task_group *tg = cfs_rq->tg;

    tg_shares = READ_ONCE(tg->shares);           // (1) 读取 cgroup 配置的总 shares

    load = max(scale_load_down(cfs_rq->load.weight),
               cfs_rq->avg.load_avg);            // (2) 本 CPU 上的负载（取瞬时值和 PELT 均值的较大者）

    tg_weight = atomic_long_read(&tg->load_avg); // (3) 读取全局总负载（所有 CPU 的贡献之和）

    tg_weight -= cfs_rq->tg_load_avg_contrib;    // (4) 减去本 CPU 上次贡献的旧值
    tg_weight += load;                            // (5) 加上本 CPU 当前的新值
                                                  //     这样 tg_weight 就是最新的全局总负载

    shares = (tg_shares * load);                  // (6) 按比例计算本 CPU 应分得的 shares
    if (tg_weight)
        shares /= tg_weight;

    return clamp_t(long, shares, MIN_SHARES, tg_shares);  // (7) 钳位到 [2, tg_shares]
}
```

**步骤 (4)+(5) 的技巧**：`tg->load_avg` 是各 CPU 异步更新的原子变量，可能包含本 CPU 的旧值。为了得到准确的全局总负载，先减去旧的本地贡献 `tg_load_avg_contrib`，再加上当前的 `load`。这避免了对 `tg->load_avg` 加锁。

### 四、全局负载 `tg->load_avg` 的维护

#### 数据结构

```c
// kernel/sched/sched.h:493
struct task_group {
    atomic_long_t load_avg;    // 所有 CPU 上的负载贡献之和（原子变量）
    // ...
};

// kernel/sched/sched.h:720
struct cfs_rq {
    long tg_load_avg_contrib;  // 本 CPU 上次贡献给 tg->load_avg 的值（本地缓存）
    // ...
};
```

#### 更新函数 `update_tg_load_avg()`

`kernel/sched/fair.c:4092-4121`：

```c
static inline void update_tg_load_avg(struct cfs_rq *cfs_rq)
{
    long delta;
    u64 now;

    if (cfs_rq->tg == &root_task_group)
        return;                                  // root task_group 不需要

    now = sched_clock_cpu(cpu_of(rq_of(cfs_rq)));
    if (now - cfs_rq->last_update_tg_load_avg < NSEC_PER_MSEC)
        return;                                  // 限频：最多 1ms 更新一次，减少原子操作争用

    delta = cfs_rq->avg.load_avg - cfs_rq->tg_load_avg_contrib;

    if (abs(delta) > cfs_rq->tg_load_avg_contrib / 64) {  // 变化超过 1/64 才更新（滞后过滤）
        atomic_long_add(delta, &cfs_rq->tg->load_avg);    // 原子地更新全局总负载
        cfs_rq->tg_load_avg_contrib = cfs_rq->avg.load_avg; // 刷新本地缓存
        cfs_rq->last_update_tg_load_avg = now;
    }
}
```

**设计要点：**

| 机制 | 目的 |
|------|------|
| 原子变量 `atomic_long_t` | 无锁更新，避免多 CPU 争用自旋锁 |
| 1ms 限频 | 降低高频 tick 路径上的原子操作开销 |
| 1/64 阈值过滤 | 过滤微小波动，减少不必要的原子写 |
| 本地缓存 `tg_load_avg_contrib` | 计算增量 delta，避免全量重算 |

#### CPU 下线时的清理

`kernel/sched/fair.c:4123-4139`：

```c
static inline void clear_tg_load_avg(struct cfs_rq *cfs_rq)
{
    // 将本 CPU 的贡献从全局总负载中减去
    delta = 0 - cfs_rq->tg_load_avg_contrib;
    atomic_long_add(delta, &cfs_rq->tg->load_avg);
    cfs_rq->tg_load_avg_contrib = 0;
}
```

### 五、权重更新的触发路径

`update_cfs_group()` → `calc_group_shares()` → `reweight_entity()` 这条链在以下路径被触发：

| 路径 | 代码位置 | 场景 |
|------|----------|------|
| 任务入队 | `fair.c:5239` | 任务唤醒或迁移到本 CPU |
| 任务出队 | `fair.c:5401` | 任务睡眠或迁移走 |
| 周期性 tick | `fair.c:5524-5525` | 时钟中断触发 |
| 负载均衡 | `fair.c:6944, 7061` | 跨 CPU 迁移任务后调整 |

在入队路径中，完整的更新序列为：

```c
// kernel/sched/fair.c:5239
update_load_avg(cfs_rq, se, UPDATE_TG | DO_ATTACH);  // 更新 PELT 并触发 tg->load_avg 更新
update_cfs_group(se);                                  // 重算 shares 并 reweight
```

### 六、`reweight_entity()` 权重变更时的 vruntime 调整

当 group entity 的权重因跨 CPU 负载变化而改变时，需要同步调整 vruntime 相关字段以保持公平性。

`kernel/sched/fair.c:3789-3831`：

```c
static void reweight_entity(struct cfs_rq *cfs_rq, struct sched_entity *se,
                            unsigned long weight)
{
    // 按权重比例缩放 vlag（虚拟滞后）
    se->vlag = div_s64(se->vlag * se->load.weight, weight);

    // 按权重比例缩放 deadline
    if (se->rel_deadline)
        se->deadline = div_s64(se->deadline * se->load.weight, weight);

    // 更新实体权重
    update_load_set(&se->load, weight);

    // 用新权重重算 PELT load_avg
    u32 divider = get_pelt_divider(&se->avg);
    se->avg.load_avg = div_u64(se_weight(se) * se->avg.load_sum, divider);
}
```

**缩放逻辑**：权重增大 → vlag/deadline 缩小 → 实体更快获得调度机会。权重减小则相反。这保证了权重变更前后的公平性连续。

### 七、负载向上传播机制

在多层 cgroup 嵌套场景中，底层 cfs_rq 的负载变化需要逐层向上传播，最终影响顶层 group entity 的权重。

`kernel/sched/fair.c:4387-4412`：

```c
static inline int propagate_entity_load_avg(struct sched_entity *se)
{
    struct cfs_rq *cfs_rq, *gcfs_rq;

    if (entity_is_task(se))
        return 0;                    // 普通任务不需要传播

    gcfs_rq = group_cfs_rq(se);     // 子 cfs_rq
    if (!gcfs_rq->propagate)
        return 0;                    // 没有待传播的变化

    gcfs_rq->propagate = 0;
    cfs_rq = cfs_rq_of(se);         // 父 cfs_rq

    add_tg_cfs_propagate(cfs_rq, gcfs_rq->prop_runnable_sum);

    update_tg_cfs_util(cfs_rq, se, gcfs_rq);      // 传播 util
    update_tg_cfs_runnable(cfs_rq, se, gcfs_rq);   // 传播 runnable
    update_tg_cfs_load(cfs_rq, se, gcfs_rq);       // 传播 load

    return 1;
}
```

传播链：子 cfs_rq 负载变化 → 设置 `propagate` 标志 → 父层 `update_load_avg()` 时检测到标志 → 调用 `propagate_entity_load_avg()` → 更新父层 group entity 的 load_avg → 继续向上传播。

### 八、具体示例：20 CPU 系统上的权重分配

以本文的场景为例，cgroupA (`tg->shares = 1024`) 的任务分布在 CPU0 和 CPU5 上：

```
cgroupA 任务分布：
  CPU0:  load_avg = 800  (多个繁忙任务)
  CPU5:  load_avg = 200  (少量任务)
  其他CPU: 无任务

tg->load_avg ≈ 800 + 200 = 1000
```

各 CPU 上 cgroupA 的 group entity 权重计算：

```
CPU0:  shares = 1024 × 800 / 1000 = 819
CPU5:  shares = 1024 × 200 / 1000 = 205
                                合计 ≈ 1024
```

如果 CPU5 上的任务迁移到 CPU0，负载重新分布：

```
CPU0:  load_avg = 1000
CPU5:  load_avg = 0  (无任务，group entity 不参与调度)

CPU0:  shares = 1024 × 1000 / 1000 = 1024  (独占全部 shares)
```

**关键结论**：同一个 cgroup 的 `tg->shares` 是所有 CPU 共享的一个池子。负载越集中的 CPU，分到的权重越多；负载越分散，每个 CPU 上的权重越小。这确保了无论任务如何分布，cgroup 获得的总 CPU 时间占比保持一致。

### 九、相关数据结构汇总

| 字段 | 位置 | 含义 |
|------|------|------|
| `tg->shares` | `sched.h:487` | 用户配置的 cgroup 总权重（cpu.shares / cpu.weight） |
| `tg->load_avg` | `sched.h:493` | 原子变量，所有 CPU 上的 PELT 负载贡献之和 |
| `cfs_rq->avg.load_avg` | `sched.h:706` | 本 CPU 上该 cgroup 的 PELT 负载均值 |
| `cfs_rq->tg_load_avg_contrib` | `sched.h:720` | 本 CPU 上次贡献给 `tg->load_avg` 的缓存值 |
| `cfs_rq->load.weight` | `sched.h:682` | 本 CPU 上该 cfs_rq 的瞬时总权重（所有实体权重之和） |
| `se->load.weight` | `sched.h:577` | group entity 在父 cfs_rq 上的实际权重（`calc_group_shares` 的输出） |
| `cfs_rq->propagate` | `sched.h:721` | 标志：是否有待向上传播的负载变化 |
| `cfs_rq->prop_runnable_sum` | `sched.h:722` | 待传播的 runnable 负载增量 |

## 为什么 taskA、taskC 和 cgroupA 之间不是精确的 1:1:1？

当在 root cgroup 增加一个 taskC（同样 nice=0）后，root cfs_rq 上有三个 `sched_entity`：

| 实体 | 权重来源 | 理论权重 |
|------|----------|----------|
| taskA (nice=0) | `scale_load(1024) = 1048576` | 固定 1048576 |
| taskC (nice=0) | `scale_load(1024) = 1048576` | 固定 1048576 |
| cgroupA group entity | `calc_group_shares()` | 动态 ≈ 1048576 |

理论上三者权重相同，应为 1:1:1。但实际观察到偏离。以下从代码层面分析原因。

### 一、理论推导：单 CPU 场景下 `calc_group_shares()` 应返回 `tg_shares`

当所有任务都绑定到同一个 CPU 时（`kernel/sched/fair.c:3920-3951`）：

```c
tg_shares = READ_ONCE(tg->shares);                    // = NICE_0_LOAD = 1048576
load = max(scale_load_down(cfs_rq->load.weight),
           cfs_rq->avg.load_avg);                      // 本 CPU 负载

tg_weight = atomic_long_read(&tg->load_avg);           // 全局总负载
tg_weight -= cfs_rq->tg_load_avg_contrib;              // 减去本 CPU 旧贡献
tg_weight += load;                                      // 加上本 CPU 新负载

shares = tg_shares * load / tg_weight;
```

单 CPU 场景下，`tg->load_avg ≈ tg_load_avg_contrib`（因为只有一个 CPU 贡献），所以：

```
tg_weight = tg->load_avg - tg_load_avg_contrib + load ≈ 0 + load = load
shares = tg_shares × load / load = tg_shares = 1048576
```

即 group entity 权重 = taskA 权重 = taskC 权重。**理论上是完美的 1:1:1。**

### 二、实际偏离的原因

#### 原因 1：`calc_group_shares()` 公式本身的系统性偏差

内核注释明确指出这个公式有系统性过估的特性（`fair.c:3912-3918`）：

```c
/*
 * And that is shares_weight and is icky. In the (near) UP case it approaches
 * (4) while in the normal case it approaches (3). It consistently
 * overestimates the ge->load.weight and therefore:
 *
 *   \Sum ge->load.weight >= tg->weight
 *
 * hence icky!
 */
```

公式使用 `max(scale_load_down(load.weight), avg.load_avg)` 取两者较大值：

- `scale_load_down(cfs_rq->load.weight)`：**瞬时值**，实体入队/出队时立即跳变
- `cfs_rq->avg.load_avg`：**PELT 均值**，半衰期约 32ms，平滑变化

两者交替成为较大者。由于取 `max()` 操作，`load` 值在它们交叉波动时**总是偏高**，导致在多 CPU 场景下各 CPU 的 shares 之和超过 `tg->shares`。

在单 CPU 场景下，虽然分子分母中的 `load` 可以抵消（`shares = tg_shares × load / load`），但 `tg_load_avg_contrib` 的更新有 **1/64 阈值和 1ms 限频**，导致分母 `tg_weight` 并不总是精确等于 `load`，产生微小但持续的偏差。

#### 原因 2：group entity 被反复 reweight，而 task entity 权重恒定

这是最关键的差异。

**taskA 和 taskC**：权重由 nice 值决定，一旦设定就**永远不变**。`se->load.weight` 始终是 1048576，`se->vlag` 和 `se->deadline` 稳定演进。

**cgroupA 的 group entity**：权重在**每次 tick、入队、出队**时被重新计算。即使计算结果只有微小变化，也会触发 `reweight_entity()`（`fair.c:3970-3972`）：

```c
shares = calc_group_shares(gcfs_rq);
if (unlikely(se->load.weight != shares))
    reweight_entity(cfs_rq_of(se), se, shares);  // 只要权重有任何变化就触发
```

`reweight_entity()` 的关键操作（`fair.c:3789-3831`）：

```c
// (1) 出队
update_curr(cfs_rq);                                    // 刷新当前 vruntime
update_entity_lag(cfs_rq, se);                           // 更新 vlag
se->deadline -= se->vruntime;                            // 转为相对 deadline
__dequeue_entity(cfs_rq, se);                            // 从红黑树摘除

// (2) 按权重比例缩放 vlag 和 deadline
se->vlag = div_s64(se->vlag * old_weight, new_weight);
se->deadline = div_s64(se->deadline * old_weight, new_weight);

// (3) 设置新权重
update_load_set(&se->load, weight);

// (4) 重新放置
place_entity(cfs_rq, se, 0);                             // 重新计算 vruntime 和 deadline
__enqueue_entity(cfs_rq, se);                            // 重新插入红黑树
```

这个"出队 → 缩放 → 重新放置"的过程有以下代价：

**a) 整数除法的精度损失**

`div_s64(vlag * old_weight, new_weight)` 是整数除法，每次都会丢失余数。如果权重在 `1048576 ↔ 1048575` 之间反复抖动，vlag 会因为反复的整数除法而产生**单方向的舍入累积**。

**b) `place_entity()` 的 lag 膨胀**

`place_entity()`（`fair.c:5096-5184`）在重新放置实体时，会对 lag 做膨胀补偿以保持公平性：

```c
// fair.c:5169-5178
// vl_i = (W + w_i) * vl'_i / W
lag *= load + scale_load_down(se->load.weight);
lag = div_s64(lag, load);
```

每次 reweight 都会触发这个 lag 膨胀计算，引入额外的整数除法误差。这些误差**不会**发生在 taskA/taskC 上（因为它们的权重不变，不会被 reweight）。

**c) `clamp_t` 的不对称截断**

```c
return clamp_t(long, shares, MIN_SHARES, tg_shares);
// MIN_SHARES = 2, tg_shares = 1048576
```

当 PELT 波动导致 `shares` 计算结果略超 `tg_shares` 时，被截断到 `tg_shares`；但低于 `tg_shares` 时不会被抬升（除非低于 2）。这产生了**向下的系统性偏差**：

```
shares 分布：  [..., 1048574, 1048575, 1048576, 1048576, 1048576, ...]
                                       ^^^^^^^^^^^^^^^^^^^^^^^^^
                                       超出部分被截断，均值 < tg_shares
```

#### 原因 3：group entity 的更新时机不如 task entity 及时

`update_cfs_group()` 只在以下路径触发（`fair.c:5239, 5401, 5525`）：

| 路径 | 触发条件 |
|------|----------|
| 入队 | cgroupA 的实体入队到 root cfs_rq 时 |
| 出队 | cgroupA 的实体出队时 |
| tick | **当前正在运行的实体**是 cgroupA 的 group entity 时 |

关键：**当 taskA 或 taskC 在 running 时，cgroupA 的 group entity 不会被更新。** 在三者轮流运行的场景下，cgroupA 每 3 个 tick 才更新一次权重，而 taskA/taskC 的权重始终是固定的（不需要更新）。

这意味着 cgroupA 内部负载的瞬时变化（如某个子 cgroup 的 PELT 衰减）需要等到 cgroupA 的 entity 获得 running 机会时才能反映到其权重上。在这个窗口期内，cgroupA 的权重可能不是最优的。

#### 原因 4：系统中存在其他 cgroup

在使用 systemd 的系统上，root cfs_rq 上不止 taskA、taskC 和 cgroupA 三个实体。systemd 自动创建的 cgroup 也有 group entity：

```
root cfs_rq
├── taskA (weight=1048576)
├── taskC (weight=1048576)
├── test_cgroupA group entity (weight≈1048576)
├── user.slice group entity (weight=?)      ← systemd 创建
├── system.slice group entity (weight=?)    ← systemd 创建
├── init.scope group entity (weight=?)      ← systemd 创建
└── ...
```

如果这些 cgroup 在 CPU 0 上有任何活跃任务（如 sshd、systemd 本身、日志服务等），它们的 group entity 会有非零权重，参与 root cfs_rq 的调度竞争。虽然这不直接改变 taskA:taskC:cgroupA 的相对权重比，但会影响三者各自的 EEVDF 调度位置。

### 三、影响的量化估计

| 因素 | 影响方向 | 预估偏差幅度 |
|------|----------|------------|
| `clamp_t` 不对称截断 | cgroupA 偏少 | ~0.1-1% |
| `reweight_entity` 整数除法累积误差 | cgroupA 偏少 | ~0.5-2% |
| `place_entity` lag 膨胀的误差 | cgroupA 波动 | ~0.1-0.5% |
| 更新时机滞后（1/3 tick 频率） | cgroupA 偏少 | ~0.5-1% |
| 系统其他 cgroup 干扰 | 三者均减少，但不均等 | 取决于系统负载 |

综合效果：**cgroupA 的有效 CPU 份额比理论值低约 1-5%**，具体取决于系统环境。

### 四、验证方法

可以通过以下方式确认偏差来源：

```bash
# 1. 查看 cgroupA 的 group entity 实际权重（通过 /proc/sched_debug）
cat /proc/sched_debug | grep -A5 "test_cgroupA"

# 2. 消除其他 cgroup 干扰：对比将 taskA 也放入 cgroupA 的子 cgroup 后的结果
#    此时 taskA 和 taskB 在同一 cfs_rq 内，nice 值直接生效

# 3. 对比长时间运行（600s+）与短时间运行（10s）的偏差
#    长时间运行可以减少 PELT 瞬态影响，但 reweight 累积误差可能更显著
```

## 解决方案

如果希望 taskB 获得更多 CPU 时间，有以下途径：

1. **增大 cgroupA 的 shares/weight**：在 cgroup v1 中设置 `cpu.shares`，cgroup v2 中设置 `cpu.weight`，使 cgroupA 在 root cfs_rq 层面获得更大的权重比例
2. **增大 taskB 所在子 cgroup 的 shares/weight**：让 taskB 的子 cgroup 在 cgroupA 内部获得更大份额
3. **减少层级深度**：将 taskB 移到更靠近 root 的 cgroup 层级，减少层级稀释
4. **将 taskA 也放入 cgroup**：让 taskA 和 cgroupA 在同一层级通过 shares 公平竞争，而非 taskA 直接占据 root cfs_rq
