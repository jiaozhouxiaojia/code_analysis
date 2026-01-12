# Linux Kernel Zswap & Memcg 问答记录

本文档完整记录了关于 Linux 内核 Zswap 与 Memory Cgroup 交互机制的分析问答。

## Q1: 帮我详细分析一下 obj_cgroup_may_zswap()函数的实现

**A:**

`obj_cgroup_may_zswap()` 函数位于 [`mm/memcontrol.c`](mm/memcontrol.c:5407) 中，它是 Linux 内核内存控制子系统（Memory Cgroup）的一部分，专门用于管理 **zswap**（压缩交换缓存）的资源限制。

### 核心功能
该函数的主要目的是：**在消耗 CPU 周期进行页面压缩之前，快速判断当前 cgroup 是否允许使用 zswap。**

这是一个**乐观的预检查（Optimistic Pre-check）**机制。如果 zswap 空间已满或被禁用，提前返回 `false` 可以避免无谓的压缩开销，直接将页面写入后端交换设备。

### 代码逻辑详细分析

```c
bool obj_cgroup_may_zswap(struct obj_cgroup *objcg)
{
    struct mem_cgroup *memcg, *original_memcg;
    bool ret = true;

    /* 
     * 1. Cgroup v2 检查
     * 如果内存子系统没有挂载在默认层级（即不是 cgroup v2），
     * 则不执行此限制检查，直接返回 true。
     * 这意味着 zswap 的 cgroup 限制功能目前主要针对 cgroup v2 实现。
     */
    if (!cgroup_subsys_on_dfl(memory_cgrp_subsys))
        return true;

    /* 
     * 2. 获取 Memory Cgroup
     * 从 obj_cgroup 对象中获取对应的 mem_cgroup 结构。
     * get_mem_cgroup_from_objcg 会增加引用计数，所以最后需要 put。
     */
    original_memcg = get_mem_cgroup_from_objcg(objcg);

    /*
     * 3. 层级遍历检查 (Hierarchy Walk)
     * 从当前的 memcg 开始，沿着层级向上遍历直到根节点（不包括根节点）。
     * 这是一个关键点：子 cgroup 的 zswap 使用必须满足其所有祖先的限制。
     */
    for (memcg = original_memcg; !mem_cgroup_is_root(memcg);
         memcg = parent_mem_cgroup(memcg)) {
        
        /* 读取当前层级的 zswap 最大限制 (zswap.max) */
        unsigned long max = READ_ONCE(memcg->zswap_max);
        unsigned long pages;

        /* 如果设置为 max (PAGE_COUNTER_MAX)，表示无限制，继续检查父级 */
        if (max == PAGE_COUNTER_MAX)
            continue;
        
        /* 如果限制为 0，表示该层级禁止使用 zswap，直接返回 false */
        if (max == 0) {
            ret = false;
            break;
        }

        /*
         * 4. 统计数据刷新与检查
         * 强制刷新 memcg 的统计信息，以确保获取到的 zswap 使用量是准确的。
         * 在 cgroup v2 中，统计通常是异步的，为了精确控制限制，这里必须同步刷新。
         */
        __mem_cgroup_flush_stats(memcg, true);
        
        /* 获取当前 zswap 使用量（字节转页数） */
        pages = memcg_page_state(memcg, MEMCG_ZSWAP_B) / PAGE_SIZE;
        
        /* 如果当前使用量小于限制，继续检查父级 */
        if (pages < max)
            continue;

        /* 如果达到或超过限制，禁止 zswap */
        ret = false;
        break;
    }

    /* 释放引用计数 */
    mem_cgroup_put(original_memcg);
    return ret;
}
```

### 关键设计点总结

1.  **层级约束 (Hierarchical Enforcement)**:
    *   限制是层级生效的。即使子 cgroup 设置了很大的 `zswap.max`，如果其父 cgroup 的限制很小且已满，子 cgroup 也无法使用 zswap。

