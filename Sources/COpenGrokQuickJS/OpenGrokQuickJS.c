#include "OpenGrokQuickJS.h"

#include "quickjs.h"

#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

typedef struct OGQHostBinding {
    OGQHostCallback callback;
    int callback_id;
} OGQHostBinding;

struct OGQRuntime {
    JSRuntime *runtime;
    atomic_bool interrupted;
    atomic_uint_fast64_t deadline_ms;
};

struct OGQContext {
    OGQRuntime *owner;
    JSContext *context;
    void *opaque;
    OGQHostBinding *bindings;
    size_t binding_count;
    size_t binding_capacity;
};

struct OGQValue {
    JSValue value;
    bool borrowed;
};

static uint64_t ogq_monotonic_milliseconds(void)
{
#if defined(_WIN32)
    return (uint64_t)GetTickCount64();
#else
    struct timespec instant;
    if (clock_gettime(CLOCK_MONOTONIC, &instant) != 0) {
        return 0;
    }

    return (uint64_t)instant.tv_sec * UINT64_C(1000) +
           (uint64_t)instant.tv_nsec / UINT64_C(1000000);
#endif
}

static int ogq_interrupt_handler(JSRuntime *runtime, void *opaque)
{
    (void)runtime;

    OGQRuntime *owner = opaque;
    if (atomic_load_explicit(&owner->interrupted, memory_order_acquire)) {
        return 1;
    }

    uint64_t deadline = atomic_load_explicit(&owner->deadline_ms,
                                              memory_order_relaxed);
    if (deadline != 0 && ogq_monotonic_milliseconds() >= deadline) {
        atomic_store_explicit(&owner->interrupted, true, memory_order_release);
        return 1;
    }

    return 0;
}

static JSModuleDef *ogq_reject_module(JSContext *context,
                                      const char *module_name,
                                      void *opaque)
{
    (void)opaque;
    JS_ThrowReferenceError(context,
                           "Unsupported import in exec: %s",
                           module_name == NULL ? "<unknown>" : module_name);
    return NULL;
}

static OGQValue *ogq_box(JSContext *context, JSValue value)
{
    OGQValue *boxed = malloc(sizeof(*boxed));
    if (boxed == NULL) {
        if (!JS_IsException(value)) {
            JS_FreeValue(context, value);
        }
        JS_ThrowOutOfMemory(context);
        return NULL;
    }

    boxed->value = value;
    boxed->borrowed = false;
    return boxed;
}

static JSValue ogq_unbox_result(JSContext *context, OGQValue *result)
{
    if (result == NULL) {
        return JS_HasException(context) ? JS_EXCEPTION : JS_UNDEFINED;
    }

    if (result->borrowed) {
        return JS_DupValue(context, result->value);
    }

    JSValue value = result->value;
    free(result);
    return value;
}

static JSValue ogq_dispatch_host_callback(JSContext *raw_context,
                                          JSValueConst this_value,
                                          int argument_count,
                                          JSValueConst *arguments,
                                          int magic,
                                          JSValueConst *function_data)
{
    (void)magic;

    OGQContext *context = JS_GetContextOpaque(raw_context);
    if (context == NULL) {
        return JS_ThrowInternalError(raw_context,
                                     "JavaScript host context is unavailable");
    }

    int32_t binding_index = 0;
    if (JS_ToInt32(raw_context, &binding_index, function_data[0]) < 0 ||
        binding_index < 0 ||
        (size_t)binding_index >= context->binding_count) {
        return JS_ThrowInternalError(raw_context,
                                     "JavaScript host callback is unavailable");
    }

    if (argument_count < 0 || argument_count > 65536) {
        return JS_ThrowRangeError(raw_context,
                                  "JavaScript host callback has too many arguments");
    }

    OGQValue *borrowed_values = NULL;
    OGQValue **borrowed_arguments = NULL;
    if (argument_count > 0) {
        size_t count = (size_t)argument_count;
        borrowed_values = calloc(count, sizeof(*borrowed_values));
        borrowed_arguments = calloc(count, sizeof(*borrowed_arguments));
        if (borrowed_values == NULL || borrowed_arguments == NULL) {
            free(borrowed_values);
            free(borrowed_arguments);
            return JS_ThrowOutOfMemory(raw_context);
        }

        for (int index = 0; index < argument_count; index++) {
            borrowed_values[index].value = arguments[index];
            borrowed_values[index].borrowed = true;
            borrowed_arguments[index] = &borrowed_values[index];
        }
    }

    OGQValue borrowed_this = {
        .value = this_value,
        .borrowed = true,
    };
    OGQHostBinding binding = context->bindings[binding_index];
    OGQValue *result = binding.callback(context,
                                        context->opaque,
                                        binding.callback_id,
                                        argument_count,
                                        borrowed_arguments,
                                        &borrowed_this);
    JSValue unboxed = ogq_unbox_result(raw_context, result);
    free(borrowed_arguments);
    free(borrowed_values);
    return unboxed;
}

