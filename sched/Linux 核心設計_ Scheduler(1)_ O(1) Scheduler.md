---
title: 'Linux 核心設計: Scheduler(1): O(1) Scheduler'
tags: [Linux Kernel Internals, ' 作業系統', Scheduler]

---

---
tags: Linux Kernel Internals, 作業系統
---
# Linux 核心設計: Scheduler(1): O(1) Scheduler

[Linux 核心設計: 不只挑選任務的排程器](https://hackmd.io/@sysprog/linux-scheduler?type=view#Linux-%E6%A0%B8%E5%BF%83%E8%A8%AD%E8%A8%88-%E4%B8%8D%E5%8F%AA%E6%8C%91%E9%81%B8%E4%BB%BB%E5%8B%99%E7%9A%84%E6%8E%92%E7%A8%8B%E5%99%A8)

:::success
:video_camera: 此筆記僅補充一些有興趣的議題，詳細請參考課程錄影 
:::


## Overview
原則上，單個 CPU 總是只能在單個時間點中執行一個任務。即使是多處理器的架構下，要運行的 process 數量往往也都超過 core 的數量。所以我們需要 scheduler，其作用為考量如任務的類型或者重要程度，並決定下一個要運行的任務及其運行時間。

Scheduler 不能毫無根據的隨便挑選下一個任務，有些任務需要及早完成，或者有些任務可以等待讓其他任務先運行，如何妥善分配時間給不同的任務是重要且困難的問題。並且，scheduler 還需要考慮 context switch 的成本，雖然頻繁的切換任務可能可以讓每個任務能儘早的回應，但過於頻繁的切換任務反而會讓 CPU 把大部份心力都花在 context switch 而非任務本身。因此，好的 scheduler 需要適當的去權衡 context switch 的頻率，讓系統可以在任務的回應與效率間取得平衡。

Scheduler 也需要考慮任務間的公平。不僅僅是用優先權衡量每個任務分配到的運行時間，也需要確保低優先權的任務仍保有一定的執行權利。(避免 [Starvation ](https://en.wikipedia.org/wiki/Starvation_(computer_science)))


## O(1) scheduler

在 linux 2.4 中，scheduler 雖然支援 SMP，但是採用方法的是統一用一個 global queue 來管理要被排程的任務，這導致延展性不佳(隨著 CPU 越多，需要越多的鎖來保持 queue 的互斥)。

另一方面，舊的 scheduler 在 context switch 時需走訪整個 runqueue，找到優先權最高的 process，這使得時間複雜為 $O(n)$。換句話說，process 數量的增加會導致 context switch 的成本增加，這同樣也造成了延展性的問題。
 
這個問題在 linux 2.6 中得以獲得改善。在 linux 2.6 下的 scheduler 中，每個 CPU 會為維護兩個 FIFO queue，共有 140 個優先級(0-99 for real time，100-139 for normal process，數字越大 priority 越低)。並且，通過一個 bitmask 去紀錄對應的優先級下的 queue 是否為空。如此一來，找出下一個任務就等於是兩個步驟：
1. 找到優先級最高且非空的 queue: 因為用 bitmask 去紀錄，就變成  find-first-bit-set 的問題(找到 bitmask 最右邊的 1)，可以透過硬體(例如 intel 的 `bsfl`)支援在單一指令下做到。
2. 選擇 queue 中任務: 因為是 FIFO queue，直接取出 queue 中第一個 task 即可

![](https://i.imgur.com/TQPlRlT.png)

挑選下一個 task 的時候，只要找到優先級最高的第一個 task 即可。當 task 的 timeslice 用盡，則把 task 放到 expired queue 去。
![](https://i.imgur.com/GaAzn5Q.png)

一旦 active queue 中的 task 已經完全為空，這時候只要把 active queue 跟 expired queue 交換，就可以得到新的 run queue 了
![](https://i.imgur.com/a77ZkcB.png)



### Timeslice 機制
O(1) scheduler 通過 timeslice 機制來分配每個 task 被允許使用 CPU 的時間。
* 每個 clock tick，正在執行的 task ([`current`](https://elixir.bootlin.com/linux/latest/source/arch/arm64/include/asm/current.h#L24)) 的 time_slice(`task_struct` 底下的 [`sched_rt_entity`](https://elixir.bootlin.com/linux/latest/source/include/linux/sched.h#L682) 中) 減一
* 一旦 time_slice 歸 0，則放進 expired queue

作業系統會根據 priority，給予 task 對應的 timeslice。一般來說，priority 高的 task 不但可以在 runqueue 中被優先挑出來執行，也擁有較長的 timeslice。


### Dynamic	priority
某些程式本身是 I/O bound 的互動介面(如 UI)，使用者會希望這些程式擁有最高的優先級，能夠快速的回應(例如鍵盤輸入後，立刻顯示在螢幕上)，但是這類的任務又不需佔用很多 timeslice。並且，有些程式也許某些時刻是 I/O bound，在某些時刻是 CPU bound。對此，作業系統就需要可以動態調整 priority，在程式是 I/O bound 時候去提升優先級，快速回應後再回去 wait queue。如果程式變回 CPU bound，則再把 priority 調低。然而，作業系統怎麼判斷一個程式現在的狀態是 I/O bound 還是 CPU bound 呢？

我們知道，I/O bound 的程式表示其大多時間都在等待 I/O(sleep)。因此，作業系統可以透過監控程式等待 I/O 的時間、對 disk 操作的密集程度對此判斷，並給予那些程式 priority 的提升。



O(1) scheduler 透過如以下的式子來計算任務的動態優先度：

![](https://i.imgur.com/EAtFn1d.png)

* bonus 根據等待 I/O 的時間計算
* static priority 來自 [nice value](https://en.wikipedia.org/wiki/Nice_(Unix))(nice 值愈高，對應優先權愈低)

> 延伸閱讀： [Linux 的 nice 指令：指定程式執行的排程優先權（Scheduling Priority](https://blog.gtwang.org/linux/linux-nice-scheduling-priority/)

![](https://i.imgur.com/4wwmwly.png)

注意到 task 將要被擺放到哪個 run queue 是由 **dynamic priority** 決定，而 nice value 直接影響的是 **static priority**。因此，不論你有多 "nice"，如果其他人都在等 I/O，你仍該先被排進 runqueue 執行！

## Rebalancing task
在後來的 linux scheduler 中，每個 CPU 都有自己的 runqueue，正常情況下，一個程式如果放在 CPU `0` ，就只會在永遠留在 CPU `0` 中。但是，例如CPU `0` 很快的把工作做完，CPU `1` 卻不斷 fork 出更多 child 的情形是可能發生的。因此，作業系統需有機制適時平衡每個 CPU 的負擔。

### load balance

在 linux 中，會透過 [PELT](https://hackmd.io/@RinHizakura/Bk4y_5o-9) 計算各 CPU 所承受的 load。我們可以找出 load 最高的 CPU，並判斷其是否需要把目前所執行的 task 分給其他 CPU 以減輕壓力。

但是需注意並非每當 CPU 負載不平衡時就要 balance，在 balance 的同時，也需要考慮到做 balance 產生的 overhead 是否超出其帶來的好處。例如，某個任務也許在 CPU `0` 跑起來會比在 CPU `1` 上快許多，這可能是因為

* CPU topology: NUMA
* Hyper-threading
* Multicore cache behavior : 需有規範應對 cache coherance

等原因

### CPU Topology

* SMP(Symmetric Multi-Processor): 在 SMP 架構下，CPU 可以共享所有資源，如 memory、I/O。在 SMP 架構下，CPU 沒有主要和次要之分，CPU 對於記憶體任何位址的存取時間。SMP 的共享性造成資源競爭的問題嚴重([Thrashing](https://en.wikipedia.org/wiki/Thrashing_(computer_science)) 問題)，因此擴展性差。

* NUMA(Non-Uniform Memory Access): NUMA 架構下，CPU 會被分成不同的組(node)，每個 node 有數個 CPU，以及自己獨立的 memory 、 I/O。node 與 node 間有 Crossbar Switch，因此仍能 access 其他 node 的 memory 等資源，但是經過 Crossbar Switch 會使得延遲增加。也就是說，NUMA 架構下，為了可以更好的發揮性能，儘量讓應用程式綁定在一個 node 中，可以減少 node 間交換訊息帶來的額外開銷，通過犧牲記憶體的訪問時延來達到更高的擴充套件性。
    
    但是，NUMA 的缺點是 CPU 數量增加，訪問資源的時間也會增加，導致性能無法隨著 CPU 的增加而線性增加。


![](https://i.imgur.com/B0uJLSo.png)

### Hyper-threading
[Hyper-threading](https://en.wikipedia.org/wiki/Hyper-threading) 是由 intel 所發表的技術。得益於製程的進步，相同面積下可以放進更多的電晶體，因此得以複製狀態儲存的資源(register)，讓兩個執行緒得以在單核下同時執行。讓一個實體 CPU 在 OS 的角度中有兩個 logical CPU。

> 延伸閱讀: [What is Hyperthreading and Why Should You Care?](https://www.online-tech-tips.com/computer-tips/what-is-hyperthreading-and-why-should-you-care/)

## Reference
* [SMP、NUMA体系结构](http://abcdxyzk.github.io/blog/2015/06/02/kernel-mm-smp-numa/)
* [CPU Topology](https://kodango.com/cpu-topology)
* [CPU Scheduling](http://www.cse.iitm.ac.in/~chester/courses/16o_os/slides/7_Scheduling.pdf)
* [Scheduling](http://www.cs.unc.edu/~porter/courses/cse506/s16/slides/scheduling.pdf)
* [Scheduling, Part 2](http://www.cs.unc.edu/~porter/courses/cse506/s16/slides/scheduling2.pdf)
* [谈谈调度 - Linux O(1)](https://zhuanlan.zhihu.com/p/33461281)