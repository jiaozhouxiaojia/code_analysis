# Control Group v2

日期: 2015年10月
作者: Tejun Heo <tj@kernel.org>

这是关于 cgroup v2 的设计、接口和约定的权威文档。它描述了 cgroup 所有用户空间可见的方面，包括核心和特定控制器的行为。所有未来的更改都必须反映在本文档中。v1 的文档可在 [Documentation/admin-guide/cgroup-v1/index.rst](Documentation/admin-guide/cgroup-v1/index.rst) 中找到。

## 目录

[每当向本文档添加新章节时，请也在此处添加条目。]

1.  简介
    1-1. 术语
    1-2. 什么是 cgroup?
2.  基本操作
    2-1. 挂载
    2-2. 组织进程和线程
    2-2-1. 进程
    2-2-2. 线程
    2-3. [非]填充通知
    2-4. 控制控制器
    2-4-1. 可用性
    2-4-2. 启用和禁用
    2-4-3. 自上而下的约束
    2-4-4. 无内部进程约束
    2-5. 委托
    2-5-1. 委托模型
    2-5-2. 委托包含
    2-6. 指南
    2-6-1. 一次组织，处处控制
    2-6-2. 避免名称冲突
3.  资源分配模型
    3-1. 权重
    3-2. 限制
    3-3. 保护
    3-4. 分配
4.  接口文件
    4-1. 格式
    4-2. 约定
    4-3. 核心接口文件
5.  控制器
    5-1. CPU
    5-1-1. CPU 接口文件
    5-2. 内存
    5-2-1. 内存接口文件
    5-2-2. 使用指南
    5-2-3. 内存所有权
    5-3. IO
    5-3-1. IO 接口文件
    5-3-2. 回写 (Writeback)
    5-3-3. IO 延迟
    5-3-3-1. IO 延迟节流如何工作
    5-3-3-2. IO 延迟接口文件
    5-3-4. IO 优先级
    5-4. PID
    5-4-1. PID 接口文件
    5-5. Cpuset
    5.5-1. Cpuset 接口文件
    5-6. 设备控制器
    5-7. RDMA
    5-7-1. RDMA 接口文件
    5-8. DMEM
    5-8-1. DMEM 接口文件
    5-9. HugeTLB
    5.9-1. HugeTLB 接口文件
    5-10. 杂项 (Misc)
    5.10-1 杂项接口文件
    5.10-2 迁移和所有权
    5-11. 其他
    5-11-1. perf_event
    5-N. 非规范性信息
    5-N-1. CPU 控制器根 cgroup 进程行为
    5-N-2. IO 控制器根 cgroup 进程行为
6.  命名空间
    6-1. 基础
    6-2. 根和视图
    6-3. 迁移和 setns(2)
    6-4. 与其他命名空间的交互
P. 内核编程信息
    P-1. 文件系统对回写的支持
D. 已弃用的 v1 核心功能
R. v1 的问题和 v2 的理由
    R-1. 多层级
    R-2. 线程粒度
    R-3. 内部节点和线程之间的竞争
    R-4. 其他接口问题
    R-5. 控制器问题和补救措施
    R-5-1. 内存

# 1. 简介

## 1-1. 术语

"cgroup" 代表 "control group"（控制组），从不大写。单数形式用于指代整个功能，也用作限定词，如 "cgroup controllers"（cgroup 控制器）。当明确指代多个单独的控制组时，使用复数形式 "cgroups"。

## 1-2. 什么是 cgroup?

cgroup 是一种机制，用于分层组织进程，并以受控和可配置的方式沿层级结构分配系统资源。

cgroup 主要由两部分组成 - 核心和控制器。cgroup 核心主要负责分层组织进程。cgroup 控制器通常负责沿层级结构分配特定类型的系统资源，尽管也有用于资源分配以外目的的实用程序控制器。

cgroups 形成树状结构，系统中的每个进程都属于且仅属于一个 cgroup。一个进程的所有线程都属于同一个 cgroup。创建时，所有进程都被放入父进程当时所属的 cgroup 中。进程可以迁移到另一个 cgroup。进程的迁移不会影响已经存在的后代进程。

遵循某些结构约束，可以在 cgroup 上选择性地启用或禁用控制器。所有控制器行为都是分层的 - 如果在 cgroup 上启用了控制器，它将影响属于构成该 cgroup 包含子层级结构的所有 cgroups 的所有进程。当在嵌套的 cgroup 上启用控制器时，它总是进一步限制资源分配。在层级结构中靠近根设置的限制不能被更远处的设置覆盖。

# 2. 基本操作

## 2-1. 挂载

与 v1 不同，cgroup v2 只有单一层级结构。可以使用以下 mount 命令挂载 cgroup v2 层级结构：

```sh
# mount -t cgroup2 none $MOUNT_POINT
```

cgroup2 文件系统具有魔数 0x63677270 ("cgrp")。所有支持 v2 且未绑定到 v1 层级结构的控制器将自动绑定到 v2 层级结构并出现在根目录下。未在 v2 层级结构中活跃使用的控制器可以绑定到其他层级结构。这允许以完全向后兼容的方式混合使用 v2 层级结构和旧版 v1 多层级结构。

只有当控制器在当前层级结构中不再被引用后，才能跨层级结构移动该控制器。由于每个 cgroup 的控制器状态是异步销毁的，并且控制器可能有残留的引用，因此在卸载前一个层级结构后，控制器可能不会立即出现在 v2 层级结构上。同样，控制器应完全禁用才能移出统一层级结构，并且禁用的控制器可能需要一些时间才能用于其他层级结构；此外，由于控制器间的依赖关系，其他控制器可能也需要被禁用。

虽然对于开发和手动配置很有用，但强烈不建议在生产环境中在 v2 和其他层级结构之间动态移动控制器。建议在系统启动后开始使用控制器之前确定层级结构和控制器关联。

在过渡到 v2 期间，系统管理软件可能仍会自动挂载 v1 cgroup 文件系统，从而在手动干预可能之前就在启动期间劫持所有控制器。为了使测试和实验更容易，内核参数 `cgroup_no_v1=` 允许在 v1 中禁用控制器，并使它们在 v2 中始终可用。

cgroup v2 目前支持以下挂载选项。

  `nsdelegate`
    将 cgroup 命名空间视为委托边界。此选项是系统范围的，只能在挂载时设置，或通过从 init 命名空间重新挂载来修改。该挂载选项在非 init 命名空间挂载上被忽略。有关详细信息，请参阅“委托”部分。

  `favordynmods`
    减少动态 cgroup 修改（如任务迁移和控制器开启/关闭）的延迟，代价是使诸如 fork 和 exit 等热路径操作更加昂贵。创建 cgroup、启用控制器，然后使用 `CLONE_INTO_CGROUP` 对其进行播种的静态使用模式不受此选项影响。

  `memory_localevents`
    仅使用当前 cgroup 的数据填充 `memory.events`，而不包括任何子树。这是旧版行为，没有此选项的默认行为是包括子树计数。此选项是系统范围的，只能在挂载时设置，或通过从 init 命名空间重新挂载来修改。该挂载选项在非 init 命名空间挂载上被忽略。

  `memory_recursiveprot`
    递归地将 `memory.min` 和 `memory.low` 保护应用于整个子树，而无需显式向下传播到叶 cgroup。这允许保护整个子树免受彼此影响，同时保留这些子树内的自由竞争。这本应是默认行为，但为了避免回归依赖原始语义的设置（例如，在较高的树级别指定虚假的高“旁路”保护值），它作为一个挂载选项提供。

  `memory_hugetlb_accounting`
    将 HugeTLB 内存使用量计入 cgroup 的内存控制器总内存使用量（用于统计报告和内存保护）。这是一种新行为，可能会导致现有设置回归，因此必须使用此挂载选项显式选择加入。

    需要记住的一些注意事项：

    * 内存控制器不涉及 HugeTLB 池管理。预分配的池不属于任何人。具体来说，当新的 HugeTLB folio 分配给池时，从内存控制器的角度来看，它不被计入。只有当它实际被使用时（例如在缺页异常时），才会向 cgroup 收费。主机内存过量使用管理在配置硬限制时必须考虑到这一点。通常，HugeTLB 池管理应通过其他机制（如 HugeTLB 控制器）完成。
    * 未能向内存控制器收取 HugeTLB folio 费用会导致 SIGBUS。即使 HugeTLB 池仍有可用页面（但 cgroup 限制已达到且回收尝试失败），也可能发生这种情况。
    * 将 HugeTLB 内存计入内存控制器会影响内存保护和回收动态。任何用户空间调整（例如 low、min 限制）都需要考虑到这一点。
    * 在未选择此选项时使用的 HugeTLB 页面将不会被内存控制器跟踪（即使稍后重新挂载 cgroup v2）。

  `pids_localevents`
    该选项恢复 `pids.events:max` 的类似 v1 的行为，即仅计算本地（cgroup 内部）fork 失败。如果没有此选项，`pids.events.max` 代表整个 cgroup 子树中的任何 `pids.max` 强制执行。

## 2-2. 组织进程和线程

### 2-2-1. 进程

最初，只存在根 cgroup，所有进程都属于它。可以通过创建子目录来创建子 cgroup：

```sh
# mkdir $CGROUP_NAME
```

给定的 cgroup 可以有多个子 cgroup，形成树状结构。每个 cgroup 都有一个读写接口文件 "cgroup.procs"。读取时，它列出属于该 cgroup 的所有进程的 PID，每行一个。PID 没有排序，如果进程移动到另一个 cgroup 然后又移回，或者在读取时 PID 被回收，同一个 PID 可能会出现多次。

可以通过将进程的 PID 写入目标 cgroup 的 "cgroup.procs" 文件来将其迁移到该 cgroup。单次 write(2) 调用只能迁移一个进程。如果一个进程由多个线程组成，写入任何线程的 PID 都会迁移该进程的所有线程。

当进程 fork 子进程时，新进程诞生于 fork 进程在操作时所属的 cgroup。退出后，进程保持与退出时所属的 cgroup 关联，直到被收割；但是，僵尸进程不会出现在 "cgroup.procs" 中，因此不能移动到另一个 cgroup。

没有子 cgroup 或活动进程的 cgroup 可以通过删除目录来销毁。请注意，没有子 cgroup 且仅与僵尸进程关联的 cgroup 被视为空，可以删除：

```sh
# rmdir $CGROUP_NAME
```

"/proc/$PID/cgroup" 列出进程的 cgroup 成员资格。如果系统中正在使用旧版 cgroup，此文件可能包含多行，每个层级结构一行。cgroup v2 的条目始终采用 "0::$PATH" 格式：

```sh
# cat /proc/842/cgroup
...
0::/test-cgroup/test-cgroup-nested
```

如果进程变成僵尸进程，并且随后删除了它关联的 cgroup，则路径后会附加 " (deleted)"：

```sh
# cat /proc/842/cgroup
...
0::/test-cgroup/test-cgroup-nested (deleted)
```

### 2-2-2. 线程

cgroup v2 支持部分控制器的线程粒度，以支持需要跨一组进程的线程进行分层资源分配的用例。默认情况下，进程的所有线程都属于同一个 cgroup，该 cgroup 也充当资源域，用于托管不特定于进程或线程的资源消耗。线程模式允许线程分布在子树中，同时仍为它们维护公共资源域。

支持线程模式的控制器称为线程控制器。不支持的称为域控制器。

将 cgroup 标记为线程化使其作为线程 cgroup 加入其父级的资源域。父级可能是另一个线程 cgroup，其资源域在层级结构中更上方。线程子树的根，即最近的非线程祖先，称为线程域或线程根，并作为整个子树的资源域。

在线程子树内，进程的线程可以放入不同的 cgroup 中，并且不受无内部进程约束的限制 - 无论其中是否有线程，都可以在非叶 cgroup 上启用线程控制器。

由于线程域 cgroup 托管子树的所有域资源消耗，因此无论其中是否有进程，它都被视为具有内部资源消耗，并且不能有非线程的已填充子 cgroup。因为根 cgroup 不受无内部进程约束的限制，它可以同时充当线程域和域 cgroup 的父级。

cgroup 的当前操作模式或类型显示在 "cgroup.type" 文件中，该文件指示 cgroup 是普通域、充当线程子树域的域还是线程 cgroup。

创建时，cgroup 始终是域 cgroup，可以通过向 "cgroup.type" 文件写入 "threaded" 来使其线程化。该操作是单向的：

```sh
# echo threaded > cgroup.type
```

一旦线程化，cgroup 就不能再次成为域。要启用线程模式，必须满足以下条件。

- 由于 cgroup 将加入父级的资源域。父级必须是有效的（线程）域或线程 cgroup。

- 当父级是未线程化的域时，它必须没有启用任何域控制器或已填充的域子级。根不受此要求限制。

在拓扑上，cgroup 可能处于无效状态。请考虑以下拓扑：

  A (线程域) - B (线程) - C (域, 刚创建)

C 被创建为域，但未连接到可以托管子域的父级。在 C 转换为线程 cgroup 之前，无法使用它。在这些情况下，"cgroup.type" 文件将报告 "domain (invalid)"。由于拓扑无效而失败的操作使用 EOPNOTSUPP 作为 errno。

当域 cgroup 的子 cgroup 之一变为线程化，或者在 cgroup 中有进程时在 "cgroup.subtree_control" 文件中启用了线程控制器时，域 cgroup 将变为线程域。当条件清除时，线程域恢复为普通域。

读取时，"cgroup.threads" 包含 cgroup 中所有线程的线程 ID 列表。除了操作是针对每个线程而不是每个进程之外，"cgroup.threads" 具有相同的格式，并且行为方式与 "cgroup.procs" 相同。虽然可以写入任何 cgroup 的 "cgroup.threads"，但由于它只能在同一个线程域内移动线程，因此其操作仅限于每个线程子树内。

线程域 cgroup 充当整个子树的资源域，虽然线程可以分散在子树中，但所有进程都被视为在线程域 cgroup 中。线程域 cgroup 中的 "cgroup.procs" 包含子树中所有进程的 PID，并且在子树本身中不可读。但是，可以从子树中的任何位置写入 "cgroup.procs"，以将匹配进程的所有线程迁移到该 cgroup。

只能在线程子树中启用线程控制器。当在线程子树内启用线程控制器时，它仅计算和控制与 cgroup 及其后代中的线程关联的资源消耗。所有不绑定到特定线程的消耗都属于线程域 cgroup。

由于线程子树不受无内部进程约束的限制，因此线程控制器必须能够处理非叶 cgroup 中的线程与其子 cgroup 之间的竞争。每个线程控制器定义了如何处理此类竞争。

