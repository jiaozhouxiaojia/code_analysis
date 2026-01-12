# pagetypeinfo_show 函数分析

`pagetypeinfo_show` 函数是 Linux 内核中用于生成 `/proc/pagetypeinfo` 文件内容的接口。该文件提供了关于内存页面按迁移类型（Migrate Type）分组的详细统计信息，对于分析内存碎片化和页面分配行为非常有帮助。

## 1. 函数概览

**定义位置**: `mm/vmstat.c`

**函数原型**:
```c
static int pagetypeinfo_show(struct seq_file *m, void *arg)
```

**功能**:
该函数是 `seq_file` 接口的一部分，用于遍历每个内存节点（Node），并输出该节点的页面类型统计信息。它主要调用了三个辅助函数来分别输出不同维度的信息：
1. `pagetypeinfo_showfree`: 输出每个迁移类型在不同阶数（Order）下的空闲页面数量。
2. `pagetypeinfo_showblockcount`: 输出每个迁移类型的页面块（Pageblock）数量。
3. `pagetypeinfo_showmixedcount`: 输出混合页面块（包含不同迁移类型页面的块）的数量（需要 `CONFIG_PAGE_OWNER` 支持）。

## 2. 详细实现分析

### 2.1. 基础信息输出

```c
seq_printf(m, "Page block order: %d\n", pageblock_order);
seq_printf(m, "Pages per block:  %lu\n", pageblock_nr_pages);
seq_putc(m, '\n');
```
- **Page block order**: 输出 `pageblock_order`，即一个页面块的阶数。通常在 x86_64 上，如果支持 HugeTLB，这个值通常是 9 (2MB) 或其他架构相关的值。
- **Pages per block**: 输出 `pageblock_nr_pages`，即一个页面块包含的页面数量。

### 2.2. 空闲页面统计 (`pagetypeinfo_showfree`)

该函数遍历每个内存区域（Zone），统计并输出每个迁移类型在每个阶数（Order 0 到 `NR_PAGE_ORDERS-1`）上的空闲页面数量。

**输出格式**:
```
Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10 
Node    0, zone      DMA, type    Unmovable      1      1      1      0      2      1      1      0      1      0      0 
Node    0, zone      DMA, type  Reclaimable      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone      DMA, type      Movable      2      3      4      1      0      0      0      0      0      0      0 
Node    0, zone      DMA, type   HighAtomic      0      0      0      0      0      0      0      0      0      0      0 
...
```

**核心逻辑**:
- 遍历所有 Zone。
- 遍历所有迁移类型 (`MIGRATE_TYPES`)。
- 遍历所有阶数 (`order`)。
- 访问 `zone->free_area[order].free_list[mtype]` 链表，统计链表中的元素个数。
- **注意**: 为了防止在持有自旋锁的情况下遍历过长的链表导致硬死锁（Hard Lockup），代码中有一个保护机制：如果链表长度超过 100,000，则停止统计并标记为溢出（输出 `>100000`）。

### 2.3. 页面块计数 (`pagetypeinfo_showblockcount`)

该函数统计每个 Zone 中属于不同迁移类型的页面块（Pageblock）的数量。

**输出格式**:
```
Number of blocks type     Unmovable  Reclaimable      Movable   HighAtomic      CMA      Isolate 
Node 0, zone      DMA            1            0            2            0        0            0 
...
```

**核心逻辑**:
- 遍历 Zone 的物理页帧范围 (`start_pfn` 到 `end_pfn`)。
- 以 `pageblock_nr_pages` 为步长进行遍历。
- 对每个页面块的第一个页面调用 `get_pageblock_migratetype(page)` 获取其迁移类型。
- 统计各类型的数量并输出。

### 2.4. 混合页面块计数 (`pagetypeinfo_showmixedcount`)

**前提**: 需要开启 `CONFIG_PAGE_OWNER` 编译选项。

该函数统计那些包含“混合”页面的页面块数量。所谓的“混合”通常指一个页面块中包含了与其标记的迁移类型不符的页面，这通常是由于内存分配时的 fallback 机制导致的。

**输出格式**:
```
Number of mixed blocks    Unmovable  Reclaimable      Movable   HighAtomic      CMA      Isolate 
Node 0, zone      DMA            0            0            0            0        0            0 
...
```

**核心逻辑**:
- 类似于 `showblockcount`，遍历页面块。
- 检查页面块内的页面是否与其标记的迁移类型一致。
- 这是一个调试功能，用于评估反碎片化机制的效果。

## 3. 输出含义详解

`/proc/pagetypeinfo` 的输出可以分为三个部分：

### 第一部分：基本参数
```
Page block order: 9
Pages per block:  512
```
- **Page block order**: 页面块的阶数。例如 9 表示 $2^9 = 512$ 个页面。
- **Pages per block**: 每个页面块包含的页面数。通常对应于大页（Huge Page）的大小。

