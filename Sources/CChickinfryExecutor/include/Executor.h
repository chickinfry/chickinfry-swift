#include <stdint.h>
#ifdef __wasi__
int32_t chik_prepare_stdio(void);
#endif
void chik_enqueue_job(uintptr_t job, double delay);
void chik_settle(int32_t call, int32_t status, const void *bytes, int32_t count);
void chik_host_call(int32_t channel, int32_t call, const void *bytes, int32_t count);