目前，以下控制器是线程化的，可以在线程 cgroup 中启用：

- cpu
- cpuset
- perf_event
- pids

## 2-3. [非]填充通知

每个非根 cgroup 都有一个 "cgroup.events" 文件，其中包含 "populated" 字段，指示 cgroup 的子层级结构中是否有活动进程。如果 cgroup 及其后代中没有活动进程，则其值为 0；否则为 1。当值更改时，会触发 poll 和 [id]notify 事件。例如，这可用于在给定子层级结构的所有进程退出后启动清理操作。填充状态更新和通知是递归的。考虑以下子层级结构，其中括号中的数字表示每个 cgroup 中的进程数：

  A(4) - B(0) - C(1)
              \ D(0)

A、B 和 C 的 "populated" 字段将为 1，而 D 为 0。在 C 中的一个进程退出后，B 和 C 的 "populated" 字段将翻转为 "0"，并且将在两个 cgroup 的 "cgroup.events" 文件上生成文件修改事件。

## 2-4. 控制控制器

### 2-4-1. 可用性

当控制器受内核支持（即编译进内核、未禁用且未附加到 v1 层级结构）并在 "cgroup.controllers" 文件中列出时，该控制器在 cgroup 中可用。可用性意味着控制器的接口文件暴露在 cgroup 的目录中，允许在该 cgroup 内观察或控制目标资源的分配。

### 2-4-2. 启用和禁用

每个 cgroup 都有一个 "cgroup.controllers" 文件，列出了该 cgroup 可启用的所有控制器：

```sh
# cat cgroup.controllers
cpu io memory
```

默认情况下不启用任何控制器。可以通过写入 "cgroup.subtree_control" 文件来启用和禁用控制器：

```sh
# echo "+cpu +memory -io" > cgroup.subtree_control
```

只能启用 "cgroup.controllers" 中列出的控制器。当如上指定多个操作时，它们要么全部成功，要么全部失败。如果对同一个控制器指定了多个操作，则最后一个有效。

在 cgroup 中启用控制器表示将控制目标资源在其直接子级之间的分配。考虑以下子层级结构。启用的控制器列在括号中：

  A(cpu,memory) - B(memory) - C()
                            \ D()

由于 A 启用了 "cpu" 和 "memory"，A 将控制 CPU 周期和内存向其子级（在本例中为 B）的分配。由于 B 启用了 "memory" 但未启用 "CPU"，C 和 D 将自由竞争 CPU 周期，但它们对 B 可用内存的划分将受到控制。

由于控制器调节目标资源向 cgroup 子级的分配，因此启用它会在子 cgroup 中创建控制器的接口文件。在上面的示例中，在 B 上启用 "cpu" 将在 C 和 D 中创建以 "cpu." 为前缀的控制器接口文件。同样，从 B 禁用 "memory" 将从 C 和 D 中删除以 "memory." 为前缀的控制器接口文件。这意味着控制器接口文件 - 任何不以 "cgroup." 开头的文件 - 归父级所有，而不是 cgroup 本身。

### 2-4-3. 自上而下的约束

资源是自上而下分配的，只有当资源已从父级分配给 cgroup 时，cgroup 才能进一步分配资源。这意味着所有非根 "cgroup.subtree_control" 文件只能包含在父级中启用的控制器。
### 2-4-4. 无内部进程约束

非根 cgroup 只有在没有任何自己的进程时，才能将域资源分配给其子级。换句话说，只有不包含任何进程的域 cgroup 才能在其 "cgroup.subtree_control" 文件中启用域控制器。

这保证了当域控制器查看启用了它的层级结构部分时，进程始终只在叶子上。这排除了子 cgroup 与父级内部进程竞争的情况。

根 cgroup 不受此限制。根包含无法与其他 cgroup 关联的进程和匿名资源消耗，并且需要大多数控制器的特殊处理。根 cgroup 中的资源消耗如何管理取决于每个控制器（有关此主题的更多信息，请参阅控制器章节中的非规范性信息部分）。

请注意，如果 cgroup 的 "cgroup.subtree_control" 中没有启用的控制器，则该限制不会造成妨碍。这很重要，否则就不可能创建已填充 cgroup 的子级。要控制 cgroup 的资源分配，cgroup 必须创建子级并将所有进程转移到子级，然后才能在其 "cgroup.subtree_control" 文件中启用控制器。

## 2-5. 委托

### 2-5-1. 委托模型

cgroup 可以通过两种方式委托。第一种是授予用户对目录及其 "cgroup.procs"、"cgroup.threads" 和 "cgroup.subtree_control" 文件的写访问权限，从而委托给特权较低的用户。第二种是如果设置了 "nsdelegate" 挂载选项，则在创建命名空间时自动委托给 cgroup 命名空间。

由于给定目录中的资源控制接口文件控制父级资源的分配，因此不应允许受托者写入它们。对于第一种方法，这是通过不授予对这些文件的访问权限来实现的。对于第二种方法，应至少通过挂载命名空间向受托者隐藏命名空间之外的文件，并且内核拒绝从 cgroup 命名空间内部写入命名空间根目录上的所有文件，除了 "/sys/kernel/cgroup/delegate" 中列出的文件（包括 "cgroup.procs"、"cgroup.threads"、"cgroup.subtree_control" 等）。

两种委托类型的最终结果是等效的。一旦委托，用户就可以在目录下构建子层级结构，在其中组织进程，并进一步分配从父级接收的资源。所有资源控制器的限制和其他设置都是分层的，无论委托的子层级结构中发生什么，都无法逃脱父级施加的资源限制。

目前，cgroup 对委托子层级结构中的 cgroup 数量或嵌套深度没有任何限制；但是，将来可能会明确限制这一点。

### 2-5-2. 委托包含

委托的子层级结构是包含的，即受托者不能将进程移入或移出子层级结构。

对于委托给特权较低的用户，这是通过要求具有非根 euid 的进程在通过将其 PID 写入 "cgroup.procs" 文件将目标进程迁移到 cgroup 时满足以下条件来实现的。

- 写入者必须具有对 "cgroup.procs" 文件的写访问权限。

- 写入者必须具有对源 cgroup 和目标 cgroup 的共同祖先的 "cgroup.procs" 文件的写访问权限。

上述两个约束确保了虽然受托者可以在委托的子层级结构中自由迁移进程，但它不能从子层级结构外部拉入或推送到外部。

举个例子，假设 cgroup C0 和 C1 已委托给用户 U0，U0 在 C0 下创建了 C00、C01，在 C1 下创建了 C10，如下所示，并且 C0 和 C1 下的所有进程都属于 U0：

  ~~~~~~~~~~~~~ - C0 - C00
  ~ cgroup    ~      \ C01
  ~ hierarchy ~
  ~~~~~~~~~~~~~ - C1 - C10

假设 U0 想要将当前在 C10 中的进程的 PID 写入 "C00/cgroup.procs"。U0 具有对该文件的写访问权限；但是，源 cgroup C10 和目标 cgroup C00 的共同祖先位于委托点之上，U0 对其 "cgroup.procs" 文件没有写访问权限，因此写入将被拒绝并返回 -EACCES。

对于委托给命名空间，包含是通过要求源 cgroup 和目标 cgroup 都可以从尝试迁移的进程的命名空间访问来实现的。如果任何一个不可访问，则迁移将被拒绝并返回 -ENOENT。

## 2-6. 指南

### 2-6-1. 一次组织，处处控制

跨 cgroup 迁移进程是一个相对昂贵的操作，并且诸如内存之类的有状态资源不会随进程一起移动。这是一个明确的设计决策，因为在迁移和各种热路径之间通常存在同步成本方面的固有权衡。

因此，不鼓励频繁跨 cgroup 迁移进程作为应用不同资源限制的手段。工作负载应在启动时根据系统的逻辑和资源结构分配给 cgroup 一次。可以通过接口文件更改控制器配置来进行资源分配的动态调整。

### 2-6-2. 避免名称冲突

cgroup 及其子 cgroup 的接口文件占用同一目录，并且可能会创建与接口文件冲突的子 cgroup。

所有 cgroup 核心接口文件都以 "cgroup." 为前缀，每个控制器的接口文件都以控制器名称和一个点为前缀。控制器名称由小写字母和 '_' 组成，但从不以 '_' 开头，因此可以用作避免冲突的前缀字符。此外，接口文件名不会以通常用于分类工作负载的术语（如 job、service、slice、unit 或 workload）开头或结尾。

cgroup 不采取任何措施来防止名称冲突，避免冲突是用户的责任。

# 3. 资源分配模型

cgroup 控制器根据资源类型和预期用例实现多种资源分配方案。本节描述了正在使用的主要方案及其预期行为。

## 3-1. 权重

父级的资源通过将所有活动子级的权重相加，并给每个子级分配与其权重占总和比例相匹配的份额来分配。由于只有当前可以使用资源的子级参与分配，因此这是工作守恒的。由于动态性质，此模型通常用于无状态资源。

所有权重的范围为 [1, 10000]，默认为 100。这允许在两个方向上以足够细的粒度进行对称乘法偏差，同时保持在直观范围内。

只要权重在范围内，所有配置组合都是有效的，没有理由拒绝配置更改或进程迁移。

"cpu.weight" 按比例将 CPU 周期分配给活动子级，是此类型的示例。

## 3-2. 限制

子级只能消耗配置数量的资源。限制可以超额承诺 - 子级限制的总和可以超过父级可用的资源量。

限制在范围 [0, max] 内，默认为 "max"，即无操作。

由于限制可以超额承诺，所有配置组合都是有效的，没有理由拒绝配置更改或进程迁移。

"io.max" 限制 cgroup 在 IO 设备上可以消耗的最大 BPS 和/或 IOPS，是此类型的示例。

## 3-3. 保护

只要所有祖先的使用量都在其受保护水平之下，cgroup 就会受到保护，直到达到配置的资源量。保护可以是硬性保证，也可以是尽力而为的软边界。保护也可以超额承诺，在这种情况下，只有父级可用的数量在子级之间受到保护。

保护在范围 [0, max] 内，默认为 0，即无操作。

由于保护可以超额承诺，所有配置组合都是有效的，没有理由拒绝配置更改或进程迁移。

"memory.low" 实现尽力而为的内存保护，是此类型的示例。

## 3-4. 分配

cgroup 独占分配一定数量的有限资源。分配不能超额承诺 - 子级分配的总和不能超过父级可用的资源量。

分配在范围 [0, max] 内，默认为 0，即无资源。

由于分配不能超额承诺，某些配置组合是无效的，应被拒绝。此外，如果资源对于进程的执行是强制性的，则可能会拒绝进程迁移。

"cpu.rt.max" 硬分配实时切片，是此类型的示例。

# 4. 接口文件

## 4-1. 格式

只要可能，所有接口文件都应采用以下格式之一：

  换行符分隔的值
  （当一次只能写入一个值时）

	VAL0\n
	VAL1\n
	...

  空格分隔的值
  （当只读或一次可以写入多个值时）

	VAL0 VAL1 ...\n

  扁平键控

	KEY0 VAL0\n
	KEY1 VAL1\n
	...

  嵌套键控

	KEY0 SUB_KEY0=VAL00 SUB_KEY1=VAL01...
	KEY1 SUB_KEY0=VAL10 SUB_KEY1=VAL11...
	...

对于可写文件，写入格式通常应与读取格式匹配；但是，控制器可能允许省略后面的字段或为最常见的用例实现受限的快捷方式。

对于扁平键控文件和嵌套键控文件，一次只能写入单个键的值。对于嵌套键控文件，子键对可以按任何顺序指定，并且不必指定所有对。

## 4-2. 约定

- 单个功能的设置应包含在单个文件中。

- 根 cgroup 应免于资源控制，因此不应具有资源控制接口文件。

- 默认时间单位是微秒。如果使用不同的单位，则必须存在显式单位后缀。

- 每份数量应使用至少两位小数部分的百分比小数 - 例如 13.40。

- 如果控制器实现基于权重的资源分配，其接口文件应命名为 "weight"，范围为 [1, 10000]，默认值为 100。选择这些值是为了在两个方向上允许足够且对称的偏差，同时保持直观（默认为 100%）。

- 如果控制器实现绝对资源保证和/或限制，接口文件应分别命名为 "min" 和 "max"。如果控制器实现尽力而为的资源保证和/或限制，接口文件应分别命名为 "low" 和 "high"。

  在上述四个控制文件中，特殊标记 "max" 应于表示向上无穷大，用于读取和写入。

- 如果设置具有可配置的默认值和键控特定覆盖，则默认条目应以 "default" 为键，并作为文件中的第一个条目出现。

  可以通过写入 "default $VAL" 或 "$VAL" 来更新默认值。

  当写入以更新特定覆盖时，可以使用 "default" 作为值来指示删除覆盖。读取时，不得出现值为 "default" 的覆盖条目。

  例如，以整数值为主要:次要设备号键控的设置可能如下所示：

    # cat cgroup-example-interface-file
    default 150
    8:0 300

  可以通过以下方式更新默认值：

    # echo 125 > cgroup-example-interface-file

  或：

    # echo "default 125" > cgroup-example-interface-file

  可以通过以下方式设置覆盖：

    # echo "8:16 170" > cgroup-example-interface-file

  并通过以下方式清除：

    # echo "8:0 default" > cgroup-example-interface-file
    # cat cgroup-example-interface-file
    default 125
    8:16 170

- 对于频率不是很高的事件，应创建一个接口文件 "events"，其中列出事件键值对。每当发生可通知事件时，应在该文件上生成文件修改事件。

## 4-3. 核心接口文件