2.  **非原子性 (Non-atomic)**:
    *   正如注释所言，这个检查不是原子的。在检查通过到实际分配 zswap 空间之间，状态可能会发生变化。但由于 zswap 的压缩率是不确定的（只有压缩后才知道大小），无法像普通内存那样预先准确 charge。因此，这里选择做一个“尽力而为”的检查。

3.  **性能权衡**:
    *   函数调用了 `__mem_cgroup_flush_stats(memcg, true)`。这保证了限制的严格执行，但引入了刷新统计的开销。

4.  **Cgroup 版本**:
    *   明确只支持 Cgroup v2 (`cgroup_subsys_on_dfl`)。对于 Cgroup v1，该函数总是返回 `true`。

---

## Q2: 帮我详细分析一下 __mem_cgroup_flush_stats()函数的实现

**A:**

`__mem_cgroup_flush_stats()` 函数位于 [`mm/memcontrol.c`](mm/memcontrol.c:596) 中，它是 Linux 内核内存控制子系统（Memory Cgroup）中用于同步统计信息的关键函数。

### 核心背景：rstat 机制
在 Cgroup v2 中，为了避免在每次统计更新（如页面分配/释放）时都争用全局锁，内核引入了 **rstat (Resource Statistics)** 机制。
*   **更新路径 (Hot Path)**: 统计更新是 **Per-CPU** 的，且通常是批量的。这非常快，但意味着全局统计视图是“过时”或“不精确”的。
*   **读取路径 (Cold Path)**: 当用户空间读取 `memory.stat` 或内核需要精确数值进行限制检查时，必须显式调用 flush 函数，将分散在各个 CPU 上的增量汇总到全局计数器中。

### 代码逻辑详细分析

```c
static void __mem_cgroup_flush_stats(struct mem_cgroup *memcg, bool force)
{
    /*
     * 1. 检查是否需要刷新
     * memcg_vmstats_needs_flush() 会检查累积的未合并更新次数
     * 是否超过了阈值 (MEMCG_CHARGE_BATCH * num_online_cpus())。
     * 这是一个启发式检查，用于避免过于频繁的刷新。
     */
    bool needs_flush = memcg_vmstats_needs_flush(memcg->vmstats);

    /* 2. Tracepoint: 记录刷新事件，用于性能分析 */
    trace_memcg_flush_stats(memcg, atomic_read(&memcg->vmstats->stats_updates),
        force, needs_flush);

    /*
     * 3. 快速路径 (Fast Path)
     * 如果不是强制刷新 (force=false) 且未达到刷新阈值，
     * 则直接返回，跳过昂贵的 flush 操作。
     */
    if (!force && !needs_flush)
        return;

    /* 4. 记录 Root Memcg 的刷新时间 (用于限流或其他策略) */
    if (mem_cgroup_is_root(memcg))
        WRITE_ONCE(flush_last_time, jiffies_64);

    /*
     * 5. 执行实际的刷新操作
     * css_rstat_flush() 是 cgroup 核心提供的函数。
     * 它会获取全局 rstat 锁，遍历所有在线 CPU，
     * 将该 memcg 及其子树的 per-cpu 统计增量汇总到全局计数器。
     * 这是一个 O(NR_CPUS) 的操作，开销较大。
     */
    css_rstat_flush(&memcg->css);
}
```

### 关键参数与辅助函数

1.  **`force` 参数**:
    *   **`false`**: 用于常规场景（如读取 `memory.stat`），允许一定的统计误差以换取性能。如果更新量很小，就不刷新。
    *   **`true`**: 用于关键路径（如 `obj_cgroup_may_zswap` 中的限制检查）。此时必须获取精确值，因此忽略阈值检查，强制执行 flush。

2.  **`memcg_vmstats_needs_flush(vmstats)`**:
    *   实现：`return atomic_read(&vmstats->stats_updates) > MEMCG_CHARGE_BATCH * num_online_cpus();`
    *   逻辑：只有当“累积的更新次数”超过“每个CPU的批处理大小 * CPU数量”时，才认为值得进行一次全局刷新。

