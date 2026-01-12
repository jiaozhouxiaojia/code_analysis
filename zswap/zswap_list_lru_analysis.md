# zswap_list_lru 实现与原理深度分析

`zswap_list_lru` 是 Linux 内核 zswap 子系统中用于管理可回收页面（Reclaimable Pages）的核心数据结构。它是一个全局的 `list_lru` 实例，充当了 zswap 存储池与内核内存回收机制（Shrinker）之间的桥梁。

## 1. 定义与初始化

### 1.1. 静态定义
在 `mm/zswap.c` 中：
```c
static struct list_lru zswap_list_lru;
```
这是一个静态全局变量，意味着系统中所有的 zswap pool（即使有多个 swap 设备）都共享同一个 LRU 管理机制。

### 1.2. 初始化
在 `zswap_init()` 函数中：
```c
if (list_lru_init_memcg(&zswap_list_lru, zswap_shrinker))
    goto lru_fail;
```
*   **Memcg 感知**: 使用 `list_lru_init_memcg` 初始化，表明它支持 Memory Cgroup。这意味着不同 Cgroup 的 zswap 页面会被隔离在不同的 LRU 链表中。
*   **绑定 Shrinker**: 传入 `zswap_shrinker`，建立了 LRU 与 zswap 回收器的关联。

## 2. 核心机制：Memcg 感知的动态管理

虽然 `zswap_list_lru` 是一个全局变量，但它内部通过 `list_lru` 的机制实现了精细的资源隔离。

### 2.1. 动态分配 (Lazy Allocation)
在 `zswap_store()`（页面存储路径）中：
```c
if (objcg) {
    memcg = get_mem_cgroup_from_objcg(objcg);
    if (memcg_list_lru_alloc(memcg, &zswap_list_lru, GFP_KERNEL))
        ...
}
```
*   **按需分配**: 内核不会预先为所有 Cgroup 分配 LRU 内存。只有当某个 Cgroup 首次尝试向 zswap 存储页面时，才会调用 `memcg_list_lru_alloc`。
*   **祖先链分配**: `memcg_list_lru_alloc` 不仅分配当前 Cgroup 的 LRU 结构，还会确保其所有**祖先 Cgroup** 的 LRU 结构都已分配。这是为了支持 **Reparenting**（当子 Cgroup 销毁时，其页面会迁移到父 Cgroup 的 LRU）。

### 2.2. 数据结构 (XArray)
底层使用 XArray (`lru->xa`) 来存储每个 Memcg 的 LRU 链表头 (`list_lru_memcg`)。索引是 Memcg 的 ID。

## 3. 操作流程

### 3.1. 添加 (zswap_lru_add)
当页面成功压缩并存储后：
```c
zswap_lru_add(&zswap_list_lru, entry);
```
该函数会根据 entry 所属的 `objcg` 和 NUMA 节点，将其添加到对应的 LRU 链表中。

### 3.2. 删除 (zswap_lru_del)
当页面被 Swap In（读取）、失效或写回时：
```c
zswap_lru_del(&zswap_list_lru, entry);
```
从 LRU 中移除。

### 3.3. 回收 (shrink_memcg)
当内存紧张时，Shrinker 触发回收：
```c
list_lru_shrink_walk(&zswap_list_lru, sc, &shrink_memcg_cb, ...);
```
*   **定向回收**: `sc->memcg` 指定了要回收的 Cgroup。`list_lru` 机制会根据这个参数，只遍历该 Cgroup 对应的 LRU 链表。
*   **全局回收**: 如果 `sc->memcg` 为 NULL，则遍历所有 Cgroup 的 LRU。

## 4. 总结

`zswap_list_lru` 的设计体现了 Linux 内核在**全局管理**与**资源隔离**之间的平衡：
1.  **统一接口**: 对上层（zswap）提供统一的全局 LRU 接口，简化了代码逻辑。
2.  **物理隔离**: 内部通过 Memcg ID 和 XArray 实现了物理上的链表隔离，确保一个 Cgroup 的活动不会影响其他 Cgroup 的 LRU 顺序。
3.  **动态扩展**: 利用 `memcg_list_lru_alloc` 实现按需分配，极大地节省了内存开销，适应了容器化环境下的高密度 Cgroup 场景。