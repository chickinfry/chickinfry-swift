#include "Executor.h"
#ifdef __wasi__
#include <stdio.h>

int32_t chik_prepare_stdio(void) {
    // libc streams are shared between requests, so leave buffering to the request collector.
    return setvbuf(stdout, NULL, _IONBF, 0) || setvbuf(stderr, NULL, _IONBF, 0);
}
__attribute__((import_module("chik-swift:1"), import_name("enqueue")))
extern void enqueue(uintptr_t job, double delay);
__attribute__((import_module("chik-swift:1"), import_name("settle")))
extern void settle(int32_t call, int32_t status, const void *bytes, int32_t count);
__attribute__((import_module("chik-swift:1"), import_name("host_call")))
extern void host_call(int32_t channel, int32_t call, const void *bytes, int32_t count);
void chik_enqueue_job(uintptr_t job, double delay) { enqueue(job, delay); }
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count) { settle(call, status, bytes, count); }
void chik_host_call(int32_t channel, int32_t call, const void *bytes, int32_t count) { host_call(channel, call, bytes, count); }
#else
void chik_enqueue_job(uintptr_t job, double delay) { (void)job; (void)delay; }
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count) {
    (void)call; (void)status; (void)bytes; (void)count;
}
void chik_host_call(int32_t channel, int32_t call, const void *bytes, int32_t count) {
    (void)channel; (void)call; (void)bytes; (void)count;
}
#endif
