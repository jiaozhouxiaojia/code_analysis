# Linux 内核 Shrinker 机制深度分析

Shrinker 是 Linux 内核内存管理子系统（MM）中的一个通用机制，用于在系统内存紧张时回收各种内核缓存（如 Dentry Cache, Inode Cache, Zswap 等）。它允许各个子系统注册回调函数，当内核进行页面回收（Page Reclaim）时，自动调用这些回调来释放内存。

## 1. 核心数据结构：struct shrinker

定义在 `include/linux/shrinker.h` 中，它是 Shrinker 机制的核心接口。

```c
struct shrinker {
    unsigned long (*count_objects)(struct shrinker *, struct shrink_control *sc);
    unsigned long (*scan_objects)(struct shrinker *, struct shrink_control *sc);

    long batch;    /* reclaim batch size, 0 = default */
    int seeks;     /* seeks to recreate an obj */
    unsigned flags;
    ...
};
```

*   **`count_objects`**: 返回当前可回收对象的数量。内核根据这个返回值和回收优先级来决定需要扫描多少对象。
*   **`scan_objects`**: 执行实际的回收操作。它应该尝试回收 `sc->nr_to_scan` 个对象，并返回实际释放的数量。
*   **`seeks`**: 表示重新创建被回收对象的代价（以磁盘寻道次数为单位）。代价越高（`seeks` 越大），内核越倾向于保留该对象。默认值为 2。
*   **`batch`**: 批处理大小。为了避免频繁调用，内核会累积一定数量的扫描请求后再一次性调用 `scan_objects`。

## 2. 注册与注销

### 2.1. 分配 (shrinker_alloc)
自 Linux 6.7 起，Shrinker 必须动态分配：
```c
struct shrinker *shrinker = shrinker_alloc(flags, "name");
```
这允许内核更好地管理 Shrinker 的生命周期和调试信息（Debugfs）。

### 2.2. 注册 (shrinker_register)
```c
void shrinker_register(struct shrinker *shrinker)
{
    ...
    mutex_lock(&shrinker_mutex);
    list_add_tail_rcu(&shrinker->list, &shrinker_list);
    shrinker->flags |= SHRINKER_REGISTERED;
    mutex_unlock(&shrinker_mutex);
    ...
}
```
注册过程将 Shrinker 添加到全局的 `shrinker_list` 链表中，使其对内存回收子系统可见。

## 3. 运行机制：do_shrink_slab()

当内核进行内存回收（如 `kswapd` 或直接回收）时，会调用 `shrink_slab`，进而遍历所有注册的 Shrinker 并调用 `do_shrink_slab`。

### 3.1. 计算扫描量
内核使用以下公式计算本次需要扫描的对象数量：

```c
delta = freeable / 2; // 默认情况
if (shrinker->seeks) {
    delta = freeable >> priority;
    delta *= 4;
    do_div(delta, shrinker->seeks);
}
total_scan = nr_deferred + delta;
```

*   **`freeable`**: 通过 `count_objects` 获取的当前可回收对象总数。
*   **`priority`**: 回收优先级（通常从 12 到 0，0 表示最高优先级/OOM）。
*   **`nr_deferred`**: 上次未完成的扫描量（累积到下一次）。

### 3.2. 循环扫描
```c
while (total_scan >= batch_size || total_scan >= freeable) {
    unsigned long nr_to_scan = min(batch_size, total_scan);
    shrinkctl->nr_to_scan = nr_to_scan;
    ret = shrinker->scan_objects(shrinker, shrinkctl);
    ...
    total_scan -= nr_to_scan;
}
```
内核会循环调用 `scan_objects`，直到完成目标扫描量。如果 `scan_objects` 返回 `SHRINK_STOP`，则提前终止。

## 4. 实例分析：Zswap Shrinker

Zswap 利用 Shrinker 机制将压缩在内存中的页面写回到后端的 Swap 设备，从而释放 RAM。

### 4.1. 注册
在 `mm/zswap.c` 中：
```c
shrinker = shrinker_alloc(SHRINKER_NUMA_AWARE | SHRINKER_MEMCG_AWARE, "mm-zswap");
shrinker->scan_objects = zswap_shrinker_scan;
shrinker->count_objects = zswap_shrinker_count;
shrinker_register(shrinker);
```
Zswap 注册了一个感知 NUMA 和 Memcg 的 Shrinker。

### 4.2. 计数策略 (zswap_shrinker_count)
Zswap 的计数逻辑非常精细：
1.  **压缩率调整**: `mult_frac(nr_freeable, nr_backing, nr_stored)`。
    *   如果压缩率很高（例如 100MB 数据压缩成 10MB），回收这 10MB 只能释放很少的内存，却需要大量的磁盘 I/O。因此，Zswap 会根据压缩率按比例减少报告的可回收数量，避免低效回收。
2.  **抖动保护**: 减去 `nr_disk_swapins`。
    *   如果最近发生了从磁盘 Swap-in 的操作，说明之前的回收可能太激进了。Zswap 会减少可回收数量，以保护活跃页面。

### 4.3. 扫描策略 (zswap_shrinker_scan)
调用 `list_lru_shrink_walk` 遍历 LRU 链表，并对每个页面调用 `shrink_memcg_cb` -> `zswap_writeback_entry`，将压缩数据解压并写入 Swap 设备。

## 5. 总结

Shrinker 机制提供了一个优雅的框架，使得内核各个子系统能够根据自身的特性（如 Zswap 的压缩率、Dentry 的层级结构）参与到全局的内存回收中。通过 `count_objects` 和 `scan_objects` 两个回调，实现了策略与机制的分离，既保证了回收的效率，又避免了“一刀切”导致的性能问题。