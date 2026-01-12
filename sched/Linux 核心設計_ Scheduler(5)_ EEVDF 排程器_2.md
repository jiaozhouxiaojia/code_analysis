---
title: 'Linux 核心設計: Scheduler(5): EEVDF 排程器/2'
tags: [Linux Kernel Internals, ' 作業系統', Scheduler]

---

# Linux 核心設計: Scheduler(5): EEVDF 排程器/2

## RFC Patches 2

前一章所研讀的 patches 最終並未正式合併到 kernel 中。維護者 Peter Zijlstra 針對此做了修正與調整，重新釋出了進階的改動 [[RFC][PATCH 00/10] sched/fair: Complete EEVDF](https://lore.kernel.org/lkml/20240405102754.435410987@infradead.org/?fbclid=IwAR22R73s3oT78BcbvQjjgKLJJPUqjS2YRsESUY3f67CmTsZPj6EXCV-Omzs)。在此系列內容中，除了原本對 time slice/request size 的支援，Peter 還新增 delayed-dequeue 機制以彌補原始論文在 EEVDF 上的缺陷。這些改動將成為補足 EEVDF 的最後一塊拼圖。而本節將針對這一系列內容進行探討。

### [RFC][PATCH 01/10] sched/eevdf: Add feature comments

單純是加上註解描述幾個 SCHED_FEAT。

```diff
--- a/kernel/sched/features.h
+++ b/kernel/sched/features.h
@@ -5,7 +5,14 @@
  * sleep+wake cycles. EEVDF placement strategy #1, #2 if disabled.
  */
 SCHED_FEAT(PLACE_LAG, true)
+/*
+ * Give new tasks half a slice to ease into the competition.
+ */
 SCHED_FEAT(PLACE_DEADLINE_INITIAL, true)
+/*
+ * Inhibit (wakeup) preemption until the current task has either matched the
+ * 0-lag point or until is has exhausted it's slice.
+ */
 SCHED_FEAT(RUN_TO_PARITY, true)
```

之前的內容已經對這些 feature 做了介紹。這裡就簡單再總結一下:
* `PLACE_DEADLINE_INITIAL`: 將新建立的任務 deadline 刻意提早，以獲得更早被排程的機會
* `RUN_TO_PARITY`: 目的是減少激進的搶占。一般來說，應該是總要選擇 deadline 最小的任務優先執行。但此 feature 會讓當下選取的任務一直被執行到 non-eligible 或者取得一個新的 slice，期間內不會被其他任務搶占。

### [RFC][PATCH 02/10] sched/eevdf: Remove min_vruntime_copy

過去存在名為 `min_vruntime_copy` 的變數，它與不同 CPU 之間的同步相關，具體使用到它的程式碼大致如下(參照 [5.19.17 版的 fair.c](https://elixir.bootlin.com/linux/v5.19.17/source/kernel/sched/fair.c))。

```cpp
void init_cfs_rq(struct cfs_rq *cfs_rq)
{
	...
	cfs_rq->min_vruntime = (u64)(-(1LL << 20));
#ifndef CONFIG_64BIT
	cfs_rq->min_vruntime_copy = cfs_rq->min_vruntime;
#endif
}

static void update_min_vruntime(struct cfs_rq *cfs_rq)
{
	...
	/* ensure we never gain time by being placed backwards. */
	cfs_rq->min_vruntime = max_vruntime(cfs_rq->min_vruntime, vruntime);
#ifndef CONFIG_64BIT
	smp_wmb();
	cfs_rq->min_vruntime_copy = cfs_rq->min_vruntime;
#endif
}

static void migrate_task_rq_fair(struct task_struct *p, int new_cpu)
{
	if (READ_ONCE(p->__state) == TASK_WAKING) {
		struct sched_entity *se = &p->se;
		struct cfs_rq *cfs_rq = cfs_rq_of(se);
		u64 min_vruntime;

#ifndef CONFIG_64BIT
		u64 min_vruntime_copy;

		do {
			min_vruntime_copy = cfs_rq->min_vruntime_copy;
			smp_rmb();
			min_vruntime = cfs_rq->min_vruntime;
		} while (min_vruntime != min_vruntime_copy);
#else
		min_vruntime = cfs_rq->min_vruntime;
#endif
		...
```

在 `CONFIG_64BIT` 沒有被設置的狀況下，表示 Linux 是使用在 32 位元的機器上。則此時存取存 64 位元的整數時，CPU 需要兩次的記憶體操作才能完成，換句話說並非 atomic 操作。因此，為確保在 reader 端得到的 `min_vruntime` 可以正確反映 writer 端的更新，`min_vruntime_copy` 搭配 read/write barrier 可以做為同步機制來避免上述的問題。這個技巧與 [sequential locks](https://docs.kernel.org/locking/seqlock.html) 有異曲同工之妙。具體的改動來自 [[PATCH 10/22] sched: Deal with non-atomic min_vruntime reads on 32bits](https://lore.kernel.org/lkml/20110302174120.976363449@chello.nl/)。之後，考慮到其他變數也需要類似技巧，後來一系列操作又以 `u64_u32_store` macro 被提供。

在 [[PATCH 07/15] sched/smp: Use lag to simplify cross-runqueue placement](https://hackmd.io/1wvEMFFVQ5ui4iPd5fPfIg#PATCH-0715-schedsmp-Use-lag-to-simplify-cross-runqueue-placement) 之後，任務在不同 CPU 核心間轉移(migration)時，不再是用 `min_vruntime` 來標準化對應 vruntime。因此在此 patch 中也將相應內容移除。

```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -780,8 +780,7 @@ static void update_min_vruntime(struct c
 	}
 
 	/* ensure we never gain time by being placed backwards. */
-	u64_u32_store(cfs_rq->min_vruntime,
-		      __update_min_vruntime(cfs_rq, vruntime));
+	cfs_rq->min_vruntime = __update_min_vruntime(cfs_rq, vruntime);
 }
 
 static inline bool __entity_less(struct rb_node *a, const struct rb_node *b)
@@ -12876,7 +12875,7 @@ static void set_next_task_fair(struct rq
 void init_cfs_rq(struct cfs_rq *cfs_rq)
 {
 	cfs_rq->tasks_timeline = RB_ROOT_CACHED;
-	u64_u32_store(cfs_rq->min_vruntime, (u64)(-(1LL << 20)));
+	cfs_rq->min_vruntime = (u64)(-(1LL << 20));
 #ifdef CONFIG_SMP
 	raw_spin_lock_init(&cfs_rq->removed.lock);
 #endif
```

```diff
--- a/kernel/sched/sched.h
+++ b/kernel/sched/sched.h
@@ -599,10 +599,6 @@ struct cfs_rq {
 	u64			min_vruntime_fi;
 #endif
 
-#ifndef CONFIG_64BIT
-	u64			min_vruntime_copy;
-#endif
-
 	struct rb_root_cached	tasks_timeline;
 
 	/*
```

### [RFC][PATCH 03/10] sched/fair: Cleanup pick_task_fair() vs throttle

`check_cfs_rq_runtime` 與 bandwith throttling 有關。概括來說是用來限制一個任務在每個周期中可以消耗 CPU 的時間，而簡單總結其作法的話，是將符合受限條件的 schedule entity(se) 從排程 runqueue 中移除。

在 `pick_next_task_fair` 中，這段邏輯被放在 `if(curr)` 的條件式中。這是因為如果不在此前提下的話，throttling 的結果最終可能會導致 runqueue 為空，因此造成後續挑選任務的邏輯(`set_next_entity`)產生錯誤。詳見 [[PATCH] sched/fair: Prevent throttling in early pick_next_task_fair()](https://lore.kernel.org/stable/20151018014907.245719036@linuxfoundation.org/) 的敘述。

```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -8435,11 +8435,11 @@ static struct task_struct *pick_task_fai
		if (curr) {
			if (curr->on_rq)
				update_curr(cfs_rq);
			else
				curr = NULL;
-
-			if (unlikely(check_cfs_rq_runtime(cfs_rq)))
-				goto again;
 		}
 
+		if (unlikely(check_cfs_rq_runtime(cfs_rq)))
+			goto again;
+
 		se = pick_next_entity(cfs_rq);
 		cfs_rq = group_cfs_rq(se);
 	} while (cfs_rq);
```

原本的 `pick_task_fair` 之邏輯是從  `pick_next_task_fair` 複製過來的(見 [[sched/core] sched: Introduce sched_class::pick_task](https://lore.kernel.org/lkml/162081530531.29796.2208363751943226264.tip-bot2@tip-bot2/))。但在 `pick_task_fair` 的 code path 上，throttle 任何任務皆不會造成上述的錯誤。因此此 patch 對此作出調整。

### [RFC][PATCH 04/10] sched/fair: Cleanup pick_task_fair()s curr

```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -8427,15 +8427,9 @@ static struct task_struct *pick_task_fai
 		return NULL;
 
 	do {
-		struct sched_entity *curr = cfs_rq->curr;
-
 		/* When we pick for a remote RQ, we'll not have done put_prev_entity() */
-		if (curr) {
-			if (curr->on_rq)
-				update_curr(cfs_rq);
-			else
-				curr = NULL;
-		}
+		if (cfs_rq->curr && cfs_rq->curr->on_rq)
+			update_curr(cfs_rq);
 
 		if (unlikely(check_cfs_rq_runtime(cfs_rq)))
 			goto again;
```

結合前一個 patch 的改動，現在我們可以移除 `curr` 這個變數。

### [RFC][PATCH 05/10] sched/fair: Unify pick_{,next_}_task_fair()

經過上面的調整後，`pick_task_fair` 的邏輯完全對應到 `pick_next_task_fair` 中的一部分，因此就可以將兩者整合起來以避免重複的程式碼。

### [RFC][PATCH 06/10] sched: Allow sched_class::dequeue_task() to fail

原始的 `dequeue_task` 設計是沒有回傳值的，這意味著呼叫 dequeue 的結果無法被確認，例如是否有成功。由於 EEVDF 的新功能需要相關的資訊，因此在此 patch 中調整該 callback 的 signature。

```diff
 /*
--- a/kernel/sched/sched.h
+++ b/kernel/sched/sched.h
@@ -2278,7 +2278,7 @@ struct sched_class {
 #endif
 
 	void (*enqueue_task) (struct rq *rq, struct task_struct *p, int flags);
-	void (*dequeue_task) (struct rq *rq, struct task_struct *p, int flags);
+	bool (*dequeue_task) (struct rq *rq, struct task_struct *p, int flags);
 	void (*yield_task)   (struct rq *rq);
 	bool (*yield_to_task)(struct rq *rq, struct task_struct *p);
```

```diff
--- a/kernel/sched/core.c
+++ b/kernel/sched/core.c
@@ -2119,7 +2119,10 @@ static inline void enqueue_task(struct r
 		sched_core_enqueue(rq, p);
 }
 
-static inline void dequeue_task(struct rq *rq, struct task_struct *p, int flags)
+/*
+ * Must only return false when DEQUEUE_SLEEP.
+ */
+static inline bool dequeue_task(struct rq *rq, struct task_struct *p, int flags)
 {
 	if (sched_core_enabled(rq))
 		sched_core_dequeue(rq, p, flags);
@@ -2133,7 +2136,7 @@ static inline void dequeue_task(struct r
 	}
 
 	uclamp_rq_dec(rq, p);
-	p->sched_class->dequeue_task(rq, p, flags);
+	return p->sched_class->dequeue_task(rq, p, flags);
 }
```

下面就是對 kernel 中所有類型的 scheduler，包含 deadline, idle, fair, rt, 和 stop 都做相對應的調整。

```diff
--- a/kernel/sched/deadline.c
+++ b/kernel/sched/deadline.c
@@ -1842,7 +1842,7 @@ static void enqueue_task_dl(struct rq *r
 		enqueue_pushable_dl_task(rq, p);
 }
 
-static void dequeue_task_dl(struct rq *rq, struct task_struct *p, int flags)
+static bool dequeue_task_dl(struct rq *rq, struct task_struct *p, int flags)
 {
 	update_curr_dl(rq);
 
@@ -1852,6 +1852,8 @@ static void dequeue_task_dl(struct rq *r
 	dequeue_dl_entity(&p->dl, flags);
 	if (!p->dl.dl_throttled && !dl_server(&p->dl))
 		dequeue_pushable_dl_task(rq, p);
+
+	return true;
 }
```

```diff
 /*
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -6828,7 +6828,7 @@ static void set_next_buddy(struct sched_
  * decreased. We remove the task from the rbtree and
  * update the fair scheduling stats:
  */
-static void dequeue_task_fair(struct rq *rq, struct task_struct *p, int flags)
+static bool dequeue_task_fair(struct rq *rq, struct task_struct *p, int flags)
 {
 	struct cfs_rq *cfs_rq;
 	struct sched_entity *se = &p->se;
@@ -6896,6 +6896,8 @@ static void dequeue_task_fair(struct rq
 dequeue_throttle:
 	util_est_update(&rq->cfs, p, task_sleep);
 	hrtick_update(rq);
+
+	return true;
 }
```

```diff
 #ifdef CONFIG_SMP
--- a/kernel/sched/idle.c
+++ b/kernel/sched/idle.c
@@ -486,13 +486,14 @@ struct task_struct *pick_next_task_idle(
  * It is not legal to sleep in the idle task - print a warning
  * message if some code attempts to do it:
  */
-static void
+static bool
 dequeue_task_idle(struct rq *rq, struct task_struct *p, int flags)
 {
 	raw_spin_rq_unlock_irq(rq);
 	printk(KERN_ERR "bad: scheduling from the idle thread!\n");
 	dump_stack();
 	raw_spin_rq_lock_irq(rq);
+	return true;
 }
```

```diff
 /*
--- a/kernel/sched/rt.c
+++ b/kernel/sched/rt.c
@@ -1493,7 +1493,7 @@ enqueue_task_rt(struct rq *rq, struct ta
 		enqueue_pushable_task(rq, p);
 }
 
-static void dequeue_task_rt(struct rq *rq, struct task_struct *p, int flags)
+static bool dequeue_task_rt(struct rq *rq, struct task_struct *p, int flags)
 {
 	struct sched_rt_entity *rt_se = &p->rt;
 
@@ -1501,6 +1501,8 @@ static void dequeue_task_rt(struct rq *r
 	dequeue_rt_entity(rt_se, flags);
 
 	dequeue_pushable_task(rq, p);
+
+	return true;
 }
```

```diff
--- a/kernel/sched/stop_task.c
+++ b/kernel/sched/stop_task.c
@@ -57,10 +57,11 @@ enqueue_task_stop(struct rq *rq, struct
 	add_nr_running(rq, 1);
 }
 
-static void
+static bool
 dequeue_task_stop(struct rq *rq, struct task_struct *p, int flags)
 {
 	sub_nr_running(rq, 1);
+	return true;
 }
```

### [RFC][PATCH 07/10] sched/fair: Re-organize dequeue_task_fair()

結合上一項改動，這一系列的調整是為了 EEVDF 需要的 "delaying dequeue" 機制。本筆 commit 對 `dequeue_task_fair` 的實作方式進行了重構。

原本的 `dequeue_task_fair` 中的大部分內容被獨立為函式 `dequeue_entities()`，這是為了讓 `dequeue_entities()` 中的邏輯可以讓 `dequeue_task_fair` 以外的地方也可以共用。

關於 `dequeue_task_fair()` 的詳細分析可在 [`dequeue_task_fair`](https://hackmd.io/@RinHizakura/BJ9m_qs-5#dequeue_task_fair) 一章中參閱，以下僅針對改動前後需留意的差異進行說明。

```cpp
 /*
  * Basically dequeue_task_fair(), except it can deal with dequeue_entity()
 * failing half-way through and resume the dequeue later.
  *
  * Returns:
  * -1 - dequeue delayed
  *  0 - dequeue throttled
  *  1 - dequeue complete
  */
static int dequeue_entities(struct rq *rq, struct sched_entity *se, int flags)
 {
 	bool was_sched_idle = sched_idle_rq(rq);
	bool task_sleep = flags & DEQUEUE_SLEEP;
	struct task_struct *p = NULL;
	struct cfs_rq *cfs_rq;
	int idle_h_nr_running;
 
	if (entity_is_task(se)) {
		p = task_of(se);
		idle_h_nr_running = task_has_idle_policy(p);
	} else {
		idle_h_nr_running = cfs_rq_is_idle(group_cfs_rq(se));
	}
```

`idle_h_nr_running` 的獲得方式與原本在 `dequeue_task_fair` 中的做法不同。在原本實作中是直接透過 `task_has_idle_policy(p)` 取得，因為只要考慮 `task_struct` 的情況即可，而此處則針對 task group 的狀況也做考量。


```cpp
 	for_each_sched_entity(se) {
 		cfs_rq = cfs_rq_of(se);
 		dequeue_entity(cfs_rq, se, flags);
 
		/* h_nr_running is the hierachical count of tasks */
		if (p) {
			cfs_rq->h_nr_running--;
			cfs_rq->idle_h_nr_running -= idle_h_nr_running;
 
			if (cfs_rq_is_idle(cfs_rq))
				idle_h_nr_running = 1;
		}
 
 		/* end evaluation on encountering a throttled cfs_rq */
 		if (cfs_rq_throttled(cfs_rq))
			return 0;
 
 		/* Don't dequeue parent if it has other entities besides us */
 		if (cfs_rq->load.weight) {
			/* Avoid re-evaluating load for this entity: */
			se = parent_entity(se);
			/*
			 * Bias pick_next to pick a task from this cfs_rq, as
			 * p is sleeping when it is within its sched_slice.
			 */
			if (task_sleep && se && !throttled_hierarchy(cfs_rq))
				set_next_buddy(se);
			break;
		}
		flags |= DEQUEUE_SLEEP;
	}
```

在第一個 `for_each_sched_entity` 中，與原先的不同在於 `if(p){...}` 的部分。如果 `se` 非來自 `task_struct` 的話，不必去做對應 `cfs_rq` 相關成員(如 `h_nr_running`、`idle_h_nr_running`)的更新。

```cpp
 	for_each_sched_entity(se) {
 		cfs_rq = cfs_rq_of(se);
 
		// XXX avoid these load updates for delayed dequeues ?
 		update_load_avg(cfs_rq, se, UPDATE_TG);
 		se_update_runnable(se);
 		update_cfs_group(se);
 
		if (p) {
			cfs_rq->h_nr_running--;
			cfs_rq->idle_h_nr_running -= idle_h_nr_running;
 
			if (cfs_rq_is_idle(cfs_rq))
				idle_h_nr_running = 1;
		}
 
 		/* end evaluation on encountering a throttled cfs_rq */
 		if (cfs_rq_throttled(cfs_rq))
			return 0;
	}
```

第二個 `for_each_sched_entity()` 也是類似，避免一些 `cfs_rq` 中變數的更新。


```cpp
	if (p) {
		sub_nr_running(rq, 1);
 
		/* balance early to pull high priority tasks */
		if (unlikely(!was_sched_idle && sched_idle_rq(rq)))
			rq->next_balance = jiffies;
 	}
 
	return 1;
}
```

最後的部分，如果 `se` 非來自 `task_struct` 的話，有一些行為也直接略過。

```cpp
/*
 * The dequeue_task method is called before nr_running is
 * decreased. We remove the task from the rbtree and
 * update the fair scheduling stats:
 */
static bool dequeue_task_fair(struct rq *rq, struct task_struct *p, int flags)
{
	util_est_dequeue(&rq->cfs, p);
 
	if (dequeue_entities(rq, &p->se, flags) < 0)
		return false;
 
	util_est_update(&rq->cfs, p, flags & DEQUEUE_SLEEP);
	hrtick_update(rq);
 	return true;
} 
```

綜合下來，`dequeue_task_fair` 與原始的行為並無二異，僅是改為利用了 `dequeue_entities`。

### [RFC][PATCH 08/10] sched/fair: Implement delayed dequeue

在 [sched/fair: Add lag based placement](https://hackmd.io/1wvEMFFVQ5ui4iPd5fPfIg#PATCH-0315-schedfair-Add-lag-based-placement) 一節，我們曾經討論到原始 EEVDF 論文在處理 lag 的缺陷。簡而言之，若 `se` 在退出排程時，其所剩餘之 lag 會在下次重新排程時繼承，則變相是在鼓勵任務在等待 CPU 時 spin wait 而不真正 sleep，以確保自己能夠得到足量的 CPU 資源。但反過來說，也不能完全不考量退出時的 lag，因為這反而導致任務刻意的 sleep 可以確保 CPU。

Peter Zijkstra 認為可以對應的辦法是稱為 delay dequeue 的機制。這種機制會把進入 sleep 但 lag 仍為負的 `se` 仍暫時保留在 queue 上。理想上，一直保留到 lag = 0 再將其 dequeued。不過實際上 kernel 不可能費心力追蹤該任務的 lag。取而代之，可以一直等到下次要選取該任務時，若其 eligible 才真正將其從 queue 中剃除。

理解了故事背景，再回頭看程式碼就很容易懂了。

```diff
--- a/include/linux/sched.h
+++ b/include/linux/sched.h
@@ -542,6 +542,7 @@ struct sched_entity {
 
 	struct list_head		group_node;
 	unsigned int			on_rq;
+	unsigned int			sched_delayed;
 
 	u64				exec_start;
 	u64				sum_exec_runtime;
```


```diff
--- a/kernel/sched/core.c
+++ b/kernel/sched/core.c
@@ -2154,10 +2154,14 @@ void activate_task(struct rq *rq, struct
 
 void deactivate_task(struct rq *rq, struct task_struct *p, int flags)
 {
-	WRITE_ONCE(p->on_rq, (flags & DEQUEUE_SLEEP) ? 0 : TASK_ON_RQ_MIGRATING);
-	ASSERT_EXCLUSIVE_WRITER(p->on_rq);
+	bool sleep = flags & DEQUEUE_SLEEP;
 
-	dequeue_task(rq, p, flags);
+	if (dequeue_task(rq, p, flags)) {
+		WRITE_ONCE(p->on_rq, sleep ? 0 : TASK_ON_RQ_MIGRATING);
+		ASSERT_EXCLUSIVE_WRITER(p->on_rq);
+	} else {
+		SCHED_WARN_ON(!sleep); /* only sleep can fail */
+	}
 }
```

前面的改動讓 `dequeue_task` 現在有了回傳值。若 dequeue 失敗，目前唯一的可能就是因為 sleep 導致的 delay dequeue。

```diff
 static inline int __normal_prio(int policy, int rt_prio, int nice)
@@ -3858,12 +3862,17 @@ static int ttwu_runnable(struct task_str
 
 	rq = __task_rq_lock(p, &rf);
 	if (task_on_rq_queued(p)) {
+		update_rq_clock(rq);
+		if (p->se.sched_delayed) {
+			/* mustn't run a delayed task */
+			SCHED_WARN_ON(task_on_cpu(rq, p));
+			enqueue_task(rq, p, ENQUEUE_DELAYED);
+		}
 		if (!task_on_cpu(rq, p)) {
 			/*
 			 * When on_rq && !on_cpu the task is preempted, see if
 			 * it should preempt the task that is current now.
 			 */
-			update_rq_clock(rq);
 			wakeup_preempt(rq, p, wake_flags);
 		}
 		ttwu_do_wakeup(p);
@@ -4243,11 +4252,16 @@ int try_to_wake_up(struct task_struct *p
 		 * case the whole 'p->on_rq && ttwu_runnable()' case below
 		 * without taking any locks.
 		 *
+		 * Specifically, given current runs ttwu() we must be before
+		 * schedule()'s deactivate_task(), as such this must not
+		 * observe sched_delayed.
+		 *
 		 * In particular:
 		 *  - we rely on Program-Order guarantees for all the ordering,
 		 *  - we're serialized against set_special_state() by virtue of
 		 *    it disabling IRQs (this allows not taking ->pi_lock).
 		 */
+		SCHED_WARN_ON(p->se.sched_delayed);
 		if (!ttwu_state_match(p, state, &success))
 			goto out;
```

`ttwu_runnable()` 函式的用途是作為 wakeup 的 fast path。如果試著 wakeup 某個任務時，該任務尚在 rq 中 runnable 還未被真正 dequeue，則直接將其狀態設為 `TASK_RUNNING` 就可完成 wakeup。

但在 delay dequeued 的狀況下，任務被留在 queue 中不一定是實際意義上的可以被排程。如果這個任務是因為 delay dequeue 而保留在 queue 中，我們需要 enqueue 這個被 delay 的任務，也就是通過 `ENQUEUE_DELAYED` flag 進行 `enqueue_task`，詳細流程會在後續說明。


```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -5270,6 +5270,10 @@ static inline int cfs_rq_throttled(struc
 static inline bool cfs_bandwidth_used(void);
 
+ static void
+requeue_delayed_entity(struct sched_entity *se);

+/* XXX bool and pull in the requeue_delayed_entity thing */
static void
 enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
 {
 	bool curr = cfs_rq->curr == se;
@@ -5356,18 +5360,33 @@ static void clear_buddies(struct cfs_rq
 
 static __always_inline void return_cfs_rq_runtime(struct cfs_rq *cfs_rq);
 
-static void
+static bool
 dequeue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
 {
 	/*
 	 * Update run-time statistics of the 'current'.
 	 */
+	if (flags & DEQUEUE_DELAYED) {
+		SCHED_WARN_ON(!se->sched_delayed);
+		se->sched_delayed = 0;
+	} else {
+		bool sleep = flags & DEQUEUE_SLEEP;
+
+		SCHED_WARN_ON(sleep && se->sched_delayed);
+		update_curr(cfs_rq);
+
+		if (sched_feat(DELAY_DEQUEUE) && sleep &&
+		    !entity_eligible(cfs_rq, se)) {
+			if (cfs_rq->next == se)
+				cfs_rq->next = NULL;
+			se->sched_delayed = 1;
+			return false;
+		}
+	}
+
	int action = UPDATE_TG;
	if (entity_is_task(se) && task_on_rq_migrating(task_of(se)))
		action |= DO_DETACH;

-	update_curr(cfs_rq);
 	/*
 	 * When dequeuing a sched_entity, we must:
@@ -5407,6 +5426,8 @@ dequeue_entity(struct cfs_rq *cfs_rq, st
 
 	if (cfs_rq->nr_running == 0)
 		update_idle_cfs_rq_clock_pelt(cfs_rq);
+
+	return true;
 }
```

這邊將 `dequeue_entity` 加上返回值，以傳遞 delay dequeue 發生的資訊給 `dequeue_task_fair`。

如果 flag 含 `DEQUEUE_DELAYED`，表示我們要 dequeue 的是一個被原本早該被 dequeue 但被 delay 的 se。這時就不需要對其 `update_curr()` 或判斷是否該 delay dequeue 等等，因為這是正常 `dequeue_entity`  流程的上半步驟，而該 se 已經完成這些，因此需要進行下半步驟就好。

如果 flag 不含 `DEQUEUE_DELAYED`，前面說到可以通過是否為 sleep 和 eligible 決定要否 delay dequeue 之。若條件滿足，該 se 在進行完 `dequeue_entity` 的上半步驟後直接 return false。否則就是正常執行完整的 dequeue。


```diff
 static void
@@ -5432,6 +5453,7 @@ set_next_entity(struct cfs_rq *cfs_rq, s
 	}
 
 	update_stats_curr_start(cfs_rq, se);
+	SCHED_WARN_ON(cfs_rq->curr);
 	cfs_rq->curr = se;
 
 	/*
@@ -5452,6 +5474,8 @@ set_next_entity(struct cfs_rq *cfs_rq, s
 	se->prev_sum_exec_runtime = se->sum_exec_runtime;
 }
```


```diff
+static int dequeue_entities(struct rq *rq, struct sched_entity *se, int flags);
+
 /*
  * Pick the next process, keeping these things in mind, in this order:
  * 1) keep things fair between processes/task groups
@@ -5460,16 +5484,29 @@ set_next_entity(struct cfs_rq *cfs_rq, s
  * 4) do not run the "skip" process, if something else is available
  */
 static struct sched_entity *
-pick_next_entity(struct cfs_rq *cfs_rq)
+pick_next_entity(struct rq *rq, struct cfs_rq *cfs_rq)
 {
 	/*
 	 * Enabling NEXT_BUDDY will affect latency but not fairness.
 	 */
 	if (sched_feat(NEXT_BUDDY) &&
-	    cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next))
+	    cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next)) {
+		/* ->next will never be delayed */
+		SCHED_WARN_ON(cfs_rq->next->sched_delayed);
 		return cfs_rq->next;
+	}
 
-	return pick_eevdf(cfs_rq);
+	struct sched_entity *se = pick_eevdf(cfs_rq);
+	if (se->sched_delayed) {
+		dequeue_entities(rq, se, DEQUEUE_SLEEP | DEQUEUE_DELAYED);
+		SCHED_WARN_ON(se->sched_delayed);
+		SCHED_WARN_ON(se->on_rq);
+		if (sched_feat(DELAY_ZERO) && se->vlag > 0)
+			se->vlag = 0;
+
+		return NULL;
+	}
+	return se;
 }
```

`set_next_entity` 與 `pick_next_entity` 做了稍許調整，包含幾個 `SCHED_WARN_ON()` 可以在早期去幫助發現 delay dequeue 實作上的缺漏。

另外就是在 `pick_eevdf()` 如果最終選到的是被 delay dequeue 的任務，則表示該任務已 eligible，因此可以正式被 dequeue。具體是在 `dequeue_entities` 加上額外的 `DEQUEUE_DELAYED`，則 `dequeue_entities` 會將此 flag 傳遞給 `dequeue_entity()`，即完成前面提到的 dequeue 的後半流程。

這邊還可以看到引入一個新的 feature `DELAY_ZERO`。前面有提到 delay dequeue 理想的完成點是 se 之 lag 為 0 時。真實場景上實作此有困難，但我們可以選擇此 feature 以直接將 lag 重設回 0

```diff
 static bool check_cfs_rq_runtime(struct cfs_rq *cfs_rq);
@@ -5493,6 +5530,7 @@ static void put_prev_entity(struct cfs_r
 		/* in !on_rq case, update occurred at dequeue */
 		update_load_avg(cfs_rq, prev, 0);
 	}
+	SCHED_WARN_ON(cfs_rq->curr != prev);
 	cfs_rq->curr = NULL;
 }
 
@@ -5793,6 +5831,10 @@ static bool throttle_cfs_rq(struct cfs_r
 		if (!se->on_rq)
 			goto done;
 
+		/*
+		 * XXX should be fine vs sched_delay; if won't run after this.
+		 * Either pick dequeues it, or unthrottle. Double check!!
+		 */
 		dequeue_entity(qcfs_rq, se, DEQUEUE_SLEEP);
 
 		if (cfs_rq_is_idle(group_cfs_rq(se)))
@@ -5882,8 +5924,11 @@ void unthrottle_cfs_rq(struct cfs_rq *cf
 	for_each_sched_entity(se) {
 		struct cfs_rq *qcfs_rq = cfs_rq_of(se);
 
-		if (se->on_rq)
+		if (se->on_rq) {
+			if (se->sched_delayed)
+				requeue_delayed_entity(se);
 			break;
+		}
 		enqueue_entity(qcfs_rq, se, ENQUEUE_WAKEUP);
 
 		if (cfs_rq_is_idle(group_cfs_rq(se)))
@@ -6729,6 +6774,40 @@ static int sched_idle_cpu(int cpu)
 }
 #endif
```

delay dequeue 可能影響的還有 `throttle_cfs_rq` 與 `unthrottle_cfs_rq`。在 throttle 方面可能是沒有影響的，因為對應任務即便被選中也就是完成後半步驟的 dequeue，不會有意外沒被 throttle 到的問題。

unthrottle 的情形下，如果 `se` 是 delayed dequeue 的狀態，我們需要重新 enqueue 之。但此時 `se` 雖仍在 queue 上，但邏輯上已經不在排隊。因此與一般的 se 處理方式不同，要藉由下面的 `requeue_delayed_entity` 來進行 enqueue。

```cpp
static void
requeue_delayed_entity(struct sched_entity *se)
{
	struct cfs_rq *cfs_rq = cfs_rq_of(se);

	/*
	 * se->sched_delayed should imply both: se->on_rq == 1 and
	 * cfs_rq->curr != se. Because a delayed entity is one that is still on
	 * the runqueue competing until elegibility.
	 *
	 * Except for groups, consider current going idle and newidle pulling a
	 * task in the same group -- in that case 'cfs_rq->curr == se'.
	 */
	SCHED_WARN_ON(!se->sched_delayed);
	SCHED_WARN_ON(!se->on_rq);
	SCHED_WARN_ON(entity_is_task(se) && cfs_rq->curr == se);

	if (sched_feat(DELAY_ZERO)) {
		update_entity_lag(cfs_rq, se);
		if (se->vlag > 0) {
			cfs_rq->nr_running--;
			if (se != cfs_rq->curr)
				__dequeue_entity(cfs_rq, se);
			se->vlag = 0;
			place_entity(cfs_rq, se, 0);
			if (se != cfs_rq->curr)
				__enqueue_entity(cfs_rq, se);
			cfs_rq->nr_running++;
		}
	}

	se->sched_delayed = 0;
}
```

`requeue_delayed_entity` 的作用是將邏輯上已被 dequeue，但因為 delay `se` 仍存在 queue 的任務進行 enqueue。

沒有使用 `DELAY_ZERO` 的情況下，`requeue_delayed_entity` 唯一需做的事是將 `sched_delayed` 重置成 0。由於 `se` 本來就還存在 queue 中，因此只是從 delayed dequeue 變成正常等待 CPU 資源的狀態。

使用 `DELAY_ZERO` 的情況比較複雜。因為我們想選擇讓 `se` 在邏輯的 dequeue 時 vlag 歸零而非繼承到下次 enqueue，需要真正將 `se` 從排程的紅黑樹上移除，vlag 重設為 0 後再重新插入到合適的位置上。


```diff
 /*
  * The enqueue_task method is called before nr_running is
  * increased. Here we update the fair scheduling stats and
@@ -6742,6 +6821,11 @@ enqueue_task_fair(struct rq *rq, struct
 	int idle_h_nr_running = task_has_idle_policy(p);
 	int task_new = !(flags & ENQUEUE_WAKEUP);
 
+	if (flags & ENQUEUE_DELAYED) {
+		requeue_delayed_entity(se);
+		return;
+	}
+
```

使用 `ENQUEUE_DELAYED` flag 進行 enqueue_task 代表已知要 enqueue 的是一個被 delayed dequeue 的任務。此時就通過前面介紹的 `requeue_delayed_entity` 完成即可。

```diff
 	/*
 	 * The code below (indirectly) updates schedutil which looks at
 	 * the cfs_rq utilization to select a frequency.
@@ -6759,8 +6843,11 @@ enqueue_task_fair(struct rq *rq, struct
 		cpufreq_update_util(rq, SCHED_CPUFREQ_IOWAIT);
 
 	for_each_sched_entity(se) {
-		if (se->on_rq)
+		if (se->on_rq) {
+			if (se->sched_delayed)
+				requeue_delayed_entity(se);
 			break;
+		}
 		cfs_rq = cfs_rq_of(se);
 		enqueue_entity(cfs_rq, se, flags);
```

一般的 enqueue 則可藉 `se->sched_delayed` 判斷 enqueue 該採用何種方式進行。

```diff
@@ -6836,6 +6923,7 @@ static int dequeue_entities(struct rq *r
 {
 	bool was_sched_idle = sched_idle_rq(rq);
 	bool task_sleep = flags & DEQUEUE_SLEEP;
+	bool task_delayed = flags & DEQUEUE_DELAYED;
 	struct task_struct *p = NULL;
 	struct cfs_rq *cfs_rq;
 	int idle_h_nr_running;
@@ -6849,7 +6937,13 @@ static int dequeue_entities(struct rq *r
 
 	for_each_sched_entity(se) {
 		cfs_rq = cfs_rq_of(se);
-		dequeue_entity(cfs_rq, se, flags);
+
+		if (!dequeue_entity(cfs_rq, se, flags)) {
+			if (p && &p->se == se)
+				return -1;
+
+			break;
+		}
```

在 `dequeue_entities` 中，如果 `dequeue_entity()` 回傳 false，代表本次 dequeue 需以 delay 方式處理。在 se 為對應到 task 之狀況下(`if (p && &p->se == se)`)，直接回傳 -1 表示 dequeue delayed。如果 se 對應到 task_group，則仍需要在下一個 `for_each_sched_entity()` 更新往上層級的 se 之 load 相關數據。

:::warning
不確定這裡的思考為何，在第二個 `for_each_sched_entity()` 我們可以看到留下 `// XXX avoid these load updates for delayed dequeues ?` 這段註解
:::

```diff
 		/* h_nr_running is the hierachical count of tasks */
 		if (p) {
@@ -6877,6 +6971,7 @@ static int dequeue_entities(struct rq *r
 			break;
 		}
 		flags |= DEQUEUE_SLEEP;
+		flags &= ~DEQUEUE_DELAYED;
 	}
```

`DEQUEUE_DELAYED` 應只處理於多層 cfs_rq 的第一階段，因此這裡將對應 flag 給清除。


```diff
 	for_each_sched_entity(se) {
@@ -6906,6 +7001,18 @@ static int dequeue_entities(struct rq *r
 		/* balance early to pull high priority tasks */
 		if (unlikely(!was_sched_idle && sched_idle_rq(rq)))
 			rq->next_balance = jiffies;
+
+		if (task_delayed) {
+			SCHED_WARN_ON(!task_sleep);
+			SCHED_WARN_ON(p->on_rq != 1);
+
+			/* Fix-up what dequeue_task_fair() skipped */
+			util_est_update(&rq->cfs, p, task_sleep);
+			hrtick_update(rq);
+
+			/* Fix-up what deactivate_task() skipped. */
+			WRITE_ONCE(p->on_rq, 0);
+		}
 	}
 
 	return 1;
```

```diff
@@ -6923,6 +7030,10 @@ static bool dequeue_task_fair(struct rq
 	if (dequeue_entities(rq, &p->se, flags) < 0)
 		return false;
 
+	/*
+	 * It doesn't make sense to update util_est for the delayed dequeue
+	 * case where ttwu will make it appear the sleep never happened.
+	 */
 	util_est_update(&rq->cfs, p, flags & DEQUEUE_SLEEP);
 	hrtick_update(rq);
 	return true;
```

:::danger
這部分不太確定QAQ
:::

```diff
@@ -8463,7 +8574,9 @@ static struct task_struct *pick_task_fai
 		if (unlikely(check_cfs_rq_runtime(cfs_rq)))
 			goto again;
 
-		se = pick_next_entity(cfs_rq);
+		se = pick_next_entity(rq, cfs_rq);
+		if (!se)
+			goto again;
 		cfs_rq = group_cfs_rq(se);
 	} while (cfs_rq);
```

由於 delayed dequeue 的存在，pick() 可能會出現挑到被 delay 的 se 的情況，此時就嘗試再挑下一個。

```diff
@@ -12803,10 +12916,17 @@ static void attach_task_cfs_rq(struct ta
 static void switched_from_fair(struct rq *rq, struct task_struct *p)
 {
 	detach_task_cfs_rq(p);
+	// XXX think harder on this
+	// this could actually be handled correctly I suppose; keep the whole
+	// se enqueued while boosted. horrible complexity though
+	p->se.sched_delayed = 0;
+	// XXX also vlag ?!?
 }
 
 static void switched_to_fair(struct rq *rq, struct task_struct *p)
 {
+	SCHED_WARN_ON(p->se.sched_delayed);
+
 	attach_task_cfs_rq(p);
 
 	set_task_max_allowed_capacity(p);
```

```diff
--- a/kernel/sched/features.h
+++ b/kernel/sched/features.h
@@ -29,6 +29,18 @@ SCHED_FEAT(NEXT_BUDDY, false)
 SCHED_FEAT(CACHE_HOT_BUDDY, true)

 /*
+ * Delay dequeueing tasks until they get selected or woken.
+ *
+ * By delaying the dequeue for non-eligible tasks, they remain in the
+ * competition and can burn off their negative lag. When they get selected
+ * they'll have positive lag by definition.
+ *
+ * DELAY_ZERO clips the lag on dequeue (or wakeup) to 0.
+ */
+SCHED_FEAT(DELAY_DEQUEUE, true)
+SCHED_FEAT(DELAY_ZERO, true)
+
+/*
```

前面引進的改動，目前是以 `DELAY_DEQUEUE` 和 `DELAY_ZERO` feature 留下選擇的空間，未直接成為固定行為。

```diff
--- a/kernel/sched/sched.h
+++ b/kernel/sched/sched.h
@@ -2245,6 +2245,7 @@ extern const u32		sched_prio_to_wmult[40
 #define DEQUEUE_MOVE		0x04 /* Matches ENQUEUE_MOVE */
 #define DEQUEUE_NOCLOCK		0x08 /* Matches ENQUEUE_NOCLOCK */
 #define DEQUEUE_MIGRATING	0x100 /* Matches ENQUEUE_MIGRATING */
+#define DEQUEUE_DELAYED		0x200 /* Matches ENQUEUE_DELAYED */
 
 #define ENQUEUE_WAKEUP		0x01
 #define ENQUEUE_RESTORE		0x02
@@ -2260,6 +2261,7 @@ extern const u32		sched_prio_to_wmult[40
 #endif
 #define ENQUEUE_INITIAL		0x80
 #define ENQUEUE_MIGRATING	0x100
+#define ENQUEUE_DELAYED		0x200
 
 #define RETRY_TASK		((void *)-1UL)
```

根據前述改動定義的兩個新的 enqueue/dequeue flag。

### [RFC][PATCH 09/10] sched/eevdf: Allow shorter slices to wakeup-preempt

```diff
--- a/kernel/sched/features.h
+++ b/kernel/sched/features.h
@@ -14,6 +14,10 @@ SCHED_FEAT(PLACE_DEADLINE_INITIAL, true)
  * 0-lag point or until is has exhausted it's slice.
  */
 SCHED_FEAT(RUN_TO_PARITY, true)
+/*
+ * Allow tasks with a shorter slice to disregard RUN_TO_PARITY
+ */
+SCHED_FEAT(PREEMPT_SHORT, true)
 
```

此改動新增一個新的 scheduler feature `PREEMPT_SHORT`。

```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -8538,9 +8538,14 @@ static void check_preempt_wakeup_fair(st
 	cfs_rq = cfs_rq_of(se);
 	update_curr(cfs_rq);
 
-	/*
-	 * XXX pick_eevdf(cfs_rq) != se ?
-	 */
+	if (sched_feat(PREEMPT_SHORT) && pse->slice < se->slice &&
+	    entity_eligible(cfs_rq, pse) &&
+	    (s64)(pse->deadline - se->deadline) < 0 &&
+	    se->vlag == se->deadline) {
+		/* negate RUN_TO_PARITY */
+		se->vlag = se->deadline - 1;
+	}
+
 	if (pick_eevdf(cfs_rq) == pse)
 		goto preempt;
```

回顧之前在 [PATCH 2/4 sched/eevdf: Sort the rbtree by virtual deadline](https://hackmd.io/1wvEMFFVQ5ui4iPd5fPfIg?view#PATCH-24-schedeevdf-Sort-the-rbtree-by-virtual-deadline) 談到 `RUN_TO_PARITY` 的功能。當 `se->vlag == se->deadline` 成立於一個 `se->on_rq == true` 的 se 時，就表示該 se 在獲得排程之後，尚未執行足一個 time slice。在開啟 `RUN_TO_PARITY` 的狀況下，`pick_eevdf()` 會繼續選擇該任務，即便被喚醒(woken up) 的任務之 deadline 更短，以確保其不被搶佔。

:::warning
原文稱之為 "Run the entity to parity"，但不確定中文上該怎麼翻譯 parity 一詞較為恰當。
:::

為了在這系列 patch 引入每個任務可以有不同 time slice/request size 的機制，`PREEMPT_SHORT` 在 `RUN_TO_PARITY` 的基礎之上，對上述可以 "run to parity" 的 se 附加額外條件: 只有在該 se 的 time slice 不比原本預期會搶佔的任務長時，才可以 "run to parity"。

畢竟，在 EEVDF 中，被分配較短 time slice/request size 的任務被預期的特性是更高的反應力(responsiveness)，如果因為 `RUN_TO_PARITY` 而失去此特性，可能並非樂見的排程方式。

在 https://lore.kernel.org/lkml/20240405110010.788110341@infradead.org/ 可以看到支持此改動必要的實驗數據。

### [RFC][PATCH 10/10] sched/eevdf: Use sched_attr::sched_runtime to set request/slice suggestion

在引入 slice/request size 的機制後，這個 patch 允許使用者可以通過 [sched_setattr()](https://man7.org/linux/man-pages/man2/sched_setattr.2.html) 來設置之。這裡需要注意的是: `sched_runtime` 並不是 EEVDF 新增的 attribute。只不過這個參數原本主要是設計給 `SCHED_DEADLINE`，而現在則為 `SCHED_FAIR` 的 EEVDF 所借用。

:::info
[`sched_runtime`](https://elixir.bootlin.com/linux/v6.10.5/source/include/uapi/linux/sched/types.h#L111) 在註解上或許可以稍做調整，避免誤解。
:::

```diff
--- a/include/linux/sched.h
+++ b/include/linux/sched.h
@@ -542,7 +542,10 @@ struct sched_entity {
 
 	struct list_head		group_node;
 	unsigned int			on_rq;
-	unsigned int			sched_delayed;
+
+	unsigned char			sched_delayed;
+	unsigned char			custom_slice;
+					/* 2 byte hole */
 
 	u64				exec_start;
 	u64				sum_exec_runtime;
```

引入 sched_entity 的新成員 `custom_slice`，這是一個 0 或 1 的變數，代表使用者是否設置了客製化的 slice。

此外，`sched_delayed` 我們之前已經提到過，由於這也是一個 0 或 1 的變數，這裡型別可以從 `int` 改為 `char`。則加入 `custom_slice` 後對 struct 整體的大小可以保持不變。


```diff
@@ -4550,7 +4550,6 @@ static void __sched_fork(unsigned long c
 	p->se.nr_migrations		= 0;
 	p->se.vruntime			= 0;
 	p->se.vlag			= 0;
-	p->se.slice			= sysctl_sched_base_slice;
 	INIT_LIST_HEAD(&p->se.group_node);
```

`__sched_fork` 中排除了對 slice 的直接初始化。取而代之的，被 fork 的新 se 可能繼承客製定義的 slice/`sched_runtime`，或者因為 `sched_reset_on_fork` 才重新初始化(見後文)。

```diff
int sched_fork(unsigned long clone_flags, struct task_struct *p)
{
	__sched_fork(clone_flags, p);
	
	...
	
	/*
	 * Revert to default priority/policy on fork if requested.
	 */
	if (unlikely(p->sched_reset_on_fork)) {
		...
 		p->prio = p->normal_prio = p->static_prio;
 		set_load_weight(p, false);
+		p->se.custom_slice = 0;
+		p->se.slice = sysctl_sched_base_slice;
```

這裡調整 fork 時對 slice 的初始化方式，如果 `sched_reset_on_fork` 為 true，這代表 fork 之後的新任務會和 parent 的一些特徵脫鉤，因此包含新增的 custom_slice 和 slice 的都需要重新初始化為預設值。

```diff
@@ -7627,10 +7628,20 @@ static void __setscheduler_params(struct
 
 	p->policy = policy;
 
-	if (dl_policy(policy))
+	if (dl_policy(policy)) {
 		__setparam_dl(p, attr);
-	else if (fair_policy(policy))
+	} else if (fair_policy(policy)) {
 		p->static_prio = NICE_TO_PRIO(attr->sched_nice);
+		if (attr->sched_runtime) {
+			p->se.custom_slice = 1;
+			p->se.slice = clamp_t(u64, attr->sched_runtime,
+					      NSEC_PER_MSEC/10,   /* HZ=1000 * 10 */
+					      NSEC_PER_MSEC*100); /* HZ=100  / 10 */
+		} else {
+			p->se.custom_slice = 0;
+			p->se.slice = sysctl_sched_base_slice;
+		}
+	}
 
```

在 `__setscheduler_params()` 時考慮 `sched_runtime`:
* 如果未設置該 attribute，就使用預設的  `sysctl_sched_base_slice`(0.75 ms, 但可藉 debugfs 調整)
* 否則使用 `sched_runtime` 給定的。留意到實際值會根據給定值 clamp 到 0.1ms 至 100ms 之間

:::danger
選定這個範圍的理由是甚麼?
:::

```diff
@@ -7812,7 +7823,9 @@ static int __sched_setscheduler(struct t
 	 * but store a possible modification of reset_on_fork.
 	 */
 	if (unlikely(policy == p->policy)) {
-		if (fair_policy(policy) && attr->sched_nice != task_nice(p))
+		if (fair_policy(policy) &&
+		    (attr->sched_nice != task_nice(p) ||
+		     (attr->sched_runtime && attr->sched_runtime != p->se.slice)))
 			goto change;
 		if (rt_policy(policy) && attr->sched_priority != p->rt_priority)
 			goto change;
@@ -7958,6 +7971,9 @@ static int _sched_setscheduler(struct ta
 		.sched_nice	= PRIO_TO_NICE(p->static_prio),
 	};
 
+	if (p->se.custom_slice)
+		attr.sched_runtime = p->se.slice;
+
 	/* Fixup the legacy SCHED_RESET_ON_FORK hack. */
 	if ((policy != SETPARAM_POLICY) && (policy & SCHED_RESET_ON_FORK)) {
 		attr.sched_flags |= SCHED_FLAG_RESET_ON_FORK;
```

```diff
@@ -8124,12 +8140,14 @@ static int sched_copy_attr(struct sched_
 
 static void get_params(struct task_struct *p, struct sched_attr *attr)
 {
-	if (task_has_dl_policy(p))
+	if (task_has_dl_policy(p)) {
 		__getparam_dl(p, attr);
-	else if (task_has_rt_policy(p))
+	} else if (task_has_rt_policy(p)) {
 		attr->sched_priority = p->rt_priority;
-	else
+	} else {
 		attr->sched_nice = task_nice(p);
+		attr->sched_runtime = p->se.slice;
+	}
 }
```

`__sched_setscheduler()`/`get_params()` 對應 `sched_runtime` 的改動。

```diff
 /**
@@ -10084,6 +10102,7 @@ void __init sched_init(void)
 	}
 
 	set_load_weight(&init_task, false);
+	init_task.se.slice = sysctl_sched_base_slice,
```

這是對應前面 `__sched_fork()` 捨棄了對 slice 的初始化。因此對於沒有 parent 的 `init_task` 而言，需要另行設置。

```diff
--- a/kernel/sched/debug.c
+++ b/kernel/sched/debug.c
@@ -579,11 +579,12 @@ print_task(struct seq_file *m, struct rq
 	else
 		SEQ_printf(m, " %c", task_state_to_char(p));
 
-	SEQ_printf(m, "%15s %5d %9Ld.%06ld %c %9Ld.%06ld %9Ld.%06ld %9Ld.%06ld %9Ld %5d ",
+	SEQ_printf(m, "%15s %5d %9Ld.%06ld %c %9Ld.%06ld %c %9Ld.%06ld %9Ld.%06ld %9Ld %5d ",
 		p->comm, task_pid_nr(p),
 		SPLIT_NS(p->se.vruntime),
 		entity_eligible(cfs_rq_of(&p->se), &p->se) ? 'E' : 'N',
 		SPLIT_NS(p->se.deadline),
+		p->se.custom_slice ? 'S' : ' ',
 		SPLIT_NS(p->se.slice),
 		SPLIT_NS(p->se.sum_exec_runtime),
 		(long long)(p->nvcsw + p->nivcsw),
```

在 sched 的 debugfs 資訊中，顯示是否啟用 `custom_slice`(`'S'`)或否(`' '`)。


```diff
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -984,7 +984,8 @@ static void update_deadline(struct cfs_r
 	 * nice) while the request time r_i is determined by
 	 * sysctl_sched_base_slice.
 	 */
-	se->slice = sysctl_sched_base_slice;
+	if (!se->custom_slice)
+		se->slice = sysctl_sched_base_slice;
 
 	/*
 	 * EEVDF: vd_i = ve_i + r_i / w_i
@@ -5169,7 +5170,8 @@ place_entity(struct cfs_rq *cfs_rq, stru
 	u64 vslice, vruntime = avg_vruntime(cfs_rq);
 	s64 lag = 0;
 
-	se->slice = sysctl_sched_base_slice;
+	if (!se->custom_slice)
+		se->slice = sysctl_sched_base_slice;
 	vslice = calc_delta_fair(se->slice, se);
 
 	/*
```

則在不使用 `custom_slice` 的情況下，任務的 request size/time slice 就以預設的  `sysctl_sched_base_slice` 來設定。

## Reference

* [[RFC][PATCH 00/10] sched/fair: Complete EEVDF](https://lore.kernel.org/lkml/20240405102754.435410987@infradead.org/?fbclid=IwAR22R73s3oT78BcbvQjjgKLJJPUqjS2YRsESUY3f67CmTsZPj6EXCV-Omzs)