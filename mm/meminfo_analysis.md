# meminfo_proc_show() 函数分析与 /proc/meminfo 输出详解

本文档详细分析了 Linux 内核中 `fs/proc/meminfo.c` 文件内的 `meminfo_proc_show()` 函数实现，并结合代码与文档解释了 `/proc/meminfo` 输出中每一行的具体含义。

## 1. meminfo_proc_show() 函数实现分析

`meminfo_proc_show` 是 `/proc/meminfo` 文件的 `show` 回调函数，当用户读取该文件时被调用。其主要流程如下：

### 1.1 数据采集

函数首先声明并初始化了一些局部变量，用于存储内存统计信息：

```c
struct sysinfo i;
unsigned long committed;
long cached;
long available;
unsigned long pages[NR_LRU_LISTS];
unsigned long sreclaimable, sunreclaim;
int lru;
```

接着调用核心函数获取系统级别的内存信息：

*   **`si_meminfo(&i)`**: 获取基础内存信息（总量、空闲、共享、缓冲等），填充到 `struct sysinfo` 结构体中。
*   **`si_swapinfo(&i)`**: 获取交换分区（Swap）信息，填充到 `struct sysinfo` 中。
*   **`vm_memory_committed()`**: 计算当前系统已提交（Committed）的虚拟内存量。
*   **`global_node_page_state(item)`**: 获取全局的节点页面状态，例如 LRU 链表上的页面数量、脏页数量、回写页数量等。
*   **`si_mem_available()`**: 估算“可用”内存（MemAvailable），这是一个复杂的估算值，旨在反映在不进行交换的情况下，应用程序可以使用的内存量。

### 1.2 关键数值计算

部分输出字段并非直接读取计数器，而是经过计算得出：

*   **Cached (页缓存)**:
    ```c
    cached = global_node_page_state(NR_FILE_PAGES) -
             total_swapcache_pages() - i.bufferram;
    if (cached < 0) cached = 0;
    ```
    这里 `Cached` 统计的是文件页缓存的大小，但排除了 SwapCache 和 Buffers。`NR_FILE_PAGES` 包含了所有文件映射页、SwapCache 和 Buffers，因此需要减去后两者。

*   **Slab 分类**:
    ```c
    sreclaimable = global_node_page_state_pages(NR_SLAB_RECLAIMABLE_B);
    sunreclaim = global_node_page_state_pages(NR_SLAB_UNRECLAIMABLE_B);
    ```
    分别获取可回收（Reclaimable）和不可回收（Unreclaimable）的 Slab 内存大小。

### 1.3 输出格式化

函数使用 `show_val_kb` 辅助函数将页面数转换为 kB（千字节）并输出。

```c
static void show_val_kb(struct seq_file *m, const char *s, unsigned long num)
{
    seq_put_decimal_ull_width(m, s, num << (PAGE_SHIFT - 10), 8);
    seq_write(m, " kB\n", 4);
}
```
注意：内核内部通常以“页（Page）”为单位存储内存大小，输出时通过 `<< (PAGE_SHIFT - 10)` 转换为 kB（假设页大小 >= 1KB）。

---

## 2. 核心函数深入分析

### 2.1 si_meminfo() 实现

`si_meminfo` 定义在 `mm/show_mem.c` 中，负责填充 `struct sysinfo` 的内存部分。

```c
void si_meminfo(struct sysinfo *val)
{
    val->totalram = totalram_pages();
    val->sharedram = global_node_page_state(NR_SHMEM);
    val->freeram = global_zone_page_state(NR_FREE_PAGES);
    val->bufferram = nr_blockdev_pages();
    val->totalhigh = totalhigh_pages();
    val->freehigh = nr_free_highpages();
    val->mem_unit = PAGE_SIZE;
}
```

