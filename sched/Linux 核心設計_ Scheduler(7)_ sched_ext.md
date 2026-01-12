---
title: 'Linux 核心設計: Scheduler(7): sched_ext'
tags: [Linux Kernel Internals, ' 作業系統', Scheduler]

---

---
tags: Linux Kernel Internals, 作業系統
---

# Linux 核心設計: Scheduler(7): sched_ext

## 引言

在 Linux 核心中的 CPU 排程器經歷許多變化。然而 Linux 作為一個可以應用於資料庫、行動裝置、雲端服務等多種平台的作業系統，從 O(1) Scheduler、CFS、到現今的 EEVDF，核心中預設的排程演算法的設計關鍵是必須提供通用(generically)的策略，以符合各式各樣的應用場景。僅有有限的參數被提供以微幅調校排程器，使得應用端得可以更接近理想的效能。

然而，對於某些採用 Linux 的公司來說，他們的平台僅存在特定的工作負載(workload)，此時通用的排程器就不能滿足他們的期待。與之相比，如果可以自訂排程器的行為，可能有機會獲得更多好處。不過若要直接改動核心程式碼實作自定義排程器，這需要一定的技術含量。考慮排程器作為作業系統的關鍵元件，若實作上有錯誤也很容易帶來負面影響。此外，Linux 不太可能允許各廠家把自訂的排程器發佈到上游，這會導致專案充斥冗餘程式碼與混亂。因此綜合來看，該以何種方式開發自訂排程器，以減輕開發的成本和維護的負擔，是至關重要的題目。

