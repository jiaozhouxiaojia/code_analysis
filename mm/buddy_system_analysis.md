# 伙伴系统（Buddy System）物理页来源及管理大小分析

本文结合 Linux 内核代码（基于 v6.x 版本），分析伙伴系统管理的物理页来源、管理大小的计算方式，以及用户态如何获取这些信息。

## 1. 物理页的来源：从 Memblock 到 Buddy System

在 Linux 内核启动的早期阶段，内存管理是由 **Memblock** 分配器负责的。伙伴系统（Buddy System）接管内存管理发生在系统初始化的后期。

### 1.1 移交过程

物理页从 Memblock 移交给伙伴系统的核心函数是 `memblock_free_all()`，定义在 `mm/memblock.c` 中。

```c
// mm/memblock.c

void __init memblock_free_all(void)
{
    unsigned long pages;

    free_unused_memmap();
    reset_all_zones_managed_pages(); // 重置所有 Zone 的 managed_pages 计数

    memblock_clear_kho_scratch_only();
    pages = free_low_memory_core_early(); // 核心移交逻辑
    totalram_pages_add(pages);
}
```

### 1.2 核心调用链

移交过程的调用链如下：

1.  **`memblock_free_all()`**: 入口函数。
2.  **`free_low_memory_core_early()`**: 遍历 Memblock 中所有标记为 `free` 的内存范围。
    *   使用 `for_each_free_mem_range` 宏遍历。
3.  **`__free_memory_core(start, end)`**: 处理具体的内存范围。
4.  **`memblock_free_pages(page, start, order)`**: 计算页面的阶数（order），准备释放。
5.  **`__free_pages_core(page, order)`**: 定义在 `mm/page_alloc.c`，这是实际将页面释放给伙伴系统的函数。

在 `__free_pages_core` 中，内核会执行以下关键操作：
*   清除页面的 `PageReserved` 标志（Memblock 管理的页面通常被标记为保留）。
*   将页面的引用计数（refcount）设置为 0。
*   更新统计信息（`managed_pages` 和 `totalram_pages`）。

## 2. 物理页总大小的计算：`managed_pages`

伙伴系统管理的物理页总大小并不是一个简单的静态值，而是通过 `struct zone` 结构体中的 `managed_pages` 字段来动态统计的。

### 2.1 `struct zone` 定义

在 `include/linux/mmzone.h` 中，`struct zone` 定义了内存区域的管理结构：

```c
// include/linux/mmzone.h

struct zone {
    /* ... */
    /*
     * managed_pages is present pages managed by the buddy system, which
     * is calculated as (reserved_pages includes pages allocated by the
     * bootmem allocator):
     *	managed_pages = present_pages - reserved_pages;
     */
    atomic_long_t		managed_pages;
    /* ... */
};
```

*   **`present_pages`**: 该 Zone 物理地址范围内实际存在的物理页数量（扣除了物理内存空洞）。
*   **`managed_pages`**: 伙伴系统实际管理的页面数量。
    *   计算公式：`managed_pages = present_pages - reserved_pages`
    *   这里的 `reserved_pages` 包括内核代码段、静态数据段、以及在 Memblock 阶段分配出去且没有释放的内存。

### 2.2 动态计算过程

`managed_pages` 的值是在内存移交过程中动态累加计算出来的：

1.  **初始化清零**：
    在 `memblock_free_all()` 开始时，调用 `reset_all_zones_managed_pages()` 将所有 Zone 的 `managed_pages` 设置为 0。

2.  **动态累加**：
    当 `__free_pages_core()` 将页面释放给伙伴系统时，会增加该计数：

    ```c
    // mm/page_alloc.c

    void __meminit __free_pages_core(struct page *page, unsigned int order,
            enum meminit_context context)
    {
        unsigned int nr_pages = 1 << order;
        // ... 清除保留标志等操作 ...

        /* memblock adjusts totalram_pages() manually. */
        atomic_long_add(nr_pages, &page_zone(page)->managed_pages); // <--- 累加 managed_pages
    }
    ```

## 3. 用户态如何知道 Buddy 管理的内存大小

用户态可以通过 `/proc` 文件系统查看伙伴系统的状态。

### 3.1 `/proc/zoneinfo`

这是查看 `managed_pages` 最直接的方式。该文件展示了每个 Zone 的详细信息。

```bash
cat /proc/zoneinfo
```

输出示例片段：
```text
Node 0, zone    DMA32
  pages free     3587
        min      1126
        low      1407
        high     1688
        spanned  1044480
        present  786432
        managed  762172  <--- 这里就是该 Zone 伙伴系统管理的页面总数
```

内核实现位于 `mm/vmstat.c` 中的 `zoneinfo_show_print` 函数：
```c
seq_printf(m, "\n        managed  %lu", zone_managed_pages(zone));
```

### 3.2 `/proc/buddyinfo`

该文件展示了伙伴系统中**当前空闲**的页面分布情况（按 Order 分类），而不是管理的总大小。

```bash
cat /proc/buddyinfo
```

输出示例：
```text
Node 0, zone    DMA32    100    50    20 ... (不同 order 的空闲页数)
```

## 4. `totalram_pages` 与 `managed_pages` 的区别

在内核代码中，经常会看到 `totalram_pages` 和 `managed_pages`。

### 4.1 定义区别

*   **`managed_pages`**:
    *   **粒度**：Per-Zone（每个内存区域独立统计）。
    *   **含义**：该特定 Zone 中由伙伴系统管理的物理页数量。
    *   **位置**：`struct zone` 结构体成员。

*   **`totalram_pages`**:
    *   **粒度**：Global（全局统计）。
    *   **含义**：系统中所有可用物理内存的总页数。
    *   **位置**：`mm/show_mem.c` 中的全局原子变量 `_totalram_pages`，通过 `totalram_pages()` 函数访问。

### 4.2 关系与联系

通常情况下，`totalram_pages` 等于系统中所有 Zone 的 `managed_pages` 之和。

在内存初始化阶段（`memblock_free_all`），两者是同步更新的：

```c
// mm/memblock.c
void __init memblock_free_all(void)
{
    // ...
    pages = free_low_memory_core_early(); // 内部调用 __free_pages_core 增加 managed_pages
    totalram_pages_add(pages);            // 显式增加 totalram_pages
}
```

在 `__free_pages_core` 中：
```c
// mm/page_alloc.c
void __meminit __free_pages_core(...)
{
    // ...
    atomic_long_add(nr_pages, &page_zone(page)->managed_pages); // 更新 Zone 计数
    // 注意：这里通常不直接更新 totalram_pages，而是由调用者（如 memblock_free_all）批量更新，
    // 或者在热插拔路径中由特定函数更新。
}
```

**总结**：
*   如果你关心某个特定内存区域（如 DMA, Normal）的容量，看 `zone->managed_pages`。
*   如果你关心整个系统的可用内存总量，看 `totalram_pages()`。
*   用户态通过 `/proc/meminfo` 中的 `MemTotal` 看到的通常是基于 `totalram_pages` 计算转换而来的（单位 KB）。