*   **`totalram`**: 调用 `totalram_pages()`，读取原子变量 `_totalram_pages`。
*   **`freeram`**: 调用 `global_zone_page_state(NR_FREE_PAGES)`，汇总所有 Zone 的空闲页数。
*   **`sharedram`**: 读取 `NR_SHMEM` 计数器（tmpfs 和共享内存）。
*   **`bufferram`**: 统计块设备的缓冲页。

### 2.2 si_swapinfo() 实现

`si_swapinfo` 定义在 `mm/swapfile.c` 中，负责统计 Swap 使用情况。

```c
void si_swapinfo(struct sysinfo *val)
{
    // ... 遍历 swap_info 数组 ...
    val->freeswap = atomic_long_read(&nr_swap_pages) + nr_to_be_unused;
    val->totalswap = total_swap_pages + nr_to_be_unused;
}
```

*   **`totalswap`**: 全局变量 `total_swap_pages`，表示所有激活 Swap 分区的总页数。
*   **`freeswap`**: 原子变量 `nr_swap_pages`，表示当前剩余的 Swap 页数。
*   **`nr_to_be_unused`**: 处理正在执行 `swapoff` 操作但尚未完全关闭的 Swap 分区，将其统计在内以保持数据一致性。

### 2.3 si_mem_available() 实现

`si_mem_available` 定义在 `mm/show_mem.c` 中，用于计算 `MemAvailable`。这是一个估算值，逻辑如下：

1.  **基础值**: `NR_FREE_PAGES`（空闲页）减去 `totalreserve_pages`（内核保留页，如低端内存保留）。
    ```c
    available = global_zone_page_state(NR_FREE_PAGES) - totalreserve_pages;
    ```

2.  **加上可回收的 Page Cache**:
    *   统计 `Active(file)` + `Inactive(file)`。
    *   **保守扣除**: 假设至少有一半的 Page Cache 或者 `wmark_low`（低水位线）数量的内存是不能被回收的（为了防止系统颠簸）。
    ```c
    pagecache -= min(pagecache / 2, wmark_low);
    available += pagecache;
    ```

3.  **加上可回收的 Slab**:
    *   统计 `SReclaimable`。
    *   **保守扣除**: 减去 `min(slab / 2, wmark_low)`。
    ```c
    reclaimable -= min(reclaimable / 2, wmark_low);
    available += reclaimable;
    ```

### 2.4 关键统计原理

#### _totalram_pages 的统计
`_totalram_pages` 是一个 `atomic_long_t` 类型的全局变量（定义在 `mm/show_mem.c`）。它代表了内核“管理”的物理内存总量。

**初始化流程**:
1.  **`free_area_init()` (mm/mm_init.c)**:
    *   初始化 Zone 数据结构、Free Lists 和 Migratetypes。
    *   计算每个 Zone 的 `managed_pages`（受管页数），但此时物理页尚未真正释放给伙伴系统。
2.  **`memblock_free_all()` (mm/memblock.c)**:
    *   这是内存初始化的关键步骤，负责将 Memblock 管理的空闲内存释放给伙伴系统。
    *   调用 `free_low_memory_core_early()`，遍历 Memblock 的空闲范围，调用 `__free_pages_core()` 将页面释放到 Zone 的 Free List 中。
    *   最后调用 `totalram_pages_add(pages)`，将释放的页面总数累加到 `_totalram_pages` 中。

**动态更新**:
*   在内存热插拔（Memory Hotplug）时，`online_pages()` 会增加此值，`offline_pages()` 会减少此值。