所有 cgroup 核心文件都以 "cgroup." 为前缀。

  `cgroup.type`
    存在于非根 cgroup 上的读写单值文件。

    读取时，它指示 cgroup 的当前类型，可以是以下值之一。

    - "domain" : 普通有效的域 cgroup。

    - "domain threaded" : 充当线程子树根的线程域 cgroup。

    - "domain invalid" : 处于无效状态的 cgroup。它不能被填充或启用控制器。它可能被允许成为线程 cgroup。

    - "threaded" : 属于线程子树成员的线程 cgroup。

    可以通过向此文件写入 "threaded" 将 cgroup 转换为线程 cgroup。

  `cgroup.procs`
    存在于所有 cgroup 上的读写换行符分隔值文件。

    读取时，它列出属于该 cgroup 的所有进程的 PID，每行一个。PID 没有排序，如果进程移动到另一个 cgroup 然后又移回，或者在读取时 PID 被回收，同一个 PID 可能会出现多次。

    可以写入 PID 以将与 PID 关联的进程迁移到 cgroup。写入者应匹配以下所有条件。

    - 它必须具有对 "cgroup.procs" 文件的写访问权限。

    - 它必须具有对源 cgroup 和目标 cgroup 的共同祖先的 "cgroup.procs" 文件的写访问权限。

    当委托子层级结构时，应连同包含目录一起授予对此文件的写访问权限。

    在线程 cgroup 中，读取此文件会失败并返回 EOPNOTSUPP，因为所有进程都属于线程根。支持写入，并将进程的每个线程移动到 cgroup。

  `cgroup.threads`
    存在于所有 cgroup 上的读写换行符分隔值文件。

    读取时，它列出属于该 cgroup 的所有线程的 TID，每行一个。TID 没有排序，如果线程移动到另一个 cgroup 然后又移回，或者在读取时 TID 被回收，同一个 TID 可能会出现多次。

    可以写入 TID 以将与 TID 关联的线程迁移到 cgroup。写入者应匹配以下所有条件。

    - 它必须具有对 "cgroup.threads" 文件的写访问权限。

    - 线程当前所在的 cgroup 必须与目标 cgroup 位于同一资源域中。

    - 它必须具有对源 cgroup 和目标 cgroup 的共同祖先的 "cgroup.procs" 文件的写访问权限。

    当委托子层级结构时，应连同包含目录一起授予对此文件的写访问权限。

  `cgroup.controllers`
    存在于所有 cgroup 上的只读空格分隔值文件。

    它显示 cgroup 可用的所有控制器的空格分隔列表。控制器没有排序。

  `cgroup.subtree_control`
    存在于所有 cgroup 上的读写空格分隔值文件。开始时为空。

    读取时，它显示已启用以控制从 cgroup 到其子级的资源分配的控制器的空格分隔列表。

    可以写入以 '+' 或 '-' 为前缀的控制器空格分隔列表来启用或禁用控制器。以 '+' 为前缀的控制器名称启用控制器，'-' 禁用。如果控制器在列表中出现多次，则最后一个有效。当指定多个启用和禁用操作时，要么全部成功，要么全部失败。

  `cgroup.events`
    存在于非根 cgroup 上的只读扁平键控文件。定义了以下条目。除非另有说明，否则此文件中的值更改会生成文件修改事件。

      populated
        如果 cgroup 或其后代包含任何活动进程，则为 1；否则为 0。
      frozen
        如果 cgroup 被冻结，则为 1；否则为 0。

  `cgroup.max.descendants`
    读写单值文件。默认为 "max"。

    允许的最大后代 cgroup 数量。如果实际后代数量等于或大于此值，则尝试在层级结构中创建新 cgroup 将失败。

  `cgroup.max.depth`
    读写单值文件。默认为 "max"。

    当前 cgroup 下允许的最大下降深度。如果实际下降深度等于或大于此值，则尝试创建新子 cgroup 将失败。

  `cgroup.stat`
    具有以下条目的只读扁平键控文件：

      nr_descendants
        可见后代 cgroup 的总数。

      nr_dying_descendants
        正在消亡的后代 cgroup 的总数。cgroup 在被用户删除后变为消亡状态。cgroup 将在消亡状态下保持一段未定义的时间（这可能取决于系统负载），然后被完全销毁。

        进程在任何情况下都不能进入消亡的 cgroup，消亡的 cgroup 不能复活。

        消亡的 cgroup 消耗的系统资源不能超过 cgroup 删除时处于活动状态的限制。
      nr_subsys_<cgroup_subsys>
        当前 cgroup 及其下方活动 cgroup 子系统（例如内存 cgroup）的总数。

      nr_dying_subsys_<cgroup_subsys>
        当前 cgroup 及其下方消亡 cgroup 子系统（例如内存 cgroup）的总数。

  `cgroup.stat.local`
    存在于非根 cgroup 中的只读扁平键控文件。定义了以下条目：

      frozen_usec
        此 cgroup 在冻结和解冻之间花费的累积时间，无论是由自身还是祖先组引起的。
        注意：此处不计算（未）达到“冻结”状态。

        使用以下 ASCII 表示 cgroup 的冻结器状态，

                       1    _____
                frozen 0 __/     \__
                          ab    cd

        测量的持续时间是 a 和 c 之间的跨度。

  `cgroup.freeze`
    存在于非根 cgroup 上的读写单值文件。允许的值为 "0" 和 "1"。默认为 "0"。

    向文件写入 "1" 会导致冻结 cgroup 和所有后代 cgroup。这意味着所有所属进程将停止，并且在 cgroup 显式解冻之前不会运行。冻结 cgroup 可能需要一些时间；当此操作完成时，cgroup.events 控制文件中的 "frozen" 值将更新为 "1"，并发出相应的通知。

    cgroup 可以通过其自己的设置或任何祖先 cgroup 的设置被冻结。如果任何祖先 cgroup 被冻结，则该 cgroup 将保持冻结状态。

    冻结 cgroup 中的进程可以被致命信号杀死。它们也可以进入和离开冻结的 cgroup：通过用户的显式移动，或者如果 cgroup 的冻结与 fork() 竞争。如果进程移动到冻结的 cgroup，它将停止。如果进程移出冻结的 cgroup，它将变为运行状态。

    cgroup 的冻结状态不影响任何 cgroup 树操作：可以删除冻结（且为空）的 cgroup，以及创建新的子 cgroup。

  `cgroup.kill`
    存在于非根 cgroup 中的只写单值文件。唯一允许的值是 "1"。

    向文件写入 "1" 会导致 cgroup 和所有后代 cgroup 被杀死。这意味着受影响 cgroup 树中的所有进程都将通过 SIGKILL 被杀死。

    杀死 cgroup 树将适当地处理并发 fork，并受到保护以防止迁移。

    在线程 cgroup 中，写入此文件会失败并返回 EOPNOTSUPP，因为杀死 cgroup 是针对进程的操作，即它会影响整个线程组。

  `cgroup.pressure`
    读写单值文件，允许的值为 "0" 和 "1"。默认为 "1"。

    向文件写入 "0" 将禁用 cgroup PSI 记账。
    向文件写入 "1" 将重新启用 cgroup PSI 记账。

    此控制属性不是分层的，因此在 cgroup 中禁用或启用 PSI 记账不会影响后代中的 PSI 记账，也不需要通过祖先从根传递启用。

    存在此控制属性的原因是 PSI 分别计算每个 cgroup 的停顿，并在层级结构的每个级别进行聚合。当处于层级结构的深层时，这可能会对某些工作负载造成不可忽略的开销，在这种情况下，可以使用此控制属性禁用非叶 cgroup 中的 PSI 记账。

  `irq.pressure`
    读写嵌套键控文件。

    显示 IRQ/SOFTIRQ 的压力停顿信息。有关详细信息，请参阅 [Documentation/accounting/psi.rst](Documentation/accounting/psi.rst)。

# 5. 控制器

## 5-1. CPU

"cpu" 控制器调节 CPU 周期的分配。此控制器为普通调度策略实现权重和绝对带宽限制模型，为实时调度策略实现绝对带宽分配模型。

在上述所有模型中，周期分配仅基于时间定义，不考虑任务执行的频率。（可选的）利用率钳位支持允许向 schedutil cpufreq 调控器提示 CPU 应始终提供的最小所需频率，以及 CPU 不应超过的最大所需频率。

警告：cgroup2 cpu 控制器尚不支持实时进程的（带宽）控制。对于启用了 CONFIG_RT_GROUP_SCHED 选项以进行实时进程组调度的内核，只有当所有 RT 进程都在根 cgroup 中时，才能启用 cpu 控制器。请注意，系统管理软件可能已在系统启动过程中将 RT 进程放入非根 cgroup 中，并且在启用 CONFIG_RT_GROUP_SCHED 的内核上启用 cpu 控制器之前，可能需要将这些进程移动到根 cgroup。

在禁用 CONFIG_RT_GROUP_SCHED 的情况下，此限制不适用，并且某些接口文件会影响实时进程或对其进行记账。有关详细信息，请参阅以下部分。只有 cpu 控制器受 CONFIG_RT_GROUP_SCHED 影响。其他控制器可用于实时进程的资源控制，而不管 CONFIG_RT_GROUP_SCHED 如何。

### 5-1-1. CPU 接口文件

进程与 cpu 控制器的交互取决于其调度策略和底层调度器。从 cpu 控制器的角度来看，进程可以分类如下：

* 公平类调度器下的进程
* 具有 `cgroup_set_weight` 回调的 BPF 调度器下的进程
* 其他所有内容：`SCHED_{FIFO,RR,DEADLINE}` 和没有 `cgroup_set_weight` 回调的 BPF 调度器下的进程

有关进程何时处于公平类调度器或 BPF 调度器下的详细信息，请查看 [Documentation/scheduler/sched-ext.rst](Documentation/scheduler/sched-ext.rst)。

对于以下每个接口文件，将引用上述类别。所有持续时间均以微秒为单位。

  `cpu.stat`
    只读扁平键控文件。无论控制器是否启用，此文件都存在。

    它始终报告以下三个统计信息，这些信息计算 cgroup 中的所有进程：

    - usage_usec
    - user_usec
    - system_usec

    当控制器启用时，报告以下五个统计信息，这些信息仅计算公平类调度器下的进程：

    - nr_periods
    - nr_throttled
    - throttled_usec
    - nr_bursts
    - burst_usec

  `cpu.weight`
    存在于非根 cgroup 上的读写单值文件。默认为 "100"。

    对于非空闲组 (cpu.idle = 0)，权重范围为 [1, 10000]。

    如果 cgroup 已配置为 SCHED_IDLE (cpu.idle = 1)，则权重将显示为 0。

    此文件仅影响公平类调度器下的进程和具有 `cgroup_set_weight` 回调的 BPF 调度器下的进程，具体取决于回调实际执行的操作。

  `cpu.weight.nice`
    存在于非根 cgroup 上的读写单值文件。默认为 "0"。

    nice 值范围为 [-20, 19]。

    此接口文件是 "cpu.weight" 的替代接口，允许使用 nice(2) 使用的相同值读取和设置权重。由于 nice 值的范围较小且粒度较粗，因此读取的值是当前权重的最接近近似值。

    此文件仅影响公平类调度器下的进程和具有 `cgroup_set_weight` 回调的 BPF 调度器下的进程，具体取决于回调实际执行的操作。

  `cpu.max`
    存在于非根 cgroup 上的读写双值文件。默认为 "max 100000"。

    最大带宽限制。格式如下：

      $MAX $PERIOD

    这表示该组在每个 $PERIOD 持续时间内最多可以消耗 $MAX。$MAX 为 "max" 表示无限制。如果只写入一个数字，则更新 $MAX。

    此文件仅影响公平类调度器下的进程。

  `cpu.max.burst`
    存在于非根 cgroup 上的读写单值文件。默认为 "0"。

    突发范围为 [0, $MAX]。

    此文件仅影响公平类调度器下的进程。

  `cpu.pressure`
    读写嵌套键控文件。

    显示 CPU 的压力停顿信息。有关详细信息，请参阅 [Documentation/accounting/psi.rst](Documentation/accounting/psi.rst)。

    此文件计算 cgroup 中的所有进程。

  `cpu.uclamp.min`
    存在于非根 cgroup 上的读写单值文件。默认为 "0"，即无利用率提升。

    请求的最小利用率（保护）作为百分比有理数，例如 12.34 表示 12.34%。

    此接口允许读取和设置类似于 sched_setattr(2) 的最小利用率钳位值。此最小利用率值用于钳位任务特定的最小利用率钳位，包括实时进程的钳位。

    请求的最小利用率（保护）始终受当前最大利用率（限制）值（即 `cpu.uclamp.max`）的上限限制。

    此文件影响 cgroup 中的所有进程。

  `cpu.uclamp.max`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。即无利用率上限。

    请求的最大利用率（限制）作为百分比有理数，例如 98.76 表示 98.76%。

    此接口允许读取和设置类似于 sched_setattr(2) 的最大利用率钳位值。此最大利用率值用于钳位任务特定的最大利用率钳位，包括实时进程的钳位。

    此文件影响 cgroup 中的所有进程。

  `cpu.idle`
    存在于非根 cgroup 上的读写单值文件。默认为 0。

    这是每个任务 SCHED_IDLE 调度策略的 cgroup 模拟。将此值设置为 1 将使 cgroup 的调度策略变为 SCHED_IDLE。cgroup 内的线程将保留其自己的相对优先级，但 cgroup 本身相对于其对等方将被视为非常低的优先级。

    此文件仅影响公平类调度器下的进程。

## 5-2. 内存

"memory" 控制器调节内存的分配。内存是有状态的，并实现限制和保护模型。由于内存使用与回收压力之间的交织以及内存的有状态性质，分配模型相对复杂。

虽然不是完全严密，但会跟踪给定 cgroup 的所有主要内存使用情况，以便可以在合理范围内计算和控制总内存消耗。目前，跟踪以下类型的内存使用情况。

- 用户空间内存 - 页面缓存和匿名内存。

- 内核数据结构，如 dentry 和 inode。

- TCP 套接字缓冲区。

上述列表将来可能会扩展以获得更好的覆盖范围。

### 5-2-1. 内存接口文件

