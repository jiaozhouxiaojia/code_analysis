# memcg_list_lrus 作用与实现深度分析

`memcg_list_lrus` 是 Linux 内核内存管理子系统中的一个关键全局数据结构，用于维护所有支持 Memory Cgroup (memcg) 的 LRU 列表。它在 Cgroup 销毁和对象迁移（Reparenting）过程中起着至关重要的作用。

## 1. 定义与数据结构

在 `mm/list_lru.c` 中定义：

```c
static LIST_HEAD(memcg_list_lrus);
static DEFINE_MUTEX(list_lrus_mutex);
```

*   **`memcg_list_lrus`**: 一个标准的内核双向链表头。它链接了系统中所有设置了 `memcg_aware` 标志的 `struct list_lru` 实例（例如 dentry LRU, inode LRU, zswap LRU 等）。
*   **`list_lrus_mutex`**: 用于保护该链表的互斥锁，确保注册和注销操作的线程安全。

## 2. 注册与注销

当一个子系统（如 zswap）初始化其 LRU 时，如果启用了 memcg 感知，该 LRU 会被自动添加到 `memcg_list_lrus` 中。

### 2.1. 注册 (list_lru_register)
```c
static void list_lru_register(struct list_lru *lru)
{
    if (!list_lru_memcg_aware(lru))
        return;

    mutex_lock(&list_lrus_mutex);
    list_add(&lru->list, &memcg_list_lrus);
    mutex_unlock(&list_lrus_mutex);
}
```
只有 `memcg_aware` 为真的 LRU 才会被加入链表。

### 2.2. 注销 (list_lru_unregister)
当 LRU 被销毁时，将其从链表中移除。

## 3. 核心作用：Memcg Reparenting

`memcg_list_lrus` 的存在主要是为了支持 **Reparenting** 机制。当一个 Memory Cgroup 被删除（Offline）时，其内部的对象（如 dentry, inode, zswap pages）不能直接丢弃，而必须迁移到其父 Cgroup 中继续管理。

### 3.1. 触发流程
当 memcg 销毁时，内核调用 `memcg_reparent_list_lrus(memcg, parent)`。

### 3.2. 遍历与迁移
该函数遍历 `memcg_list_lrus` 链表，对系统中的每一个 memcg 感知的 LRU 执行以下操作：

1.  **查找数据**: 使用 memcg ID 在 LRU 的 XArray 中找到对应的 `list_lru_memcg` 结构。
2.  **原子移除**: 从 XArray 中移除该结构（设置为 NULL），防止后续的新分配。
3.  **对象迁移**: 调用 `memcg_reparent_list_lru_one`，将该 memcg 在所有 NUMA 节点上的链表拼接到父 memcg 的对应链表尾部。
    *   这是一个高效的 O(1) 操作（链表拼接），不需要逐个移动元素。
    *   同时更新计数器（`nr_items`）。
4.  **资源释放**: 使用 RCU 释放 `list_lru_memcg` 结构体内存。

## 4. 总结

`memcg_list_lrus` 充当了内核中所有 Memcg LRU 的**全局注册表**。它使得内核在处理 Cgroup 销毁这一复杂事件时，能够统一地找到并处理分散在各个子系统（VFS, Zswap 等）中的 LRU 数据，确保对象能够正确地迁移到父 Cgroup，避免了内存泄漏和资源管理混乱。