OGQRuntime *ogq_runtime_new(void)
{
    OGQRuntime *runtime = calloc(1, sizeof(*runtime));
    if (runtime == NULL) {
        return NULL;
    }

    runtime->runtime = JS_NewRuntime();
    if (runtime->runtime == NULL) {
        free(runtime);
        return NULL;
    }

    atomic_init(&runtime->interrupted, false);
    atomic_init(&runtime->deadline_ms, 0);
    JS_SetRuntimeOpaque(runtime->runtime, runtime);
    JS_SetInterruptHandler(runtime->runtime, ogq_interrupt_handler, runtime);
    JS_SetModuleLoaderFunc(runtime->runtime, NULL, ogq_reject_module, runtime);
    JS_SetCanBlock(runtime->runtime, false);
    return runtime;
}

void ogq_runtime_free(OGQRuntime *runtime)
{
    if (runtime == NULL) {
        return;
    }

    JS_SetInterruptHandler(runtime->runtime, NULL, NULL);
    JS_SetRuntimeOpaque(runtime->runtime, NULL);
    JS_FreeRuntime(runtime->runtime);
    free(runtime);
}

void ogq_runtime_set_memory_limit(OGQRuntime *runtime, size_t limit_bytes)
{
    if (runtime != NULL) {
        JS_SetMemoryLimit(runtime->runtime, limit_bytes);
    }
}

void ogq_runtime_set_stack_limit(OGQRuntime *runtime, size_t limit_bytes)
{
    if (runtime != NULL) {
        JS_SetMaxStackSize(runtime->runtime, limit_bytes);
    }
}

void ogq_runtime_interrupt(OGQRuntime *runtime)
{
    if (runtime != NULL) {
        atomic_store_explicit(&runtime->interrupted,
                              true,
                              memory_order_release);
    }
}

void ogq_runtime_clear_interrupt(OGQRuntime *runtime)
{
    if (runtime != NULL) {
        atomic_store_explicit(&runtime->deadline_ms, 0, memory_order_relaxed);
        atomic_store_explicit(&runtime->interrupted,
                              false,
                              memory_order_release);
    }
}

void ogq_runtime_set_deadline_ms(OGQRuntime *runtime, uint64_t duration_ms)
{
    if (runtime == NULL) {
        return;
    }

    if (duration_ms == 0) {
        atomic_store_explicit(&runtime->deadline_ms, 0, memory_order_relaxed);
        return;
    }

    uint64_t now = ogq_monotonic_milliseconds();
    uint64_t deadline = duration_ms > UINT64_MAX - now
                            ? UINT64_MAX
                            : now + duration_ms;
    atomic_store_explicit(&runtime->deadline_ms,
                          deadline,
                          memory_order_relaxed);
}

bool ogq_runtime_was_interrupted(const OGQRuntime *runtime)
{
    return runtime != NULL &&
           atomic_load_explicit(&runtime->interrupted, memory_order_acquire);
}

bool ogq_runtime_job_pending(OGQRuntime *runtime)
{
    return runtime != NULL && JS_IsJobPending(runtime->runtime);
}

int ogq_execute_pending_job(OGQRuntime *runtime)
{
    if (runtime == NULL) {
        return -1;
    }

    JSContext *job_context = NULL;
    return JS_ExecutePendingJob(runtime->runtime, &job_context);
}

OGQContext *ogq_context_new(OGQRuntime *runtime)
{
    if (runtime == NULL) {
        return NULL;
    }

    OGQContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }

    context->owner = runtime;
    context->context = JS_NewContext(runtime->runtime);
    if (context->context == NULL) {
        free(context);
        return NULL;
    }

    JS_SetContextOpaque(context->context, context);

    static const char *const blocked_globals[] = {
        "console",
        "Atomics",
        "SharedArrayBuffer",
        "WebAssembly",
    };
    for (size_t index = 0;
         index < sizeof(blocked_globals) / sizeof(blocked_globals[0]);
         index++) {
        if (ogq_delete_global(context, blocked_globals[index]) < 0) {
            ogq_context_free(context);
            return NULL;
        }
    }

    return context;
}