所有内存量均以字节为单位。如果写入的值未与 PAGE_SIZE 对齐，则读回时该值可能会向上舍入到最接近的 PAGE_SIZE 倍数。

  `memory.current`
    存在于非根 cgroup 上的只读单值文件。

    cgroup 及其后代当前使用的内存总量。

  `memory.min`
    存在于非根 cgroup 上的读写单值文件。默认为 "0"。

    硬内存保护。如果 cgroup 的内存使用量在其有效 min 边界内，则在任何情况下都不会回收 cgroup 的内存。如果没有可用的未受保护的可回收内存，则调用 OOM killer。在有效 min 边界之上（如果有效 low 边界更高，则为有效 low 边界），页面将按超额比例回收，从而减少较小超额的回收压力。

    有效 min 边界受所有祖先 cgroup 的 memory.min 值限制。如果存在 memory.min 超额承诺（子 cgroup 需要的受保护内存多于父级允许的内存），则每个子 cgroup 将获得父级保护的一部分，该部分与其低于 memory.min 的实际内存使用量成比例。

    不鼓励在此保护下放置比通常可用的更多内存，这可能会导致持续的 OOM。

    如果内存 cgroup 未填充进程，则忽略其 memory.min。

  `memory.low`
    存在于非根 cgroup 上的读写单值文件。默认为 "0"。

    尽力而为的内存保护。如果 cgroup 的内存使用量在其有效 low 边界内，则除非未受保护的 cgroup 中没有可回收内存，否则不会回收 cgroup 的内存。在有效 low 边界之上（如果有效 min 边界更高，则为有效 min 边界），页面将按超额比例回收，从而减少较小超额的回收压力。

    有效 low 边界受所有祖先 cgroup 的 memory.low 值限制。如果存在 memory.low 超额承诺（子 cgroup 需要的受保护内存多于父级允许的内存），则每个子 cgroup 将获得父级保护的一部分，该部分与其低于 memory.low 的实际内存使用量成比例。

    不鼓励在此保护下放置比通常可用的更多内存。

  `memory.high`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    内存使用节流限制。如果 cgroup 的使用量超过 high 边界，则 cgroup 的进程将受到节流并处于沉重的回收压力之下。

    超过 high 限制永远不会调用 OOM killer，并且在极端条件下可能会突破该限制。high 限制应用于外部进程监视受限 cgroup 以减轻沉重回收压力的场景。

    如果使用 O_NONBLOCK 打开 memory.high，则绕过同步回收。这对于需要动态调整作业内存限制而不消耗自身 CPU 资源进行内存回收的管理进程非常有用。作业将在其下一个收费请求时触发回收和/或受到节流。

    请注意，使用 O_NONBLOCK 时，由于延迟的收费请求或忙于访问其内存以减慢回收速度，目标内存 cgroup 可能会花费无限长的时间将使用量降低到限制以下。

  `memory.max`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    内存使用硬限制。这是限制 cgroup 内存使用的主要机制。如果 cgroup 的内存使用量达到此限制且无法减少，则在 cgroup 中调用 OOM killer。在某些情况下，使用量可能会暂时超过限制。

    在默认配置中，除非 OOM killer 选择当前任务作为受害者，否则常规 0 阶分配总是成功。

    某些类型的分配不会调用 OOM killer。调用者可以以不同方式重试它们，向用户空间返回 -ENOMEM，或者在磁盘预读等情况下静默忽略。

    如果使用 O_NONBLOCK 打开 memory.max，则绕过同步回收和 oom-kill。这对于需要动态调整作业内存限制而不消耗自身 CPU 资源进行内存回收的管理进程非常有用。作业将在其下一个收费请求时触发回收和/或 oom-kill。

    请注意，使用 O_NONBLOCK 时，由于延迟的收费请求或忙于访问其内存以减慢回收速度，目标内存 cgroup 可能会花费无限长的时间将使用量降低到限制以下。

  `memory.reclaim`
    存在于所有 cgroup 上的只写嵌套键控文件。

    这是触发目标 cgroup 中内存回收的简单接口。

    示例：

      echo "1G" > memory.reclaim

    请注意，内核可能会对目标 cgroup 进行过度回收或回收不足。如果回收的字节数少于指定数量，则返回 -EAGAIN。

    请注意，主动回收（由此接口触发）并不意味着内存 cgroup 存在内存压力。因此，通常不会在这种情况下执行由内存回收触发的套接字内存平衡。这意味着网络层不会根据 memory.reclaim 引起的回收进行调整。

    定义了以下嵌套键：

      swappiness
        用于回收的 Swappiness 值

      指定 swappiness 值指示内核使用该 swappiness 值执行回收。请注意，这与应用于 memcg 回收的 vm.swappiness 具有相同的语义，包括所有现有的限制和潜在的未来扩展。

      swappiness 的有效范围是 [0-200, max]，设置 swappiness=max 仅回收匿名内存。

  `memory.peak`
    存在于非根 cgroup 上的读写单值文件。

    自 cgroup 创建或该 FD 最近一次重置以来，为 cgroup 及其后代记录的最大内存使用量。

    向此文件写入任何非空字符串都会将其重置为当前内存使用量，以便通过同一文件描述符进行后续读取。

  `memory.oom.group`
    存在于非根 cgroup 上的读写单值文件。默认值为 "0"。

    确定 OOM killer 是否应将 cgroup 视为不可分割的工作负载。如果设置，属于 cgroup 或其后代（如果内存 cgroup 不是叶 cgroup）的所有任务都将被一起杀死或根本不被杀死。这可用于避免部分杀死以保证工作负载完整性。

    具有 OOM 保护（oom_score_adj 设置为 -1000）的任务被视为例外，永远不会被杀死。

    如果在 cgroup 中调用 OOM killer，它不会杀死此 cgroup 之外的任何任务，无论祖先 cgroup 的 memory.oom.group 值如何。

  `memory.events`
    存在于非根 cgroup 上的只读扁平键控文件。定义了以下条目。除非另有说明，否则此文件中的值更改会生成文件修改事件。

    请注意，此文件中的所有字段都是分层的，并且文件修改事件可能是由于层级结构下方的事件生成的。有关 cgroup 级别的本地事件，请参阅 memory.events.local。

      low
        由于高内存压力，即使使用量低于 low 边界，cgroup 被回收的次数。这通常表明 low 边界已超额承诺。

      high
        由于超过 high 内存边界，cgroup 的进程受到节流并被路由执行直接内存回收的次数。对于内存使用受 high 限制而不是全局内存压力限制的 cgroup，此事件的发生是预期的。

      max
        cgroup 的内存使用量即将超过 max 边界的次数。如果直接回收
        未能将其降低，则 cgroup 进入 OOM 状态。

      oom
        cgroup 的内存使用量达到限制且分配即将失败的次数。

        如果 OOM killer 未被视为选项（例如，对于失败的高阶分配或如果调用者要求不重试尝试），则不会引发此事件。

      oom_kill
        属于此 cgroup 的被任何类型的 OOM killer 杀死的进程数。

      oom_group_kill
        发生组 OOM 的次数。

  `memory.events.local`
    类似于 memory.events，但文件中的字段是 cgroup 本地的，即不是分层的。在此文件上生成的文件修改事件仅反映本地事件。

  `memory.stat`
    存在于非根 cgroup 上的只读扁平键控文件。

    这将 cgroup 的内存占用分解为不同类型的内存、特定于类型的详细信息以及有关内存管理系统状态和过去事件的其他信息。

    所有内存量均以字节为单位。

    条目按人类可读的顺序排列，新条目可能会出现在中间。不要依赖项目保持在固定位置；使用键来查找特定值！

    如果条目没有每节点计数器（或未显示在 memory.numa_stat 中）。我们使用 'npn'（非每节点）作为标记来指示它不会显示在 memory.numa_stat 中。

      anon
        匿名映射中使用的内存量，例如 brk()、sbrk() 和 mmap(MAP_ANONYMOUS)。请注意，如果只有部分（但不是全部）此类分配的内存被映射，某些内核配置可能会计算完整的较大分配（例如 THP）。

      file
        用于缓存文件系统数据的内存量，包括 tmpfs 和共享内存。

      kernel (npn)
        总内核内存量，包括 (kernel_stack, pagetables, percpu, vmalloc, slab) 以及其他内核内存用例。

      kernel_stack
        分配给内核堆栈的内存量。

      pagetables
        分配给页表的内存量。

      sec_pagetables
        分配给二级页表的内存量，目前包括 x86 和 arm64 上的 KVM mmu 分配以及 IOMMU 页表。

      percpu (npn)
        用于存储每 cpu 内核数据结构的内存量。

      sock (npn)
        网络传输缓冲区中使用的内存量。

      vmalloc (npn)
        用于 vmap 支持的内存的内存量。

      shmem
        交换支持的缓存文件系统数据量，例如 tmpfs、shm 段、共享匿名 mmap()。

      zswap
        zswap 压缩后端消耗的内存量。

      zswapped
        交换到 zswap 的应用程序内存量。

      file_mapped
        使用 mmap() 映射的缓存文件系统数据量。请注意，如果只有部分（但不是全部）此类分配的内存被映射，某些内核配置可能会计算完整的较大分配（例如 THP）。

      file_dirty
        已修改但尚未写回磁盘的缓存文件系统数据量。

      file_writeback
        已修改且当前正在写回磁盘的缓存文件系统数据量。

      swapcached
        内存中缓存的交换量。swapcache 计入内存和交换使用量。

      anon_thp
        由透明大页支持的匿名映射中使用的内存量。

      file_thp
        由透明大页支持的缓存文件系统数据量。

      shmem_thp
        由透明大页支持的 shm、tmpfs、共享匿名 mmap() 的量。

      inactive_anon, active_anon, inactive_file, active_file, unevictable
        页面回收算法使用的内部内存管理列表上的内存量（交换支持和文件系统支持）。

        由于这些代表内部列表状态（例如 shmem 页面在匿名内存管理列表上），inactive_foo + active_foo 可能不等于 foo 计数器的值，因为 foo 计数器是基于类型的，而不是基于列表的。

      slab_reclaimable
        可能被回收的 "slab" 部分，例如 dentry 和 inode。

      slab_unreclaimable
        在内存压力下无法回收的 "slab" 部分。

      slab (npn)
        用于存储内核内数据结构的内存量。

      workingset_refault_anon
        先前驱逐的匿名页面的重新故障数。

      workingset_refault_file
        先前驱逐的文件页面的重新故障数。

      workingset_activate_anon
        立即激活的重新故障匿名页面的数量。

      workingset_activate_file
        立即激活的重新故障文件页面的数量。

      workingset_restore_anon
        在被回收之前被检测为活动工作集的恢复匿名页面的数量。

      workingset_restore_file
        在被回收之前被检测为活动工作集的恢复文件页面的数量。

      workingset_nodereclaim
        影子节点被回收的次数。

      pswpin (npn)
        交换到内存中的页面数。

      pswpout (npn)
        从内存交换出的页面数。

      pgscan (npn)
        扫描的页面量（在非活动 LRU 列表中）。

      pgsteal (npn)
        回收的页面量。

      pgscan_kswapd (npn)
        kswapd 扫描的页面量（在非活动 LRU 列表中）。

      pgscan_direct (npn)
        直接扫描的页面量（在非活动 LRU 列表中）。

      pgscan_khugepaged (npn)
        khugepaged 扫描的页面量（在非活动 LRU 列表中）。

      pgscan_proactive (npn)
        主动扫描的页面量（在非活动 LRU 列表中）。

      pgsteal_kswapd (npn)
        kswapd 回收的页面量。

      pgsteal_direct (npn)
        直接回收的页面量。

      pgsteal_khugepaged (npn)
        khugepaged 回收的页面量。

      pgsteal_proactive (npn)
        主动回收的页面量。

      pgfault (npn)
        发生的缺页异常总数。

      pgmajfault (npn)
        发生的主要缺页异常数。

      pgrefill (npn)
        扫描的页面量（在活动 LRU 列表中）。

      pgactivate (npn)
        移动到活动 LRU 列表的页面量。

      pgdeactivate (npn)
        移动到非活动 LRU 列表的页面量。

      pglazyfree (npn)
        在内存压力下推迟释放的页面量。

      pglazyfreed (npn)
        回收的 lazyfree 页面量。

      swpin_zero
        交换到内存并填充为零的页面数，其中 I/O 被优化掉，因为在交换出期间检测到页面内容为零。

      swpout_zero
        由于检测到内容为零而跳过 I/O 的零填充页面交换出数。

      zswpin
        从 zswap 移入内存的页面数。

      zswpout
        从内存移出到 zswap 的页面数。

      zswpwb
        从 zswap 写入交换的页面数。

      thp_fault_alloc (npn)
        分配以满足缺页异常的透明大页数。当未设置 CONFIG_TRANSPARENT_HUGEPAGE 时，此计数器不存在。

      thp_collapse_alloc (npn)
        分配以允许折叠现有页面范围的透明大页数。当未设置 CONFIG_TRANSPARENT_HUGEPAGE 时，此计数器不存在。

      thp_swpout (npn)
        作为一个整体交换出而没有拆分的透明大页数。

      thp_swpout_fallback (npn)
        在交换出之前被拆分的透明大页数。通常是因为无法为大页分配一些连续的交换空间。

      numa_pages_migrated (npn)
        NUMA 平衡迁移的页面数。

      numa_pte_updates (npn)
        NUMA 平衡修改页表条目以在访问时产生 NUMA 提示错误的页面数。

      numa_hint_faults (npn)
        NUMA 提示错误数。

      pgdemote_kswapd
        kswapd 降级的页面数。

      pgdemote_direct
        直接降级的页面数。

      pgdemote_khugepaged
        khugepaged 降级的页面数。

      pgdemote_proactive
        主动降级的页面数。

      hugetlb
        hugetlb 页面使用的内存量。仅当 hugetlb 使用量计入 memory.current（即 cgroup 使用 memory_hugetlb_accounting 选项挂载）时，才会显示此指标。

  `memory.numa_stat`
    存在于非根 cgroup 上的只读嵌套键控文件。

    这将 cgroup 的内存占用分解为不同类型的内存、特定于类型的详细信息以及有关内存管理系统状态的每节点其他信息。

    这对于提供 memcg 内的 NUMA 局部性信息很有用，因为允许从任何物理节点分配页面。用例之一是通过将此信息与应用程序的 CPU 分配相结合来评估应用程序性能。

    所有内存量均以字节为单位。

    memory.numa_stat 的输出格式为：

      type N0=<bytes in node 0> N1=<bytes in node 1> ...

    条目按人类可读的顺序排列，新条目可能会出现在中间。不要依赖项目保持在固定位置；使用键来查找特定值！

    条目可以参考 memory.stat。

  `memory.swap.current`
    存在于非根 cgroup 上的只读单值文件。

    cgroup 及其后代当前使用的交换总量。

  `memory.swap.high`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    交换使用节流限制。如果 cgroup 的交换使用量超过此限制，则其所有进一步分配都将受到节流，以允许用户空间实现自定义内存不足过程。

    此限制标志着 cgroup 的不归路。它并非旨在管理工作负载在常规操作期间进行的交换量。与 memory.swap.max 相比，后者禁止交换超过设定量，但只要可以回收其他内存，就允许 cgroup 不受阻碍地继续。

    预计健康的工作负载不会达到此限制。

  `memory.swap.peak`
    存在于非根 cgroup 上的读写单值文件。

    自 cgroup 创建或该 FD 最近一次重置以来，为 cgroup 及其后代记录的最大交换使用量。

    向此文件写入任何非空字符串都会将其重置为当前内存使用量，以便通过同一文件描述符进行后续读取。

  `memory.swap.max`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    交换使用硬限制。如果 cgroup 的交换使用量达到此限制，则 cgroup 的匿名内存将不会被交换出。

  `memory.swap.events`
    存在于非根 cgroup 上的只读扁平键控文件。定义了以下条目。除非另有说明，否则此文件中的值更改会生成文件修改事件。

      high
        cgroup 的交换使用量超过 high 阈值的次数。

      max
        cgroup 的交换使用量即将超过 max 边界且交换分配失败的次数。

      fail
        由于系统范围内的交换耗尽或 max 限制而导致交换分配失败的次数。

    当减少到当前使用量以下时，现有的交换条目将逐渐回收，并且交换使用量可能会在很长一段时间内保持高于限制。这减少了对工作负载和内存管理的影响。

  `memory.zswap.current`
    存在于非根 cgroup 上的只读单值文件。

    zswap 压缩后端消耗的内存总量。

  `memory.zswap.max`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    Zswap 使用硬限制。如果 cgroup 的 zswap 池达到此限制，它将拒绝存储更多内容，直到现有条目缺页换回或写出到磁盘。

  `memory.zswap.writeback`
    读写单值文件。默认值为 "1"。
    请注意，此设置是分层的，即如果上层层级结构禁用回写，则子 cgroup 将隐式禁用回写。

    当设置为 0 时，禁用所有向交换设备的交换尝试。这包括 zswap 回写和由于 zswap 存储失败而导致的交换。如果 zswap 存储失败反复发生（例如，如果页面不可压缩），用户可能会在禁用回写后观察到回收效率低下（因为相同的页面可能会一次又一次地被拒绝）。

    请注意，这与将 memory.swap.max 设置为 0 有细微差别，因为它仍然允许将页面写入 zswap 池。如果禁用了 zswap，则此设置无效，并且除非 memory.swap.max 设置为 0，否则允许交换。

  `memory.pressure`
    只读嵌套键控文件。

    显示内存的压力停顿信息。有关详细信息，请参阅 [Documentation/accounting/psi.rst](Documentation/accounting/psi.rst)。

