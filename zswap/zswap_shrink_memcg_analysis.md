# zswap shrink_memcg() 函数深度分析

`shrink_memcg()` 是 Linux 内核 `mm/zswap.c` 中负责回收（Reclaim）zswap 内存的关键函数。当 zswap 池已满或 Memory Cgroup (memcg) 的内存限制达到阈值时，该函数会被调用，将 zswap 中的压缩页面解压并写回到后端的 Swap 设备（如磁盘分区或 Swap 文件），从而释放宝贵的 RAM 空间。

## 1. 函数签名与入口

```c
static int shrink_memcg(struct mem_cgroup *memcg)
```

*   **`memcg`**: 指定需要回收内存的 Memory Cgroup。如果为 NULL，通常表示全局回收。
*   **返回值**: `0` 表示成功回收了至少一个页面，`-EAGAIN` 表示尝试了但未成功回收，`-ENOENT` 表示没有可回收的页面或 writeback 被禁用。

## 2. 核心流程详解

### 2.1. 前置检查

```c
if (!mem_cgroup_zswap_writeback_enabled(memcg))
    return -ENOENT;

if (memcg && !mem_cgroup_online(memcg))
    return -ENOENT;
```

*   **Writeback 启用检查**: 首先检查该 memcg 是否启用了 zswap writeback。如果禁用，则无法进行回收。
*   **Zombie Memcg 检查**: 如果 memcg 已经离线（offline），则跳过。因为离线 memcg 的 LRU 链表会被重新父级化（reparented），应从父级进行回收。

### 2.2. 遍历 NUMA 节点与 LRU

```c
for_each_node_state(nid, N_NORMAL_MEMORY) {
    unsigned long nr_to_walk = 1;

    shrunk += list_lru_walk_one(&zswap_list_lru, nid, memcg,
                    &shrink_memcg_cb, NULL, &nr_to_walk);
    scanned += 1 - nr_to_walk;
}
```

*   函数遍历所有具有普通内存的 NUMA 节点。
*   使用 `list_lru_walk_one` 遍历全局的 `zswap_list_lru` 链表。
*   **`nr_to_walk = 1`**: 这里设置每次只尝试回收 **1个** 页面。这是一个非常细粒度的控制，意味着 `shrink_memcg` 的一次调用目标就是成功写回一个页面。
*   **回调函数**: `shrink_memcg_cb` 是处理每个 LRU 元素的核心回调。

## 3. LRU 回调：shrink_memcg_cb()

这个回调函数实现了具体的回收策略和并发控制。

### 3.1. 二次机会算法 (Second Chance Algorithm)

```c
if (entry->referenced) {
    entry->referenced = false;
    return LRU_ROTATE;
}
```

*   Zswap 实现了一个简单的二次机会算法。每个 `zswap_entry` 有一个 `referenced` 标志。
*   如果标志被设置（表示最近被访问过），则清除标志并将 entry 移动到 LRU 链表的末尾（Rotate），给予它第二次机会，暂不回收。

### 3.2. 准备写回与锁释放

```c
list_move_tail(item, &l->list);
swpentry = entry->swpentry;
spin_unlock(&l->lock);
```

*   如果决定回收，首先将 entry 移动到 LRU 尾部（为了处理失败后的重试逻辑）。
*   **关键点**: 在调用耗时的写回操作前，必须释放 LRU 锁 (`spin_unlock`)。
*   **安全性**: 在释放锁之前，将 `swpentry` 复制到栈上。这是因为一旦锁释放，`entry` 可能被并发释放，但 `swpentry` 值是持久的，用于后续验证。

### 3.3. 执行写回

```c
writeback_result = zswap_writeback_entry(entry, swpentry);
```

调用 `zswap_writeback_entry` 执行实际的解压和写回操作。

## 4. 写回逻辑：zswap_writeback_entry()

这是最底层的写回实现。

### 4.1. 获取 Swap Cache Folio

```c
folio = __read_swap_cache_async(swpentry, GFP_KERNEL, mpol,
        NO_INTERLEAVE_INDEX, &folio_was_allocated, true);
```

*   尝试在 Swap Cache 中分配一个新的 Folio（页面）。
*   如果 Folio 已经存在（`!folio_was_allocated`），说明发生了竞争（例如页面刚被 Swap In），此时放弃写回（返回 `-EEXIST`）。

### 4.2. 验证 Entry 有效性 (Race Check)

```c
tree = swap_zswap_tree(swpentry);
if (entry != xa_load(tree, offset)) {
    ret = -ENOMEM;
    goto out;
}
```

*   在分配并锁定 Folio 后，必须再次验证 `zswap_entry` 是否仍然有效。
*   通过 `xa_load` 从 XArray 中查找该 `swpentry` 对应的 entry。如果查到的 entry 与传入的指针不一致，说明在释放 LRU 锁期间，该 entry 已经被释放或替换，必须终止操作。

### 4.3. 解压数据

```c
if (!zswap_decompress(entry, folio)) {
    ret = -EIO;
    goto out;
}
```

*   调用 `zswap_decompress` 将压缩数据解压到新分配的 Folio 中。

### 4.4. 释放 Zswap Entry 并触发 Writeback

```c
xa_erase(tree, offset);
zswap_entry_free(entry);

folio_mark_uptodate(folio);
folio_set_reclaim(folio);
__swap_writepage(folio, NULL);
```

*   **从树中移除**: 使用 `xa_erase` 将 entry 从 XArray 中移除。
*   **释放内存**: 调用 `zswap_entry_free` 释放 zswap 占用的内存。
*   **标记页面**: 将 Folio 标记为最新（Uptodate）并设置回收标记（Reclaim）。
*   **写入磁盘**: 调用 `__swap_writepage` 将解压后的 Folio 写入实际的 Swap 设备。

## 5. 总结

`shrink_memcg` 及其辅助函数构建了一个健壮的内存回收路径：

1.  **细粒度控制**: 每次只回收一个页面，避免长时间持有锁。
2.  **活跃度保护**: 通过 `referenced` 位保护活跃页面不被过早回收。
3.  **并发安全**: 在复杂的锁操作（LRU 锁、Folio 锁）和并发场景（Swap In 竞争、Entry 失效）中，通过严格的检查顺序（Check-Lock-Check）保证了数据一致性。
4.  **资源隔离**: 严格遵循 Memcg 的配置，确保只回收允许写回的 Cgroup 内存。