void ogq_context_free(OGQContext *context)
{
    if (context == NULL) {
        return;
    }

    JS_SetContextOpaque(context->context, NULL);
    JS_FreeContext(context->context);
    free(context->bindings);
    free(context);
}

void ogq_set_opaque(OGQContext *context, void *opaque)
{
    if (context != NULL) {
        context->opaque = opaque;
    }
}

void *ogq_get_opaque(const OGQContext *context)
{
    return context == NULL ? NULL : context->opaque;
}

OGQValue *ogq_eval(OGQContext *context,
                   const char *source,
                   size_t source_length,
                   const char *filename,
                   unsigned int flags)
{
    if (context == NULL || source == NULL) {
        return NULL;
    }

    int eval_flags = (flags & OGQ_EVAL_MODULE) != 0
                         ? JS_EVAL_TYPE_MODULE
                         : JS_EVAL_TYPE_GLOBAL;
    if ((flags & OGQ_EVAL_ASYNC) != 0 &&
        (flags & OGQ_EVAL_MODULE) == 0) {
        eval_flags |= JS_EVAL_FLAG_ASYNC;
    }

    return ogq_box(context->context,
                   JS_Eval(context->context,
                           source,
                           source_length,
                           filename == NULL ? "<code-mode>" : filename,
                           eval_flags));
}

OGQValue *ogq_get_global(OGQContext *context)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context, JS_GetGlobalObject(context->context));
}

OGQValue *ogq_new_object(OGQContext *context)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context, JS_NewObject(context->context));
}

OGQValue *ogq_new_array(OGQContext *context)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context, JS_NewArray(context->context));
}

OGQValue *ogq_new_string(OGQContext *context, const char *value)
{
    if (value == NULL) {
        return NULL;
    }

    return ogq_new_string_len(context, value, strlen(value));
}

OGQValue *ogq_new_string_len(OGQContext *context,
                             const char *value,
                             size_t length)
{
    if (context == NULL || value == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_NewStringLen(context->context, value, length));
}

OGQValue *ogq_new_double(OGQContext *context, double value)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context,
                         JS_NewFloat64(context->context, value));
}

OGQValue *ogq_new_int64(OGQContext *context, int64_t value)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context,
                         JS_NewInt64(context->context, value));
}

OGQValue *ogq_new_bool(OGQContext *context, bool value)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context,
                         JS_NewBool(context->context, value));
}

OGQValue *ogq_new_null(OGQContext *context)
{
    return context == NULL ? NULL : ogq_box(context->context, JS_NULL);
}

OGQValue *ogq_new_undefined(OGQContext *context)
{
    return context == NULL ? NULL : ogq_box(context->context, JS_UNDEFINED);
}

OGQValue *ogq_dup(OGQContext *context, const OGQValue *value)
{
    if (context == NULL || value == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_DupValue(context->context, value->value));
}

void ogq_free_value(OGQContext *context, OGQValue *value)
{
    if (context == NULL || value == NULL || value->borrowed) {
        return;
    }

    JS_FreeValue(context->context, value->value);
    free(value);
}

OGQValue *ogq_get_property(OGQContext *context,
                           const OGQValue *object,
                           const char *name)
{
    if (context == NULL || object == NULL || name == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_GetPropertyStr(context->context, object->value, name));
}

OGQValue *ogq_get_index(OGQContext *context,
                        const OGQValue *object,
                        uint32_t index)
{
    if (context == NULL || object == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_GetPropertyUint32(context->context,
                                        object->value,
                                        index));
}

int ogq_set_property(OGQContext *context,
                     const OGQValue *object,
                     const char *name,
                     const OGQValue *value)
{
    if (context == NULL || object == NULL || name == NULL || value == NULL) {
        return -1;
    }

    return JS_SetPropertyStr(context->context,
                             object->value,
                             name,
                             JS_DupValue(context->context, value->value));
}

int ogq_set_index(OGQContext *context,
                  const OGQValue *object,
                  uint32_t index,
                  const OGQValue *value)
{
    if (context == NULL || object == NULL || value == NULL) {
        return -1;
    }

    return JS_SetPropertyUint32(context->context,
                                object->value,
                                index,
                                JS_DupValue(context->context, value->value));
}

