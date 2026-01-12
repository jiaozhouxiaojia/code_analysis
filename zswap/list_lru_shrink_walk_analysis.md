# list_lru_shrink_walk() 函数深度分析

`list_lru_shrink_walk()` 是 Linux 内核中用于遍历和收缩 LRU (Least Recently Used) 列表的通用接口。它主要被内存回收机制（如 Shrinker）使用，用于从特定的 Memory Cgroup (memcg) 和 NUMA 节点中回收对象。

## 1. 函数定义与调用链

该函数定义在 `include/linux/list_lru.h` 中，是一个内联包装函数：

```c
static inline unsigned long
list_lru_shrink_walk(struct list_lru *lru, struct shrink_control *sc,
                     list_lru_walk_cb isolate, void *cb_arg)
{
    return list_lru_walk_one(lru, sc->nid, sc->memcg, isolate, cb_arg,
                             &sc->nr_to_scan);
}
```

它将 `shrink_control` 结构体解包，并调用 `list_lru_walk_one`。最终，核心逻辑由 `mm/list_lru.c` 中的 `__list_lru_walk_one` 实现。

## 2. 核心逻辑：__list_lru_walk_one()

这是实际执行遍历和收缩的函数。

```c
static unsigned long
__list_lru_walk_one(struct list_lru *lru, int nid, struct mem_cgroup *memcg,
                    list_lru_walk_cb isolate, void *cb_arg,
                    unsigned long *nr_to_walk, bool irq_off)
```

### 2.1. 锁获取与 Memcg 定位

```c
l = lock_list_lru_of_memcg(lru, nid, memcg, irq_off, true);
if (!l)
    return isolated;
```

*   **多级索引**: `list_lru` 结构体支持基于 NUMA 节点和 Memcg 的双重索引。
*   **`lock_list_lru_of_memcg`**: 该函数负责查找对应的 `list_lru_one`（实际的链表头）并获取其自旋锁（Spinlock）。
*   **RCU 保护**: 在查找 memcg 对应的 LRU 时，使用 `rcu_read_lock` 保护，防止 memcg 在查找过程中被释放。

### 2.2. 链表遍历与计数控制

```c
list_for_each_safe(item, n, &l->list) {
    if (!*nr_to_walk)
        break;
    --*nr_to_walk;
    ...
}
```

*   使用 `list_for_each_safe` 安全地遍历链表，允许在遍历过程中删除当前元素。
*   **`nr_to_walk`**: 控制遍历的步数。这对于控制回收的粒度和延迟至关重要（例如 zswap 每次只回收 1 个页面）。

### 2.3. 回调调用与状态处理

```c
ret = isolate(item, l, cb_arg);
switch (ret) {
    case LRU_RETRY:
        goto restart;
    case LRU_REMOVED:
        isolated++;
        atomic_long_dec(&nlru->nr_items);
        break;
    case LRU_ROTATE:
        list_move_tail(item, &l->list);
        break;
    ...
}
```

*   **`isolate` 回调**: 对每个元素调用用户提供的回调函数（如 zswap 的 `shrink_memcg_cb`）。
*   **返回值处理**:
    *   **`LRU_RETRY`**: 回调函数释放了锁并请求重试。此时必须跳转到 `restart` 重新获取锁并重新开始遍历。这是处理复杂并发场景（如需要睡眠的操作）的关键机制。
    *   **`LRU_REMOVED`**: 元素被成功移除（回收）。更新计数器。
    *   **`LRU_ROTATE`**: 元素被移动到 LRU 尾部（例如二次机会算法）。
    *   **`LRU_STOP`**: 停止遍历。

### 2.4. 锁释放与重试机制

```c
restart:
    l = lock_list_lru_of_memcg(...);
    ...
    list_for_each_safe(...) {
        ...
        case LRU_RETRY:
            goto restart;
    }
    unlock_list_lru(l, irq_off);
```

*   **锁的粒度**: 锁只在遍历期间持有。如果回调函数需要执行耗时操作（如写回磁盘），它通常会释放锁，返回 `LRU_RETRY`，然后 `__list_lru_walk_one` 会重新获取锁。
*   **避免死锁**: 这种“释放-重获”机制避免了长时间持有自旋锁，减少了对系统其他部分的阻塞。

## 3. 并发与 Memcg Reparenting

在 `lock_list_lru_of_memcg` 中，有一个微妙的处理逻辑：

```c
l = list_lru_from_memcg_idx(lru, nid, memcg_kmem_id(memcg));
```

*   当一个 Memcg 被删除（Offline）时，它的 LRU 列表会被“Reparent”到父级 Memcg。
*   `list_lru` 机制必须能够处理这种动态变化，确保即使在 Memcg 正在销毁的过程中，也能正确地找到并锁定对应的 LRU 列表。

## 4. 总结

`list_lru_shrink_walk` 提供了一个高效、并发安全的框架，用于管理内核中的各种 LRU 缓存（如 Dentry Cache, Inode Cache, Zswap）。它通过回调机制将通用的 LRU 管理逻辑与具体的回收策略解耦，使得内核子系统可以轻松实现复杂的内存回收逻辑。