### 5-2-2. 使用指南

"memory.high" 是控制内存使用的主要机制。超额承诺 high 限制（high 限制之和 > 可用内存）并让全局内存压力根据使用情况分配内存是一种可行的策略。

由于突破 high 限制不会触发 OOM killer，而是会限制违规 cgroup，因此管理代理有充足的机会进行监控并采取适当的措施，例如授予更多内存或终止工作负载。

确定 cgroup 是否有足够的内存并非易事，因为内存使用量并不表示工作负载是否可以从更多内存中受益。例如，将从网络接收的数据写入文件的工作负载可以使用所有可用内存，但也可以使用少量内存高效运行。内存压力的度量 - 工作负载因缺乏内存而受到的影响程度 - 对于确定工作负载是否需要更多内存是必要的；不幸的是，内存压力监控机制尚未实现。

### 5-2-3. 内存所有权

内存区域计入实例化它的 cgroup，并保持计入该 cgroup，直到该区域被释放。将进程迁移到不同的 cgroup 不会将它在先前 cgroup 中实例化的内存使用量移动到新的 cgroup。

内存区域可能由属于不同 cgroup 的进程使用。该区域将计入哪个 cgroup 是不确定的；但是，随着时间的推移，内存区域可能会最终进入具有足够内存余量以避免高回收压力的 cgroup。

如果 cgroup 扫过大量预期会被其他 cgroup 重复访问的内存，则使用 POSIX_FADV_DONTNEED 放弃属于受影响文件的内存区域的所有权以确保正确的内存所有权可能是有意义的。

## 5-3. IO

"io" 控制器调节 IO 资源的分配。此控制器实现基于权重的和绝对带宽或 IOPS 限制分配；但是，仅当使用 cfq-iosched 时才可使用基于权重的分配，并且这两种方案都不适用于 blk-mq 设备。

### 5-3-1. IO 接口文件

  `io.stat`
    只读嵌套键控文件。

    行以 $MAJ:$MIN 设备号为键，且未排序。定义了以下嵌套键。

      ======    =====================
      rbytes    读取字节数
      wbytes    写入字节数
      rios      读取 IO 数
      wios      写入 IO 数
      dbytes    丢弃字节数
      dios      丢弃 IO 数
      ======    =====================

    示例读取输出如下：

      8:16 rbytes=1459200 wbytes=314773504 rios=192 wios=353 dbytes=0 dios=0
      8:0 rbytes=90430464 wbytes=299008000 rios=8950 wios=1252 dbytes=50331648 dios=3021

  `io.cost.qos`
    仅存在于根 cgroup 上的读写嵌套键控文件。

    此文件配置基于 IO 成本模型的控制器 (CONFIG_BLK_CGROUP_IOCOST) 的服务质量，该控制器目前实现 "io.weight" 比例控制。行以 $MAJ:$MIN 设备号为键，且未排序。给定设备的行在首次写入 "io.cost.qos" 或 "io.cost.model" 时填充。定义了以下嵌套键。
      ======    =====================================
      enable    基于权重的控制启用
      ctrl      "auto" 或 "user"
      rpct      读取延迟百分位数    [0, 100]
      rlat      读取延迟阈值
      wpct      写入延迟百分位数    [0, 100]
      wlat      写入延迟阈值
      min       最小缩放百分比 [1, 10000]
      max       最大缩放百分比 [1, 10000]
      ======    =====================================

    该控制器默认禁用，可以通过将 "enable" 设置为 1 来启用。"rpct" 和 "wpct" 参数默认为零，控制器使用内部设备饱和状态在 "min" 和 "max" 之间调整整体 IO 速率。

    当需要更好的控制质量时，可以配置延迟 QoS 参数。例如：

      8:16 enable=1 ctrl=auto rpct=95.00 rlat=75000 wpct=95.00 wlat=150000 min=50.00 max=150.0

    显示在 sdb 上，控制器已启用，如果读取完成延迟的第 95 个百分位数高于 75ms 或写入高于 150ms，则认为设备饱和，并相应地在 50% 和 150% 之间调整整体 IO 发出率。

    饱和点越低，延迟 QoS 越好，但代价是聚合带宽。在 "min" 和 "max" 之间允许的调整范围越窄，IO 行为就越符合成本模型。请注意，IO 发出基本速率可能远非 100%，盲目设置 "min" 和 "max" 可能会导致设备容量或控制质量的显着损失。"min" 和 "max" 对于调节显示出广泛的临时行为变化的设备很有用 - 例如，SSD 可以在一段时间内以线速接受写入，然后完全停顿数秒。

    当 "ctrl" 为 "auto" 时，参数由内核控制，可能会自动更改。将 "ctrl" 设置为 "user" 或设置任何百分位数和延迟参数会将其置于 "user" 模式并禁用自动更改。可以通过将 "ctrl" 设置为 "auto" 来恢复自动模式。

  `io.cost.model`
    仅存在于根 cgroup 上的读写嵌套键控文件。

    此文件配置基于 IO 成本模型的控制器 (CONFIG_BLK_CGROUP_IOCOST) 的成本模型，该控制器目前实现 "io.weight" 比例控制。行以 $MAJ:$MIN 设备号为键，且未排序。给定设备的行在首次写入 "io.cost.qos" 或 "io.cost.model" 时填充。定义了以下嵌套键。

      =====     ================================
      ctrl      "auto" 或 "user"
      model     正在使用的成本模型 - "linear"
      =====     ================================

    当 "ctrl" 为 "auto" 时，内核可能会动态更改所有参数。当 "ctrl" 设置为 "user" 或写入任何其他参数时，"ctrl" 变为 "user" 并且禁用自动更改。

    当 "model" 为 "linear" 时，定义了以下模型参数。

      ============= ========================================
      [r|w]bps      最大顺序 IO 吞吐量
      [r|w]seqiops  每秒最大 4k 顺序 IO 数
      [r|w]randiops 每秒最大 4k 随机 IO 数
      ============= ========================================

    根据上述内容，内置线性模型确定顺序和随机 IO 的基本成本以及 IO 大小的成本系数。虽然简单，但此模型可以接受地覆盖大多数常见设备类。

    IO 成本模型不期望在绝对意义上是准确的，并且会动态缩放到设备行为。

    如果需要，可以使用 tools/cgroup/iocost_coef_gen.py 生成特定于设备的系数。

  `io.weight`
    存在于非根 cgroup 上的读写扁平键控文件。默认为 "default 100"。

    第一行是应用于没有特定覆盖的设备的默认权重。其余的是以 $MAJ:$MIN 设备号为键的覆盖，且未排序。权重范围为 [1, 10000]，指定 cgroup 相对于其兄弟可以使用的相对 IO 时间量。

    可以通过写入 "default $WEIGHT" 或简单地 "$WEIGHT" 来更新默认权重。可以通过写入 "$MAJ:$MIN $WEIGHT" 来设置覆盖，并通过写入 "$MAJ:$MIN default" 来取消设置。

    示例读取输出如下：

      default 100
      8:16 200
      8:0 50

  `io.max`
    存在于非根 cgroup 上的读写嵌套键控文件。

    基于 BPS 和 IOPS 的 IO 限制。行以 $MAJ:$MIN 设备号为键，且未排序。定义了以下嵌套键。

      =====     ==================================
      rbps      每秒最大读取字节数
      wbps      每秒最大写入字节数
      riops     每秒最大读取 IO 操作数
      wiops     每秒最大写入 IO 操作数
      =====     ==================================

    写入时，可以按任何顺序指定任意数量的嵌套键值对。可以将 "max" 指定为值以删除特定限制。如果多次指定同一键，则结果未定义。

    BPS 和 IOPS 在每个 IO 方向上测量，如果达到限制，IO 将被延迟。允许临时突发。

    为 8:16 设置读取限制为 2M BPS 和写入限制为 120 IOPS：

      echo "8:16 rbps=2097152 wiops=120" > io.max

    读取返回以下内容：

      8:16 rbps=2097152 wbps=max riops=max wiops=120

    可以通过写入以下内容来删除写入 IOPS 限制：

      echo "8:16 wiops=max" > io.max

    现在读取返回以下内容：

      8:16 rbps=2097152 wbps=max riops=max wiops=max

  `io.pressure`
    只读嵌套键控文件。

    显示 IO 的压力停顿信息。有关详细信息，请参阅 [Documentation/accounting/psi.rst](Documentation/accounting/psi.rst)。

### 5-3-2. 回写 (Writeback)

页面缓存通过缓冲写入和共享 mmap 变脏，并通过回写机制异步写入后备文件系统。回写位于内存和 IO 域之间，通过平衡脏化和写入 IO 来调节脏内存的比例。

io 控制器与内存控制器结合，实现对页面缓存回写 IO 的控制。内存控制器定义计算和维护脏内存比率的内存域，io 控制器定义为内存域写出脏页的 io 域。检查系统范围和每个 cgroup 的脏内存状态，并强制执行两者中更严格的一个。

cgroup 回写需要底层文件系统的显式支持。目前，cgroup 回写在 ext2、ext4、btrfs、f2fs 和 xfs 上实现。在其他文件系统上，所有回写 IO 都归因于根 cgroup。

内存和回写管理存在固有的差异，这会影响 cgroup 所有权的跟踪方式。内存按页跟踪，而回写按 inode 跟踪。出于回写的目的，inode 被分配给一个 cgroup，并且从该 inode 写出脏页的所有 IO 请求都归因于该 cgroup。

由于内存的 cgroup 所有权是按页跟踪的，因此可能存在与 inode 关联的 cgroup 不同的 cgroup 关联的页面。这些被称为外来页面。回写不断跟踪外来页面，如果特定的外来 cgroup 在一段时间内成为多数，则将 inode 的所有权切换到该 cgroup。

虽然此模型对于大多数用例来说已经足够，即给定 inode 主要由单个 cgroup 弄脏，即使主要写入 cgroup 随时间变化，但多个 cgroup 同时写入单个 inode 的用例支持得不好。在这种情况下，很大一部分 IO 可能会被错误地归因。由于内存控制器在首次使用时分配页面所有权，并且在页面释放之前不会更新它，即使回写严格遵循页面所有权，多个 cgroup 弄脏重叠区域也不会按预期工作。建议避免此类使用模式。

影响回写行为的 sysctl 旋钮应用于 cgroup 回写如下。

  `vm.dirty_background_ratio`, `vm.dirty_ratio`
    这些比率同样适用于 cgroup 回写，可用内存量受内存控制器施加的限制和系统范围内的干净内存的限制。

  `vm.dirty_background_bytes`, `vm.dirty_bytes`
    对于 cgroup 回写，这被计算为与总可用内存的比率，并以与 `vm.dirty[_background]_ratio` 相同的方式应用。

### 5-3-3. IO 延迟

这是用于 IO 工作负载保护的 cgroup v2 控制器。您为组提供延迟目标，如果平均延迟超过该目标，控制器将限制任何延迟目标低于受保护工作负载的对等方。

限制仅应用于层级结构中的对等级别。这意味着在下图中，只有组 A、B 和 C 会相互影响，组 D 和 F 会相互影响。组 G 不会影响任何人：

			[root]
		/	   |		\
		A	   B		C
	       /  \        |
	      D    F	   G

因此，配置此功能的理想方法是在组 A、B 和 C 中设置 io.latency。通常，您不希望设置低于设备支持的延迟的值。进行实验以找到最适合您的工作负载的值。从高于设备预期延迟的值开始，并观察工作负载组的 io.stat 中的 avg_lat 值，以了解正常操作期间看到的延迟。使用 avg_lat 值作为实际设置的基础，设置为比 io.stat 中的值高 10-15%。

#### 5-3-3-1. IO 延迟节流如何工作

io.latency 是工作守恒的；因此，只要每个人都达到其延迟目标，控制器就不会做任何事情。一旦一个组开始错过其目标，它就会开始限制任何目标高于其自身的对等组。这种限制采取 2 种形式：

- 队列深度限制。这是一个组允许拥有的未完成 IO 的数量。我们将相对较快地进行钳制，从无限制开始，一直下降到一次 1 个 IO。

- 人工延迟诱导。某些类型的 IO 无法在不可能会对更高优先级组产生不利影响的情况下进行限制。这包括交换和元数据 IO。允许这些类型的 IO 正常发生，但它们被“记在”发起组的账上。如果发起组受到限制，您将看到 io.stat 中的 use_delay 和 delay 字段增加。delay 值是添加到在此组中运行的任何进程的微秒数。由于如果发生大量交换或元数据 IO，此数字可能会变得非常大，因此我们将单个延迟事件限制为一次 1 秒。

一旦受害组再次开始达到其延迟目标，它将开始取消限制先前受限的任何对等组。如果受害组只是停止进行 IO，则全局计数器将适当地取消限制。

