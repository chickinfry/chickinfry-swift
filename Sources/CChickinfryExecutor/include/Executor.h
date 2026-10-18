#include <stdint.h>
void chik_enqueue_job(uintptr_t job, double delay);
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count);