### 第二部分：空闲页面按迁移类型分布
```
Free pages count per migrate type at order       0      1      2 ...
Node    0, zone      DMA, type    Unmovable      1      1      1 ...
Node    0, zone      DMA, type  Reclaimable      0      0      0 ...
Node    0, zone      DMA, type      Movable      2      3      4 ...
...
```
- **Node/Zone**: 具体的内存节点和区域。
- **type**: 迁移类型。根据当前内核版本 (`include/linux/mmzone.h`)，主要包括：
    - **Unmovable**: 不可移动页，如内核分配的内存。
    - **Reclaimable**: 可回收页，如文件缓存（Page Cache）。
    - **Movable**: 可移动页，如用户进程的匿名内存。
    - **HighAtomic**: 高阶原子分配保留页，用于防止原子分配失败。
    - **CMA**: 连续内存分配器使用的页（如果开启 `CONFIG_CMA`）。
    - **Isolate**: 隔离页，用于内存热插拔或碎片整理（如果开启 `CONFIG_MEMORY_ISOLATION`）。
- **数字**: 对应阶数（Order）下的空闲页面**个数**（不是字节数）。

### 第三部分：页面块按迁移类型统计
```
Number of blocks type     Unmovable  Reclaimable      Movable   HighAtomic      CMA      Isolate 
Node 0, zone      DMA            1            0            2            0        0            0 
...
```
- 统计了每个 Zone 中，被标记为特定迁移类型的页面块的总数。
- 这反映了内存的整体布局和碎片化程度。例如，如果 `Unmovable` 的块非常多，可能会导致无法分配大块的 `Movable` 内存。

## 4. 常见问题

### 4.1. 关于 Reserve 内存

**Q: `pagetypeinfo_showblockcount` 统计的内存会包括 reserve 的内存吗？**

**A:** 这取决于你所指的 "reserve" 具体是什么含义：

1.  **MIGRATE_RESERVE 类型**:
    - 在较旧的 Linux 内核版本中，确实存在 `MIGRATE_RESERVE` 类型，用于紧急情况下的内存分配。
    - **但在当前的内核版本中，`MIGRATE_RESERVE` 已经被移除**。取而代之的是 **`MIGRATE_HIGHATOMIC`**，用于保留一部分内存以满足高阶原子分配的需求。因此，你不会在输出中看到 "Reserve" 这一列，但可能会看到 "HighAtomic"。

2.  **系统保留内存 (System Reserved Memory)**:
    - 指的是在系统启动时通过 BIOS/UEFI 或内核参数保留的内存（例如 Crash Kernel, Firmware Reserved）。
    - `pagetypeinfo_showblockcount` 遍历的是 Zone 内的所有**在线（Online）**页面块。
    - 如果这些保留内存没有被释放给伙伴系统（Buddy System），它们通常不会被标记为标准的迁移类型。
    - 但是，该函数统计的是页面块（Pageblock）的属性。只要页面块所在的物理页帧范围（PFN）在 Zone 内且是在线的，它就会被统计。
    - 通常情况下，大部分可用的内存会被初始化为 `MIGRATE_MOVABLE`。

**总结**: 当前版本中没有名为 "Reserve" 的迁移类型。相关的保留机制主要通过 `HighAtomic` 类型体现。该函数统计的是所有在线页面块的迁移类型属性。

### 4.2. 与 `/proc/zoneinfo` 中 `present` 的区别

**Q: 通过 `pagetypeinfo_showblockcount()` 计算得出的总内存和通过 `cat /proc/zoneinfo` 里面 `present` 计算得出的总内存一样吗？有啥区别？**

**A:** **通常不一样，且存在区别。**

1.  **统计粒度不同**:
    - **`present` (zoneinfo)**: 精确到**页 (Page, 4KB)**。它表示 Zone 中实际存在的物理页面数量，已经剔除了内存空洞（Holes）。
    - **`pagetypeinfo`**: 统计单位是**页面块 (Pageblock, 通常 2MB)**。它遍历 Zone 的 PFN 范围，以 Pageblock 为步长。

2.  **边界与空洞处理差异**:
    - **`pagetypeinfo` 可能高估**: `pagetypeinfo` 在遍历时，只要一个 Pageblock 的**起始页面**是有效的（Online 且属于该 Zone），就会将整个 Pageblock 计入统计（即算作 `pageblock_nr_pages` 大小）。
    - 如果一个 Pageblock 跨越了 Zone 的边界，或者跨越了物理内存空洞（即只有部分页面有效），`pagetypeinfo` 仍然会将其视为一个完整的块进行统计。
    - 因此，`pagetypeinfo` 计算出的总内存（$\sum blocks \times block\_size$）通常会**大于或等于** `present` 内存。

3.  **计算公式**:
    - `zoneinfo present` = $\sum$ (有效物理页)
    - `pagetypeinfo total` = $\sum$ (有效 Pageblock 数量) $\times$ `pageblock_nr_pages`

**结论**: `pagetypeinfo` 主要用于宏观观察内存的碎片化和迁移类型分布，而不是用于精确的内存核算。如果需要精确的内存大小，应以 `/proc/zoneinfo` 中的 `present` 或 `managed` 字段为准。