### 总结
`__mem_cgroup_flush_stats` 是连接“高性能 Per-CPU 统计更新”与“精确全局统计读取”的桥梁。它通过阈值检查机制（`needs_flush`）在性能和精确度之间取得平衡，同时通过 `force` 参数允许关键路径强制获取精确视图。

---

## Q3: 帮我详细分析一下 css_rstat_flush()函数的实现

**A:**

`css_rstat_flush()` 函数位于 [`kernel/cgroup/rstat.c`](kernel/cgroup/rstat.c:397) 中，它是 Linux Cgroup rstat (Resource Statistics) 机制的核心同步函数。

### 核心功能
该函数负责将指定 Cgroup 子系统状态 (css) 及其所有后代节点的 **Per-CPU 统计增量** 汇总到 **全局计数器** 中。这是从“高性能写入视图”切换到“精确读取视图”的关键步骤。

### 代码逻辑详细分析

```c
__bpf_kfunc void css_rstat_flush(struct cgroup_subsys_state *css)
{
    int cpu;
    bool is_self = css_is_self(css);

    /* 1. 安全检查：防止 BPF 程序访问未初始化的 rstat 指针 */
    if (!css_uses_rstat(css))
        return;

    /* 2. 声明可能睡眠：因为后续会获取锁 */
    might_sleep();

    /* 
     * 3. 遍历所有可能的 CPU
     * rstat 的数据分散在每个 CPU 上，必须逐个收集。
     */
    for_each_possible_cpu(cpu) {
        struct cgroup_subsys_state *pos;

        /* 
         * 4. 获取锁 (__css_rstat_lock)
         * 获取全局 rstat 锁 (cgroup_rstat_lock)。
         * 注意：锁是在每个 CPU 循环内部获取和释放的。
         * 这样做是为了避免长时间持有自旋锁（raw_spinlock 会关中断），
         * 从而减少对系统延迟的影响。
         */
        __css_rstat_lock(css, cpu);

        /*
         * 5. 获取更新列表 (Updated List)
         * 这是一个关键优化：rstat 维护了一个“有更新的节点链表”。
         * 我们只需要遍历那些确实发生了统计更新的节点，
         * 而不需要遍历整个 Cgroup 树。
         */
        pos = css_rstat_updated_list(css, cpu);

        /* 6. 遍历链表并执行 Flush 回调 */
        for (; pos; pos = pos->rstat_flush_next) {
            if (is_self) {
                /* 处理 Cgroup 核心的基础统计 (如 cpu.stat) */
                cgroup_base_stat_flush(pos->cgroup, cpu);
                bpf_rstat_flush(pos->cgroup, cgroup_parent(pos->cgroup), cpu);
            } else {
                /* 
                 * 处理特定子系统的统计 (如 memory controller)
                 * 调用子系统注册的 css_rstat_flush 回调。
                 * 对于 memcg，这里会调用 mem_cgroup_css_rstat_flush()，
                 * 将该 CPU 上的统计增量加到全局原子计数器中。
                 */
                pos->ss->css_rstat_flush(pos, cpu);
            }
        }

        /* 7. 释放锁 */
        __css_rstat_unlock(css, cpu);

        /* 8. 调度点：允许内核在处理不同 CPU 之间进行调度 */
        if (!cond_resched())
            cpu_relax();
    }
}
```

### 关键设计点总结

1.  **只处理“脏”节点 (Updated List Optimization)**:
    *   rstat 机制非常高效，因为它只处理那些自上次 flush 以来确实有数据更新的 cgroup 节点。这是通过在更新路径（`cgroup_rstat_updated`）将节点加入 per-cpu 的链表来实现的。

2.  **锁的粒度与延迟控制**:
    *   虽然使用了一个全局锁，但锁的持有时间被严格限制在处理单个 CPU 的更新列表内。
    *   `cond_resched()` 的使用确保了在 CPU 数量较多的服务器上，flush 操作不会造成长时间的调度延迟（Latency Spike）。

