---
title: 'Linux 核心設計: Scheduler(6): 排程器測試工具'
tags: [Linux Kernel Internals, ' 作業系統', Scheduler]

---

---
tags: Linux Kernel Internals, 作業系統
---

# Linux 核心設計: Scheduler(6): CPU 排程器測試工具

## Hackbench

### 簡介
[Hackbench](https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git/tree/src/hackbench/hackbench.c) 是在 [rt-tests](https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git/) 中的效能測試工具之一，其用途在於對 CPU scheduler 進行壓力測試。具體產生的情境是: 創建指定數量的 schedulable entities(thread/process)各自做為 sender 和 receiver，並將各個 sender 和 receiver 劃分組別。對於同組別的 sender 和 receiver，這些 entities 之間會透過 socket 或 pipe 進行特定次數的資料交換。最後，計算完成所有來回收發資料所需的時間。

![image](https://hackmd.io/_uploads/HJrjGigUp.png)
> 圖片來源: [Is Benchmarking a Gimmick or Strength?](https://www.alibabacloud.com/blog/is-benchmarking-a-gimmick-or-strength_598946)

為什麼這個時間與 CPU scheduler 的能力有關聯呢? 可以先從 context switch 的發生方式說起。首先，要知道 context swtich 可以分成主動與被動兩種。在主動的部份，對於 receiver 來說，當 read 沒辦法取得資料時，receiver 會被 blocking 並主動讓出 CPU 進入 sleep。反之對於 sender，如果 write 找不到足夠空間寫入資料時，sender 也會被 blocking 且主動讓出 CPU。此外核心也有例如 timer interrupt 的機制來迫使 schedulable entities 讓出 CPU，這是被動 context switch 的部份。

因為 Hackbench 可以建立頻繁且密集 I/O 的工作，因此能夠引發密集的 context switch。可以想像 benchmark 執行的時間裡就有一定比例的時間 CPU 是在進行 context switch，而非 message 交換本身。在此事實上，假設測試情境固定工作量，只改變 context switch 的演算法，則如果 benchmark 在演算法 A 完成時間比演算法 B 更短，間接就表示方法 A 的表現在此情境更好，反之是方法 B 更好。

懷疑 Hackbench 是否確實可以頻繁的觸發 context switch? 我們可以透過執行 Hackbench + [Perfetto](https://perfetto.dev/) 觀察到密集的 context switch 發生。
```
$ out/linux/tracebox -o trace_file.perfetto-trace --txt \
    -c test/configs/scheduling.cfg

(another terminal)
$ taskset -c 1 hackbench --loops=1000
```

![image](https://hackmd.io/_uploads/SyC4h3gLp.png)

### 示例: 使用 Hackbench 分析 CFS 參數

在文章 [Is Benchmarking a Gimmick or Strength?](https://www.alibabacloud.com/blog/is-benchmarking-a-gimmick-or-strength_598946) 中展示了應用 Hackbench 來分析 CFS 性能的方式。

回顧一下之前介紹過的 CFS。在 CFS 中，[`sched_init_debug()`](https://elixir.bootlin.com/linux/v5.16.6/source/kernel/sched/debug.c#L300) 註冊了 debugfs 允許更改與排程演算法相關的可變參數，其中有兩個我們接下來要重點關注的:
* `sched_min_granularity_ns`: 透過 `/proc/sys/kernel/sched_min_granularity_ns` 可修改 `sysctl_sched_min_granularity`，後者和 task 可被保證獲得的最小 time slice 相關
* `sched_wakeup_granularity_ns`: 透過 `/proc/sys/kernel/sched_wakeup_granularity_ns` 可修改 `sysctl_sched_wakeup_granularity`，後者與 task 被 wakeup 後，可真正允許進行 preemption 的時間相關

![image](https://hackmd.io/_uploads/r1ATcY-Lp.png)

則首先我們觀察上圖在固定 `sched_wakeup_granularity_ns` 更改 `min_granularity_ns` 對相同工作量的 Hackbench 時間差異:
* 在區間 A，`min_granularity_ns` 增加的同時效能表現提升(time 下降)，因為過小的 `min_granularity_ns` 會導致許多無意義的被動 context switch
* 在區間 B，`min_granularity_ns` 超出一定大小後，context switch 太少反而造成無意義的等待，這樣反而也對效能造成負面影響
* 在區間 C，`min_granularity_ns` 的增加對效能的影響趨近平穩，因為當 `min_granularity_ns` 大到一定程度就代表幾乎沒有被動的 context switch，後續再增加就對性能沒有影響

![image](https://hackmd.io/_uploads/ryW5RY-8p.png)

若改為固定 `min_granularity_ns` 並調整 `sched_wakeup_granularity_ns` 對相同工作量的 Hackbench 時間差異:
* 在區間 A，`sched_wakeup_granularity_ns` 增加對效能造成正向影響，因為減少 wakeup preemption，讓 task 有更多時間完成 send/receive 任務
* 在區間 B，`sched_wakeup_granularity_ns` 增加對時間影響有增加趨勢，可能有一些 sender 已經完成穿輸等待被 responce，但被 wakeup 的 receiver 沒辦法馬上獲得排程導致
* 在區間 C，`sched_wakeup_granularity_ns` 到一定大小後造成幾乎沒有 wakueup preeption 的情況，對性能表現趨近平穩



## Schbench

### 簡介

Hackbench 只能透過總結的平均數據來估算 context switch 延遲，而缺乏對延遲的統計分布數據，因此在使用上可能產生誤差。[schbench](https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git/) 在這層需求上能提供更好的 benchmarking。這個 benchmark 是由 Facebook/Meta 所推出，引述貢獻者 Chris Mason 的說明:

> "The focus on p99 latencies instead of average latencies is the most important part. For us, lots of problems only show up when you start looking at the long tail in the latency graphs." 

在許多情況下，從平均延遲並不能看出 Scheduler 的缺陷，p99 才能顯示真正的問題。而 Schbench 因為輸出統計分布數據，對這項需求能做到一定程度的滿足。

Schbench 中會建立 message threads 和 worker threads 兩者角色。Worker 負責做 usleep 和一些矩陣運算來模擬 request，模擬現實中網路、硬碟和 locking 操作頻繁的場景。Message thread 會建立這些 worker 並等待結果。

則在這個 workload 模型下，可以統計以下三種數據:
* Wakeup latency: message thread 喚醒 worker 的時間到 worker thread 真正開始運行的時間
* Request latency: 完成一個 request (fake) 所需的時間
* Requests per second: 每秒鐘可以完成 request 的數量

更多細節可以參考 [README.md](https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git/tree/README.md)。在 [schbench v1.0](https://lore.kernel.org/lkml/bc85a40c-1ea0-9b57-6ba3-b920c436a02c@meta.com/) 郵件中則可以看到基於 Schbench 對 EEVDF 的分析和討論。


## Adrestia

### 簡介
[Adrestia](https://github.com/mfleming/adrestia) 並非主流常用的 scheduler 分析工具，算是 [A survey of scheduler benchmarks](https://lwn.net/Articles/725238/) 文章的作者老王賣瓜順便介紹XD。不過作為一個簡易的工具，相關的程式碼很精簡，因此倒是很適合作為設計 benchmark 入門的參考材料。

具體的模型是: 建立 pipe，假設 thread A 負責對 pipe 寫入，thread B 則在 pipe 有資料時將此讀出。則 thread B 一開始建立出來時，由於 pipe 中無可讀資料，會主動 context switch 進入 sleep 狀態。直到 thread A 寫入 pipe，此時記錄一個 timestamp x。然後 thread B 因此被喚醒，read 從 blocking 狀態下返回，此時記錄一個 timestamp y。則 y - x 的時間差就很接近 Scheduler wakeup 需要的延遲時間。

## Rt-app

[Rt-app](https://github.com/scheduler-tools/rt-app) 提供透過 json 格式來描述 workload 的方式。可以構建許多的種類的測試場景。

## Cyclictest

[Cyclictest](https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git/tree/src/cyclictest) 是在 [rt-tests](https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git/) 中的另一個效能測試工具，這個工具主要應用於 RT kernel 中，用來測試任務被喚醒的延遲時間，藉此理解 Realtime 系統中由硬體、韌體和作業系統引起的延遲。

### 測試原理

Cyclictest 如何達到上述目的呢? 在 Cyclictest 被啟動後，測試程式會啟動一個非 realtime/`SCHED_OTHER` 的主執行緒，該執行緒以執行時定義的優先權(priority) 啟動定義數量的 `SCHED_FIFO` 執行緒。

這些 `SCHED_FIFO` 的執行緒用來測量延遲，測試時會透過到期計時器(expiring timer)，例如 [nanosleep](https://man7.org/linux/man-pages/man2/nanosleep.2.html)，以定義的間隔定期喚醒之。隨後，通過計算預期喚醒時間和實際喚醒時間之間的差值，主執行緒可以藉由與其共享的記憶體得知這些數據，進而追蹤延遲值。在每一輪的測試中即時更新目前的最小、最大和平均延遲等數據。

### Output

根據測試的平台與系統環境，我們會需要調校 `cyclictest` 的參數以獲得可靠的結果。以下是一個 `cyclictest` 的執行範例: 它預設系統是 SMP 架構(`--smp`)建立 CPU 同等數量、優先權為 99 的 `SCHED_FIFO` 執行緒(`--priority 99`)，他們會以 200us 為最小週期定期的被喚醒(`--interval=200`)。

```
$ sudo ./cyclictest --mlockall --smp \
    --priority=99 --interval=200
```

得到類似以下的輸出:

```
# /dev/cpu_dma_latency set to 0us
policy: fifo: loadavg: 0.08 0.02 0.01 1/371 1137

T: 0 ( 1118) P:99 I:200 C:   9149 Min:      9 Act:   26 Avg:   38 Max:     276
T: 1 ( 1119) P:99 I:700 C:   2616 Min:     30 Act:   74 Avg:   85 Max:     321
T: 2 ( 1120) P:99 I:1200 C:   1525 Min:     40 Act:  105 Avg:  124 Max:     375
T: 3 ( 1121) P:99 I:1700 C:   1075 Min:     98 Act:  172 Avg:  160 Max:     312
T: 4 ( 1122) P:99 I:2200 C:    823 Min:      8 Act:  221 Avg:  196 Max:     579
T: 5 ( 1123) P:99 I:2700 C:    676 Min:      9 Act:  196 Avg:  224 Max:     511
T: 6 ( 1124) P:99 I:3200 C:    570 Min:     49 Act:  308 Avg:  289 Max:     481
T: 7 ( 1125) P:99 I:3700 C:    492 Min:    116 Act:  301 Avg:  324 Max:     531
T: 8 ( 1126) P:99 I:4200 C:    433 Min:    164 Act:  337 Avg:  360 Max:     541
T: 9 ( 1127) P:99 I:4700 C:    387 Min:     60 Act:  454 Avg:  404 Max:     591
T:10 ( 1128) P:99 I:5200 C:    350 Min:     91 Act:  425 Avg:  424 Max:     711
T:11 ( 1129) P:99 I:5700 C:    319 Min:    164 Act:  465 Avg:  478 Max:     680
T:12 ( 1130) P:99 I:6200 C:    293 Min:    238 Act:  562 Avg:  525 Max:     704
T:13 ( 1131) P:99 I:6700 C:    271 Min:     98 Act:  541 Avg:  526 Max:     730
T:14 ( 1132) P:99 I:7200 C:    252 Min:     22 Act:  210 Avg:  399 Max:     852
T:15 ( 1133) P:99 I:7700 C:    235 Min:    205 Act:  616 Avg:  633 Max:     816
T:16 ( 1134) P:99 I:8200 C:    220 Min:     81 Act:  655 Avg:  664 Max:     967
T:17 ( 1135) P:99 I:8700 C:    208 Min:     26 Act:  705 Avg:  696 Max:     795
T:18 ( 1136) P:99 I:9200 C:    196 Min:     56 Act:  564 Avg:  690 Max:     914
T:19 ( 1137) P:99 I:9700 C:    186 Min:     84 Act:  779 Avg:  774 Max:     922
```
:::info
由於筆者是在非 RT kernel 下執行，只是作為範例展示，可以看到平均延遲是很高的~
:::

對此輸出的解釋可以參考以下表格:

| abr. | Label    | Description          |
|:---- |:-------- | -------------------- |
| T    | Thread   | 執行緒的編號和 tid   |
| P    | Priority | 執行緒的優先級       |
| I    | Interval | 執行緒被喚醒的週期   |
| C    | Count    | iteration 次數       |
| Min  | Minimum  | 喚醒延遲的最小值     |
| Act  | Actual   | 最近一次喚醒延遲的值 |
| Avg  | Average  | 喚醒延遲的平均值     |
| Max  | Maximum  | 喚醒延遲的最大值     |

* 預設的時間是以 us 為單位，但可以透過參數調整

### Histograms

在 Cyclictest 另外支援 histogram 模式，可以在測試結束時輸出直方圖，以知道各個延遲時間的比例分布。透過 option `–histogram` 和 `–histofall` 可取得。


建議上，可以將 histogram 的結果輸出到檔案裡。例如以下方式:
```
$ sudo ../../cyclictest --mlockall --smp \
    --priority=99 --interval=200 \
    --histogram 1000 -D 10s > output
```

然後再藉由 [plot-cyclictest-hist.sh](https://github.com/RinHizakura/mysetting/blob/main/plot/plot-cyclictest-hist.sh) 轉為較容易可視化的輸出。

```
$  ./plot-cyclictest-hist.sh output
```

![image](https://hackmd.io/_uploads/SyhYObgPye.png)

### 分析結果

一般來說，在 Cyclictest 結果中最被關注是檢測到的最大延遲。因為對於 Realtime 的系統來說，會預期其在容忍範圍內產生回應，因此知道最壞情況下的延遲時間是重要的。

但是當在評判測試結果的好壞時，必須要審慎思考其合理性，因為最大測量值不一定代表系統的最壞情況。受限於 Cyclictest 使用 `nanosleep()` 作為喚醒測量執行緒的手段，測量延遲的結果可能較為樂觀，因此要留意其中的偏差。相關的限制與使用細節可以參考 [Cyclictest 文件](https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cyclictest/start) 中的敘述。

## Reference

* [A survey of scheduler benchmarks](https://lwn.net/Articles/725238/)
* [Is Benchmarking a Gimmick or Strength?](https://www.alibabacloud.com/blog/is-benchmarking-a-gimmick-or-strength_598946)
* [Cyclictest](https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cyclictest/start)