int ogq_delete_global(OGQContext *context, const char *name)
{
    if (context == NULL || name == NULL) {
        return -1;
    }

    JSValue global = JS_GetGlobalObject(context->context);
    if (JS_IsException(global)) {
        return -1;
    }

    JSAtom atom = JS_NewAtom(context->context, name);
    if (atom == JS_ATOM_NULL) {
        JS_FreeValue(context->context, global);
        return -1;
    }

    int status = JS_DeleteProperty(context->context,
                                   global,
                                   atom,
                                   JS_PROP_THROW);
    JS_FreeAtom(context->context, atom);
    JS_FreeValue(context->context, global);
    return status;
}

bool ogq_is_null(const OGQValue *value)
{
    return value != NULL && JS_IsNull(value->value);
}

bool ogq_is_undefined(const OGQValue *value)
{
    return value != NULL && JS_IsUndefined(value->value);
}

bool ogq_is_bool(const OGQValue *value)
{
    return value != NULL && JS_IsBool(value->value);
}

bool ogq_is_number(const OGQValue *value)
{
    return value != NULL && JS_IsNumber(value->value);
}

bool ogq_is_string(const OGQValue *value)
{
    return value != NULL && JS_IsString(value->value);
}

bool ogq_is_object(const OGQValue *value)
{
    return value != NULL && JS_IsObject(value->value);
}

bool ogq_is_array(const OGQValue *value)
{
    return value != NULL && JS_IsArray(value->value);
}

bool ogq_is_function(OGQContext *context, const OGQValue *value)
{
    return context != NULL && value != NULL &&
           JS_IsFunction(context->context, value->value);
}

bool ogq_is_promise(const OGQValue *value)
{
    return value != NULL && JS_IsPromise(value->value);
}

bool ogq_is_exception(const OGQValue *value)
{
    return value != NULL && JS_IsException(value->value);
}

int ogq_to_bool(OGQContext *context, const OGQValue *value)
{
    return context == NULL || value == NULL
               ? -1
               : JS_ToBool(context->context, value->value);
}

int ogq_to_double(OGQContext *context,
                  const OGQValue *value,
                  double *result)
{
    return context == NULL || value == NULL || result == NULL
               ? -1
               : JS_ToFloat64(context->context, result, value->value);
}

int ogq_to_int64(OGQContext *context,
                 const OGQValue *value,
                 int64_t *result)
{
    return context == NULL || value == NULL || result == NULL
               ? -1
               : JS_ToInt64(context->context, result, value->value);
}

char *ogq_to_string(OGQContext *context, const OGQValue *value)
{
    return ogq_to_string_len(context, value, NULL);
}

char *ogq_to_string_len(OGQContext *context,
                        const OGQValue *value,
                        size_t *length)
{
    if (context == NULL || value == NULL) {
        return NULL;
    }

    size_t byte_count = 0;
    const char *source = JS_ToCStringLen(context->context,
                                        &byte_count,
                                        value->value);
    if (source == NULL || byte_count == SIZE_MAX) {
        if (source != NULL) {
            JS_FreeCString(context->context, source);
        }
        return NULL;
    }

    char *copy = malloc(byte_count + 1);
    if (copy == NULL) {
        JS_FreeCString(context->context, source);
        JS_ThrowOutOfMemory(context->context);
        return NULL;
    }

    memcpy(copy, source, byte_count);
    copy[byte_count] = '\0';
    JS_FreeCString(context->context, source);
    if (length != NULL) {
        *length = byte_count;
    }
    return copy;
}

void ogq_free_string(char *value)
{
    free(value);
}

OGQValue *ogq_json_parse(OGQContext *context,
                         const char *json,
                         size_t length)
{
    if (context == NULL || json == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_ParseJSON(context->context,
                                json,
                                length,
                                "<code-mode-json>"));
}

OGQValue *ogq_json_stringify(OGQContext *context, const OGQValue *value)
{
    if (context == NULL || value == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_JSONStringify(context->context,
                                    value->value,
                                    JS_UNDEFINED,
                                    JS_UNDEFINED));
}

OGQValue *ogq_call(OGQContext *context,
                   const OGQValue *function,
                   const OGQValue *this_value,
                   int argument_count,
                   OGQValue *const *arguments)
{
    if (context == NULL || function == NULL || argument_count < 0 ||
        (argument_count > 0 && arguments == NULL)) {
        return NULL;
    }

    JSValue *raw_arguments = NULL;
    if (argument_count > 0) {
        size_t count = (size_t)argument_count;
        if (count > SIZE_MAX / sizeof(*raw_arguments)) {
            return ogq_box(context->context,
                           JS_ThrowRangeError(context->context,
                                              "too many JavaScript arguments"));
        }

        raw_arguments = malloc(count * sizeof(*raw_arguments));
        if (raw_arguments == NULL) {
            return ogq_box(context->context,
                           JS_ThrowOutOfMemory(context->context));
        }

        for (int index = 0; index < argument_count; index++) {
            raw_arguments[index] = arguments[index] == NULL
                                       ? JS_UNDEFINED
                                       : arguments[index]->value;
        }
    }

    JSValue result = JS_Call(context->context,
                             function->value,
                             this_value == NULL
                                 ? JS_UNDEFINED
                                 : this_value->value,
                             argument_count,
                             raw_arguments);
    free(raw_arguments);
    return ogq_box(context->context, result);
}