3.  **回调机制**:
    *   它是一个通用框架。具体的统计汇总逻辑由各个子系统（如 memory, block, io）通过 `css_rstat_flush` 回调函数自己实现。

---

## Q4: 帮我详细分析一下MEMCG_ZSWAP_B的含义和实现

**A:**

`MEMCG_ZSWAP_B` 是 Linux 内核内存控制子系统（Memory Cgroup）中用于统计 **Zswap 实际内存占用** 的关键枚举常量。

### 1. 含义与定义
*   **定义**: 它是 `enum memcg_stat_item` 的一个成员，通常定义在 `include/linux/memcontrol.h` 或 `mm/memcontrol.c` 中。
*   **含义**: `MEMCG_ZSWAP_B` 代表 **"Memory Cgroup Zswap Bytes"**。它统计的是当前 Cgroup 在 Zswap 存储池中实际占用的**压缩后的字节数**。
*   **对比**:
    *   `MEMCG_ZSWAPPED`: 统计被交换出的**原始页面数量** (Pages)。
    *   `MEMCG_ZSWAP_B`: 统计**压缩后的实际大小** (Bytes)。
    *   二者的关系反映了 Zswap 的压缩率。

### 2. 实现机制
该统计值的维护主要发生在 Zswap 的存储（Store）和加载（Load/Free）路径上，通过 `obj_cgroup` 接口进行管理。

#### A. 增加计数 (Charge)
当页面被成功压缩并准备存入 Zswap 时，内核会调用 `obj_cgroup_charge_zswap()`：
```c
void obj_cgroup_charge_zswap(struct obj_cgroup *objcg, size_t size)
{
    /* ... */
    /* 1. 增加通用内存计数 (计入 memory.current) */
    obj_cgroup_charge(objcg, GFP_KERNEL, size);

    rcu_read_lock();
    memcg = obj_cgroup_memcg(objcg);
    
    /* 2. 增加 Zswap 专用计数 (计入 zswap.current) */
    mod_memcg_state(memcg, MEMCG_ZSWAP_B, size);
    mod_memcg_state(memcg, MEMCG_ZSWAPPED, 1); // 增加页面计数
    rcu_read_unlock();
}
```

#### B. 减少计数 (Uncharge)
当页面从 Zswap 读回内存（Swapin）或被废弃时，内核会调用 `obj_cgroup_uncharge_zswap()`：
```c
void obj_cgroup_uncharge_zswap(struct obj_cgroup *objcg, size_t size)
{
    /* ... */
    obj_cgroup_uncharge(objcg, size);

    rcu_read_lock();
    memcg = obj_cgroup_memcg(objcg);
    
    /* 减少 Zswap 专用计数 */
    mod_memcg_state(memcg, MEMCG_ZSWAP_B, -size);
    mod_memcg_state(memcg, MEMCG_ZSWAPPED, -1);
    rcu_read_unlock();
}
```

### 3. 关键用途
1.  **资源限制检查**:
    在 `obj_cgroup_may_zswap()` 函数中，内核会读取 `MEMCG_ZSWAP_B` 的值，并将其与用户设置的 `zswap.max` 限制进行比较。如果当前占用超过限制，则禁止新的 Zswap 分配。

2.  **用户空间统计**:
    *   在 Cgroup v2 的 `memory.stat` 文件中，该值映射为 `zswap` 字段（单位：字节）。
    *   在 `zswap.current` 文件中，直接显示该值。

### 总结
`MEMCG_ZSWAP_B` 是 Zswap 资源控制的核心统计指标。它精确反映了压缩内存的物理占用，使得管理员能够通过 Cgroup 限制 Zswap 的实际内存消耗，防止其无限制增长导致系统内存耗尽。

---

## Q5: 帮我详细分析一下 zswap_check_limits()函数的实现

**A:**

`zswap_check_limits()` 函数位于 [`mm/zswap.c`](mm/zswap.c:463) 中，它是 Linux Zswap 机制中用于管理 **全局存储池容量** 的核心函数。