#### NR_FREE_PAGES 的统计原理
`NR_FREE_PAGES` 是一个 Zone 级别的统计项（`enum zone_stat_item`）。
*   **维护者**: 伙伴系统（Buddy Allocator）。
*   **增加**: 当页面被释放回伙伴系统时（`__free_pages` -> `free_one_page`），计数器增加。
*   **减少**: 当从伙伴系统分配页面时（`alloc_pages` -> `rmqueue`），计数器减少。
*   **Per-CPU 缓存**: 为了性能，部分释放和分配操作在 Per-CPU Pageset（PCP）中进行，不会立即更新全局 Zone 计数器。只有当 PCP 填满或清空，或者进行大块内存操作时，才会更新 Zone 的 `NR_FREE_PAGES`。
*   **读取**: `global_zone_page_state(NR_FREE_PAGES)` 会遍历所有 Zone 并汇总该值，提供一个系统级的精确快照。

#### pageblock_nr_pages 的含义与作用
`pageblock_nr_pages` 定义为 `1UL << pageblock_order`，表示内核管理内存迁移类型（Migratetype）的最小粒度（Pageblock）。

*   **具体含义**:
    *   它是内核为了避免内存碎片（Fragmentation Avoidance）而引入的概念。内核将内存划分为一个个 Pageblock，并为每个 Pageblock 标记迁移类型（如 `MIGRATE_MOVABLE`, `MIGRATE_UNMOVABLE`, `MIGRATE_RECLAIMABLE`）。
    *   **大小**: 通常等于 `MAX_ORDER` 对应的页面数（例如 x86_64 上通常是 2MB 或 4MB，取决于 HugePage 配置）。
    *   **定义**: 在 `include/linux/pageblock-flags.h` 中定义。如果支持可变 HugePage 大小（如 PowerPC），它可能是变量；否则是编译时常量。

*   **变更场景**:
    *   **初始化**: 在系统启动时，`set_pageblock_order()` 会根据 HugePage 配置初始化 `pageblock_order`。
    *   **运行时**: 在大多数架构上，它是一个常量，运行时不会改变。
    *   **迁移类型变更**: 虽然 `pageblock_nr_pages` 本身大小不变，但 Pageblock 的**属性**（Migratetype）会动态改变。例如，当 `MIGRATE_MOVABLE` 类型的内存不足时，内核可能会从 `MIGRATE_UNMOVABLE` 的 Pageblock 中“借用”内存，并将该 Pageblock 的类型标记为 `MIGRATE_MOVABLE`（Fallback 机制）。

---

## 3. /proc/meminfo 输出字段详解

下表详细列出了 `/proc/meminfo` 的每一行输出、对应的内核代码来源以及具体含义。