#### 5-3-3-2. IO 延迟接口文件

  `io.latency`
    这采用与其他控制器类似的格式。

      "MAJOR:MINOR target=<target time in microseconds>"

  `io.stat`
    如果启用了控制器，除了正常的统计信息外，您还将在 io.stat 中看到额外的统计信息。

      depth
        这是组的当前队列深度。

      avg_lat
        这是一个指数移动平均值，衰减率为 1/exp，受采样间隔限制。可以通过将 io.stat 中的 win 值乘以基于 win 值的相应样本数来计算衰减率间隔。

      win
        以毫秒为单位的采样窗口大小。这是评估事件之间的最短持续时间。窗口仅随 IO 活动流逝。空闲期延长最近的窗口。

### 5-3-4. IO 优先级

单个属性控制 I/O 优先级 cgroup 策略的行为，即 io.prio.class 属性。该属性接受以下值：

  `no-change`
    不修改 I/O 优先级类。

  `promote-to-rt`
    对于具有非 RT I/O 优先级类的请求，将其更改为 RT。还将这些请求的优先级级别更改为 4。不修改具有优先级类 RT 的请求的 I/O 优先级。

  `restrict-to-be`
    对于没有 I/O 优先级类或具有 I/O 优先级类 RT 的请求，将其更改为 BE。还将这些请求的优先级级别更改为 0。不修改具有优先级类 IDLE 的请求的 I/O 优先级类。

  `idle`
    将所有请求的 I/O 优先级类更改为 IDLE，即最低 I/O 优先级类。

  `none-to-rt`
    已弃用。只是 promote-to-rt 的别名。

以下数值与 I/O 优先级策略相关联：

+----------------+---+
| no-change      | 0 |
+----------------+---+
| promote-to-rt  | 1 |
+----------------+---+
| restrict-to-be | 2 |
+----------------+---+
| idle           | 3 |
+----------------+---+

对应于每个 I/O 优先级类的数值如下：

+-------------------------------+---+
| IOPRIO_CLASS_NONE             | 0 |
+-------------------------------+---+
| IOPRIO_CLASS_RT (real-time)   | 1 |
+-------------------------------+---+
| IOPRIO_CLASS_BE (best effort) | 2 |
+-------------------------------+---+
| IOPRIO_CLASS_IDLE             | 3 |
+-------------------------------+---+

设置请求的 I/O 优先级类的算法如下：

- 如果 I/O 优先级类策略是 promote-to-rt，则将请求 I/O 优先级类更改为 IOPRIO_CLASS_RT，并将请求 I/O 优先级级别更改为 4。
- 如果 I/O 优先级类策略不是 promote-to-rt，则将 I/O 优先级类策略转换为数字，然后将请求 I/O 优先级类更改为 I/O 优先级类策略编号和数值 I/O 优先级类的最大值。

## 5-4. PID

进程数控制器用于允许 cgroup 在达到指定限制后停止任何新任务被 fork() 或 clone()。

cgroup 中的任务数可能会以其他控制器无法阻止的方式耗尽，因此需要自己的控制器。例如，fork 炸弹很可能在达到内存限制之前耗尽任务数。

请注意，此控制器中使用的 PID 指的是 TID，即内核使用的进程 ID。

### 5-4-1. PID 接口文件

  `pids.max`
    存在于非根 cgroup 上的读写单值文件。默认为 "max"。

    进程数的硬限制。

  `pids.current`
    存在于非根 cgroup 上的只读单值文件。

    cgroup 及其后代中当前的进程数。

  `pids.peak`
    存在于非根 cgroup 上的只读单值文件。

    cgroup 及其后代中的进程数曾经达到的最大值。

  `pids.events`
    存在于非根 cgroup 上的只读扁平键控文件。除非另有说明，否则此文件中的值更改会生成文件修改事件。定义了以下条目。

      max
        cgroup 的总进程数达到 pids.max 限制的次数（另请参阅 pids_localevents）。

  `pids.events.local`
    类似于 pids.events，但文件中的字段是 cgroup 本地的，即不是分层的。在此文件上生成的文件修改事件仅反映本地事件。

组织操作不受 cgroup 策略的阻止，因此可能有 pids.current > pids.max。这可以通过将限制设置为小于 pids.current，或者将足够的进程附加到 cgroup 以使 pids.current 大于 pids.max 来完成。但是，不可能通过 fork() 或 clone() 违反 cgroup PID 策略。如果创建新进程会导致违反 cgroup 策略，这些将返回 -EAGAIN。

## 5-5. Cpuset

"cpuset" 控制器提供了一种机制，用于将任务的 CPU 和内存节点放置仅限制为任务当前 cgroup 的 cpuset 接口文件中指定的资源。这在大型 NUMA 系统上特别有价值，在这些系统上，通过仔细的处理器和内存放置将作业放置在系统的适当大小的子集上以减少跨节点内存访问和争用，可以提高整体系统性能。

"cpuset" 控制器是分层的。这意味着控制器不能使用其父级不允许的 CPU 或内存节点。

### 5.5-1. Cpuset 接口文件

  `cpuset.cpus`
    存在于非根启用 cpuset 的 cgroup 上的读写多值文件。

    它列出了此 cgroup 内的任务请求使用的 CPU。但是，实际授予的 CPU 列表受其父级施加的约束，并且可能与请求的 CPU 不同。

    CPU 编号是逗号分隔的数字或范围。例如：

      # cat cpuset.cpus
      0-4,6,8-10

    空值表示 cgroup 使用与具有非空 "cpuset.cpus" 的最近 cgroup 祖先相同的设置，如果未找到，则使用所有可用 CPU。

    "cpuset.cpus" 的值在下次更新之前保持不变，并且不会受到任何 CPU 热插拔事件的影响。

  `cpuset.cpus.effective`
    存在于所有启用 cpuset 的 cgroup 上的只读多值文件。

    它列出了其父级实际授予此 cgroup 的在线 CPU。允许当前 cgroup 内的任务使用这些 CPU。

    如果 "cpuset.cpus" 为空，则 "cpuset.cpus.effective" 文件显示父 cgroup 中可供此 cgroup 使用的所有 CPU。否则，它应该是 "cpuset.cpus" 的子集，除非无法授予 "cpuset.cpus" 中列出的任何 CPU。在这种情况下，它将被视为空的 "cpuset.cpus"。

    其值将受到 CPU 热插拔事件的影响。

  `cpuset.mems`
    存在于非根启用 cpuset 的 cgroup 上的读写多值文件。

    它列出了此 cgroup 内的任务请求使用的内存节点。但是，实际授予的内存节点列表受其父级施加的约束，并且可能与请求的内存节点不同。

    内存节点编号是逗号分隔的数字或范围。例如：

      # cat cpuset.mems
      0-1,3

    空值表示 cgroup 使用与具有非空 "cpuset.mems" 的最近 cgroup 祖先相同的设置，如果未找到，则使用所有可用内存节点。

    "cpuset.mems" 的值在下次更新之前保持不变，并且不会受到任何内存节点热插拔事件的影响。

    将非空值设置为 "cpuset.mems" 会导致 cgroup 内的任务的内存迁移到指定的节点（如果它们当前正在使用指定节点之外的内存）。

    这种内存迁移是有代价的。迁移可能不完整，并且可能会留下一些内存页面。因此，建议应正确设置 "cpuset.mems"。
    在将新任务生成到 cpuset 之前。即使需要更改具有活动任务的 "cpuset.mems"，也不应频繁进行。

  `cpuset.mems.effective`
    存在于所有启用 cpuset 的 cgroup 上的只读多值文件。

    它列出了其父级实际授予此 cgroup 的在线内存节点。允许当前 cgroup 内的任务使用这些内存节点。

    如果 "cpuset.mems" 为空，它显示父 cgroup 中可供此 cgroup 使用的所有内存节点。否则，它应该是 "cpuset.mems" 的子集，除非无法授予 "cpuset.mems" 中列出的任何内存节点。在这种情况下，它将被视为空的 "cpuset.mems"。

    其值将受到内存节点热插拔事件的影响。

  `cpuset.cpus.exclusive`
    存在于非根启用 cpuset 的 cgroup 上的读写多值文件。

    它列出了允许用于创建新 cpuset 分区的所有独占 CPU。除非 cgroup 成为有效的分区根，否则不使用其值。有关 cpuset 分区的描述，请参阅下面的 "cpuset.cpus.partition" 部分。

    当 cgroup 成为分区根时，分配给该分区的实际独占 CPU 列在 "cpuset.cpus.exclusive.effective" 中，这可能与 "cpuset.cpus.exclusive" 不同。如果之前已设置 "cpuset.cpus.exclusive"，则 "cpuset.cpus.exclusive.effective" 始终是它的子集。

    用户可以手动将其设置为与 "cpuset.cpus" 不同的值。设置它的一个约束是 CPU 列表必须与其兄弟的 "cpuset.cpus.exclusive" 互斥。如果未设置兄弟 cgroup 的 "cpuset.cpus.exclusive"，则其 "cpuset.cpus" 值（如果已设置）不能是它的子集，以便在拿走独占 CPU 时至少留出一个 CPU 可用。

    对于父 cgroup，其任何一个独占 CPU 最多只能分配给其一个子 cgroup。不允许独占 CPU 出现在其两个或更多子 cgroup 中（排他性规则）。违反排他性规则的值将被拒绝并出现写入错误。

    根 cgroup 是分区根，其所有可用 CPU 都在其独占 CPU 集中。

  `cpuset.cpus.exclusive.effective`
    存在于所有非根启用 cpuset 的 cgroup 上的只读多值文件。

    此文件显示可用于创建分区根的有效独占 CPU 集。如果其父级不是根 cgroup，则此文件的内容将始终是其父级 "cpuset.cpus.exclusive.effective" 的子集。如果已设置，它也将是 "cpuset.cpus.exclusive" 的子集。如果未设置 "cpuset.cpus.exclusive"，则在形成本地分区时将其视为具有 "cpuset.cpus" 的隐式值。

  `cpuset.cpus.isolated`
    只读且仅限根 cgroup 的多值文件。

    此文件显示现有隔离分区中使用的所有隔离 CPU 的集合。如果未创建隔离分区，它将为空。

  `cpuset.cpus.partition`
    存在于非根启用 cpuset 的 cgroup 上的读写单值文件。此标志归父 cgroup 所有，不可委托。

    写入时仅接受以下输入值。

      ==========    =====================================
      "member"      分区的非根成员
      "root"        分区根
      "isolated"    无负载均衡的分区根
      ==========    =====================================

    cpuset 分区是启用 cpuset 的 cgroup 的集合，在层级结构的顶部有一个分区根，及其后代，除了那些本身是单独分区根及其后代的 cgroup。分区对其分配的独占 CPU 集具有独占访问权限。该分区之外的其他 cgroup 不能使用该集中的任何 CPU。

    有两种类型的分区 - 本地和远程。本地分区是其父 cgroup 也是有效分区根的分区。远程分区是其父 cgroup 本身不是有效分区根的分区。对于创建本地分区，写入 "cpuset.cpus.exclusive" 是可选的，因为如果未设置，其 "cpuset.cpus.exclusive" 文件将假定一个与 "cpuset.cpus" 相同的隐式值。对于创建远程分区，必须在目标分区根之前的 cgroup 层级结构中写入正确的 "cpuset.cpus.exclusive" 值。

    目前，无法在本地分区下创建远程分区。除了根 cgroup 之外，远程分区根的所有祖先都不能是分区根。

    根 cgroup 始终是分区根，其状态无法更改。所有其他非根 cgroup 最初都是 "member"。

    当设置为 "root" 时，当前 cgroup 是新分区或调度域的根。独占 CPU 集由其 "cpuset.cpus.exclusive.effective" 的值确定。

    当设置为 "isolated" 时，该分区中的 CPU 将处于隔离状态，没有任何来自调度程序的负载平衡，并且从非绑定工作队列中排除。放置在具有多个 CPU 的此类分区中的任务应仔细分发并绑定到每个单独的 CPU 以获得最佳性能。

    分区根（"root" 或 "isolated"）可以处于两种可能的状态之一 - 有效或无效。无效的分区根处于降级状态，其中可能会保留一些状态信息，但行为更像 "member"。

    允许在 "member"、"root" 和 "isolated" 之间进行所有可能的状态转换。

    读取时，"cpuset.cpus.partition" 文件可以显示以下值。

      ============================= =====================================
      "member"                      分区的非根成员
      "root"                        分区根
      "isolated"                    无负载均衡的分区根
      "root invalid (<reason>)"     无效的分区根
      "isolated invalid (<reason>)" 无效的隔离分区根
      ============================= =====================================

    在无效分区根的情况下，括号内包含有关分区为何无效的描述性字符串。

    要使本地分区根有效，必须满足以下条件。

    1) 父 cgroup 是有效的分区根。
    2) "cpuset.cpus.exclusive.effective" 文件不能为空，尽管它可能包含离线 CPU。
    3) 除非没有与此分区关联的任务，否则 "cpuset.cpus.effective" 不能为空。

    要使远程分区根有效，必须满足除第一个条件之外的所有上述条件。

    诸如热插拔或对 "cpuset.cpus" 或 "cpuset.cpus.exclusive" 的更改之类的外部事件可能导致有效的分区根变为无效，反之亦然。请注意，无法将任务移动到具有空 "cpuset.cpus.effective" 的 cgroup。

    当没有与其关联的任务时，有效的非根父分区可以将其所有 CPU 分发给其子本地分区。

    必须小心将有效的分区根更改为 "member"，因为它的所有子本地分区（如果存在）将变为无效，从而导致在这些子分区中运行的任务中断。如果这些非活动分区的父级切换回具有 "cpuset.cpus" 或 "cpuset.cpus.exclusive" 中正确值的分区根，则可以恢复这些分区。

    每当 "cpuset.cpus.partition" 的状态发生变化时，都会触发 Poll 和 inotify 事件。这包括由写入 "cpuset.cpus.partition"、cpu 热插拔或其他修改分区有效性状态的更改引起的更改。这将允许用户空间代理监视对 "cpuset.cpus.partition" 的意外更改，而无需进行连续轮询。

    用户可以在启动时使用 "isolcpus" 内核启动命令行选项将某些 CPU 预配置为禁用负载平衡的隔离状态。如果要将这些 CPU 放入分区，则必须在隔离分区中使用它们。

## 5-6. 设备控制器

设备控制器管理对设备文件的访问。它包括创建新设备文件（使用 mknod）和访问现有设备文件。

Cgroup v2 设备控制器没有接口文件，是在 cgroup BPF 之上实现的。为了控制对设备文件的访问，用户可以创建 BPF_PROG_TYPE_CGROUP_DEVICE 类型的 bpf 程序，并使用 BPF_CGROUP_DEVICE 标志将其附加到 cgroup。在尝试访问设备文件时，将执行相应的 BPF 程序，根据返回值，尝试将成功或失败并返回 -EPERM。