### 核心功能
该函数的主要目的是：**防止 Zswap 占用过多的系统物理内存。**
它通过检查当前 Zswap 存储池的总大小是否超过了用户设定的上限（`max_pool_percent`），来决定是否允许新的页面存入 Zswap。

### 代码逻辑详细分析

```c
static bool zswap_check_limits(void)
{
    /* 1. 获取当前 Zswap 占用的总物理页数 */
    unsigned long cur_pages = zswap_total_pages();
    
    /* 2. 计算允许的最大页数 (基于 totalram_pages * zswap_max_pool_percent / 100) */
    unsigned long max_pages = zswap_max_pages();

    /* 
     * 3. 检查是否超过上限 (High Watermark)
     * 如果当前使用量 >= 最大限制，标记池为“已满” (reached_full)。
     */
    if (cur_pages >= max_pages) {
        zswap_pool_limit_hit++;     // 增加统计计数
        zswap_pool_reached_full = true;
    } 
    /* 
     * 4. 检查是否可以解除限制 (Low Watermark)
     * 这是一个滞后回环 (Hysteresis) 机制。
     * 只有当使用量下降到“接受阈值”以下时，才重新允许使用 Zswap。
     * 阈值通常是 max_pages 的 90% (zswap_accept_thr_percent)。
     */
    else if (zswap_pool_reached_full &&
           cur_pages <= zswap_accept_thr_pages()) {
            zswap_pool_reached_full = false;
    }

    /* 返回当前状态：true 表示已满（拒绝存储），false 表示未满（允许存储） */
    return zswap_pool_reached_full;
}
```

### 关键设计点：滞后回环 (Hysteresis)
该函数不仅仅是一个简单的 `current > max` 检查，它引入了一个“缓冲区”：
*   **停止接受**: 当使用量达到 **100%** 的限制时。
*   **恢复接受**: 当使用量下降到 **90%** (默认) 的限制时。

**目的**: 这种设计是为了防止在限制边缘发生剧烈的**抖动 (Thrashing)**。如果没有这个缓冲区，系统可能会在“允许”和“拒绝”之间频繁切换，导致性能不稳定。

### 辅助函数
1.  **`zswap_total_pages()`**: 遍历所有活动的 zswap pools，累加它们实际占用的物理内存页数。
2.  **`zswap_max_pages()`**: `totalram_pages() * zswap_max_pool_percent / 100`。
3.  **`zswap_accept_thr_pages()`**: `zswap_max_pages() * zswap_accept_thr_percent / 100`。

### 总结
`zswap_check_limits` 是 Zswap 的全局刹车机制。它确保 Zswap 不会消耗掉所有的系统内存，保留足够的内存给应用程序和内核其他部分使用，并通过滞后机制保证了控制的稳定性。

---

## Q6: 帮我详细分析一下 zswap_pool_current_get()函数的实现

**A:**

`zswap_pool_current_get()` 函数位于 [`mm/zswap.c`](mm/zswap.c:406) 中，它是 Zswap 存储路径上的关键函数，用于获取当前活动的存储池（Pool）引用。

### 核心功能
该函数的主要目的是：**在 RCU 保护下，安全地获取当前 Zswap Pool 的指针，并增加其引用计数。**

### 代码逻辑详细分析

```c
static struct zswap_pool *zswap_pool_current_get(void)
{
    struct zswap_pool *pool;

    /* 
     * 1. RCU 读锁
     * zswap_pools 链表是受 RCU 保护的。
     * 这允许在读取当前 pool 的同时，其他线程可以并发地添加新 pool 或删除旧 pool。
     */
    rcu_read_lock();

    /* 
     * 2. 获取当前 Pool 指针
     * __zswap_pool_current() 调用 list_first_or_null_rcu()，
     * 获取 zswap_pools 链表的第一个节点。
     * 在 Zswap 设计中，最新的（活动的）pool 总是位于链表头部。
     */
    pool = __zswap_pool_current();

    /*
     * 3. 尝试增加引用计数
     * zswap_pool_tryget() 使用 percpu_ref_tryget()。
     * - 如果 pool 处于活跃状态，引用计数加 1，返回 true。
     * - 如果 pool 正在被销毁（percpu_ref 处于 dying 状态），返回 false。
     * 
     * 使用 Per-CPU 引用计数 (percpu_ref) 是为了性能：
     * 避免在每次页面交换（高频操作）时争用全局原子变量。
     */
    if (!zswap_pool_tryget(pool))
        pool = NULL;

    /* 4. RCU 解锁 */
    rcu_read_unlock();

    return pool;
}
```

