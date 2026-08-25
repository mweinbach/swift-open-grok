#ifndef OPEN_GROK_QUICK_JS_H
#define OPEN_GROK_QUICK_JS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OGQRuntime OGQRuntime;
typedef struct OGQContext OGQContext;
typedef struct OGQValue OGQValue;

typedef OGQValue *(*OGQHostCallback)(OGQContext *context,
                                    void *opaque,
                                    int callback_id,
                                    int argument_count,
                                    OGQValue *const *arguments,
                                    OGQValue *this_value);

enum {
    OGQ_EVAL_GLOBAL = 0,
    OGQ_EVAL_MODULE = 1 << 0,
    OGQ_EVAL_ASYNC = 1 << 1,
};

enum {
    OGQ_PROMISE_NOT_A_PROMISE = -1,
    OGQ_PROMISE_PENDING = 0,
    OGQ_PROMISE_FULFILLED = 1,
    OGQ_PROMISE_REJECTED = 2,
};

OGQRuntime *ogq_runtime_new(void);
void ogq_runtime_free(OGQRuntime *runtime);
void ogq_runtime_set_memory_limit(OGQRuntime *runtime, size_t limit_bytes);
void ogq_runtime_set_stack_limit(OGQRuntime *runtime, size_t limit_bytes);
void ogq_runtime_interrupt(OGQRuntime *runtime);
void ogq_runtime_clear_interrupt(OGQRuntime *runtime);
void ogq_runtime_set_deadline_ms(OGQRuntime *runtime, uint64_t duration_ms);
bool ogq_runtime_was_interrupted(const OGQRuntime *runtime);
bool ogq_runtime_job_pending(OGQRuntime *runtime);
int ogq_execute_pending_job(OGQRuntime *runtime);

OGQContext *ogq_context_new(OGQRuntime *runtime);
void ogq_context_free(OGQContext *context);
void ogq_set_opaque(OGQContext *context, void *opaque);
void *ogq_get_opaque(const OGQContext *context);

OGQValue *ogq_eval(OGQContext *context,
                   const char *source,
                   size_t source_length,
                   const char *filename,
                   unsigned int flags);
OGQValue *ogq_get_global(OGQContext *context);
OGQValue *ogq_new_object(OGQContext *context);
OGQValue *ogq_new_array(OGQContext *context);
OGQValue *ogq_new_string(OGQContext *context, const char *value);
OGQValue *ogq_new_string_len(OGQContext *context,
                             const char *value,
                             size_t length);
OGQValue *ogq_new_double(OGQContext *context, double value);
OGQValue *ogq_new_int64(OGQContext *context, int64_t value);
OGQValue *ogq_new_bool(OGQContext *context, bool value);
OGQValue *ogq_new_null(OGQContext *context);
OGQValue *ogq_new_undefined(OGQContext *context);
OGQValue *ogq_dup(OGQContext *context, const OGQValue *value);
void ogq_free_value(OGQContext *context, OGQValue *value);

OGQValue *ogq_get_property(OGQContext *context,
                           const OGQValue *object,
                           const char *name);
OGQValue *ogq_get_index(OGQContext *context,
                        const OGQValue *object,
                        uint32_t index);
int ogq_set_property(OGQContext *context,
                     const OGQValue *object,
                     const char *name,
                     const OGQValue *value);
int ogq_set_index(OGQContext *context,
                  const OGQValue *object,
                  uint32_t index,
                  const OGQValue *value);
int ogq_delete_global(OGQContext *context, const char *name);

bool ogq_is_null(const OGQValue *value);
bool ogq_is_undefined(const OGQValue *value);
bool ogq_is_bool(const OGQValue *value);
bool ogq_is_number(const OGQValue *value);
bool ogq_is_string(const OGQValue *value);
bool ogq_is_object(const OGQValue *value);
bool ogq_is_array(const OGQValue *value);
bool ogq_is_function(OGQContext *context, const OGQValue *value);
bool ogq_is_promise(const OGQValue *value);
bool ogq_is_exception(const OGQValue *value);
int ogq_to_bool(OGQContext *context, const OGQValue *value);
int ogq_to_double(OGQContext *context,
                  const OGQValue *value,
                  double *result);
int ogq_to_int64(OGQContext *context,
                 const OGQValue *value,
                 int64_t *result);
char *ogq_to_string(OGQContext *context, const OGQValue *value);
char *ogq_to_string_len(OGQContext *context,
                        const OGQValue *value,
                        size_t *length);
void ogq_free_string(char *value);

OGQValue *ogq_json_parse(OGQContext *context,
                         const char *json,
                         size_t length);
OGQValue *ogq_json_stringify(OGQContext *context, const OGQValue *value);
OGQValue *ogq_call(OGQContext *context,
                   const OGQValue *function,
                   const OGQValue *this_value,
                   int argument_count,
                   OGQValue *const *arguments);
OGQValue *ogq_new_function(OGQContext *context,
                           int callback_id,
                           OGQHostCallback callback,
                           int length);

OGQValue *ogq_promise_new(OGQContext *context,
                          OGQValue **resolve,
                          OGQValue **reject);
int ogq_promise_state(OGQContext *context, const OGQValue *promise);
OGQValue *ogq_promise_result(OGQContext *context, const OGQValue *promise);

bool ogq_has_exception(OGQContext *context);
OGQValue *ogq_take_exception(OGQContext *context);
OGQValue *ogq_throw_string(OGQContext *context, const char *message);

#ifdef __cplusplus
}
#endif

#endif