| 字段名 | 内核数据源 / 计算方式 | 含义详解 |
| :--- | :--- | :--- |
| **MemTotal** | `i.totalram` | **物理内存总量**。指可用的 RAM 总量，已减去内核保留的区域（如内核代码段）。 |
| **MemFree** | `i.freeram` | **空闲内存总量**。完全未被使用的物理 RAM。 |
| **MemAvailable** | `si_mem_available()` | **可用内存估算值**。估算在不进行交换（Swap）的情况下，可以分配给新应用程序的内存量。它考虑了 MemFree 以及部分可回收的 Page Cache 和 Slab。 |
| **Buffers** | `i.bufferram` | **缓冲区内存**。用于块设备（如磁盘）的原始数据块的临时存储（相对较小，通常在 20MB 左右）。 |
| **Cached** | `NR_FILE_PAGES` - `SwapCached` - `Buffers` | **页缓存（Page Cache）**。用于缓存从磁盘读取的文件内容，以及 tmpfs 和 shmem。不包含 SwapCached。 |
| **SwapCached** | `total_swapcache_pages()` | **交换缓存**。那些已经被交换出到磁盘，但又被换入内存，同时在磁盘 Swap 文件中仍保留副本的内存页。如果再次需要交换出，可以直接丢弃内存副本而无需 I/O。 |
| **Active** | `Active(anon)` + `Active(file)` | **活跃内存**。最近被频繁使用，除非非常必要否则不会被回收的内存。 |
| **Inactive** | `Inactive(anon)` + `Inactive(file)` | **不活跃内存**。最近使用较少，更有可能被回收用于其他目的。 |
| **Active(anon)** | `pages[LRU_ACTIVE_ANON]` | **活跃匿名内存**。活跃的匿名页（如进程堆栈、堆、shmem）。 |
| **Inactive(anon)** | `pages[LRU_INACTIVE_ANON]` | **不活跃匿名内存**。不活跃的匿名页。 |
| **Active(file)** | `pages[LRU_ACTIVE_FILE]` | **活跃文件内存**。活跃的文件映射页（Page Cache）。 |
| **Inactive(file)** | `pages[LRU_INACTIVE_FILE]` | **不活跃文件内存**。不活跃的文件映射页，是内存回收的主要候选者。 |
| **Unevictable** | `pages[LRU_UNEVICTABLE]` | **不可驱逐内存**。不能被换出的内存，例如被 `mlock()` 锁定的页面、Ramfs 等。 |
| **Mlocked** | `global_zone_page_state(NR_MLOCK)` | **锁定内存**。被 `mlock()` 系统调用锁定的内存总量。 |
| **HighTotal** | `i.totalhigh` | *(仅 HighMem 系统)* **高端内存总量**。32位系统中高于 ~860MB 的物理内存区域，内核不能直接映射。 |
| **HighFree** | `i.freehigh` | *(仅 HighMem 系统)* **高端内存空闲量**。 |
| **LowTotal** | `i.totalram` - `i.totalhigh` | *(仅 HighMem 系统)* **低端内存总量**。内核可以直接映射和使用的内存区域。 |
| **LowFree** | `i.freeram` - `i.freehigh` | *(仅 HighMem 系统)* **低端内存空闲量**。 |
| **MmapCopy** | `mmap_pages_allocated` | *(仅 No-MMU 系统)* `mmap` 分配的内存量。 |
| **SwapTotal** | `i.totalswap` | **交换空间总量**。所有 Swap 分区和 Swap 文件的总大小。 |
| **SwapFree** | `i.freeswap` | **空闲交换空间**。未被使用的 Swap 空间。 |
| **Zswap** | `zswap_total_pages()` | *(需 CONFIG_ZSWAP)* **Zswap 占用内存**。Zswap 后端实际占用的物理内存（压缩后的数据）。 |
| **Zswapped** | `zswap_stored_pages` | *(需 CONFIG_ZSWAP)* **Zswap 存储数据量**。存储在 Zswap 中的原始数据大小（压缩前）。 |
| **Dirty** | `NR_FILE_DIRTY` | **脏页**。等待被写回磁盘的内存页。 |
| **Writeback** | `NR_WRITEBACK` | **回写页**。正在被写回磁盘的内存页。 |
| **AnonPages** | `NR_ANON_MAPPED` | **匿名页**。映射到用户空间页表的非文件背景页面（如 malloc 分配的内存）。 |
| **Mapped** | `NR_FILE_MAPPED` | **映射页**。被 `mmap` 映射的文件，如动态库。 |
| **Shmem** | `i.sharedram` | **共享内存**。tmpfs 和共享内存（Shared Memory）使用的内存总量。 |
| **KReclaimable** | `sreclaimable` + `NR_KERNEL_MISC_RECLAIMABLE` | **内核可回收内存**。内核分配的、在内存压力下可被回收的内存，主要包括可回收 Slab。 |
| **Slab** | `sreclaimable` + `sunreclaim` | **Slab 总量**。内核 Slab 分配器使用的内存总量。 |
| **SReclaimable** | `sreclaimable` | **可回收 Slab**。Slab 中可被回收的部分（如 dentry cache, inode cache）。 |
| **SUnreclaim** | `sunreclaim` | **不可回收 Slab**。Slab 中不可被回收的部分，必须常驻内存。 |
| **KernelStack** | `NR_KERNEL_STACK_KB` | **内核栈**。所有进程的内核栈占用的内存。 |
| **ShadowCallStack**| `NR_KERNEL_SCS_KB` | *(需 CONFIG_SHADOW_CALL_STACK)* **影子调用栈**。用于防范 ROP 攻击的影子栈内存。 |
| **PageTables** | `NR_PAGETABLE` | **页表**。用户空间页表占用的内存。 |
| **SecPageTables** | `NR_SECONDARY_PAGETABLE` | **二级页表**。如 KVM EPT 或 IOMMU 页表占用的内存。 |
| **NFS_Unstable** | 0 | **NFS 不稳定页**。现已总是为 0（历史遗留字段）。 |
| **Bounce** | 0 | **Bounce Buffers**。现已总是为 0（历史遗留字段）。 |
| **WritebackTmp** | 0 | **FUSE 临时回写**。现已总是为 0（历史遗留字段）。 |
| **CommitLimit** | `vm_commit_limit()` | **提交限制**。系统可分配内存的上限（仅在 strict overcommit 模式下生效）。基于 `vm.overcommit_ratio` 计算。 |
| **Committed_AS** | `vm_memory_committed()` | **已提交内存**。系统当前已分配的内存总量（包括 malloc 但未使用的）。如果开启 strict overcommit，此值不能超过 CommitLimit。 |
| **VmallocTotal** | `VMALLOC_TOTAL` | **Vmalloc 区域总量**。vmalloc 虚拟地址空间的总大小。 |
| **VmallocUsed** | `vmalloc_nr_pages()` | **Vmalloc 已用量**。实际使用的 vmalloc 区域大小。 |
| **VmallocChunk** | 0 | **Vmalloc 最大块**。现已总是为 0（获取该值开销过大）。 |
| **Percpu** | `pcpu_nr_pages()` | **Per-CPU 内存**。Per-CPU 分配器使用的内存。 |
| **HardwareCorrupted**| `num_poisoned_pages` | *(需 CONFIG_MEMORY_FAILURE)* **硬件损坏内存**。被内核标记为损坏（MCE）的内存量。 |
| **AnonHugePages** | `NR_ANON_THPS` | **匿名大页**。透明大页（THP）使用的匿名内存量。 |
| **ShmemHugePages** | `NR_SHMEM_THPS` | **Shmem 大页**。共享内存使用的透明大页量。 |
| **ShmemPmdMapped** | `NR_SHMEM_PMDMAPPED` | **Shmem PMD 映射**。用户空间映射的 Shmem 大页量。 |
| **FileHugePages** | `NR_FILE_THPS` | **文件大页**。文件系统使用的透明大页量。 |
| **FilePmdMapped** | `NR_FILE_PMDMAPPED` | **文件 PMD 映射**。用户空间映射的文件大页量。 |
| **CmaTotal** | `totalcma_pages` | *(需 CONFIG_CMA)* **CMA 总量**。连续内存分配器（CMA）管理的内存总量。 |
| **CmaFree** | `NR_FREE_CMA_PAGES` | *(需 CONFIG_CMA)* **CMA 空闲量**。CMA 区域中空闲的内存量。 |
| **Unaccepted** | `NR_UNACCEPTED` | *(需 CONFIG_UNACCEPTED_MEMORY)* **未接受内存**。UEFI 固件已分配但内核尚未“接受”（Accept）的内存（用于机密计算虚拟机）。 |
| **Balloon** | `NR_BALLOON_PAGES` | **Balloon 内存**。虚拟化驱动（如 VirtIO Balloon）锁定的内存，归还给宿主机使用。 |

### 4. 总结

`meminfo_proc_show` 是一个综合性的内存状态报告函数。它不仅从 `struct sysinfo` 获取基础信息，还大量查询了 `vmstat` 计数器（`global_node_page_state`）来提供细粒度的内存使用情况（如 LRU 状态、Slab 分布、脏页等）。理解这些字段对于性能调优、内存泄漏排查以及系统监控至关重要。