BPF_PROG_TYPE_CGROUP_DEVICE 程序采用指向 bpf_cgroup_dev_ctx 结构的指针，该结构描述了设备访问尝试：访问类型（mknod/read/write）和设备（类型、主设备号和次设备号）。如果程序返回 0，则尝试失败并返回 -EPERM，否则成功。

BPF_PROG_TYPE_CGROUP_DEVICE 程序的示例可以在内核源代码树中的 tools/testing/selftests/bpf/progs/dev_cgroup.c 中找到。

## 5-7. RDMA

"rdma" 控制器调节 RDMA 资源的分配和记账。

### 5-7-1. RDMA 接口文件

  `rdma.max`
    存在于除根之外的所有 cgroup 上的读写嵌套键控文件，描述了 RDMA/IB 设备的当前配置资源限制。

    行以设备名称为键，且未排序。每行包含空格分隔的资源名称及其可分配的配置限制。

    定义了以下嵌套键。

      ==========    =============================
      hca_handle    HCA 句柄的最大数量
      hca_object    HCA 对象的最大数量
      ==========    =============================

    mlx4 和 ocrdma 设备的示例如下：

      mlx4_0 hca_handle=2 hca_object=2000
      ocrdma1 hca_handle=3 hca_object=max

  `rdma.current`
    描述当前资源使用情况的只读文件。它存在于除根之外的所有 cgroup 中。

    mlx4 和 ocrdma 设备的示例如下：

      mlx4_0 hca_handle=1 hca_object=20
      ocrdma1 hca_handle=1 hca_object=23

## 5-8. DMEM

"dmem" 控制器调节设备内存区域的分配和记账。由于每个内存区域可能有自己的页面大小，不必等于系统页面大小，因此单位始终是字节。

### 5-8-1. DMEM 接口文件

  `dmem.max`, `dmem.min`, `dmem.low`
    存在于除根之外的所有 cgroup 上的读写嵌套键控文件，描述了区域的当前配置资源限制。

    xe 的示例如下：

      drm/0000:03:00.0/vram0 1073741824
      drm/0000:03:00.0/stolen max

    语义与内存 cgroup 控制器相同，并且以相同的方式计算。

  `dmem.capacity`
    描述最大区域容量的只读文件。它仅存在于根 cgroup 上。并非所有内存都可以由 cgroup 分配，因为内核保留了一些供内部使用。

    xe 的示例如下：

      drm/0000:03:00.0/vram0 8514437120
      drm/0000:03:00.0/stolen 67108864

  `dmem.current`
    描述当前资源使用情况的只读文件。它存在于除根之外的所有 cgroup 中。

    xe 的示例如下：

      drm/0000:03:00.0/vram0 12550144
      drm/0000:03:00.0/stolen 8650752

## 5-9. HugeTLB

HugeTLB 控制器允许限制每个控制组的 HugeTLB 使用量，并在缺页异常期间强制执行控制器限制。

### 5.9-1. HugeTLB 接口文件

  `hugetlb.<hugepagesize>.current`
    显示 "hugepagesize" hugetlb 的当前使用情况。它存在于除根之外的所有 cgroup 中。

  `hugetlb.<hugepagesize>.max`
    设置/显示 "hugepagesize" hugetlb 使用量的硬限制。默认值为 "max"。它存在于除根之外的所有 cgroup 中。

  `hugetlb.<hugepagesize>.events`
    存在于非根 cgroup 上的只读扁平键控文件。

      max
        由于 HugeTLB 限制导致的分配失败次数

  `hugetlb.<hugepagesize>.events.local`
    类似于 hugetlb.<hugepagesize>.events，但文件中的字段是 cgroup 本地的，即不是分层的。在此文件上生成的文件修改事件仅反映本地事件。

  `hugetlb.<hugepagesize>.numa_stat`
    类似于 memory.numa_stat，它显示此 cgroup 中 <hugepagesize> 的 hugetlb 页面的 numa 信息。仅包括活动使用的 hugetlb 页面。每节点值以字节为单位。

## 5-10. 杂项 (Misc)

杂项 cgroup 为无法像其他 cgroup 资源那样抽象的标量资源提供资源限制和跟踪机制。控制器由 CONFIG_CGROUP_MISC 配置选项启用。

可以通过 include/linux/misc_cgroup.h 文件中的 enum misc_res_type{} 将资源添加到控制器，并通过 kernel/cgroup/misc.c 文件中的 misc_res_name[] 添加相应的名称。资源的提供者必须在通过调用 misc_cg_set_capacity() 使用资源之前设置其容量。

一旦设置了容量，就可以使用 charge 和 uncharge API 更新资源使用情况。与 misc 控制器交互的所有 API 都在 include/linux/misc_cgroup.h 中。

### 5.10-1 杂项接口文件

杂项控制器提供 3 个接口文件。如果注册了两个杂项资源（res_a 和 res_b），则：

  `misc.capacity`
    仅在根 cgroup 中显示的只读扁平键控文件。它显示平台上可用的杂项标量资源及其数量：

      $ cat misc.capacity
      res_a 50
      res_b 10

  `misc.current`
    在所有 cgroup 中显示的只读扁平键控文件。它显示 cgroup 及其子级中资源的当前使用情况。：

      $ cat misc.current
      res_a 3
      res_b 0

  `misc.peak`
    在所有 cgroup 中显示的只读扁平键控文件。它显示 cgroup 及其子级中资源的历史最大使用情况。：

      $ cat misc.peak
      res_a 10
      res_b 8

  `misc.max`
    在非根 cgroup 中显示的读写扁平键控文件。允许 cgroup 及其子级中资源的最大使用量。：

      $ cat misc.max
      res_a max
      res_b 4

    可以通过以下方式设置限制：

      # echo res_a 1 > misc.max

    可以通过以下方式将限制设置为 max：

      # echo res_a max > misc.max

    可以将限制设置为高于 misc.capacity 文件中的容量值。

  `misc.events`
    存在于非根 cgroup 上的只读扁平键控文件。定义了以下条目。除非另有说明，否则此文件中的值更改会生成文件修改事件。此文件中的所有字段都是分层的。

      max
        cgroup 的资源使用量即将超过 max 边界的次数。

  `misc.events.local`
    类似于 misc.events，但文件中的字段是 cgroup 本地的，即不是分层的。在此文件上生成的文件修改事件仅反映本地事件。

### 5.10-2 迁移和所有权

杂项标量资源计入首次使用它的 cgroup，并保持计入该 cgroup，直到该资源被释放。将进程迁移到不同的 cgroup 不会将费用移动到进程移动到的目标 cgroup。

## 5-11. 其他

### 5-11-1. perf_event

如果未挂载在旧版层级结构上，perf_event 控制器将在 v2 层级结构上自动启用，以便始终可以通过 cgroup v2 路径过滤 perf 事件。在填充 v2 层级结构后，控制器仍可以移动到旧版层级结构。

## 5-N. 非规范性信息

本节包含不被视为稳定内核 API 一部分的信息，因此可能会发生变化。

### 5-N-1. CPU 控制器根 cgroup 进程行为

在根 cgroup 中分配 CPU 周期时，此 cgroup 中的每个线程都被视为托管在根 cgroup 的单独子 cgroup 中。此子 cgroup 的权重取决于其线程 nice 级别。

有关此映射的详细信息，请参阅 kernel/sched/core.c 文件中的 sched_prio_to_weight 数组（应适当缩放此数组中的值，以便中性 - nice 0 - 值为 100 而不是 1024）。

### 5-N-2. IO 控制器根 cgroup 进程行为

根 cgroup 进程托管在隐式叶子节点中。在分配 IO 资源时，此隐式子节点被考虑在内，就好像它是根 cgroup 的普通子 cgroup，权重值为 200。

# 6. 命名空间

## 6-1. 基础

cgroup 命名空间提供了一种机制来虚拟化 "/proc/$PID/cgroup" 文件和 cgroup 挂载的视图。CLONE_NEWCGROUP clone 标志可与 clone(2) 和 unshare(2) 一起使用以创建新的 cgroup 命名空间。在 cgroup 命名空间内运行的进程的 "/proc/$PID/cgroup" 输出将限制为 cgroupns 根。cgroupns 根是创建 cgroup 命名空间时进程的 cgroup。

如果没有 cgroup 命名空间，"/proc/$PID/cgroup" 文件将显示进程 cgroup 的完整路径。在旨在隔离进程的一组 cgroup 和命名空间的容器设置中，"/proc/$PID/cgroup" 文件可能会向隔离进程泄漏潜在的系统级信息。例如：

  # cat /proc/self/cgroup
  0::/batchjobs/container_id1

路径 '/batchjobs/container_id1' 可以被视为系统数据，不希望暴露给隔离进程。cgroup 命名空间可用于限制此路径的可见性。例如，在创建 cgroup 命名空间之前，人们会看到：

  # ls -l /proc/self/ns/cgroup
  lrwxrwxrwx 1 root root 0 2014-07-15 10:37 /proc/self/ns/cgroup -> cgroup:[4026531835]
  # cat /proc/self/cgroup
  0::/batchjobs/container_id1

取消共享新命名空间后，视图将更改：

  # ls -l /proc/self/ns/cgroup
  lrwxrwxrwx 1 root root 0 2014-07-15 10:35 /proc/self/ns/cgroup -> cgroup:[4026532183]
  # cat /proc/self/cgroup
  0::/

当多线程进程中的某个线程取消共享其 cgroup 命名空间时，新的 cgroupns 将应用于整个进程（所有线程）。这对于 v2 层级结构来说是很自然的；但是，对于旧版层级结构，这可能是意想不到的。
  `misc.capacity`
    仅在根 cgroup 中显示的只读扁平键控文件。它显示平台上可用的杂项标量资源及其数量：

      $ cat misc.capacity
      res_a 50
      res_b 10

  `misc.current`
    在所有 cgroup 中显示的只读扁平键控文件。它显示 cgroup 及其子级中资源的当前使用情况。：

      $ cat misc.current
      res_a 3
      res_b 0

  `misc.peak`
    在所有 cgroup 中显示的只读扁平键控文件。它显示 cgroup 及其子级中资源的历史最大使用情况。：

      $ cat misc.peak
      res_a 10
      res_b 8

  `misc.max`
    在非根 cgroup 中显示的读写扁平键控文件。允许 cgroup 及其子级中资源的最大使用量。：

      $ cat misc.max
      res_a max
      res_b 4

    可以通过以下方式设置限制：

      # echo res_a 1 > misc.max

    可以通过以下方式将限制设置为 max：

      # echo res_a max > misc.max

    可以将限制设置为高于 misc.capacity 文件中的容量值。

  `misc.events`
    存在于非根 cgroup 上的只读扁平键控文件。定义了以下条目。除非另有说明，否则此文件中的值更改会生成文件修改事件。此文件中的所有字段都是分层的。

      max
        cgroup 的资源使用量即将超过 max 边界的次数。

  `misc.events.local`
    类似于 misc.events，但文件中的字段是 cgroup 本地的，即不是分层的。在此文件上生成的文件修改事件仅反映本地事件。

### 5.10-2 迁移和所有权

杂项标量资源计入首次使用它的 cgroup，并保持计入该 cgroup，直到该资源被释放。将进程迁移到不同的 cgroup 不会将费用移动到进程移动到的目标 cgroup。

## 5-11. 其他

### 5-11-1. perf_event

如果未挂载在旧版层级结构上，perf_event 控制器将在 v2 层级结构上自动启用，以便始终可以通过 cgroup v2 路径过滤 perf 事件。在填充 v2 层级结构后，控制器仍可以移动到旧版层级结构。

## 5-N. 非规范性信息

本节包含不被视为稳定内核 API 一部分的信息，因此可能会发生变化。

### 5-N-1. CPU 控制器根 cgroup 进程行为

在根 cgroup 中分配 CPU 周期时，此 cgroup 中的每个线程都被视为托管在根 cgroup 的单独子 cgroup 中。此子 cgroup 的权重取决于其线程 nice 级别。

有关此映射的详细信息，请参阅 kernel/sched/core.c 文件中的 sched_prio_to_weight 数组（应适当缩放此数组中的值，以便中性 - nice 0 - 值为 100 而不是 1024）。

### 5-N-2. IO 控制器根 cgroup 进程行为

根 cgroup 进程托管在隐式叶子节点中。在分配 IO 资源时，此隐式子节点被考虑在内，就好像它是根 cgroup 的普通子 cgroup，权重值为 200。

# 6. 命名空间

## 6-1. 基础

cgroup 命名空间提供了一种机制来虚拟化 "/proc/$PID/cgroup" 文件和 cgroup 挂载的视图。CLONE_NEWCGROUP clone 标志可与 clone(2) 和 unshare(2) 一起使用以创建新的 cgroup 命名空间。在 cgroup 命名空间内运行的进程的 "/proc/$PID/cgroup" 输出将限制为 cgroupns 根。cgroupns 根是创建 cgroup 命名空间时进程的 cgroup。

如果没有 cgroup 命名空间，"/proc/$PID/cgroup" 文件将显示进程 cgroup 的完整路径。在旨在隔离进程的一组 cgroup 和命名空间的容器设置中，"/proc/$PID/cgroup" 文件可能会向隔离进程泄漏潜在的系统级信息。例如：

  # cat /proc/self/cgroup
  0::/batchjobs/container_id1

路径 '/batchjobs/container_id1' 可以被视为系统数据，不希望暴露给隔离进程。cgroup 命名空间可用于限制此路径的可见性。例如，在创建 cgroup 命名空间之前，人们会看到：

  # ls -l /proc/self/ns/cgroup
  lrwxrwxrwx 1 root root 0 2014-07-15 10:37 /proc/self/ns/cgroup -> cgroup:[4026531835]
  # cat /proc/self/cgroup
  0::/batchjobs/container_id1

取消共享新命名空间后，视图将更改：

  # ls -l /proc/self/ns/cgroup
  lrwxrwxrwx 1 root root 0 2014-07-15 10:35 /proc/self/ns/cgroup -> cgroup:[4026532183]
  # cat /proc/self/cgroup
  0::/

当多线程进程中的某个线程取消共享其 cgroup 命名空间时，新的 cgroupns 将应用于整个进程（所有线程）。这对于 v2 层级结构来说是很自然的；但是，对于旧版层级结构，这可能是意想不到的。

只要内部有进程或挂载固定它，cgroup 命名空间就是活动的。当最后一次使用消失时，cgroup 命名空间将被销毁。cgroupns 根和实际的 cgroup 仍然存在。

## 6-2. 根和视图