### 关键设计点

1.  **RCU (Read-Copy-Update)**:
    *   Zswap 支持动态更换压缩算法（如从 lzo 换到 zstd）。
    *   当参数改变时，会创建一个新 pool 并插入链表头部，旧 pool 依然存在直到所有页面被释放。
    *   RCU 机制保证了在这个切换过程中，读者（`zswap_store`）可以无锁地访问链表。

2.  **Per-CPU 引用计数 (`percpu_ref`)**:
    *   Zswap 的吞吐量很高，如果使用普通的 `atomic_t` 引用计数，多核并发下的缓存行争用（Cache Line Bouncing）会严重影响性能。
    *   `percpu_ref` 允许在本地 CPU 上进行计数，只有在销毁时才汇总，极大地提高了并发性能。

3.  **生命周期管理**:
    *   调用者必须在完成操作后调用 `zswap_pool_put(pool)` 来释放引用，否则 pool 永远不会被销毁（内存泄漏）。

---

## Q7: 帮我详细分析一下 memcg_list_lru_alloc()函数的实现

**A:**

`memcg_list_lru_alloc()` 函数位于 [`mm/list_lru.c`](mm/list_lru.c:513) 中，它是 Linux 内核中实现 **Per-Memcg Slab 内存回收** 的关键基础设施。

### 核心功能
该函数负责为指定的 Memory Cgroup 分配和初始化 `list_lru` 结构。
这使得内核能够将属于不同 Cgroup 的 Slab 对象（如 dentry, inode）隔离在不同的 LRU 链表中，从而在内存压力下实现针对特定 Cgroup 的精确回收。

### 代码逻辑详细分析

```c
int memcg_list_lru_alloc(struct mem_cgroup *memcg, struct list_lru *lru, gfp_t gfp)
{
    /* 1. 快速检查：如果 LRU 不支持 memcg 或已经分配过，直接返回 */
    if (!list_lru_memcg_aware(lru) || memcg_list_lru_allocated(memcg, lru))
        return 0;

    gfp &= GFP_RECLAIM_MASK;

    /*
     * 2. 祖先遍历与分配 (Ancestor Allocation Loop)
     * 这是一个关键设计：必须确保当前 Cgroup 及其所有祖先都分配了 LRU 结构。
     * 原因：当 Cgroup 被删除时，其对象会被 Reparent 到父 Cgroup。
     * 如果父级没有 LRU 结构，这些对象将无法被正确管理。
     */
    do {
        /* 2.1 向上查找最远的未分配祖先 */
        pos = memcg;
        parent = parent_mem_cgroup(pos);
        while (!memcg_list_lru_allocated(parent, lru)) {
            pos = parent;
            parent = parent_mem_cgroup(pos);
        }

        /* 2.2 分配内存 (如果尚未分配) */
        if (!mlru) {
            mlru = memcg_init_list_lru_one(lru, gfp);
            if (!mlru)
                return -ENOMEM;
        }

        /* 
         * 2.3 将分配的结构存储到 XArray 中
         * lru->xa 是一个映射表：kmemcg_id -> list_lru_memcg
         */
        xas_set(&xas, pos->kmemcg_id);
        do {
            xas_lock_irqsave(&xas, flags);
            /* 再次检查是否已分配 (并发保护) 且 cgroup 未处于 dying 状态 */
            if (!xas_load(&xas) && !css_is_dying(&pos->css)) {
                xas_store(&xas, mlru);
                if (!xas_error(&xas))
                    mlru = NULL; /* 成功存储，指针被消耗，下次循环需重新分配 */
            }
            xas_unlock_irqrestore(&xas, flags);
        } while (xas_nomem(&xas, gfp));

    } while (pos != memcg && !css_is_dying(&pos->css));

    /* 如果 mlru 分配了但没用到（例如并发竞争输了），释放它 */
    if (unlikely(mlru))
        kfree(mlru);

    return 0;
}
```