OGQValue *ogq_new_function(OGQContext *context,
                           int callback_id,
                           OGQHostCallback callback,
                           int length)
{
    if (context == NULL || callback == NULL ||
        context->binding_count >= (size_t)INT32_MAX) {
        return NULL;
    }

    if (context->binding_count == context->binding_capacity) {
        size_t capacity = context->binding_capacity == 0
                              ? 8
                              : context->binding_capacity * 2;
        if (capacity < context->binding_capacity ||
            capacity > SIZE_MAX / sizeof(*context->bindings)) {
            return ogq_box(context->context,
                           JS_ThrowOutOfMemory(context->context));
        }

        OGQHostBinding *bindings = realloc(context->bindings,
                                           capacity * sizeof(*bindings));
        if (bindings == NULL) {
            return ogq_box(context->context,
                           JS_ThrowOutOfMemory(context->context));
        }

        context->bindings = bindings;
        context->binding_capacity = capacity;
    }

    int32_t binding_index = (int32_t)context->binding_count;
    context->bindings[context->binding_count] = (OGQHostBinding){
        .callback = callback,
        .callback_id = callback_id,
    };
    context->binding_count++;

    JSValue binding_index_value = JS_NewInt32(context->context, binding_index);
    JSValue function = JS_NewCFunctionData(context->context,
                                           ogq_dispatch_host_callback,
                                           length,
                                           callback_id,
                                           1,
                                           &binding_index_value);
    JS_FreeValue(context->context, binding_index_value);
    return ogq_box(context->context, function);
}

OGQValue *ogq_promise_new(OGQContext *context,
                          OGQValue **resolve,
                          OGQValue **reject)
{
    if (context == NULL || resolve == NULL || reject == NULL) {
        return NULL;
    }

    *resolve = NULL;
    *reject = NULL;
    JSValue functions[2] = {JS_UNDEFINED, JS_UNDEFINED};
    JSValue promise = JS_NewPromiseCapability(context->context, functions);
    if (JS_IsException(promise)) {
        return ogq_box(context->context, promise);
    }

    OGQValue *boxed_promise = ogq_box(context->context, promise);
    if (boxed_promise == NULL) {
        JS_FreeValue(context->context, functions[0]);
        JS_FreeValue(context->context, functions[1]);
        return NULL;
    }

    OGQValue *boxed_resolve = ogq_box(context->context, functions[0]);
    if (boxed_resolve == NULL) {
        JS_FreeValue(context->context, functions[1]);
        ogq_free_value(context, boxed_promise);
        return NULL;
    }

    OGQValue *boxed_reject = ogq_box(context->context, functions[1]);
    if (boxed_reject == NULL) {
        ogq_free_value(context, boxed_resolve);
        ogq_free_value(context, boxed_promise);
        return NULL;
    }

    *resolve = boxed_resolve;
    *reject = boxed_reject;
    return boxed_promise;
}

int ogq_promise_state(OGQContext *context, const OGQValue *promise)
{
    return context == NULL || promise == NULL
               ? OGQ_PROMISE_NOT_A_PROMISE
               : (int)JS_PromiseState(context->context, promise->value);
}

OGQValue *ogq_promise_result(OGQContext *context, const OGQValue *promise)
{
    if (context == NULL || promise == NULL) {
        return NULL;
    }

    return ogq_box(context->context,
                   JS_PromiseResult(context->context, promise->value));
}

bool ogq_has_exception(OGQContext *context)
{
    return context != NULL && JS_HasException(context->context);
}

OGQValue *ogq_take_exception(OGQContext *context)
{
    return context == NULL
               ? NULL
               : ogq_box(context->context, JS_GetException(context->context));
}

OGQValue *ogq_throw_string(OGQContext *context, const char *message)
{
    if (context == NULL || message == NULL) {
        return NULL;
    }

    JSValue error = JS_NewString(context->context, message);
    if (JS_IsException(error)) {
        return ogq_box(context->context, error);
    }

    return ogq_box(context->context, JS_Throw(context->context, error));
}
