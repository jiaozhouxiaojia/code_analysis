# shrinker_register() 函数深度分析

`shrinker_register()` 是 Linux 内核中用于激活内存回收器（Shrinker）的关键函数。它将一个已经分配并配置好的 `struct shrinker` 实例加入到内核的全局回收机制中。

## 1. 函数源码

位于 `mm/shrinker.c`:

```c
void shrinker_register(struct shrinker *shrinker)
{
    if (unlikely(!(shrinker->flags & SHRINKER_ALLOCATED))) {
        pr_warn("Must use shrinker_alloc() to dynamically allocate the shrinker");
        return;
    }

    mutex_lock(&shrinker_mutex);
    list_add_tail_rcu(&shrinker->list, &shrinker_list);
    shrinker->flags |= SHRINKER_REGISTERED;
    shrinker_debugfs_add(shrinker);
    mutex_unlock(&shrinker_mutex);

    init_completion(&shrinker->done);
    /*
     * Now the shrinker is fully set up, take the first reference to it to
     * indicate that lookup operations are now allowed to use it via
     * shrinker_try_get().
     */
    refcount_set(&shrinker->refcount, 1);
}
```

## 2. 详细逻辑解析

### 2.1. 强制动态分配检查
```c
if (unlikely(!(shrinker->flags & SHRINKER_ALLOCATED)))
```
*   **背景**: 在旧版本内核中，`struct shrinker` 可以静态定义或嵌入在其他结构体中。这导致了生命周期管理的复杂性，特别是在模块卸载或结构体释放时，很难确保没有并发的回收器正在使用它。
*   **现状**: 现代内核强制要求使用 `shrinker_alloc()` 动态分配 Shrinker。该函数会设置 `SHRINKER_ALLOCATED` 标志。
*   **检查**: 这里检查该标志，如果未设置，则发出警告并拒绝注册。这确保了所有注册的 Shrinker 都遵循统一的生命周期管理规则。

### 2.2. 全局链表操作 (RCU)
```c
mutex_lock(&shrinker_mutex);
list_add_tail_rcu(&shrinker->list, &shrinker_list);
...
mutex_unlock(&shrinker_mutex);
```
*   **`shrinker_mutex`**: 这是一个全局互斥锁，用于保护对 `shrinker_list` 的**写操作**（添加和删除）。
*   **`list_add_tail_rcu`**: 关键点在于使用了 **RCU (Read-Copy-Update)** 版本的链表添加函数。
    *   **意义**: 这允许内存回收路径（`shrink_slab`）在**不持有任何锁**的情况下并发遍历 `shrinker_list`。
    *   **性能**: 内存回收是一个高频且对延迟敏感的操作。使用 RCU 避免了锁竞争，极大地提高了系统在内存压力下的性能。

### 2.3. 状态标记与 Debugfs
```c
shrinker->flags |= SHRINKER_REGISTERED;
shrinker_debugfs_add(shrinker);
```
*   **`SHRINKER_REGISTERED`**: 标记该 Shrinker 已处于活动状态。这用于防止重复注册，并在注销时进行校验。
*   **Debugfs**: 在 `/sys/kernel/debug/shrinker/` 下创建对应的目录和文件。这为开发者和管理员提供了观察 Shrinker 行为（如扫描计数、对象数量）的窗口。

### 2.4. 引用计数与生命周期管理
```c
init_completion(&shrinker->done);
refcount_set(&shrinker->refcount, 1);
```
这是 Shrinker 机制中最精妙的部分之一，用于解决并发销毁问题。

*   **`refcount` 初始化为 1**: 这个初始引用代表“注册状态”。只要这个引用存在，说明 Shrinker 是注册且有效的。
*   **并发保护**: 当内核需要使用 Shrinker 时（例如在 `do_shrink_slab` 中），它会调用 `shrinker_try_get()` 尝试增加引用计数。
    *   如果引用计数 > 0，成功增加，可以安全使用。
    *   如果引用计数 == 0（说明正在注销），失败，跳过该 Shrinker。
*   **注销流程**: 当调用 `shrinker_free()` 时，会递减这个初始引用。当引用计数降为 0 时，通过 RCU 回调最终释放内存。
*   **`completion`**: 用于在注销过程中等待所有正在进行的并发操作完成。

## 3. 总结

`shrinker_register` 不仅仅是一个简单的链表添加操作，它构建了一个**并发安全**、**可观测**且**生命周期严谨**的内存回收框架。通过强制动态分配和 RCU 机制，它解决了长期困扰内核开发者的 Shrinker 并发失效（Use-after-free）问题。