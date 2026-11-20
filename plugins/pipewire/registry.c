#include <stdlib.h>
#include <string.h>
#include <pipewire/pipewire.h>

typedef void (*sm_node_added)(void *data, uint32_t id, const struct spa_dict *props);
typedef void (*sm_node_removed)(void *data, uint32_t id);

struct sm_registry {
	struct pw_thread_loop *loop;
	struct pw_core *core;
	struct pw_registry *registry;
	struct spa_hook core_hook;
	struct spa_hook registry_hook;
	sm_node_added added;
	sm_node_removed removed;
	void *data;
	int pending;
	int synced;
	int failed;
};

static void on_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version, const struct spa_dict *props)
{
	struct sm_registry *r = data;
	(void)permissions;
	(void)version;
	if (props == NULL || strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
		return;
	r->added(r->data, id, props);
}

static void on_global_remove(void *data, uint32_t id)
{
	struct sm_registry *r = data;
	r->removed(r->data, id);
}

static const struct pw_registry_events registry_events = {
	PW_VERSION_REGISTRY_EVENTS,
	.global = on_global,
	.global_remove = on_global_remove,
};

static void on_done(void *data, uint32_t id, int seq)
{
	struct sm_registry *r = data;
	if (id == PW_ID_CORE && seq == r->pending) {
		r->synced = 1;
		pw_thread_loop_signal(r->loop, false);
	}
}

static void on_error(void *data, uint32_t id, int seq, int res, const char *message)
{
	struct sm_registry *r = data;
	(void)seq;
	(void)res;
	(void)message;
	if (id == PW_ID_CORE) {
		r->failed = 1;
		pw_thread_loop_signal(r->loop, false);
	}
}

static const struct pw_core_events core_events = {
	PW_VERSION_CORE_EVENTS,
	.done = on_done,
	.error = on_error,
};

struct sm_registry *sm_registry_new(struct pw_thread_loop *loop, struct pw_core *core, sm_node_added added, sm_node_removed removed, void *data)
{
	struct sm_registry *r = calloc(1, sizeof(*r));
	if (r == NULL)
		return NULL;
	r->loop = loop;
	r->core = core;
	r->added = added;
	r->removed = removed;
	r->data = data;
	r->registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
	if (r->registry == NULL) {
		free(r);
		return NULL;
	}
	pw_core_add_listener(core, &r->core_hook, &core_events, r);
	pw_registry_add_listener(r->registry, &r->registry_hook, &registry_events, r);
	return r;
}

int sm_registry_sync(struct sm_registry *r)
{
	r->synced = 0;
	r->pending = pw_core_sync(r->core, PW_ID_CORE, r->pending);
	while (!r->synced && !r->failed)
		pw_thread_loop_wait(r->loop);
	return r->failed ? -1 : 0;
}

void sm_registry_destroy(struct sm_registry *r)
{
	spa_hook_remove(&r->registry_hook);
	spa_hook_remove(&r->core_hook);
	pw_proxy_destroy((struct pw_proxy *)r->registry);
	free(r);
}

const char *sm_dict_lookup(const struct spa_dict *props, const char *key)
{
	return spa_dict_lookup(props, key);
}

uint32_t sm_dict_size(const struct spa_dict *props)
{
	return props->n_items;
}

const char *sm_dict_key(const struct spa_dict *props, uint32_t i)
{
	return props->items[i].key;
}

const char *sm_dict_value(const struct spa_dict *props, uint32_t i)
{
	return props->items[i].value;
}
