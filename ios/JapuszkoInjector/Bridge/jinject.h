// C interface of the Rust core (core/src/ffi.rs). All payloads are JSON.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef void (*jinject_event_cb)(void *ctx, const char *json);

/// 0 = ok, 1 = already initialised, -1 = failed.
int32_t jinject_init(const char *root, jinject_event_cb cb, void *ctx);
/// Starts an async op, returns its id. Result arrives as a done/failed event.
uint64_t jinject_call(const char *request_json);
/// Quick local op. Returns {"ok":...} or {"error":"..."}; free with jinject_free.
char *jinject_call_sync(const char *request_json);
bool jinject_respond(uint64_t prompt, const char *answer_json);
void jinject_cancel_prompts(void);
void jinject_free(char *s);