cgroup 命名空间的 'cgroupns 根' 是调用 unshare(2) 的进程正在运行的 cgroup。例如，如果 /batchjobs/container_id1 cgroup 中的进程调用 unshare，则 cgroup /batchjobs/container_id1 将成为 cgroupns 根。对于 init_cgroup_ns，这是真正的根 ('/') cgroup。

即使命名空间创建者进程稍后移动到不同的 cgroup，cgroupns 根 cgroup 也不会更改：

  # ~/unshare -c # 在某个 cgroup 中取消共享 cgroupns
  # cat /proc/self/cgroup
  0::/
  # mkdir sub_cgrp_1
  # echo 0 > sub_cgrp_1/cgroup.procs
  # cat /proc/self/cgroup
  0::/sub_cgrp_1

每个进程都会获得其特定于命名空间的 "/proc/$PID/cgroup" 视图。

在 cgroup 命名空间内运行的进程将只能看到其根 cgroup 内的 cgroup 路径（在 /proc/self/cgroup 中）。从取消共享的 cgroupns 内部：

  # sleep 100000 &
  [1] 7353
  # echo 7353 > sub_cgrp_1/cgroup.procs
  # cat /proc/7353/cgroup
  0::/sub_cgrp_1

从初始 cgroup 命名空间，将看到真正的 cgroup 路径：

  $ cat /proc/7353/cgroup
  0::/batchjobs/container_id1/sub_cgrp_1

从兄弟 cgroup 命名空间（即以不同 cgroup 为根的命名空间），将显示相对于其自己的 cgroup 命名空间根的 cgroup 路径。例如，如果 PID 7353 的 cgroup 命名空间根位于 '/batchjobs/container_id2'，那么它将看到：

  # cat /proc/7353/cgroup
  0::/../container_id2/sub_cgrp_1

请注意，相对路径始终以 '/' 开头，以指示它相对于调用者的 cgroup 命名空间根。

## 6-3. 迁移和 setns(2)

如果 cgroup 命名空间内的进程具有对外部 cgroup 的适当访问权限，则它们可以移入和移出命名空间根。例如，从 cgroupns 根位于 /batchjobs/container_id1 的命名空间内部，并假设全局层级结构在 cgroupns 内部仍然可访问：

  # cat /proc/7353/cgroup
  0::/sub_cgrp_1
  # echo 7353 > batchjobs/container_id2/cgroup.procs
  # cat /proc/7353/cgroup
  0::/../container_id2

请注意，不鼓励这种设置。cgroup 命名空间内的任务应仅暴露于其自己的 cgroupns 层级结构。

在以下情况下允许 setns(2) 到另一个 cgroup 命名空间：

(a) 进程对其当前用户命名空间具有 CAP_SYS_ADMIN
(b) 进程对目标 cgroup 命名空间的 userns 具有 CAP_SYS_ADMIN

附加到另一个 cgroup 命名空间不会发生隐式 cgroup 更改。预计有人会将附加进程移动到目标 cgroup 命名空间根下。

## 6-4. 与其他命名空间的交互

在非 init cgroup 命名空间内运行的进程可以挂载特定于命名空间的 cgroup 层级结构：

  # mount -t cgroup2 none $MOUNT_POINT

这将挂载以 cgroupns 根作为文件系统根的统一 cgroup 层级结构。该进程需要对其用户和挂载命名空间具有 CAP_SYS_ADMIN。

"/proc/self/cgroup" 文件的虚拟化与通过命名空间私有 cgroupfs 挂载限制 cgroup 层级结构的视图相结合，在容器内提供了适当隔离的 cgroup 视图。

# P. 内核编程信息

本节包含需要与 cgroup 交互的领域的内核编程信息。不包括 cgroup 核心和控制器。

## P-1. 文件系统对回写的支持

文件系统可以通过更新 address_space_operations->writepages() 来支持 cgroup 回写，使用以下两个函数注释 bio。

  `wbc_init_bio(@wbc, @bio)`
    应该为每个携带回写数据的 bio 调用，并将 bio 与 inode 的所有者 cgroup 和相应的请求队列相关联。这必须在队列（设备）与 bio 关联之后且在提交之前调用。

  `wbc_account_cgroup_owner(@wbc, @folio, @bytes)`
    应该为写出的每个数据段调用。虽然此函数并不完全关心在回写会话期间何时调用它，但在将数据段添加到 bio 时调用它是最简单和最自然的。

在注释了回写 bio 后，可以通过在 ->s_iflags 中设置 SB_I_CGROUPWB 来为每个 super_block 启用 cgroup 支持。这允许选择性地禁用 cgroup 回写支持，这在某些文件系统功能（例如日志数据模式）不兼容时很有帮助。

wbc_init_bio() 将指定的 bio 绑定到其 cgroup。根据配置，bio 可能会以较低的优先级执行，如果回写会话持有共享资源（例如日志条目），可能会导致优先级反转。这个问题没有简单的解决方案。文件系统可以尝试通过跳过 wbc_init_bio() 并直接使用 bio_associate_blkg() 来解决特定问题情况。

# D. 已弃用的 v1 核心功能

- 不支持包括命名层级结构在内的多层级结构。

- 不支持所有 v1 挂载选项。

- "tasks" 文件被删除，"cgroup.procs" 未排序。

- "cgroup.clone_children" 被删除。

- /proc/cgroups 对 v2 没有意义。请改用根目录下的 "cgroup.controllers" 或 "cgroup.stat" 文件。

# R. v1 的问题和 v2 的理由

## R-1. 多层级

cgroup v1 允许任意数量的层级结构，每个层级结构可以托管任意数量的控制器。虽然这似乎提供了高度的灵活性，但在实践中并没有用处。

例如，由于每个控制器只有一个实例，因此像 freezer 这样在所有层级结构中都有用的实用程序类型控制器只能在一个层级结构中使用。一旦填充了层级结构，控制器就无法移动到另一个层级结构，这一事实加剧了这个问题。另一个问题是，绑定到层级结构的所有控制器都被迫具有完全相同的层级结构视图。不可能根据特定控制器改变粒度。

在实践中，这些问题严重限制了可以将哪些控制器放在同一个层级结构上，大多数配置都求助于将每个控制器放在其自己的层级结构上。只有密切相关的控制器，如 cpu 和 cpuacct 控制器，放在同一个层级结构上才有意义。这通常意味着用户空间最终要管理多个类似的层级结构，每当需要层级结构管理操作时，都要在每个层级结构上重复相同的步骤。

此外，对多层级结构的支持付出了高昂的代价。它极大地复杂化了 cgroup 核心实现，但更重要的是，对多层级结构的支持限制了 cgroup 的一般使用方式以及控制器能够做什么。

层级结构的数量没有限制，这意味着线程的 cgroup 成员资格无法用有限长度描述。键可能包含任意数量的条目且长度不受限制，这使得操作非常笨拙，并导致添加仅用于识别成员资格的控制器，这反过来又加剧了层级结构数量激增的原始问题。

此外，由于控制器无法对其他控制器可能所在的层级结构的拓扑有任何期望，因此每个控制器都必须假设所有其他控制器都附加到完全正交的层级结构。这使得控制器相互协作变得不可能，或者至少非常麻烦。

在大多数用例中，将控制器放在彼此完全正交的层级结构上是不必要的。通常需要的是根据特定控制器具有不同粒度级别的能力。换句话说，从特定控制器的角度来看，层级结构可能会从叶子向根折叠。例如，给定的配置可能不关心超过一定级别的内存分配方式，但仍希望控制 CPU 周期的分配方式。

## R-2. 线程粒度

cgroup v1 允许进程的线程属于不同的 cgroup。这对某些控制器没有意义，这些控制器最终实现了不同的方法来忽略这种情况，但更重要的是，它模糊了暴露给单个应用程序的 API 和系统管理接口之间的界限。

通常，进程内知识仅对进程本身可用；因此，与进程的服务级组织不同，对进程的线程进行分类需要拥有目标进程的应用程序的积极参与。

cgroup v1 有一个定义模糊的委托模型，该模型与线程粒度结合使用时被滥用。cgroup 被委托给单个应用程序，以便它们可以创建和管理自己的子层级结构并控制沿途的资源分配。这有效地将 cgroup 提升到了暴露给普通程序的类似系统调用的 API 的地位。

首先，cgroup 具有根本不足以以这种方式暴露的接口。为了让进程访问自己的旋钮，它必须从 /proc/self/cgroup 中提取目标层级结构上的路径，通过将旋钮名称附加到路径来构造路径，打开然后读取和/或写入它。这不仅极其笨拙和不寻常，而且本质上是竞争的。没有常规方法来定义跨所需步骤的事务，也没有什么可以保证进程实际上会在其自己的子层级结构上运行。

cgroup 控制器实现了许多永远不会被接受为公共 API 的旋钮，因为它们只是向系统管理伪文件系统添加控制旋钮。cgroup 最终得到的接口旋钮没有被正确抽象或细化，直接揭示了内核内部细节。这些旋钮通过定义不明确的委托机制暴露给单个应用程序，有效地滥用 cgroup 作为实现公共 API 的捷径，而无需经过必要的审查。

这对用户空间和内核来说都是痛苦的。用户空间最终得到了行为不端和抽象不佳的接口，而内核无意中暴露并锁定在构造中。

## R-3. 内部节点和线程之间的竞争

cgroup v1 允许线程处于任何 cgroup 中，这产生了一个有趣的问题，即属于父 cgroup 的线程与其子 cgroup 竞争资源。这很糟糕，因为两种不同类型的实体竞争，没有明显的方法来解决它。不同的控制器做了不同的事情。

cpu 控制器将线程和 cgroup 视为等效，并将 nice 级别映射到 cgroup 权重。这在某些情况下有效，但当子级想要分配特定比例的 CPU 周期并且内部线程数波动时就会失败 - 随着竞争实体数量的波动，比率不断变化。还有其他问题。从 nice 级别到权重的映射并不明显或通用，并且还有各种其他旋钮根本不适用于线程。

io 控制器隐式地为每个 cgroup 创建一个隐藏的叶节点来托管线程。隐藏的叶节点拥有所有带有 ``leaf_`` 前缀的旋钮的副本。虽然这允许对内部线程进行等效控制，但它具有严重的缺点。它总是增加一层额外的嵌套，否则这是不必要的，使接口变得混乱，并显着复杂化了实现。

内存控制器无法控制内部任务和子 cgroup 之间发生的事情，并且行为没有明确定义。曾尝试添加临时行为和旋钮以针对特定工作负载定制行为，但这会导致长期难以解决的问题。

多个控制器与内部任务作斗争，并提出了不同的处理方法；不幸的是，所有方法都有严重的缺陷，此外，广泛不同的行为使得 cgroup 作为一个整体高度不一致。

这显然是一个需要从 cgroup 核心以统一方式解决的问题。

## R-4. 其他接口问题

cgroup v1 在没有监督的情况下发展，并产生了大量的特质和不一致之处。cgroup 核心方面的一个问题是如何通知空 cgroup - 分叉并执行用户空间辅助二进制文件以处理每个事件。事件传递不是递归的或可委托的。该机制的局限性还导致内核内事件传递过滤机制进一步复杂化了接口。

控制器接口也有问题。一个极端的例子是控制器完全忽略层级组织，并将所有 cgroup 视为直接位于根 cgroup 下。一些控制器向用户空间暴露了大量不一致的实现细节。

控制器之间也没有一致性。创建新 cgroup 时，一些控制器默认不施加额外限制，而另一些控制器则不允许任何资源使用，直到明确配置。相同类型控制的配置旋钮使用广泛不同的命名方案和格式。统计信息和信息旋钮被任意命名，甚至在同一个控制器中使用不同的格式和单位。

cgroup v2 在适当的地方建立了通用约定，并更新了控制器，以便它们暴露最小且一致的接口。

## R-5. 控制器问题和补救措施

### R-5-1. 内存

原始的下限，即软限制，定义为默认未设置的限制。结果，全局回收首选的 cgroup 集是选择加入的，而不是选择退出的。优化这些主要是负面查找的成本非常高，以至于尽管其规模巨大，但实现甚至没有提供基本的理想行为。首先，软限制没有层级意义。所有配置的组都组织在全局 rbtree 中，并被视为平等的对等方，无论它们位于层级结构中的何处。这使得子树委托成为不可能。其次，软限制回收过程非常激进，不仅给系统带来了高分配延迟，而且由于过度回收而影响了系统性能，以至于该功能变得弄巧成拙。

另一方面，memory.low 边界是自上而下分配的预留。当 cgroup 在其有效 low 范围内时，它享有回收保护，这使得子树委托成为可能。当高于其有效 low 时，它还享有与其超额成比例的回收压力。

原始的上限，即硬限制，定义为严格的限制，即使必须调用 OOM killer 也不能让步。但这通常违背了充分利用可用内存的目标。工作负载的内存消耗在运行时会有所不同，这需要用户超额承诺。但是，使用严格的上限这样做需要相当准确地预测工作集大小或向限制添加松弛。由于工作集大小估计很困难且容易出错，并且弄错会导致 OOM 终止，因此大多数用户倾向于采用较宽松的限制，最终浪费宝贵的资源。

另一方面，memory.high 边界可以设置得更加保守。当达到时，它通过强制它们进入直接回收来消除多余部分从而限制分配，但它从不调用 OOM killer。结果，选择得过于激进的高边界不会终止进程，而是会导致性能逐渐下降。用户可以监控这一点并进行更正，直到找到仍然提供可接受性能的最小内存占用。

在极端情况下，如果有许多并发分配并且组内的回收进度完全崩溃，则可能会超过高边界。但即使那样，满足来自其他组或系统其余部分的可用松弛的分配通常也比杀死该组更好。否则，memory.max 在那里限制这种类型的溢出，并最终包含有缺陷甚至恶意的应用程序。

将原始 memory.limit_in_bytes 设置为低于当前使用量受竞争条件的影响，其中并发收费可能导致限制设置失败。另一方面，memory.max 将首先设置限制以防止新的收费，然后回收和 OOM 杀死直到满足新限制 - 或者写入 memory.max 的任务被杀死。

组合的内存+交换记账和限制被对交换空间的实际控制所取代。

在原始 cgroup 设计中，组合内存+交换设施的主要论点是，无论子级自己的（可能不受信任的）配置如何，全局或父级压力总是能够交换子组的所有匿名内存。然而，不受信任的组可以通过其他方式破坏交换 - 例如在紧密循环中引用其匿名内存 - 管理员在超额承诺不受信任的作业时不能假设完全可交换性。

另一方面，对于受信任的作业，组合计数器不是直观的用户空间接口，它违背了 cgroup 控制器应记账和限制特定物理资源的想法。交换空间是系统中的一种资源，就像所有其他资源一样，这就是统一层级结构允许单独分发它的原因。