### 关键数据结构与设计

1.  **XArray (`lru->xa`)**:
    *   内核使用 XArray 来存储 `kmemcg_id` 到 `struct list_lru_memcg` 的映射。
    *   这提供了高效的查找性能（O(log N)），允许在分配/释放对象时快速找到对应的 LRU 列表。

2.  **`struct list_lru_memcg`**:
    *   这是实际存储 LRU 链表头的结构。
    *   它包含一个数组 `node[nr_node_ids]`，这意味着对于每个 Memcg，内核还进一步按 **NUMA Node** 进行了物理隔离，以保证局部性。

3.  **Reparenting 保障**:
    *   代码中的 `do-while` 循环确保了从根到当前节点的完整路径上，所有 LRU 结构都已就绪。这是 Cgroup 层次化管理和资源回收正确性的基础。

---

## Q8: 帮我分析一下zswap_list_lru的作用

**A:**

`zswap_list_lru` 是 Linux Zswap 机制中用于管理 **页面回收 (Reclaim)** 的核心数据结构，定义在 [`mm/zswap.c`](mm/zswap.c:164) 中。

### 核心定义
```c
/* Global LRU lists shared by all zswap pools. */
static struct list_lru zswap_list_lru;
```
它是一个全局的 `struct list_lru` 结构，用于维护所有存储在 Zswap 中的页面条目 (`zswap_entry`) 的 LRU (Least Recently Used) 顺序。

### 关键作用：Memcg 感知的页面回收
虽然它是一个全局变量，但它被配置为 **Memcg-aware (Memory Cgroup 感知)** 的。这意味着它不仅仅是一个简单的双向链表，而是一个复杂的索引结构，能够：

1.  **按 Cgroup 隔离**:
    内部通过 XArray 维护了每个 Memory Cgroup 的独立 LRU 列表。这使得内核能够区分属于不同容器/进程组的 Zswap 页面。

2.  **精确回收 (Targeted Reclaim)**:
    当某个 Cgroup 的内存（或 Zswap 使用量）达到限制时，内核可以利用 `zswap_list_lru` **仅回收该 Cgroup 拥有的最旧页面**，将其写回后端 Swap 设备（Writeback），从而释放 Zswap 空间。这避免了“全局回收”导致的邻居干扰问题。

### 生命周期管理
*   **添加 (Add)**: 在 `zswap_store()` 中，当页面成功压缩并存入 Zswap 后，会调用 `zswap_lru_add(&zswap_list_lru, entry)` 将其加入 LRU。
*   **删除 (Del)**: 在 `zswap_load()` (读回内存) 或 `zswap_invalidate()` (页面失效) 时，调用 `zswap_lru_del()` 将其移除。
*   **收缩 (Shrink)**:
    *   **主动回收**: 当 Zswap 池满时 (`zswap_check_limits` 触发)，会调用 `list_lru_walk_one()` 主动驱逐旧页面。
    *   **被动回收**: 通过注册 Shrinker (`zswap_shrinker`)，当系统整体内存紧张时，内核的内存回收机制会自动扫描此 LRU 并驱逐页面。

### 总结
`zswap_list_lru` 是 Zswap 实现 **动态容量管理** 和 **Cgroup 资源隔离** 的基石。它让 Zswap 不再是一个“只进不出”的黑洞，而是一个可以根据内存压力智能调节大小、并能按需将冷数据下刷到磁盘的缓存层。