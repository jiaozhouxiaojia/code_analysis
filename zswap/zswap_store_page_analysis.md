# zswap_store_page() 函数深度分析

`zswap_store_page()` 是 Linux 内核 `mm/zswap.c` 中的核心函数之一，负责将一个内存页面（Page）压缩并存储到 zswap 池（zswap pool）中。它是 zswap 前端（Frontswap）接口的关键实现，用于拦截交换（Swap）操作，尝试将页面压缩存储在 RAM 中，从而减少对物理 Swap 设备的 I/O 操作。

## 1. 函数签名与参数

```c
static bool zswap_store_page(struct page *page,
                             struct obj_cgroup *objcg,
                             struct zswap_pool *pool)
```

*   **`page`**: 需要被 Swap Out 的物理页面。
*   **`objcg`**: 该页面所属的 Object Cgroup（用于内存计费和限制）。
*   **`pool`**: 目标 zswap 内存池，用于存储压缩后的数据。
*   **返回值**: `true` 表示存储成功，`false` 表示失败（失败后内核将继续执行常规 Swap 流程）。

## 2. 核心流程详解

该函数的执行流程可以分为以下几个关键步骤：

### 2.1. 初始化与 Entry 分配

```c
swp_entry_t page_swpentry = page_swap_entry(page);
struct zswap_entry *entry, *old;

/* allocate entry */
entry = zswap_entry_cache_alloc(GFP_KERNEL, page_to_nid(page));
if (!entry) {
    zswap_reject_kmemcache_fail++;
    return false;
}
```

*   首先获取页面对应的 Swap Entry 信息。
*   从 `zswap_entry_cache`（一个 `kmem_cache`）中分配一个新的 `zswap_entry` 结构体。
*   如果分配失败，增加 `zswap_reject_kmemcache_fail` 计数并返回失败。

### 2.2. 页面压缩 (zswap_compress)

```c
if (!zswap_compress(page, entry, pool))
    goto compress_failed;
```

调用 `zswap_compress` 函数尝试压缩页面数据。这个函数内部逻辑复杂，主要包括：
1.  获取每 CPU 的压缩上下文 (`acomp_ctx`)。
2.  调用 Crypto API 进行压缩。
3.  **压缩率检查**: 如果压缩后的数据大小 (`dlen`) 不小于 `PAGE_SIZE`，或者压缩失败：
    *   如果启用了 writeback，则直接存储未压缩的数据（为了保持 LRU 顺序）。
    *   如果未启用 writeback，则拒绝存储（因为没有节省空间且增加了元数据开销）。
4.  **内存分配**: 使用 `zs_malloc` 从 `zsmalloc` 分配器中分配内存来存储压缩数据。
5.  **数据写入**: 使用 `zs_obj_write` 将数据写入分配的内存。

### 2.3. 存储到 XArray (并发控制关键点)

```c
old = xa_store(swap_zswap_tree(page_swpentry),
               swp_offset(page_swpentry),
               entry, GFP_KERNEL);
if (xa_is_err(old)) {
    int err = xa_err(old);
    WARN_ONCE(err != -ENOMEM, "unexpected xarray error: %d\n", err);
    zswap_reject_alloc_fail++;
    goto store_failed;
}
```

*   使用 `xa_store` 将新的 `entry` 存储到全局的 `zswap_trees` (XArray) 中。
*   **原子性与旧数据**: `xa_store` 会原子地替换指定索引处的值，并返回旧值（如果存在）。
*   **错误处理**: 如果 `xa_store` 返回错误（如 `-ENOMEM`），则回滚操作。

### 2.4. 清理旧 Entry (Stale Entry Handling)

```c
/*
 * We may have had an existing entry that became stale when
 * the folio was redirtied and now the new version is being
 * swapped out. Get rid of the old.
 */
if (old)
    zswap_entry_free(old);
```

