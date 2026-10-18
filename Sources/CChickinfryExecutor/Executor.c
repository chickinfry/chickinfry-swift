#include "Executor.h"
#ifdef __wasi__
__attribute__((import_module("chik-swift:1"), import_name("enqueue")))
extern void enqueue(uintptr_t job, double delay);
__attribute__((import_module("chik-swift:1"), import_name("settle")))
extern void settle(int32_t call, int32_t status, const void *bytes, int32_t count);
void chik_enqueue_job(uintptr_t job, double delay) { enqueue(job, delay); }
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count) { settle(call, status, bytes, count); }
#else
void chik_enqueue_job(uintptr_t job, double delay) { (void)job; (void)delay; }
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count) {
    (void)call; (void)status; (void)bytes; (void)count;
}
#endif
