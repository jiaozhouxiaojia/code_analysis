---
title: 'Linux 核心設計: Scheduler(8): Energy Aware Scheduling'
tags: [Linux Kernel Internals, ' 作業系統', Scheduler]

---

---
tags: Linux Kernel Internals, 作業系統
---

# Linux 核心設計: Scheduler(8): Energy Aware Scheduling

> 引用: [Energy Aware Scheduling
](https://docs.kernel.org/scheduler/sched-energy.html)

## 引言

在過往，Linux 應用的場景大多是伺服器或桌面系統，因此系統的效能如吞吐量(throughput)等指標是評斷排程器優劣的重要基準。但現今的 Linux 應用的領域更為多元，也帶出新的問題著眼點。舉例來說，Linux 現在也被大量應用在手機等嵌入式裝置上。在這類平台中，耗電的程度也會是評判的標準，使用者會希望使用最低的功耗來達到理想的工作目標。此外，過度的耗電也可能導致嵌入式裝置的溫度升高，間接影響 CPU 的運作而導致效能降低。因此，如何管理裝置的電源耗損是近代 Linux 的重要課題。

隨此需求，Energy Aware Schedulng（EAS）機制被導入至 Linux 核心中。EAS 使排程器能夠預測對 CPU 功耗的影響。其依靠 CPU 的能源模型 (Energy Model, EM) 為每個任務選擇節能的 CPU，並盡量降低對吞吐量的影響。

:::info
留意到當前的 EAS 僅使用在異質多核的架構 (heterogeneous CPU topologies，如 Arm big.LITTLE)，而不支持同質多核(symmetric CPU topologies)
:::

## 相關術語

### Energy Model

EM 框架是 driver 與 kernel subsystem 間的接口。driver 認識到不同性能級別的裝置功耗，可通過該接口使 kernel 得到並使用該資訊來做出節能決策。

考量到有關裝置功耗的資訊來源在不同平台上可能存在很大差異。舉例來說，某些情況下可以使用 device tree 資料來估計成本。但在其他情況下，可能韌體層或 userspace 會更清楚此資訊。為了避免每個客戶端各自重新實現取得資訊來源的方式，EM 框架作為抽象層介入，其標準化了核心中電力成本表的格式，從而能夠避免在 Linux 上估計電力方式的混亂。

在 EM 中，功率可以用微瓦或 "抽象刻度(abstract scale)" 來表示。多個子系統可能使用 EM，並由系統整合商檢查是否符合功率值刻度類型的要求。舉例來說，對於某些子系統，例如 thermal 或 powercap，以抽像刻度表示的功率值可能會導致問題。這些子系統更感興趣的是過去使用的功率估計值，這種時候就需要微瓦刻度。Kernel subsystem 可能會自動檢測註冊 EM 的裝置是否具有不一致的刻度。需要記住的重要一點是，當功率值以抽象刻度表示時，不可能換算得出對應微焦耳的真實能量。

下圖描述了一個驅動程式範例（以 Arm 為例，但該方法適用於任何架構）為 EM 框架提供功耗成本。

```
+---------------+  +-----------------+  +---------------+
| Thermal (IPA) |  | Scheduler (EAS) |  |     Other     |
+---------------+  +-----------------+  +---------------+
        |                   | em_cpu_energy()   |
        |                   | em_cpu_get()      |
        +---------+         |         +---------+
                  |         |         |
                  v         v         v
                 +---------------------+
                 |    Energy Model     |
                 |     Framework       |
                 +---------------------+
                    ^       ^       ^
                    |       |       | em_dev_register_perf_domain()
         +----------+       |       +---------+
         |                  |                 |
 +---------------+  +---------------+  +--------------+
 |  cpufreq-dt   |  |   arm_scmi    |  |    Other     |
 +---------------+  +---------------+  +--------------+
         ^                  ^                 ^
         |                  |                 |
 +--------------+   +---------------+  +--------------+
 | Device Tree  |   |   Firmware    |  |      ?       |
 +--------------+   +---------------+  +--------------+
```

### Performance Domain

對於 CPU，EM 管理著每個「perfomance domain」的功耗表。Perfomance domain (PD) 是指一組效能會一起按比例縮放的 CPU。Perfomance domain 通常與各個 CPUFreq 組具有一對一的對應。同 domain 中所有 CPU 都需要具有相同的 micro architecture，反之則可以不同。

### Root Domain

Root domain(RD) 是 Linux 為了考量擴展性(Scability) 而引入，其對 CPU 劃分為數個子集。則每個任務在被排程器做選擇決策，將限縮在所屬的 root domain 範圍內。

對於每個 RD，排程器維護與其有交集的所有 PD 的單向 linked list。不同的 RD 可能包含重複的 PD。以如下案例來說，12 個 CPU 被分成 3 個 PD，而使用者將系統分為 2 個 RD，則 RD 底下 linked list 的狀態為:
* RD1: PD0->PD4
* RD2: PD4->PD8

```
CPUs:   0 1 2 3 4 5 6 7 8 9 10 11
PDs:   |--pd0--|--pd4--|---pd8---|
RDs:   |----rd1----|-----rd2-----|
```

:::info
注意到此案例中 PD4 的兩個節點實體是各自獨立的，但結構底下將 reference 到同一個 EM 相關資料結構
:::

由於對這些 linked list 的存取可以在熱插拔等操作時同時發生，因此其受到 RCU 的保護。

### Scheduler Domains

[Scheduler Domains(SD)](https://www.kernel.org/doc/html/next/scheduler/sched-domains.html)  對排程器的意義是「描述一組需要被平衡負載(load balance)的 CPU」。現代 CPU 架構中，排程到每個 CPU 所需的成本，或是從一個 CPU 遷移至另外兩個不同 CPU 的成本皆可能有所不同。舉例來說:
* 假設系統包含是 2 個物理 CPU A/B 並透過 [Hyperthreading](https://zh.wikipedia.org/zh-tw/%E8%B6%85%E5%9F%B7%E8%A1%8C%E7%B7%92) 可以有 4 個邏輯 CPU A-1/A-2/B-1/B2。則若要選擇特定兩個 CPU 進入 idle 以節能，選擇 A-1/A-2 和 A-1/B-1 的效果並不相同
* 假設系統包含 4 個 CPU A/B/C/D，而 A/B 共用一個 cache，C/D 共用另一個，則任務從 A 遷移至 B 與從 A 遷移至 C 所帶來的成本可能不同

因此，將系統所有的 CPU 直接視為一致來做平衡負載是不理想的做法。

取而代之，Linux 中採用的方案是提出 Scheduler Domains 和底下包含結構 Scheduler Group(SG) 的概念(後續會深入解釋)，每個 SD 下含一至多個 SG，而 SD 之上可以屬更高層級的 SD。則當 Linux 進行負載平衡時，系統首先去確保 SD 中所有 SG 之間的負載平衡，然後再往上考慮跨 SD 的負載平衡。如此一來，開發者可以透過合理的組織 SD 和 SG，來使系統僅考慮特定集合 CPU 間的平衡，以達更理想的結果。

![image](https://hackmd.io/_uploads/S1fTN9M9p.png)



在 Linux 中描述 SD 的資料結構為 [`struct sched_domain`](https://elixir.bootlin.com/linux/v6.7/source/include/linux/sched/topology.h#L87)，其是由 `parent` 和 `child` 指標形成層次結構，且每個 CPU 都會有一個 "base" SD，以 per-CPU 資料結構維護以允許 lockless 的存取方式。每個 SD 所涵蓋的 CPU 資訊稱為 "span"，儲存在 `sd->span` 欄位中。性質上，每個 SD 的 span 必須是其 child SD 之 span 的 superset，並且 CPU i 的 base SD 之 span 必須至少包含 i 本身。每個 CPU 最上層的 span 通常會嚴格地涵蓋系統中的所有 CPU(但非必要)。

每個 SD 含有一個或多個 scheduler groups（`struct sched_group`），後者是做負載平衡的基本單元。具體是以 `sd->groups` 指標形成的單向 circular linked list 所描述。這些 group 的 cpumask 之聯集必須與 SD 的 span 相同，且 `sd->groups` 所指向的 `sched_group` 必須包含 SD 所屬的 CPU。

### Energy and Power

在 EAS 區分兩個重要的單位:
* 能量(Energy) = [焦耳]（比如供電設備上電池所提供）
* 功率(Power) = 能量/時間 = [焦耳/秒] = [瓦]

而 EAS 的目標是最大限度地減少能量耗損，同時仍能完成工作。亦即最大化：

$$
\frac{performance(inst/s)}{power(W)}
$$

也就是最小化
$$
= \frac{Energy}{inst}
$$

同時仍能獲得不錯的效能。

簡而言之，EAS 改變了排程器將任務分配給 CPU 的方式。當排程器決定任務應該在哪裡運行時，EM 從幾個理想的 CPU 候選者中選擇一個預計會產生最佳能耗，同時而不損害系統效能者。EAS 所做的預測來自對相關平台拓撲(topology)的認識，其中包括 CPU 的 "capacity" 及其各自的能源成本。

### CPU Capacity

EAS 使用 "capacity" 來區分不同計算吞吐率的 CPU。CPU 的 "capacity" 表示的是與系統中功能最強大的 CPU 相比，其以最高頻率運作時可以吸收的工作量。Capacity 值被標準化至 1024 範圍內。則將 capacity 搭配 [PELT](https://hackmd.io/@RinHizakura/Bk4y_5o-9) 機制，EAS 能夠估計一個任務或 CPU 的大小等級和繁忙程度，以作為功耗權衡的考慮點。

## Operating Performance Point

現今複雜的 SoC 由多個協同工作的子模組組成。在作業系統運作的不同情境中，並非 SoC 中的所有模組都需要始終以其最高頻率運作。為了實現這一點，SoC 中的子模組被分組為多個 Performance domain，並允許某些 PD 以較低的電壓和頻率運行，而其他 PD 以較高的電壓和頻率運行。PD 中設備支持的電壓/頻率設定的幾個組合之離散單元就稱為 [Operating Performance Point(OPP)](https://docs.kernel.org/power/opp.html)。

舉例來說，讓我們考慮一個 MPU 裝置支援以下幾種頻率/電壓組合，則可以表示其對應的 OPP:
* 300MHz，最低電壓 1V -> `{300000000, 1000000}`
* 800MHz，最低電壓 1.2V -> `{800000000, 1200000}`
* 1GHz，最低電壓 1.3V -> `{1000000000, 1300000}`

### OPP Library

OPP library 是在 Linux 系統上組織和查詢 OPP 資訊的介面，函式庫的原始碼可以在 [drivers/opp](https://github.com/torvalds/linux/tree/master/drivers/opp) 中找到，而 header 則位於 [include/linux/pm_opp.h](https://github.com/torvalds/linux/blob/master/include/linux/pm_opp.h) 中。透過開啟 `CONFIG_PM_OPP` 可以啟用 OPP library。


## EAS 的運作方式

### Task Replacment

EAS 作用於 CFS/EEVDF 喚醒任務的相關程式碼中，它使用平台的 EM 和 PELT 在該時候選擇最節省功耗的 CPU。當 EAS 啟用時([`sched_energy_enabled()`](https://elixir.bootlin.com/linux/v6.7/source/kernel/sched/sched.h#L3196) == true)， [`select_task_rq_fair()`](https://elixir.bootlin.com/linux/v6.7/source/kernel/sched/fair.c#L8079) 中會呼叫 [`find_energy_efficient_cpu()`](https://elixir.bootlin.com/linux/v6.7/source/kernel/sched/fair.c#L7880) 來決定 task 要被放置到哪個 CPU 上去執行，後者會尋找每個 PD 中具有最多剩餘 capacity（CPU capacity - CPU utilization）的 CPU，因為這可以讓 CPU 保持最低頻率。然後，該函數還會檢查將任務放在該 CPU 與將其保留在先前執行之 CPU (`prev_cpu`)相比是否可以節省更多能源。

`find_energy_efficient_cpu()` 使用 [`compute_energy()`](https://elixir.bootlin.com/linux/v6.7/source/kernel/sched/fair.c#L7824) 來估計遷移(migrate)喚醒任務時系統的能量消耗。後者會查看 CPU 的目前使用率情況並對調整以「模擬」任務遷移。藉 EM 框架提供的 `em_pd_energy()` 計算給定情況下每個 PD 的預期能耗。

下面以案例說明。假設我們在一個有兩個 PD，且 PD 各自有兩個 CPU 的平台上。C0 和 C1 在 PD0 為小核，C2 和 C3 則是在 PD1 為大核。當前系統的統計數據如下。排程器下一個要抉擇是一個 task P，其根據 PELT util_avg = 200 且 `prev_cpu` = 0，要擺在何處。

```
CPU util.
 1024                 - - - - - - -              Energy Model
                                          +-----------+-------------+
                                          |  Little   |     Big     |
  768                 =============       +-----+-----+------+------+
                                          | Cap | Pwr | Cap  | Pwr  |
                                          +-----+-----+------+------+
  512  ===========    - ##- - - - -       | 170 | 50  | 512  | 400  |
                        ##     ##         | 341 | 150 | 768  | 800  |
  341  -PP - - - -      ##     ##         | 512 | 300 | 1024 | 1700 |
        PP              ##     ##         +-----+-----+------+------+
  170  -## - - - -      ##     ##
        ##     ##       ##     ##
      ------------    -------------
       CPU0   CPU1     CPU2   CPU3

 Current OPP: =====       Other OPP: - - -     util_avg (100 each): ##
```

解釋一下從本圖中可以看到的資訊:
* 每一個 `##` 表示 100 的 `util_avg`，即 C0~C3 的 `util_avg` 各自是 400, 100, 600, 500
* 每個 PD 都有三個 OPP，其中 `==` 標示當前的 OPP `--` 則標示另外兩個
    * PD0 的是 170/341/512，當前 OPP 為 512
    * PD1 的是 512/768/1024，當前 OPP 為 768
* task P 的 util_avg 是 200 且之前在 C0，也就是在 C0 的 4 個 `##` 中的其中兩個 `PP`

`find_energy_efficient_cpu()` 會在兩個 PD 中先各自尋找當前擁有最大剩餘 capacity 的 CPU，以前面案例來說是 C1 和 C3。然後再估算 P 被放到其中任一個的時候的能量耗損，並比較這兩個數據是否有比放在原本的 C0 來得更為節省能量。也就是說有三種可能的結果:

1. 移至 C1，此時根據估計總共耗能 1364
* 由於 PD0 中最大的 util 值下降，OPP 可以降低至更節能的 **cap:341-pwr:150**
```
1024                 - - - - - - -

                                      Energy calculation:
 768                 =============     * CPU0: 200 / 341 * 150 = 88
                                       * CPU1: 300 / 341 * 150 = 131
                                       * CPU2: 600 / 768 * 800 = 625
 512  - - - - - -    - ##- - - - -     * CPU3: 500 / 768 * 800 = 520
                       ##     ##          => total_energy = 1364
 341  ===========      ##     ##
              PP       ##     ##
 170  -## - - PP-      ##     ##
       ##     ##       ##     ##
     ------------    -------------
      CPU0   CPU1     CPU2   CPU3
```

2. 移至 C3 的話，根據估計總共耗能 1485
```
1024                 - - - - - - -

                                      Energy calculation:
 768                 =============     * CPU0: 200 / 341 * 150 = 88
                                       * CPU1: 100 / 341 * 150 = 43
                              PP       * CPU2: 600 / 768 * 800 = 625
 512  - - - - - -    - ##- - -PP -     * CPU3: 700 / 768 * 800 = 729
                       ##     ##          => total_energy = 1485
 341  ===========      ##     ##
                       ##     ##
 170  -## - - - -      ##     ##
       ##     ##       ##     ##
     ------------    -------------
      CPU0   CPU1     CPU2   CPU3
```
3. 保留在 C0，根據估計總共耗能 1437
```
1024                 - - - - - - -

                                      Energy calculation:
 768                 =============     * CPU0: 400 / 512 * 300 = 234
                                       * CPU1: 100 / 512 * 300 = 58
                                       * CPU2: 600 / 768 * 800 = 625
 512  ===========    - ##- - - - -     * CPU3: 500 / 768 * 800 = 520
                       ##     ##          => total_energy = 1437
 341  -PP - - - -      ##     ##
       PP              ##     ##
 170  -## - - - -      ##     ##
       ##     ##       ##     ##
     ------------    -------------
      CPU0   CPU1     CPU2   CPU3
```

根據上述計算 C1 耗能最低，是最佳的選擇。

注意到大核通常比小核更耗電，但這並不代表選擇小核總是能省下最多，這是因為小核的高 OPP 可能比大核的低 OPP 來得耗能。

### Over Utilization

縱然期待最低的能量耗損，然而，還是要最低限度的確保對 throughput 不會帶來過度的衝擊。對此 EAS 也實現了另一種稱為 "Over Utilization" 的機制。

一般角度來看，EAS 最有幫助的狀況是那些不涉及高 CPU 使用率的場景。因為對運行長時間的 CPU 密集型任務來說，它們將需要所有可用的 CPU 容量，而 EAS 無法在不嚴重損害吞吐量的情況下節省能源。為了避免 EAS 對效能造成損害，一旦 CPU 的使用超過其 capacity 的 80%，就會將其標記為 "Over Utilization" 。只有在 root domain 中沒有 Over Utilization，EAS 機制才會被啟用，且此時負載平衡器(load-balancer)被停用，因為其效果會與 EAS 產生矛盾(最為節能的 CPU 可能被賦予更多的任務)而破壞 EAS 發現的節能任務設置。這樣做被認為是安全的，因為 CPU 使用率低於 80% 臨界點意味著以下假設成立：
* 所有 CPU 上都有一些空閒的時間，因此 CPU 利用率的預測可能準確地表示系統中各種任務的大小
* 無論 nice 值為何，所有任務都應該已經擁有足夠的 CPU capacity
* 由於存在多餘的 capacity，所有任務都會定期睡眠(或 blocking)，在喚醒時進行平衡就足夠

反過來 CPU 使用率超過 80% 的話，上述假設就不成立。這時標示 overutilized 的 flag 被舉起以關閉 EAS 並且重啟 load balancer。排程回歸到考量最佳化 CPU 使用的方式。

留意到 Over Utilization 很大程度上依賴於偵測系統中是否有空閒時間，因此必須考慮高於 fair 的 sched_class 和 IRQ 使用的 CPU capacity。

### Schedutil Governor

從前述案例可以看到，EAS 演算法假設 OPP 的選擇是遵循 CPU 用量而調整。儘管實際上很難對此假設提供完全準確的保證，但與其他 CPUFreq governor 相比，schedutil governor 至少是使用利用率計算 requests 頻率，是唯一能在頻率和耗能間提供一定程度一致性的機制。因此 EAS 不能搭配 schedutil 以外的 governor 使用。


## 程式碼分析

:::info
此處分析版本 v6.14.6
:::

### `select_task_rq_fair`

當一個任務被喚醒，[`select_task_rq`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/core.c#L3575) 就被啟動並用以挑選執行該任務的 CPU，其會呼叫任務所屬的 scheduler class 之對應實作，以 fair class 為例即 [`select_task_rq_fair`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8577)。

```cpp
static int
select_task_rq_fair(struct task_struct *p, int prev_cpu, int wake_flags)
{
	int sync = (wake_flags & WF_SYNC) && !(current->flags & PF_EXITING);
	struct sched_domain *tmp, *sd = NULL;
	int cpu = smp_processor_id();
	int new_cpu = prev_cpu;
	int want_affine = 0;
	/* SD_flags and WF_flags share the first nibble */
	int sd_flag = wake_flags & 0xF;

	/*
	 * required for stable ->cpus_allowed
	 */
	lockdep_assert_held(&p->pi_lock);
	if (wake_flags & WF_TTWU) {
		record_wakee(p);

		if ((wake_flags & WF_CURRENT_CPU) &&
		    cpumask_test_cpu(cpu, p->cpus_ptr))
			return cpu;

		if (!is_rd_overutilized(this_rq()->rd)) {
			new_cpu = find_energy_efficient_cpu(p, prev_cpu);
			if (new_cpu >= 0)
				return new_cpu;
			new_cpu = prev_cpu;
		}

		want_affine = !wake_wide(p) && cpumask_test_cpu(cpu, p->cpus_ptr);
	}
```

如果 `wake_flags` 中包含 [`WF_TTWU`](https://elixir.bootlin.com/linux/v6.7/source/kernel/sched/sched.h#L2142)，表示任務是從 suspend 狀態被喚醒(另外還有 fork 出新任務時的 `WF_FORK` 和 exec 新 process 時的 `WF_EXEC` 也會做 `select_task_rq`)。
* `record_wakee`: [wake affine](https://oskernellab.com/2020/05/24/2020/0524-0001-linux_cfs_scheduler_31_wake_affine/)
* 如果 `wake_flags` 含 `WF_CURRENT_CPU`，這提示 scheduler 沿用原本 task 所在的 CPU 可能可以得到好處
    * 前提是 `cpumask_test_cpu` 允許使用該 CPU 執行目標任務
    * [ sched/umcg: add WF_CURRENT_CPU and externise ttwu](https://patchwork.kernel.org/project/linux-mm/patch/20220120160822.790430899@infradead.org/)

[`is_rd_overutilized`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L6851) 判斷 EAS 是否被開啟(`sched_energy_enabled()`) 且無 over utilizatuon(`rd->overutilized`)。若是就使用 `find_energy_efficient_cpu()` 來嘗試尋找更為節能的 CPU


後半部份是有別 EAS，使用 wake affine 或其他方式選擇 CPU 的方式。在本章節中先對其省略。

### `find_energy_efficient_cpu`

[`find_energy_efficient_cpu()`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8379) 用以找到最省電的 CPU。

首先，讓我們先一起來看看上面許多字數的註解。

```cpp
/*
 * find_energy_efficient_cpu(): Find most energy-efficient target CPU for the
 * waking task. find_energy_efficient_cpu() looks for the CPU with maximum
 * spare capacity in each performance domain and uses it as a potential
 * candidate to execute the task. Then, it uses the Energy Model to figure
 * out which of the CPU candidates is the most energy-efficient.
```

之前有提到 `find_energy_efficient_cpu()` 會在所有 PD 中先各自尋找擁有最大 capacity 的 CPU，然後再估算任務被放到其中任一個的時候的能量耗損，並比較這這些數據是否有比放在原本的 CPU 來得更為節省能量，來決定任務的下個歸屬。

```cpp
/* The rationale for this heuristic is as follows. In a performance domain,
 * all the most energy efficient CPU candidates (according to the Energy
 * Model) are those for which we'll request a low frequency. When there are
 * several CPUs for which the frequency request will be the same, we don't
 * have enough data to break the tie between them, because the Energy Model
 * only includes active power costs. With this model, if we assume that
 * frequency requests follow utilization (e.g. using schedutil), the CPU with
 * the maximum spare capacity in a performance domain is guaranteed to be among
 * the best candidates of the performance domain.
 *
```

這個作法是根據以下 heuristic: 在 PD 中，根據 Energy Model(EM) 最省電的 CPU 應該是其中以最低頻率運行者。因為 EM 僅考慮動態功耗，當有多個 CPU 的頻率相同時，沒有足夠的數據區分它們之間的優劣。則如果我們假設頻率大小遵循 CPU utilization(例如使用 schedutil governor 的狀況)，那麼 PD 中具有最大空閒 capacity 的 CPU 將是 PD 中的最佳候選者。

```cpp
/* In practice, it could be preferable from an energy standpoint to pack
 * small tasks on a CPU in order to let other CPUs go in deeper idle states,
 * but that could also hurt our chances to go cluster idle, and we have no
 * ways to tell with the current Energy Model if this is actually a good
 * idea or not. So, find_energy_efficient_cpu() basically favors
 * cluster-packing, and spreading inside a cluster. That should at least be
 * a good thing for latency, and this is consistent with the idea that most
 * of the energy savings of EAS come from the asymmetry of the system, and
 * not so much from breaking the tie between identical CPUs. That's also the
 * reason why EAS is enabled in the topology code only for systems where
 * SD_ASYM_CPUCAPACITY is set.
```

在實際的應用上，最佳省電方式最好是將小任務集中在一個 CPU 上，以便讓其他 CPU 進入更深的 idle 狀態。但這種作法也可能會破壞整個 CPU cluster 進入 idle 的機會。當前的 EM 下，我們沒有辦法全面的考量讓特定 CPU idle 到底是否對系統整體有利。有鑑於此，`find_energy_efficient_cpu()` 傾向於以 cluster 的角度最佳化能量耗損。

這作法至少對於 latency 來說是正向的。這也是為何 EAS 的節能效果大部分來自系統的不對稱性(asymmetry)，也因此僅在異質多核的架構啟用 EAS。

```cpp
/* NOTE: Forkees are not accepted in the energy-aware wake-up path because
 * they don't have any useful utilization data yet and it's not possible to
 * forecast their impact on energy consumption. Consequently, they will be
 * placed by sched_balance_find_dst_cpu() on the least loaded CPU, which might turn out
 * to be energy-inefficient in some use-cases. The alternative would be to
 * bias new tasks towards specific types of CPUs first, or to try to infer
 * their util_avg from the parent task, but those heuristics could hurt
 * other use-cases too. So, until someone finds a better way to solve this,
 * let's keep things simple by re-using the existing slow path.
 */
```

注意到被 fork 出來的新任務(forkee)不參與 EAS wakeup 的策略，這是因為 EAS 需遵循 PELT 追蹤的 CPU utilization，而 forkee 並不存在這些過往數據。他們會由其他機制選擇所屬 CPU。其由 `sched_balance_find_dst_cpu()` 放置在 load 最少的 CPU 上，但這在某些情況中可能會導致能源損耗。一種改善策略可能是先將新任務放在偏向特定類型的 CPU，或嘗試從其父任務推斷其 utilization。但無論那種方法事實上都可能有缺陷而反倒造成反效果，因此在有最佳解之前，暫時先以此為主。

```cpp
static int find_energy_efficient_cpu(struct task_struct *p, int prev_cpu)
{
	struct cpumask *cpus = this_cpu_cpumask_var_ptr(select_rq_mask);
	unsigned long prev_delta = ULONG_MAX, best_delta = ULONG_MAX;
	unsigned long p_util_min = uclamp_is_used() ? uclamp_eff_value(p, UCLAMP_MIN) : 0;
	unsigned long p_util_max = uclamp_is_used() ? uclamp_eff_value(p, UCLAMP_MAX) : 1024;
	struct root_domain *rd = this_rq()->rd;
	int cpu, best_energy_cpu, target = -1;
	int prev_fits = -1, best_fits = -1;
	unsigned long best_actual_cap = 0;
	unsigned long prev_actual_cap = 0;
	struct sched_domain *sd;
	struct perf_domain *pd;
	struct energy_env eenv;

	rcu_read_lock();
	pd = rcu_dereference(rd->pd);
	if (!pd)
		goto unlock;
```

維護 PD 的 linked list 受 RCU 保護，因此需先 `rcu_read_lock()` 再由 `rcu_dereference()` 取得。

```cpp
	/*
	 * Energy-aware wake-up happens on the lowest sched_domain starting
	 * from sd_asym_cpucapacity spanning over this_cpu and prev_cpu.
	 */
	sd = rcu_dereference(*this_cpu_ptr(&sd_asym_cpucapacity));
	while (sd && !cpumask_test_cpu(prev_cpu, sched_domain_span(sd)))
		sd = sd->parent;
	if (!sd)
		goto unlock;
```

EAS 作用的 sceduler domain 是從最低階的 [`sd_asym_cpucapacity`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/topology.c#L690) 開始，往 parent 方向的 SD 中，第一個其 `span` 裡有包含 `prev_cpu`(任務上個被排程在的 CPU) 和 `this_cpu`(當前執行這段程式的 CPU) 的 SD。

```cpp
	target = prev_cpu;

	sync_entity_load_avg(&p->se);
	if (!task_util_est(p) && p_util_min == 0)
		goto unlock;

	eenv_task_busy_time(&eenv, p, prev_cpu);
```

* `sync_entity_load_avg()` 將對應 se 的 load/utiliation 數據更新。具體是使用 `__update_load_avg_blocked_se()` 去更新 load: 由於 se 過去一段時間是屬 blocked 狀態，實作上不累加新的 load，僅根據與前次更新之時間差距將 load 進行衰減(decay)計算
* [`task_util_est()`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L4852) 取得對 utilization 的估計值。若其得值為 0，且 uclamp 未限制 util 最小值的情況(`p_util_min == 0`)，則代表任務不再有 CPU 資源需求，不需採用 EAS 策略
    * 注意到 `task_util_est()` 取值上並非直接參考 PELT 計算的 `util_avg`，詳見 [sched/fair: add util_est on top of PELT](https://patchwork.kernel.org/project/linux-pm/patch/20180206144131.31233-2-patrick.bellasi@arm.com/) 提到的問題與改善方案
* [`eenv_task_busy_time()`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8217) 計算之後在 `compute_energy()` 時需知道之準備 wakeup 任務在 util 上的貢獻(`eenv->task_busy_time`)。
    * 值得留意的是其中用到 [`scale_irq_capacity`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/sched.h#L3518) 以根據任務在 irq 期間的 util 將任務校正至真實的 util。數據保存在 `eenv->task_busy_time` 下

> [[PATCH v6 6/7] sched/fair: Remove task_util from effective utilization in feec()](https://lore.kernel.org/lkml/20220426093506.3415588-7-vincent.donnefort@arm.com/)

```cpp
	for (; pd; pd = pd->next) {
		unsigned long util_min = p_util_min, util_max = p_util_max;
		unsigned long cpu_cap, cpu_actual_cap, util;
		long prev_spare_cap = -1, max_spare_cap = -1;
		unsigned long rq_util_min, rq_util_max;
		unsigned long cur_delta, base_energy;
		int max_spare_cap_cpu = -1;
		int fits, max_fits = -1;

		cpumask_and(cpus, perf_domain_span(pd), cpu_online_mask);

		if (cpumask_empty(cpus))
			continue;
```

下面的 for 迴圈涵蓋大量的程式碼的內容，是對 PD linked list 中的每一個 PD 進行確認，以找到其中可以提供最佳省電效果的 PD。

`cpumask_and` 首先將 bitmap `perf_domain_span(pd)` 和 `cpu_online_mask` 的 and 運算結果保存至 `cpus`。其中 [`perf_domain_span(pd)`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/sched.h#L3546) 是藉 [`to_cpumask()`](https://elixir.bootlin.com/linux/v6.14.6/source/include/linux/cpumask.h#L1068) 獲得 PD 中代表有效 CPU 的 bitmask，而 [`cpu_online_mask`](https://elixir.bootlin.com/linux/v6.14.6/source/include/linux/cpumask.h#L122) 則是一個全域變數，表示當前工作中的 CPU。只有在 bitmask 顯示其中有可用 CPU 的情況下才進行後續的計算。

:::info
這裡可以留意到 linked list 使用的介面並非 Linux 常見的形式，不確定是否有特定考量?
:::

```cpp
		/* Account external pressure for the energy estimation */
		cpu = cpumask_first(cpus);
		cpu_actual_cap = get_actual_cpu_capacity(cpu);

		eenv.cpu_cap = cpu_actual_cap;
		eenv.pd_cap = 0;

		for_each_cpu(cpu, cpus) {
```

這裡初始化的變數 `cpu_actual_cap` 所代表是當前 CPU 所能提供的最大 capacity `arch_scale_cpu_capacity(cpu)` 減去 `max(hw_load_avg(cpu_rq(cpu)), cpufreq_get_pressure(cpu))` 後，可得到的實際可用 capacity 之估計值。
* `hw_load_avg`: 反映硬體壓力(hardware pressure)。硬體壓力是一個能夠提示排程器因為硬體節流(throttle)，導致 CPU 運算能力受限的數值。例如當 CPU 效能因高溫而降低
* `cpufreq_get_pressure`: 參考 cpufreq 的回饋來評估實際可用的 capacity


`eenv.pd_cap` 則初始成 0，這會在稍後要遍歷所有 CPU 的 `for_each_cpu` 迴圈中計算。我們需要檢視 PD 中的每個 CPU 以確認當前有最多剩餘 capacity 的 CPU 是哪一個。

:::info
從這裡可以很直接看出在同一 PD 中的 CPU 被預期要有相同的 capacity
:::

```cpp
			struct rq *rq = cpu_rq(cpu);

			eenv.pd_cap += cpu_actual_cap;

			if (!cpumask_test_cpu(cpu, sched_domain_span(sd)))
				continue;

			if (!cpumask_test_cpu(cpu, p->cpus_ptr))
				continue;
```
下面來看內層迴圈的實作。

首先是更新 `eenv.pd_cap`，其意義代表的是整個 PD 的 capacity，因此實際上最終在迴圈外使用 `eenv` 時，算出來即所有 PD 中可選 CPU 數量乘上 `cpu_actual_cap`。

接著是要確定:
1. 當前 PD 所涵蓋的每個 CPU 是否與 EAS 所作用的 SD 中包含的 CPU 有交集。
2. 當前 PD 所涵蓋的每個 CPU 是否與任務被設定可運行的 cpumask 有交集 

若否，將任務挑選至該 CPU 上並不被考慮。

```cpp
			util = cpu_util(cpu, p, cpu, 0);
			cpu_cap = capacity_of(cpu);
```

若是，則 [`cpu_util`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8000) 可以計算出將任務放到該 CPU 中會得到的 capacity，而 [`capacity_of(cpu)`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L7280) 則是該 CPU 剩餘可提供的 capacity。

```cpp
			/*
			 * Skip CPUs that cannot satisfy the capacity request.
			 * IOW, placing the task there would make the CPU
			 * overutilized. Take uclamp into account to see how
			 * much capacity we can get out of the CPU; this is
			 * aligned with sched_cpu_util().
			 */
			if (uclamp_is_used() && !uclamp_rq_is_idle(rq)) {
				/*
				 * Open code uclamp_rq_util_with() except for
				 * the clamp() part. I.e.: apply max aggregation
				 * only. util_fits_cpu() logic requires to
				 * operate on non clamped util but must use the
				 * max-aggregated uclamp_{min, max}.
				 */
				rq_util_min = uclamp_rq_get(rq, UCLAMP_MIN);
				rq_util_max = uclamp_rq_get(rq, UCLAMP_MAX);

				util_min = max(rq_util_min, p_util_min);
				util_max = max(rq_util_max, p_util_max);
			}

```

`rq = cpu_rq(cpu)` 是 CPU 專屬的 rq。則在 uclamp 啟用且該 rq 之 `rq->uclamp_flags` 中不含 `UCLAMP_FLAG_IDLE` 的情況下(即 [`uclamp_rq_is_idle`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/sched.h#L3409))。我們需要對 uclamp 範圍(`util_min`/`util_max`)做一些微調。

* `UCLAMP_FLAG_IDLE` 會在 rq 當前最後一個任務 dequeue 時設置，表示 rq 中不含任務，因此該 rq 不受 task uclamp 影響)，

:::warning
本文中不討論 uclamp 細節。不過可以留意到 rq uclamp 值是來自被 enqueue 至其中的 task 影響
:::

[`uclamp_rq_get()`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/sched.h#L3397) 可以取得對 rq 的 min/max uclamp(`rq_util_min`/`rq_util_max`)，將其與 task 的 min/max uclamp (`p_util_min`/`p_util_max`) 一併考量後，可得出最終將任務加入指定 CPU 後應該被假定的 uclamp 範圍。

* 具體來說是從 `rq_util_*` 和 `p_util_*` 對應值中選出最大的。更多詳情可參考 [sched/uclamp: Fix fits_capacity() check in feec()](https://www.spinics.net/lists/stable/msg646416.html)。
 
```cpp

			fits = util_fits_cpu(util, util_min, util_max, cpu);
			if (!fits)
				continue;

			lsub_positive(&cpu_cap, util);
```

在有了 `util`、`util_min`、`util_max` 之下，假定將任務產生的額外 `util` 被加入到 `cpu` 下，則可由 [`util_fits_cpu`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L4987) 計算出 `fits`。`fits` 的意義是該 task 是否被認為適應於目標 CPU。

則假設該任務可以加入目標 CPU(`fits==1`)，可預期 CPU 新的剩餘 capacity 為 `cpu_cap - util`(但最小就是剩餘 0)。

```cpp
			if (cpu == prev_cpu) {
				/* Always use prev_cpu as a candidate. */
				prev_spare_cap = cpu_cap;
				prev_fits = fits;
			} else if ((fits > max_fits) ||
				   ((fits == max_fits) && ((long)cpu_cap > max_spare_cap))) {
				/*
				 * Find the CPU with the maximum spare capacity
				 * among the remaining CPUs in the performance
				 * domain.
				 */
				max_spare_cap = cpu_cap;
				max_spare_cap_cpu = cpu;
				max_fits = fits;
			}
		}
```

則我們可以檢視每個合適的 CPU，並比較之間可以帶來最大剩餘 CPU capacity 者，對應資訊記錄在變數 `max_spare_cap` 和 `max_spare_cap_cpu` 下。留意所選 CPU 與前一次被排程的 CPU 相同的情況下，相關資訊會另外獨立記錄在 `prev_spare_cap`。

這是內層迴圈所做的所有事情。

```cpp

		if (max_spare_cap_cpu < 0 && prev_spare_cap < 0)
			continue;
```

`max_spare_cap_cpu < 0 && prev_spare_cap < 0` 若成立表示前面 for loop 中沒有找到任何的 CPU 候選，則當前 PD 就不列入 CPU migration 的考量。

```cpp
		eenv_pd_busy_time(&eenv, cpus, p);
		/* Compute the 'base' energy of the pd, without @p */
		base_energy = compute_energy(&eenv, pd, cpus, p, -1);
```

[`eenv_pd_busy_time`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8252) 用以計算 `eenv->pd_busy_time`，後者是根據給定的 PD 之 cpumask，算出此 PD 排除 task `p` 後之 utilization。則結合之前計算而得的 `eenv->task_busy_time`，就可透過 [`compute_energy`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8323) 計算功耗相關的數據。

總結來說，計算所得的 `base_energy` 是排除 task `p` 後，PD 所產生的功耗。

```cpp
		/* Evaluate the energy impact of using prev_cpu. */
		if (prev_spare_cap > -1) {
			prev_delta = compute_energy(&eenv, pd, cpus, p,
						    prev_cpu);
			/* CPU utilization has changed */
			if (prev_delta < base_energy)
				goto unlock;
			prev_delta -= base_energy;
			prev_thermal_cap = cpu_thermal_cap;
			best_delta = min(best_delta, prev_delta);
		}
```

`prev_spare_cap > -1` 意即此 PD 包含前次排程所選的 CPU(`prev_cpu`)因此這裡要考慮把 task `p` 留在之前的 CPU，所能帶來的功耗是否是最低。

```cpp
		/* Evaluate the energy impact of using max_spare_cap_cpu. */
		if (max_spare_cap_cpu >= 0 && max_spare_cap > prev_spare_cap) {
			/* Current best energy cpu fits better */
			if (max_fits < best_fits)
				continue;

			/*
			 * Both don't fit performance hint (i.e. uclamp_min)
			 * but best energy cpu has better capacity.
			 */
			if ((max_fits < 0) &&
			    (cpu_thermal_cap <= best_thermal_cap))
				continue;

			cur_delta = compute_energy(&eenv, pd, cpus, p,
						   max_spare_cap_cpu);
			/* CPU utilization has changed */
			if (cur_delta < base_energy)
				goto unlock;
			cur_delta -= base_energy;

			/*
			 * Both fit for the task but best energy cpu has lower
			 * energy impact.
			 */
			if ((max_fits > 0) && (best_fits > 0) &&
			    (cur_delta >= best_delta))
				continue;

			best_delta = cur_delta;
			best_energy_cpu = max_spare_cap_cpu;
			best_fits = max_fits;
			best_thermal_cap = cpu_thermal_cap;
		}
	}
```

如果 `max_spare_cap_cpu >= 0 && max_spare_cap > prev_spare_cap`，表示 PD 中有非 `prev_cpu` 的 CPU 選擇，可能可以帶來最佳功耗。則考慮若把任務 `p` 放到該 CPU 時的能源耗損是否是帶來最佳效益。

:::danger
TODO: 釐清為甚麼不能直接比較 capacity (`max_spare_cap`/`prev_spare_cap`) 判斷哪個剩餘最多來決定 best CPU，而是必須透過 `compute_energy` 更詳細計算能量耗損? 是因為後者才是比較精準的依據嗎?
:::
```cpp
	rcu_read_unlock();

	if ((best_fits > prev_fits) ||
	    ((best_fits > 0) && (best_delta < prev_delta)) ||
	    ((best_fits < 0) && (best_actual_cap > prev_actual_cap)))
		target = best_energy_cpu;

	return target;

unlock:
	rcu_read_unlock();

	return target;
}

```

CPU 的選擇 `target` 預設為 `prev_cpu`，最終根據以下條件做變更為  `best_energy_cpu`:
1. 若 `best_fits > prev_fits`，表示 best 對應的 `best_energy_cpu` 是相較 prev 對應的 `prev_cpu` 的最佳選擇
2. 若 `(best_fits > 0) && (best_delta < prev_delta)`，表示選擇 best 帶來的能量消耗提升較低，選擇之
3. 若 `best_fits <= prev_fits` && `(best_fits < 0) &&  (best_actual_cap > prev_actual_cap)`，表示選擇 best 雖然並不被認為是合適(`fits<0`)，但至少 capacity 上 best 擁有的 capacity 比起 prev 較多，則選之


> [sched/fair: unlink misfit task from cpu overutilized](https://lore.kernel.org/lkml/167611145487.4906.13681923703017103189.tip-bot2@tip-bot2/)

:::info
提醒這裡 `best_fits` 和 `prev_fits` 的值只可能是 0、1 或 -1
:::

:::warning
`prev_delta < best_delta` 理論上是不可能發生的情況? 因為此二變數一起被初始為 `ULONG_MAX` 然後在 `prev_delta` 重新 assign 成非 `ULONG_MAX` 時，`best_delta` 也會一併被更新(`best_delta = min(best_delta, prev_delta`);
:::

### util_fits_cpu

[`util_fits_cpu`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L4987) 計算給定 `util` 在 uclamp 範圍 `util_min` 和 `util_max` 之下加入特定 CPU 的適應度。

```cpp
static inline int util_fits_cpu(unsigned long util,
				unsigned long uclamp_min,
				unsigned long uclamp_max,
				int cpu)
{
	unsigned long capacity_orig, capacity_orig_thermal;
	unsigned long capacity = capacity_of(cpu);
	bool fits, uclamp_max_fits;

	/*
	 * Check if the real util fits without any uclamp boost/cap applied.
	 */
	fits = fits_capacity(util, capacity);
```

[`fits_capacity()`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L105) 首先不考慮 uclamp，計算依此 util 是否對於 CPU 剩餘的 capacity `capacity_of(cpu)` 是合適的量。`fits_capacity(cap, max)` 展開為	`((cap) * 1280 < (max) * 1024)`，即若 util 不足剩餘量的 1024/1280 = 80%，這被認為是可接受的(`fits == 1`)，反之(`fits == 0`)。

這裡保留 20% capacity 的考量點為: 因為 migration 本身也需要 CPU 資源來進行，因此盡量不要占滿 CPU 的所有 capacity 以確保進行 migration 的空間。

```cpp
	if (!uclamp_is_used())
		return fits;

```

在不採用 uclamp 的狀況下，考慮 `fits_capacity` 的結果即可。

```cpp
	/*
	 * We must use arch_scale_cpu_capacity() for comparing against uclamp_min and
	 * uclamp_max. We only care about capacity pressure (by using
	 * capacity_of()) for comparing against the real util.
	 *
	 * If a task is boosted to 1024 for example, we don't want a tiny
	 * pressure to skew the check whether it fits a CPU or not.
	 *
	 * Similarly if a task is capped to arch_scale_cpu_capacity(little_cpu), it
	 * should fit a little cpu even if there's some pressure.
	 *
	 * Only exception is for HW or cpufreq pressure since it has a direct impact
	 * on available OPP of the system.
	 *
	 * We honour it for uclamp_min only as a drop in performance level
	 * could result in not getting the requested minimum performance level.
	 *
	 * For uclamp_max, we can tolerate a drop in performance level as the
	 * goal is to cap the task. So it's okay if it's getting less.
	 */
	capacity_orig = arch_scale_cpu_capacity(cpu);
```

`arch_scale_cpu_capacity(cpu)` 可計 CPU 可提供的最大 capacity。

留意到註解的說明: 在考慮 uclamp 時，我們不在乎 CPU 剩餘的 capacity(`capacity_of(cpu)`)，而只看 CPU 總共能允許的最大 capacity(`arch_scale_cpu_capacity(cpu)`)。

同時這裡不會考慮 20% 的保留空間，因為這會導致使用者對 uclamp 參數設定的預期，與實際的排程器安排不同。

舉例來說:
* 一個 task 被設置 `uclamp_min=1024`。然而為保留 20% 的 CPU capacity，其被判定為不 fit 任何 CPU
* 一個 task 被設置 `uclamp_max=capacity_orig_of(little_cpu)`，表示預期該任務應被排程在小核上。但由於 margin 的存在，當負載增加時，任務最終被安派到更大的 CPU

為了使系統能對使用者端在 uclamp 的要求達到預期的處理，在 `fits_capacity` 設計上優先考量 `uclamp_min`，因為其目的是要求保證 task 的最低效能，導致無法獲得所要求的效能是不能容忍的。而對於 `uclamp_max`，效能的下降是可以接受的，因為這個參數的目標是限制任務的執行。

詳情可見 [sched/uclamp: Fix relationship between uclamp and migration margin](https://lore.kernel.org/lkml/20220629194632.1117723-2-qais.yousef@arm.com/)

```cpp
	/*
	 * We want to force a task to fit a cpu as implied by uclamp_max.
	 * But we do have some corner cases to cater for..
	 *
	 *
	 *                                 C=z
	 *   |                             ___
	 *   |                  C=y       |   |
	 *   |_ _ _ _ _ _ _ _ _ ___ _ _ _ | _ | _ _ _ _ _  uclamp_max
	 *   |      C=x        |   |      |   |
	 *   |      ___        |   |      |   |
	 *   |     |   |       |   |      |   |    (util somewhere in this region)
	 *   |     |   |       |   |      |   |
	 *   |     |   |       |   |      |   |
	 *   +----------------------------------------
	 *         CPU0        CPU1       CPU2
	 *
	 *   In the above example if a task is capped to a specific performance
	 *   point, y, then when:
	 *
	 *   * util = 80% of x then it does not fit on CPU0 and should migrate
	 *     to CPU1
	 *   * util = 80% of y then it is forced to fit on CPU1 to honour
	 *     uclamp_max request.
	 *
	 *   which is what we're enforcing here. A task always fits if
	 *   uclamp_max <= capacity_orig. But when uclamp_max > capacity_orig,
	 *   the normal upmigration rules should withhold still.
	 *
	 *   Only exception is when we are on max capacity, then we need to be
	 *   careful not to block overutilized state. This is so because:
	 *
	 *     1. There's no concept of capping at max_capacity! We can't go
	 *        beyond this performance level anyway.
	 *     2. The system is being saturated when we're operating near
	 *        max capacity, it doesn't make sense to block overutilized.
	 */
```

排程器會希望根據 `uclamp_max` 來強迫 CPU 的選擇。為此，有些特殊的情況需要被處理。

在上面註解的範例中，三個 CPU 的 capacity 總量各自是 `C0=x`、`C1=y`、`C2=z` 如果一個任務被 uclamp 限制為 `y`，則預期上:
* util 為 x 的 80% 時，該任務將無法在 CPU0 上運行，應遷移到 CPU1
* util 為 y 的 80% 時，該任務將被迫在 CPU1 上運行，以滿足 `uclamp_max`。

換言之，如果 `uclamp_max <= capacity_orig`，則任務該被判定為 "fit"。反之 `uclamp_max > capacity_orig`，必須保證正常的 migration 規則被執行。

唯一的例外是有任務之 uclamp_max = 1024。因為這是沒有特別意義的，任務原本就無法超過這個限制。

```cpp
	uclamp_max_fits = (capacity_orig == SCHED_CAPACITY_SCALE) && (uclamp_max == SCHED_CAPACITY_SCALE);
	uclamp_max_fits = !uclamp_max_fits && (uclamp_max <= capacity_orig);
	fits = fits || uclamp_max_fits;
```

從實作來看。即便實際的 util 不 fit，能夠因為 uclamp 而改判為 fit 的條件是: CPU 的原始 capcity(`capacity_orig`) 或者 `uclamp_max` 不為 `SCHED_CAPACITY_SCALE(1024)`，於此同時，`uclamp_max <= capacity_orig)`。正如前所解釋的。

```cpp
	/*
	 *
	 *                                 C=z
	 *   |                             ___       (region a, capped, util >= uclamp_max)
	 *   |                  C=y       |   |
	 *   |_ _ _ _ _ _ _ _ _ ___ _ _ _ | _ | _ _ _ _ _ uclamp_max
	 *   |      C=x        |   |      |   |
	 *   |      ___        |   |      |   |      (region b, uclamp_min <= util <= uclamp_max)
	 *   |_ _ _|_ _|_ _ _ _| _ | _ _ _| _ | _ _ _ _ _ uclamp_min
	 *   |     |   |       |   |      |   |
	 *   |     |   |       |   |      |   |      (region c, boosted, util < uclamp_min)
	 *   +----------------------------------------
	 *         CPU0        CPU1       CPU2
	 *
	 * a) If util > uclamp_max, then we're capped, we don't care about
	 *    actual fitness value here. We only care if uclamp_max fits
	 *    capacity without taking margin/pressure into account.
	 *    See comment above.
	 *
	 * b) If uclamp_min <= util <= uclamp_max, then the normal
	 *    fits_capacity() rules apply. Except we need to ensure that we
	 *    enforce we remain within uclamp_max, see comment above.
	 *
	 * c) If util < uclamp_min, then we are boosted. Same as (b) but we
	 *    need to take into account the boosted value fits the CPU without
	 *    taking margin/pressure into account.
	 *
	 * Cases (a) and (b) are handled in the 'fits' variable already. We
	 * just need to consider an extra check for case (c) after ensuring we
	 * handle the case uclamp_min > uclamp_max.
	 */
```

考慮示例圖的說明:
1. 如果 `util` > `uclamp_max`，我們不在乎實際的 `fits`，只考慮 `uclamp_max` 是否符合 CPU capacity。這已經涵蓋在前段的程式碼。
2. 如果 `uclamp_min` <= `util` <= `uclamp_max`，則適用一般的 `fits_capacity()` 計算規則。即函式最開始所計算的內容。
3. 如果 `util` < `uclamp_min`，表示與實際值相比 capacity 被提升，我們需要在不考慮 margin 和 pressue 的情況下(不使用 `fits_capacity()` 或 `arch_scale_cpu_capacity()`)，計算提升後的值是否適合目標 CPU。


```cpp
	uclamp_min = min(uclamp_min, uclamp_max);
	if (fits && (util < uclamp_min) &&
	    (uclamp_min > get_actual_cpu_capacity(cpu)))
		return -1;

	return fits;
}
```

本段程式碼及處理上述的第三點。

### `compute_energy`

```cpp
/*
 * compute_energy(): Use the Energy Model to estimate the energy that @pd would
 * consume for a given utilization landscape @eenv. When @dst_cpu < 0, the task
 * contribution is ignored.
 */
static inline unsigned long
compute_energy(struct energy_env *eenv, struct perf_domain *pd,
	       struct cpumask *pd_cpus, struct task_struct *p, int dst_cpu)
```

[`compute_energy`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8323) 計算目標 Perf Domain(`pd`) 在給定的 utilization landscape(`eenv`，含 utilization/capacity 等資訊)下，考量 PD 中的有效 CPU(`pd_cpus`)，計算出任務 `p` 在移動到 `dst_cpu` 上後對能量的能量耗損。

當 `dst_cpu < 0`，這時 `p` 對於所貢獻的能量消耗將不會被納入計算(`struct energy_env` 相關欄位無效)。
    
```cpp
{
	unsigned long max_util = eenv_pd_max_util(eenv, pd_cpus, p, dst_cpu);
	unsigned long busy_time = eenv->pd_busy_time;
	unsigned long energy;
```

首先 [`eenv_pd_max_util`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8276) 計算把 `p` 加入到 `dst_cpu` 時，PD 最大可能的 utilization。然後是要知道 Perf Domain 在排除 `p` 以外的 utilization `busy_time = eenv->pd_busy_time`)。

```cpp
	if (dst_cpu >= 0)
		busy_time = min(eenv->pd_cap, busy_time + eenv->task_busy_time);
```

當 `dst_cpu >=0` 則，此計算把 `p` 能夠貢獻的 utilization(`eenv->task_busy_time`)也包含進來。但 `busy_time` 的值只能在 PD 的 capacity(`eenv->pd_cap`) 限制內。
    
```cpp
	energy = em_cpu_energy(pd->em_pd, max_util, busy_time, eenv->cpu_cap);

	trace_sched_compute_energy_tp(p, dst_cpu, energy, max_util, busy_time);

	return energy;
}
```

[`em_cpu_energy`](https://elixir.bootlin.com/linux/v6.14.6/source/include/linux/energy_model.h#L219) 計算在給定 utilization 下，PD 中能產生的能量，詳見下節。


### `em_cpu_energy`

```cpp
/**
 * em_cpu_energy() - Estimates the energy consumed by the CPUs of a
 *		performance domain
 * @pd		: performance domain for which energy has to be estimated
 * @max_util	: highest utilization among CPUs of the domain
 * @sum_util	: sum of the utilization of all CPUs in the domain
 * @allowed_cpu_cap	: maximum allowed CPU capacity for the @pd, which
 *			  might reflect reduced frequency (due to thermal)
 *
 * This function must be used only for CPU devices. There is no validation,
 * i.e. if the EM is a CPU type and has cpumask allocated. It is called from
 * the scheduler code quite frequently and that is why there is not checks.
 *
 * Return: the sum of the energy consumed by the CPUs of the domain assuming
 * a capacity state satisfying the max utilization of the domain.
 */
static inline unsigned long em_cpu_energy(struct em_perf_domain *pd,
				unsigned long max_util, unsigned long sum_util,
				unsigned long allowed_cpu_cap)
```


[`em_cpu_energy`](https://elixir.bootlin.com/linux/v6.14.6/source/include/linux/energy_model.h#L219) 計算在 [`compute_energy`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8323) 前段計算出 CPU 群之的 utilization 總和後(`sum_util`)，且考量兩個前提 
* PD 中最大的 CPU capacity: `allowed_cpu_cap`
* PD 最大 utilization: `max_util`
 
下，在特定 PD(`pd`)中的能量耗損。

```cpp
{
	struct em_perf_table *em_table;
	struct em_perf_state *ps;
	int i;

#ifdef CONFIG_SCHED_DEBUG
	WARN_ONCE(!rcu_read_lock_held(), "EM: rcu read lock needed\n");
#endif

	if (!sum_util)
		return 0;

	/*
	 * In order to predict the performance state, map the utilization of
	 * the most utilized CPU of the performance domain to a requested
	 * performance, like schedutil. Take also into account that the real
	 * performance might be set lower (due to thermal capping). Thus, clamp
	 * max utilization to the allowed CPU capacity before calculating
	 * effective performance.
	 */
	max_util = min(max_util, allowed_cpu_cap);
```


```cpp
	/*
	 * Find the lowest performance state of the Energy Model above the
	 * requested performance.
	 */
	em_table = rcu_dereference(pd->em_table);
	i = em_pd_get_efficient_state(em_table->state, pd, max_util);
	ps = &em_table->state[i];

	/*
	 * The performance (capacity) of a CPU in the domain at the performance
	 * state (ps) can be computed as:
	 *
	 *                     ps->freq * scale_cpu
	 *   ps->performance = --------------------                  (1)
	 *                         cpu_max_freq
	 *
	 * So, ignoring the costs of idle states (which are not available in
	 * the EM), the energy consumed by this CPU at that performance state
	 * is estimated as:
	 *
	 *             ps->power * cpu_util
	 *   cpu_nrg = --------------------                          (2)
	 *               ps->performance
	 *
	 * since 'cpu_util / ps->performance' represents its percentage of busy
	 * time.
	 *
	 *   NOTE: Although the result of this computation actually is in
	 *         units of power, it can be manipulated as an energy value
	 *         over a scheduling period, since it is assumed to be
	 *         constant during that interval.
	 *
	 * By injecting (1) in (2), 'cpu_nrg' can be re-expressed as a product
	 * of two terms:
	 *
	 *             ps->power * cpu_max_freq
	 *   cpu_nrg = ------------------------ * cpu_util           (3)
	 *               ps->freq * scale_cpu
	 *
	 * The first term is static, and is stored in the em_perf_state struct
	 * as 'ps->cost'.
	 *
	 * Since all CPUs of the domain have the same micro-architecture, they
	 * share the same 'ps->cost', and the same CPU capacity. Hence, the
	 * total energy of the domain (which is the simple sum of the energy of
	 * all of its CPUs) can be factorized as:
	 *
	 *   pd_nrg = ps->cost * \Sum cpu_util                       (4)
	 */
	return ps->cost * sum_util;
}
```


### `eenv_pd_max_util`

 [`eenv_pd_max_util`](https://elixir.bootlin.com/linux/v6.14.6/source/kernel/sched/fair.c#L8276) 

```cpp
/*
 * Compute the maximum utilization for compute_energy() when the task @p
 * is placed on the cpu @dst_cpu.
 *
 * Returns the maximum utilization among @eenv->cpus. This utilization can't
 * exceed @eenv->cpu_cap.
 */
static inline unsigned long
eenv_pd_max_util(struct energy_env *eenv, struct cpumask *pd_cpus,
		 struct task_struct *p, int dst_cpu)
{
	unsigned long max_util = 0;
	int cpu;

	for_each_cpu(cpu, pd_cpus) {
		struct task_struct *tsk = (cpu == dst_cpu) ? p : NULL;
		unsigned long util = cpu_util(cpu, p, dst_cpu, 1);
		unsigned long eff_util, min, max;

		/*
		 * Performance domain frequency: utilization clamping
		 * must be considered since it affects the selection
		 * of the performance domain frequency.
		 * NOTE: in case RT tasks are running, by default the min
		 * utilization can be max OPP.
		 */
		eff_util = effective_cpu_util(cpu, util, &min, &max);

		/* Task's uclamp can modify min and max value */
		if (tsk && uclamp_is_used()) {
			min = max(min, uclamp_eff_value(p, UCLAMP_MIN));

			/*
			 * If there is no active max uclamp constraint,
			 * directly use task's one, otherwise keep max.
			 */
			if (uclamp_rq_is_idle(cpu_rq(cpu)))
				max = uclamp_eff_value(p, UCLAMP_MAX);
			else
				max = max(max, uclamp_eff_value(p, UCLAMP_MAX));
		}

		eff_util = sugov_effective_cpu_perf(cpu, eff_util, min, max);
		max_util = max(max_util, eff_util);
	}

	return min(max_util, eenv->cpu_cap);
}
```

## Reference

* [Energy Aware Scheduling
](https://docs.kernel.org/scheduler/sched-energy.html)
* [Energy Model of devices](https://docs.kernel.org/power/energy-model.html)
* [Operating Performance Points (OPP) Library](https://docs.kernel.org/power/opp.html)
* [CFS任务放置代码详解](http://www.wowotech.net/process_management/task_placement_detail.html)
* [Scheduler Domains(SD)](https://www.kernel.org/doc/html/next/scheduler/sched-domains.html)