*   如果 `xa_store` 返回了非空的 `old` 指针，说明该 Swap Entry 之前已经有数据在 zswap 中。
*   这种情况通常发生在页面被 Swap Out 后又被读入（Swap In），修改（Redirtied），然后再次 Swap Out。此时旧的 zswap 数据已过时，必须释放。

### 2.5. 资源引用与计费 (Charging)

```c
zswap_pool_get(pool);
if (objcg) {
    obj_cgroup_get(objcg);
    obj_cgroup_charge_zswap(objcg, entry->length);
}
atomic_long_inc(&zswap_stored_pages);
if (entry->length == PAGE_SIZE)
    atomic_long_inc(&zswap_stored_incompressible_pages);
```

*   **Pool 引用**: 增加 `zswap_pool` 的引用计数，防止在使用过程中被释放。
*   **Cgroup 计费**: 如果关联了 `objcg`，增加其引用并进行 zswap 内存计费 (`obj_cgroup_charge_zswap`)。这是限制容器 zswap 使用量的关键。
*   **统计**: 更新全局统计信息 `zswap_stored_pages`。

### 2.6. 完成初始化与加入 LRU

```c
entry->pool = pool;
entry->swpentry = page_swpentry;
entry->objcg = objcg;
entry->referenced = true;
if (entry->length) {
    INIT_LIST_HEAD(&entry->lru);
    zswap_lru_add(&zswap_list_lru, entry);
}

return true;
```

*   填充 `entry` 的剩余字段。
*   **LRU 管理**: 调用 `zswap_lru_add` 将 `entry` 加入到全局的 LRU 链表 (`zswap_list_lru`)。这个 LRU 链表用于后续的 zswap 收缩（Shrink）和写回（Writeback）机制。
*   **安全性注释**: 代码注释提到，此时完成初始化是安全的，因为：
    1.  并发存储和失效被 Folio Lock 互斥。
    2.  Writeback 逻辑在 Entry 加入 LRU 之前无法看到它。

### 2.7. 错误处理路径

```c
store_failed:
    zs_free(pool->zs_pool, entry->handle);
compress_failed:
    zswap_entry_cache_free(entry);
    return false;
```

*   如果存储到 XArray 失败，释放 `zsmalloc` 分配的内存。
*   如果压缩失败（或存储失败），释放 `zswap_entry` 结构体。

## 3. 关键设计与机制分析

### 3.1. 乐观压缩策略
Zswap 采用“先压缩，后存储”的策略。虽然这可能导致压缩后发现无法存储（例如内存不足），但它避免了持有锁进行耗时的压缩操作。

### 3.2. 与 Cgroup 的深度集成
函数显式处理 `obj_cgroup`，确保 zswap 的使用被正确计费到相应的 Cgroup。这对于容器环境下的资源隔离至关重要。如果 Cgroup 的 zswap 限制已达到，上层调用者（`zswap_store`）会触发收缩（Shrink）操作。

### 3.3. 并发控制
*   **Folio Lock**: 保证了对同一个页面的并发操作是互斥的。
*   **XArray**: 提供了高效的、支持并发的索引结构，用于通过 Swap Entry 查找 zswap 数据。
*   **Per-CPU Compression**: `zswap_compress` 使用每 CPU 的压缩上下文，避免了锁竞争，提高了多核下的吞吐量。

### 3.4. 拒绝策略 (Rejection)
函数中有多个拒绝点（Rejection Points），并维护了相应的统计计数（如 `zswap_reject_compress_poor`, `zswap_reject_alloc_fail`）。这些统计对于系统调优和故障排查非常有价值。

## 4. 总结

`zswap_store_page` 是一个高度优化的内存存储路径，它巧妙地结合了压缩技术、内存分配器（zsmalloc）和内核的数据结构（XArray, LRU）。它不仅要处理数据的存储，还要兼顾内存计费、并发安全以及与现有 Swap 机制的兼容性。通过对旧数据的自动清理和完善的错误处理，它保证了系统的稳定性和数据的一致性。