在此訴求下，有開發人員開始想在 Linux 中引入「可插入」的排程器機制。這將使得每個人都可以編寫自己定制的排程器，然後以低成本的方式輕鬆的將其植入到核心中使用。然而該用什麼方式來提供能最符合上述的要求呢? 此時 [eBPF](https://en.wikipedia.org/wiki/EBPF) 就映入開發者的眼簾。eBPF 不但支援動態載入程式碼到 kernel 中執行的功能，也提供檢查器(verifier)來減少載入的程式破壞 kernel 的風險，無疑可以說是最適合發展「可插入」排程器的基礎。

於是在此基礎上，[`sched_ext`](https://github.com/sched-ext/sched_ext) 就此誕生了。`sched_ext` 除了允許客製化排程器，也能做為測試各種排程演算法的試驗台，其包含以下的特點:
* 開放完整的排程介面，以允許可以在上面實現任何排程演算法
* 排程器可以按照它認為合適的方式將 CPU 分組並排程，因為任務在被喚醒時不需要綁定在特定的 CPU 綁定
* 透過 sched_ext 製作的排程器可以隨時被插入或移除，而不會破壞系統的運作
* 排程器的安全性被保護 -- 如果偵測到錯誤、可運行任務停止或呼叫 [SysRq-S](https://docs.kernel.org/admin-guide/sysrq.html)，將會自動恢復成預設排程器
* 當觸發錯誤時，除錯資訊將被保存。也可以透過 `sched_ext_dump` tracepoint 或 SysRq-D 保存此資訊


## 如何使用 `sched_ext`?

`sched_ext` 的使用到底是否足夠達到前述的目的呢? 接下來就讓我們動手來試一試。

### 編譯 Linux 核心

自 6.12 以後的 Linux 版本皆支援 sched_ext，因此可以選用任意 6.12 以上的版本進行實驗。

```
$ git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
```

:::info
:notes: 可以善用 `--depth` 選項來加快 clone 專案的速度
:::

```
$ cd linux
$ make CC=clang-17 LLVM=1 defconfig
```

首先透過以上命令建立一個預設的 config 檔。注意到這邊特別設置了 `CC=clang-17` 和 `LLVM=1`，因為根據 `linux/tools/sched_ext` 路徑下的 [README](https://github.com/torvalds/linux/tree/master/tools/sched_ext)，建議我們需要使用 clang-16 或以上的版本，因此這裡可以選用 clang-17 來編譯。

:::info
關於不同版本的 clang 如何安裝可以參考 [How to install Clang 17 or 16 in Ubuntu 22.04 | 20.04](https://ubuntuhandbook.org/index.php/2023/09/how-to-install-clang-17-or-16-in-ubuntu-22-04-20-04/)
:::

參考 sched-ext 的[文件](https://www.kernel.org/doc/html/next/scheduler/sched-ext.html)，我們需要額外啟以下 kernel config。

```
CONFIG_BPF=y
CONFIG_SCHED_CLASS_EXT=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_JIT_DEFAULT_ON=y
CONFIG_PAHOLE_HAS_SPLIT_BTF=y
CONFIG_PAHOLE_HAS_BTF_TAG=y
```

如果是透過選單(`menuconfig`)進行設定，可以參考以下方式開啟對應選項。

```
$ make CC=clang-17 LLVM=1 menuconfig
```

* General setup -> BPF subsystem 
![image](https://hackmd.io/_uploads/rJyp7-QwT.png)
* Kernel hacking -> Scheduler Debugging
![image](https://hackmd.io/_uploads/BydEVb7P6.png)
* Kernel hacking ->  Compile-time checks and compiler options 
![image](https://hackmd.io/_uploads/HkNz5gEPT.png)
![image](https://hackmd.io/_uploads/SJwJsMmw6.png)
* General setup
![image](https://hackmd.io/_uploads/SknvCXmPp.png)

```
$ make CC=clang-17 LLVM=1 -j$(nproc)
```

然後就可以編譯核心了。編譯完成後，我們即可以在 QEMU 或者 virtme-ng 上測試!

:::info
這些工具的使用細節就不贅述，可以參考 [Linux 核心設計: 開發、測試與除錯環境](https://hackmd.io/@RinHizakura/SJ8GXUPJ6) 這篇文章了解更多資訊 :smiley:~
:::

:::warning
若在編譯時遇到以下訊息:
```
BTF: .tmp_vmlinux.btf: pahole (pahole) is not available
Failed to generate BTF for vmlinux
Try to disable CONFIG_DEBUG_INFO_BTF
make[2]: *** [scripts/Makefile.vmlinux:37: vmlinux] Error 1
make[1]: *** [/home/rin/Linux/sched_ext/Makefile:1165: vmlinux] Error 2
make[1]: *** Waiting for unfinished jobs....
  LD [M]  net/ipv4/netfilter/iptable_nat.ko
  LD [M]  net/netfilter/xt_addrtype.ko
make: *** [Makefile:234: __sub-make] Error 2
```
有可能是缺少套件導致，可嘗試安裝 dwarves 再重新編譯過:
```
$ sudo apt install dwarves
```
:::

### 編譯 `sched_ext` 範例程式碼

接著我們進到 `tools/sched_ext/` 路徑下編譯出範例的自訂排程器。

```
$ cd tools/sched_ext
```

這邊筆者在編譯時遇到一些麻煩，具體問題是 [`scx_utils`](https://docs.rs/scx_utils/latest/scx_utils/) 會嘗試辨認 clang 版本是否足夠新(>= 16)，取得的方式是強制使用預設的 `clang --version` 命令。但此前我們預想其實是透過 `clang-17` 才能得到正確結果。由於 `clang --version` 在筆者的電腦上得到的版本號 <16 會導致使用到 `scx_utils` 套件的函式庫編譯失敗。

因為 [scx_utils](https://docs.rs/scx_utils/0.4.0/src/scx_utils/bpf_builder.rs.html#229) 原始碼中發現可以透過 `BPF_CLANG` 去指定使用的 clang，若遇到相同問題，可採取以下方式排除。

* 在 `scx_rusty/build.rs` 和 `scx_layered/build.rs` 但 `main.rs` 額外加入一行:
```diff
+ std::env::set_var("BPF_CLANG", "clang-17");
```

然後就可以進行執行以下命令:

```
$ make CC=clang-17 LLVM=1 -j$(nproc)
```

:::warning
如果編譯時遇到以下訊息:
```
/usr/bin/ld: cannot find -lzstd: No such file or directory
```
需安裝必要的函式庫套件:
```
sudo apt-get install libzstd-dev
```
:::

完成上述所有步驟後，應該可以得到一系列的 `build/bin/scx*` 檔案，這代表我們已經得到要值入核心的排程器!

### 測試基於 `sched_ext` 框架的排程器

這裡我們展示用 `virtme-ng` 測試的方式。這相較於直接使用 QEMU 應更好上手，不需要另外建立 root filesystem image，也不必複雜的額外設定，推薦想先專注於學習 `sched_ext` 的讀者嘗試。

以測試 `scx_simple` 為範例，啟動 `virtme-ng` 後在 `sched_ext` 資料夾底下使用以下命令來測試結果:

```
$ vng
$ sudo ./build/bin/scx_simple
local=0 global=0
local=5 global=2
local=137 global=9
local=140 global=11
local=143 global=22
local=274 global=27
...
```

可以透過 sysfs 確認當前 `sched_ext` 的狀態和載入的排程器名稱。
```
$ cat /sys/kernel/sched_ext/state
enabled
$ cat /sys/kernel/sched_ext/root/ops
simple
```

確認 BPF 排程器被載入的次數(0 表示沒有 BPF scheduler 被載入過)。

```
# cat /sys/kernel/sched_ext/enable_seq
1
```

## 撰寫簡單的 `sched_ext` 排程器

若想理解如何撰寫 sched_ext 排程器，以 [`scx_simple`](https://github.com/torvalds/linux/blob/master/tools/sched_ext/scx_simple.bpf.c) 作為起點是不錯的入門方式。該程式碼展示了一個基本的 sched_ext 排程器中，需要涵蓋的所有部分。

### Scheduling Cycle

正式深入探討程式碼之前，我們可以先閱讀 [Scheduling Cycle](https://www.kernel.org/doc/html/next/scheduler/sched-ext.html#scheduling-cycle) 一節以明白 `sched_ext` 大致的排程流程。

1. 當任務被喚醒時，首先進行 `select_cpu()`。這有兩個目的: 一是提示在 CPU 選擇上的最佳解答。其次，如果所選 CPU 是 idle 狀態則喚醒之。
    * `select_cpu()` 若選擇不合法的 CPU(例如 task 透過 cpumask 標示不在特定 CPU 上運行)，此選擇最終會變成無效
    * `select_cpu()` 所選的 CPU 被視為是優化的提示，但不是強制的綁定
    * `select_cpu()` 的副作用是會將所選 CPU 從 Idle 狀態中喚醒。也可以使用 `scx_bpf_kick_cpu()` 喚醒任何 cpu，但明智地使用 `ops.select_cpu()` 是更簡單且有效率的推薦途徑
    * 如果在 `select_cpu()` 中呼叫 `scx_bpf_dsq_insert()`，可以在此階段立刻將任務加入到 DSQ 中。當目標是 local queue 時，任務將加入到函式回傳的 CPU 之 local DSQ。這也會導致跳過 `enqueue()`(步驟 2)
2. 選擇目標 CPU 後，呼叫 `enqueue()`。此階段可以做出以下其中一種決定：
    * 立即以 `scx_bpf_dispatch()` 選擇 `SCX_DSQ_GLOBAL` 或 `SCX_DSQ_LOCAL` 直接將任務分派到全域或本地 DSQ
    * 以 `scx_bpf_dispatch()` 將任務分派到 `scx_bpf_create_dsq` 建立的 DSQ
    * 先 enqueue task 到 BPF 內部的自定義結構中
3. 當 CPU 準備好排程時，會首先檢查 local DSQ。如果為空，則進一步查看 global DSQ。如果仍然沒有找到可以執行的任務，則會呼叫 `dispatch()`。這時有兩種方式可以將任務加入到 local DSQ 中:
    * `scx_bpf_dsq_insert()` 將任務加入到 DSQ。可以選擇任何的包含 `SCX_DSQ_LOCAL`、`SCX_DSQ_LOCAL_ON | cpu`、`SCX_DSQ_GLOBAL` 或自建的 DSQ。`scx_bpf_dsq_insert()` 僅插入而不立即執行任務，且最多可以有 `.dispatch_max_batch` 數量的待處理任務
    * `scx_bpf_move_to_local()` 將任務從指定的非本地 DSQ 轉移到 local DSQ
4. `dispatch()` 結束後，再檢查一次 local DSQ，此時有任務的話則執行之，若否
    * 再嘗試一遍 global DSQ
    * 若前一步失敗，而之前的 `dispatch()` 是有分派新任務的，那再試一遍步驟 3
    * 若前一步還是失敗，而前一個任務是 SCX task 且仍是 runnable，就繼續執行它
    * 否則 CPU 進入 idle


介面上，`scx_bpf_dsq_insert()` 將任務插入目標 DSQ 的 FIFO 中。使用 `scx_bpf_dsq_insert_vtime()` 則是使用 priority queue。留意到內部的 DSQ `SCX_DSQ_LOCAL` 和 `SCX_DSQ_GLOBAL` 不支援 priority queue，因此只能使用 `scx_bpf_dsq_insert()` 進行排程。詳細會在後續章節探討範例的 `scx_simple` 時說明。

### Dispatch Queues

在 sched_ext 藉由 [Dispatch Queue(DSQ)](https://www.kernel.org/doc/html/next/scheduler/sched-ext.html#dispatch-queues)的佇列實作來決定任務的優先順序。DSQ 可以用 FIFO 或 priority queue 方式來管理任務。

預設上，系統中會有 1 個全域的 FIFO DSQ(`SCX_DSQ_GLOBAL`)，而每個 CPU 又會有自己的 DSQ (`SCX_DSQ_LOCAL`)。每個 CPU 只能從自己的 local DSQ 執行任務: 可能是直接被加入到 local DSQ 中，或者由其他的 DSQ 移動而來。當 CPU 尋找下一個要執行的任務時，如果本地 DSQ 不為空，則選擇其中的第一個任務。否則，CPU 會嘗試從 global DSQ 移動任務。如果這也沒有產生可運行的任務，則會呼叫 `.dispatch()`。

### BPF 程式碼

在撰寫 eBPF 程式碼的時候，通常會分為兩個部份。一部份會編譯成 BPF bytecode，之後被載入至 kernel space 運行;另一部份則是執行於 userspace 的 BPF loader。其依賴於 libbpf，被用來將 BPF bytecode 載入到 kernel，並監視其狀態以在 userspace 進行對應行為。


:::info
請閱讀 [Linux 核心設計: eBPF](https://hackmd.io/@RinHizakura/S1DGq8ebw) 和 [BPF 的可移植性: Good Bye BCC! Hi CO-RE!](https://hackmd.io/@RinHizakura/HynIEOD7n) 來得知更多細節~
:::

載入核心的部份，也就是 [`scx_simple.bpf.c`](https://github.com/torvalds/linux/blob/master/tools/sched_ext/scx_simple.bpf.c)，涵蓋以下的內容。

```c
SCX_OPS_DEFINE(simple_ops,
    .select_cpu = (void *)simple_select_cpu,
    .enqueue    = (void *)simple_enqueue,
    .dispatch   = (void *)simple_dispatch,
    .running    = (void *)simple_running,
    .stopping   = (void *)simple_stopping,
    .enable     = (void *)simple_enable,
    .init       = (void *)simple_init,
    .exit       = (void *)simple_exit,
    .name       = "simple");
```
```c
/*
 * Define sched_ext_ops. This may be expanded to define multiple variants for
 * backward compatibility. See compat.h::SCX_OPS_LOAD/ATTACH().
 */
#define SCX_OPS_DEFINE(__name, ...)     \
        SEC(".struct_ops.link")         \
        struct sched_ext_ops __name = { \
        __VA_ARGS__,                    \
    };
```

在 sched_ext 中，我們可以藉由 [`SCX_OPS_DEFINE`](https://github.com/torvalds/linux/blob/master/tools/sched_ext/include/scx/compat.bpf.h#L137) 來定義用來描述排程器的名稱及各種操作的 `struct sched_ext_ops` 結構(例如挑選目標 CPU、分派任務等)。

值得一提的是，在 `SCX_OPS_DEFINE` 的展開中，開頭的 `SEC` 標註這個資料結構應該被放在 ELF 的哪個 section。我們必須要將此放在 `.struct_ops.link` 來讓 sched_ext 正確連結到要插入的操作。

```c
/*
 * Scheduling policies
 */
#define SCHED_NORMAL		0
#define SCHED_FIFO		1
#define SCHED_RR		2
#define SCHED_BATCH		3
/* SCHED_ISO: reserved but not implemented yet */
#define SCHED_IDLE		5
#define SCHED_DEADLINE		6
#define SCHED_EXT		7
```

查看 `include/uapi/linux/sched.h`，在 sched_ext 框架下 scheduler 被分成上面的數類，其實就是 kernel 原有的種類加上 `SCHED_EXT` 一種。若沒有插入 sched_ext 排程器的話，`SCHED_EXT` 就被當成 `SCHED_NORMAL` 處理。

```c
#define SHARED_DSQ 0

s32 BPF_STRUCT_OPS_SLEEPABLE(simple_init)
{
    return scx_bpf_create_dsq(SHARED_DSQ, -1);
}
```

一旦 eBPF 程式碼被植入，`.init` 是首先會被執行的 callback。

此時，如果 `ops->flags` 中沒有設定 `SCX_OPS_SWITCH_PARTIAL`，所有 `SCHED_NORMAL`、`SCHED_BATCH`、`SCHED_IDLE` 和 `SCHED_EXT` 任務都將由 `sched_ext` 來管理排程。

但是，`ops->flags` 中設定 `SCX_OPS_SWITCH_PARTIAL` 時，只有具有 `SCHED_EXT`  的任務由 `sched_ext` 調度，上述的其他任務由 fair(EEVDF) 排程器管理。

可以使用 `scx_bpf_create_dsq` 來建立額外的 DSQ。以此範例而言，我們利用 `dsq_id=0`(`SHARED_DSQ`) 建立一個由所有 CPU 共享的 queue。


```c
void BPF_STRUCT_OPS(simple_running, struct task_struct *p)
{
    if (fifo_sched)
        return;

    /*
     * Global vtime always progresses forward as tasks start executing. The
     * test and update can be performed concurrently from multiple CPUs and
     * thus racy. Any error should be contained and temporary. Let's just
     * live with it.
     */
    if (vtime_before(vtime_now, p->scx.dsq_vtime))
        vtime_now = p->scx.dsq_vtime;
}
```

當一個任務在 CPU 上獲得排程時則呼叫 `running()`。這裡如果 `fifo_sched` 沒開啟狀況下，我們會記錄當前最新的 `vtime` 至 `vtime_now`，`fifo_sched` 開啟時因為時間不是影響任務排隊的因素，因此可以不用記錄此資訊。

```cpp
s32 BPF_STRUCT_OPS(simple_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
    bool is_idle = false;
    s32 cpu;

    cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
    if (is_idle) {
        stat_inc(0);	/* count local queueing */
        scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
    }

    return cpu;
}
```

`select_cpu()` 為任務挑選合適的目標 CPU。

`scx_bpf_select_cpu_dfl` 是 sched_ext 提供的預設挑選 CPU 方式。回傳值是此介面所選擇的 CPU，回傳的 `is_idle` 則表示該 CPU 當前是否是 idle 狀態。

如果目標排程 CPU 是 idle 狀態下，會在此階段直接把任務加入到 local DSQ 中。

```c
void BPF_STRUCT_OPS(simple_enable,
                    struct task_struct *p,
                    struct scx_enable_args *args)
{
    p->scx.dsq_vtime = vtime_now;
}
```

`enable()` 用來操作首次被 sched_ext 所管理的任務，例如由 `fork()`、`clone()` 建立，或是在初始化階段從其他 class 轉移至 `SCHED_EXT` 者。

在 sched_ext 中每個排程單元會有各自的 [`struct sched_ext_entity`](https://github.com/sched-ext/sched_ext/blob/sched_ext/include/linux/sched/ext.h#L645) 來描述自己，而其中 `dsq_vtime` 與任務在以 priority queue 方式管理的 DSQ 中之順序有關。這裡顯式地將 `dsq_vtime` 對齊 `vtime_now`，後者即最近一次被排程(running)任務的 vtime。

:::warning
這裡留意到 `vtime_now` 一開始初始為 0，因此可預期的是當其他任務被轉移至 `SCHED_EXT` 的時候，他們原本的先後優先次序將不被考慮進來，因為大家都是從 vtime = 0 開始。
:::

```c
void BPF_STRUCT_OPS(simple_enqueue, struct task_struct *p, u64 enq_flags)
{
	stat_inc(1);	/* count global queueing */

	if (fifo_sched) {
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	} else {
		u64 vtime = p->scx.dsq_vtime;

		/*
		 * Limit the amount of budget that an idling task can accumulate
		 * to one slice.
		 */
		if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
			vtime = vtime_now - SCX_SLICE_DFL;

		scx_bpf_dsq_insert_vtime(p, SHARED_DSQ, SCX_SLICE_DFL, vtime,
					 enq_flags);
	}
}
```

`enqueue()` 是用來將一個任務加入到排程器的 queue 中。當啟用 `fifo_sched` 時，使用 FIFO 方式的 `scx_bpf_dsq_insert` 將任務加入到之前建立的 `SHARED_DSQ` 中。


```c
void scx_bpf_dsq_insert(struct task_struct *p, 
    u64 dsq_id,
    u64 slice,
    u64 enq_flags);
```
`scx_bpf_dsq_insert()` 的介面是
* `p` 是接下來要加入到 DSQ 中的 task
* `dsq_id` 是所選擇的 DSQ 之編號
* `slice` 是任務之後被挑選出來後可以執行的時間長度 (單位是 ns)，輸入 0 的話則沿用原本的設定值
* `enq_flags` 是 `SCX_ENQ_*` 系列的特殊標識

否則的話，就使用 priority queue 方式的  `scx_bpf_dsq_insert_vtime`。

```cpp
void scx_bpf_dsq_insert_vtime(struct task_struct *p,
    u64 dsq_id,
    u64 slice,
    u64 vtime,
    u64 enq_flags)
```
* `vtime` 是在 priority queue 中決定次序的依據

:::info
問: 從 `scx_bpf_dsq_insert_*` 必須要傳遞 `enq_flags` 來看，是否任務的管理綁定要透過 DSQ 而不能使用自訂的 runqueue 結構?

答: 可以僅把 DSQ 當成中間層，先在自定義的資料結構上維護任務的優先級，在 dispatch 的時候再加入到 dsq 中。`scx_bpf_dsq_insert` 的註解也提到這 API 可以在 `select_cpu()`、`enqueue()` 或 `dispatch()` 時使用。
:::

```c
void BPF_STRUCT_OPS(simple_dispatch, s32 cpu, struct task_struct *prev)
{
	scx_bpf_dsq_move_to_local(SHARED_DSQ);
}
```

當 CPU 要尋找下一個要執行的任務時，如果 local DSQ 中有任務，則從中選擇第一個。否則，CPU 會嘗試從 global DSQ 搬移來新任務。

如果這兩個方式都不能找到可運行的任務，就會呼叫 `dispatch()` 方法。此時可以將自行管理的 DSQ 中的任務移動到該 CPU DSQ 執行。即此處的 `scx_bpf_dsq_move_to_local`。


```c
void BPF_STRUCT_OPS(simple_stopping, struct task_struct *p, bool runnable)
{
    if (fifo_sched)
        return;

    /*
     * Scale the execution time by the inverse of the weight and charge.
     *
     * Note that the default yield implementation yields by setting
     * @p->scx.slice to zero and the following would treat the yielding task
     * as if it has consumed all its slice. If this penalizes yielding tasks
     * too much, determine the execution time by taking explicit timestamps
     * instead of depending on @p->scx.slice.
     */
    p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}
```

一個任務結束時會呼叫 `stopping()`。參數的 `runnable` 則是指 stop 之後狀態是否是可執行。這裡的處理是將 `dsq_vtime` 以權重方式推進運行時間的長度，運行時間的依據則是剩餘可運行的 slice `p->scx.slice` 和一開始指派的值 `SCX_SLICE_DFL` 推算。注意到註解提及這種算法在 yield 情況下的效果。

```cpp
void BPF_STRUCT_OPS(simple_exit, struct scx_exit_info *ei)
{
    UEI_RECORD(uei, ei);
}
```

`exit()` 在 sched_ext 排程器被移除時呼叫，可以保存退出時的資訊，以提供給 BPF loader 進行確認。

### BPF loader

在上一章節所講述的程式碼會被轉換成 eBPF bytecode，再交由 [scx_simple.c](https://github.com/torvalds/linux/blob/master/tools/sched_ext/scx_simple.c) 這個 BPF loader 植入到核心中運行。

```cpp
static volatile int exit_req;

static void sigint_handler(int simple)
{
	exit_req = 1;
}

int main(int argc, char **argv)
{
	struct scx_simple *skel;
	struct bpf_link *link;
	__u32 opt;
	__u64 ecode;

	libbpf_set_print(libbpf_print_fn);
	signal(SIGINT, sigint_handler);
	signal(SIGTERM, sigint_handler);
```

BPF loader 的程式碼相對容易。首先 `libbpf_set_print()` 可以設定給定的 callback 來決定警告或資訊訊息的處理方式(例如忽略或者嵌入額外內容等)。

接著，註冊 signal handler 以正確處理 BPF loader 的結束。Handler 的行為只是設置一個 flag，以終止後續會看到的主要功能迴圈。

```cpp
restart:
	skel = SCX_OPS_OPEN(simple_ops, scx_simple);

	while ((opt = getopt(argc, argv, "fvh")) != -1) {
		switch (opt) {
		case 'f':
			skel->rodata->fifo_sched = true;
			break;
		case 'v':
			verbose = true;
			break;
		default:
			fprintf(stderr, help_fmt, basename(argv[0]));
			return opt != 'h';
		}
	}
```

在 BPF loader 中以 BPF **skeleton** 來使 userspace 關聯到 kernel 中的 BPF 程式，以存取其中的變數或資料結構。

這裡透過 `SCX_OPS_OPEN()` 來建立對應到前段所述之 BPF Scheduler 的 `skel`。接著，可以對 `skel->rodata` 的變數進行修改，以影響到後續載入的 BPF code 中之全域變數(`fifo_sched`)之值。

```cpp
	SCX_OPS_LOAD(skel, simple_ops, scx_simple, uei);
	link = SCX_OPS_ATTACH(skel, simple_ops, scx_simple);

	while (!exit_req && !UEI_EXITED(skel, uei)) {
		__u64 stats[2];

		read_stats(skel, stats);
		printf("local=%llu global=%llu\n", stats[0], stats[1]);
		fflush(stdout);
		sleep(1);
	}
```


BPF code 以 `SCX_OPS_LOAD` 載入之後，藉 `SCX_OPS_ATTACH` 會正式啟用定義的 sched_ext 排程器行為，進行之前我們看到的那些 Scheduler 程式碼。

```cpp
static void read_stats(struct scx_simple *skel, __u64 *stats)
{
	int nr_cpus = libbpf_num_possible_cpus();
	__u64 cnts[2][nr_cpus];
	__u32 idx;

	memset(stats, 0, sizeof(stats[0]) * 2);

	for (idx = 0; idx < 2; idx++) {
		int ret, cpu;

		ret = bpf_map_lookup_elem(bpf_map__fd(skel->maps.stats),
					  &idx, cnts[idx]);
		if (ret < 0)
			continue;
		for (cpu = 0; cpu < nr_cpus; cpu++)
			stats[idx] += cnts[idx][cpu];
	}
}
```

在 BPF 程式碼運行中，我們可以動態去和 kernel 交互來拿到在 BPF 中定義的 `map` 之資訊。特別關注 `read_stats` 可以看到: 我們藉由 `bpf_map_lookup_elem` 能夠從定義的 array map `stats` 中即時取得當下在 kernel 中對應結構下的數據。

```cpp
	bpf_link__destroy(link);
	ecode = UEI_REPORT(skel, uei);
	scx_simple__destroy(skel);

	if (UEI_ECODE_RESTART(ecode))
		goto restart;
	return 0;
}
```

後續就是一些資源釋放的處理，這裡就不再多做深入。

## scx

在 [scx](https://github.com/sched-ext/scx) 專案裡提供了一系列基於 sched_ext 的排程器，以及一些便於撰寫這類 eBPF-based 排程器的工具。如果想更進一步探討 sched_ext 的優勢，是很值得深入研究的內容!

### 安裝與編譯

首先，由於專案是使用 [`meson`](https://zh.wikipedia.org/zh-tw/Meson) 編譯系統，我們需要安裝此工具。然而其需要 >= 1.2 的版本，而一般的發行版例如 `apt` 僅能下載到較舊版本，因此建議使用 pip 下載之。

```
$ pip3 install meson
```


接著，我們要先藉以下步驟在之前取得的 [`sched_ext`](https://github.com/sched-ext/sched_ext) 中額外建立 kernel headers 和 libbpf，以確保 scx 使用的 kernel 資訊符合其將要執行的 kernel。

```
$ make CC=clang-17 LLVM=1 headers
$ make CC=clang-17 LLVM=1 -C tools/bpf/bpftool
```

假設 [scx](https://github.com/sched-ext/scx) 被下載到 [`sched_ext`](https://github.com/sched-ext/sched_ext) 的資料夾底下，則可以透過以下方式決定好編譯的設置。

```
$ cd scx
$ export KERNEL=$(realpath ..)
$ export BPFTOOL=$KERNEL/tools/bpf/bpftool
$ meson setup build -Dkernel_headers=$KERNEL/usr/include \
    -Dbpf_clang=clang-17 \
    -Dbpftool=$BPFTOOL/bpftool \
    -Dlibbpf_a=$BPFTOOL/libbpf/libbpf.a \
    -Dlibbpf_h=$BPFTOOL/libbpf/include
```

最後，通過以下命令可以指定要編譯的排程器類型。例如要選擇 `scx_rustland` 的話:
```
meson compile -C build scx_rustland
```

或者也可以直接在對應排程器的資料夾底下直接編譯!

```
BPF_CLANG=clang-17 cargo build
```


## Reference

* [The extensible scheduler class](https://lwn.net/Articles/922405/)
* [Doc: sched-ext](https://www.kernel.org/doc/html/next/scheduler/sched-ext.html)
* [sched_ext: a BPF-extensible scheduler class (Part 1)](https://blogs.igalia.com/changwoo/sched-ext-a-bpf-extensible-scheduler-class-part-1/)
* [sched_ext: scheduler architecture and interfaces (Part 2)](https://blogs.igalia.com/changwoo/sched-ext-scheduler-architecture-and-interfaces-part-2/)
* [Kernel Recipes 2023 - sched_ext: pluggable scheduling in the Linux kernel](https://www.youtube.com/watch?v=8kAcnNVSAdI)
* [Getting started with sched-ext development](https://arighi.blogspot.com/2024/04/getting-started-with-sched-ext.html)
