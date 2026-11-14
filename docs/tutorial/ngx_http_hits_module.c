
/*
 * ngx_http_hits_module: per-URI request counters kept in shared memory,
 * with least-recently-used eviction and a plain-text report.
 */


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


#define NGX_HTTP_HITS_MAX_KEY  256


typedef struct {
    ngx_rbtree_node_t            node;      /* node.key: crc32 of the URI */
    ngx_queue_t                  queue;     /* position in the LRU list */
    ngx_uint_t                   count;
    u_short                      len;
    u_char                       data[1];   /* the URI, len bytes */
} ngx_http_hits_node_t;


typedef struct {
    ngx_rbtree_t                 rbtree;
    ngx_rbtree_node_t            sentinel;
    ngx_queue_t                  queue;     /* most recently used first */
} ngx_http_hits_shctx_t;


typedef struct {
    ngx_http_hits_shctx_t       *sh;
    ngx_slab_pool_t             *shpool;
} ngx_http_hits_ctx_t;


typedef struct {
    ngx_shm_zone_t              *zone;      /* "hits": count requests here */
    ngx_shm_zone_t              *status;    /* "hits_status": report a zone */
} ngx_http_hits_loc_conf_t;


typedef struct {
    ngx_uint_t                   count;
    ngx_str_t                    uri;
} ngx_http_hits_entry_t;


static ngx_int_t ngx_http_hits_log_handler(ngx_http_request_t *r);
static ngx_int_t ngx_http_hits_status_handler(ngx_http_request_t *r);
static ngx_http_hits_node_t *ngx_http_hits_lookup(ngx_rbtree_t *rbtree,
    ngx_str_t *key, uint32_t hash);
static void ngx_http_hits_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);
static void ngx_http_hits_evict(ngx_http_hits_ctx_t *ctx);
static int ngx_libc_cdecl ngx_http_hits_cmp(const void *one,
    const void *two);
static ngx_int_t ngx_http_hits_init_zone(ngx_shm_zone_t *shm_zone,
    void *data);
static void *ngx_http_hits_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_hits_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child);
static char *ngx_http_hits_zone(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static char *ngx_http_hits(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_hits_status(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static ngx_int_t ngx_http_hits_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_hits_commands[] = {

    { ngx_string("hits_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE2,
      ngx_http_hits_zone,
      0,
      0,
      NULL },

    { ngx_string("hits"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_hits,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("hits_status"),
      NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_hits_status,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_hits_module_ctx = {
    NULL,                                  /* preconfiguration */
    ngx_http_hits_init,                    /* postconfiguration */

    NULL,                                  /* create main configuration */
    NULL,                                  /* init main configuration */

    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */

    ngx_http_hits_create_loc_conf,         /* create location configuration */
    ngx_http_hits_merge_loc_conf           /* merge location configuration */
};


ngx_module_t  ngx_http_hits_module = {
    NGX_MODULE_V1,
    &ngx_http_hits_module_ctx,             /* module context */
    ngx_http_hits_commands,                /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_int_t
ngx_http_hits_log_handler(ngx_http_request_t *r)
{
    size_t                     n;
    uint32_t                   hash;
    ngx_str_t                  key;
    ngx_http_hits_ctx_t       *ctx;
    ngx_http_hits_node_t      *hn;
    ngx_http_hits_loc_conf_t  *hlcf;

    hlcf = ngx_http_get_module_loc_conf(r, ngx_http_hits_module);

    if (hlcf->zone == NULL) {
        return NGX_OK;
    }

    ctx = hlcf->zone->data;

    key = r->uri;

    if (key.len > NGX_HTTP_HITS_MAX_KEY) {
        key.len = NGX_HTTP_HITS_MAX_KEY;
    }

    hash = ngx_crc32_short(key.data, key.len);

    ngx_shmtx_lock(&ctx->shpool->mutex);

    hn = ngx_http_hits_lookup(&ctx->sh->rbtree, &key, hash);

    if (hn) {
        hn->count++;

        ngx_queue_remove(&hn->queue);
        ngx_queue_insert_head(&ctx->sh->queue, &hn->queue);

        ngx_shmtx_unlock(&ctx->shpool->mutex);
        return NGX_OK;
    }

    n = offsetof(ngx_http_hits_node_t, data) + key.len;

    for ( ;; ) {
        hn = ngx_slab_alloc_locked(ctx->shpool, n);

        if (hn) {
            break;
        }

        if (ngx_queue_empty(&ctx->sh->queue)) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            return NGX_OK;
        }

        ngx_http_hits_evict(ctx);
    }

    hn->node.key = hash;
    hn->count = 1;
    hn->len = (u_short) key.len;
    ngx_memcpy(hn->data, key.data, key.len);

    ngx_rbtree_insert(&ctx->sh->rbtree, &hn->node);
    ngx_queue_insert_head(&ctx->sh->queue, &hn->queue);

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    return NGX_OK;
}


static ngx_http_hits_node_t *
ngx_http_hits_lookup(ngx_rbtree_t *rbtree, ngx_str_t *key, uint32_t hash)
{
    ngx_int_t              rc;
    ngx_rbtree_node_t     *node, *sentinel;
    ngx_http_hits_node_t  *hn;

    node = rbtree->root;
    sentinel = rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key: a collision is possible, compare the URIs */

        hn = (ngx_http_hits_node_t *) node;

        rc = ngx_memn2cmp(key->data, hn->data, key->len, (size_t) hn->len);

        if (rc == 0) {
            return hn;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    return NULL;
}


static void
ngx_http_hits_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t     **p;
    ngx_http_hits_node_t   *hn, *hnt;

    for ( ;; ) {

        if (node->key < temp->key) {
            p = &temp->left;

        } else if (node->key > temp->key) {
            p = &temp->right;

        } else { /* node->key == temp->key */

            hn = (ngx_http_hits_node_t *) node;
            hnt = (ngx_http_hits_node_t *) temp;

            p = (ngx_memn2cmp(hn->data, hnt->data, hn->len, hnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}


/* Called with the zone mutex held and a non-empty LRU queue. */

static void
ngx_http_hits_evict(ngx_http_hits_ctx_t *ctx)
{
    ngx_queue_t           *q;
    ngx_http_hits_node_t  *hn;

    q = ngx_queue_last(&ctx->sh->queue);
    hn = ngx_queue_data(q, ngx_http_hits_node_t, queue);

    ngx_queue_remove(q);
    ngx_rbtree_delete(&ctx->sh->rbtree, &hn->node);

    ngx_slab_free_locked(ctx->shpool, hn);
}


static ngx_int_t
ngx_http_hits_status_handler(ngx_http_request_t *r)
{
    size_t                     len;
    ngx_int_t                  rc;
    ngx_buf_t                 *b;
    ngx_uint_t                 i, n;
    ngx_chain_t                out;
    ngx_queue_t               *q;
    ngx_http_hits_ctx_t       *ctx;
    ngx_http_hits_node_t      *hn;
    ngx_http_hits_entry_t     *entries;
    ngx_http_hits_loc_conf_t  *hlcf;

    if (!(r->method & (NGX_HTTP_GET|NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    rc = ngx_http_discard_request_body(r);

    if (rc != NGX_OK) {
        return rc;
    }

    hlcf = ngx_http_get_module_loc_conf(r, ngx_http_hits_module);
    ctx = hlcf->status->data;

    /* copy a snapshot out of shared memory, then sort it without the lock */

    ngx_shmtx_lock(&ctx->shpool->mutex);

    n = 0;

    for (q = ngx_queue_head(&ctx->sh->queue);
         q != ngx_queue_sentinel(&ctx->sh->queue);
         q = ngx_queue_next(q))
    {
        n++;
    }

    entries = ngx_palloc(r->pool, (n ? n : 1) * sizeof(ngx_http_hits_entry_t));
    if (entries == NULL) {
        ngx_shmtx_unlock(&ctx->shpool->mutex);
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    len = sizeof("# hits zone \"\": entries\n") - 1
          + hlcf->status->shm.name.len + NGX_INT_T_LEN;

    i = 0;

    for (q = ngx_queue_head(&ctx->sh->queue);
         q != ngx_queue_sentinel(&ctx->sh->queue);
         q = ngx_queue_next(q))
    {
        hn = ngx_queue_data(q, ngx_http_hits_node_t, queue);

        entries[i].count = hn->count;
        entries[i].uri.len = hn->len;
        entries[i].uri.data = ngx_pnalloc(r->pool, hn->len);

        if (entries[i].uri.data == NULL) {
            ngx_shmtx_unlock(&ctx->shpool->mutex);
            return NGX_HTTP_INTERNAL_SERVER_ERROR;
        }

        ngx_memcpy(entries[i].uri.data, hn->data, hn->len);

        len += NGX_INT_T_LEN + sizeof(" \n") - 1 + hn->len;
        i++;
    }

    ngx_shmtx_unlock(&ctx->shpool->mutex);

    ngx_qsort(entries, n, sizeof(ngx_http_hits_entry_t), ngx_http_hits_cmp);

    b = ngx_create_temp_buf(r->pool, len);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    b->last = ngx_sprintf(b->last, "# hits zone \"%V\": %ui entries\n",
                          &hlcf->status->shm.name, n);

    for (i = 0; i < n; i++) {
        b->last = ngx_sprintf(b->last, "%ui %V\n",
                              entries[i].count, &entries[i].uri);
    }

    b->last_buf = (r == r->main) ? 1 : 0;
    b->last_in_chain = 1;

    out.buf = b;
    out.next = NULL;

    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = b->last - b->pos;
    r->headers_out.content_type_len = sizeof("text/plain") - 1;
    ngx_str_set(&r->headers_out.content_type, "text/plain");
    r->headers_out.content_type_lowcase = NULL;

    rc = ngx_http_send_header(r);

    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    return ngx_http_output_filter(r, &out);
}


/* highest count first; equal counts in URI order */

static int ngx_libc_cdecl
ngx_http_hits_cmp(const void *one, const void *two)
{
    const ngx_http_hits_entry_t  *a = one;
    const ngx_http_hits_entry_t  *b = two;

    if (a->count != b->count) {
        return (a->count < b->count) ? 1 : -1;
    }

    return (int) ngx_memn2cmp(a->uri.data, b->uri.data, a->uri.len,
                              b->uri.len);
}


static ngx_int_t
ngx_http_hits_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_hits_ctx_t  *octx = data;

    size_t                len;
    ngx_http_hits_ctx_t  *ctx;

    ctx = shm_zone->data;

    if (octx) {
        /* reload: keep the counters from the previous cycle */
        ctx->sh = octx->sh;
        ctx->shpool = octx->shpool;

        return NGX_OK;
    }

    ctx->shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        ctx->sh = ctx->shpool->data;

        return NGX_OK;
    }

    ctx->sh = ngx_slab_alloc(ctx->shpool, sizeof(ngx_http_hits_shctx_t));
    if (ctx->sh == NULL) {
        return NGX_ERROR;
    }

    ctx->shpool->data = ctx->sh;

    ngx_rbtree_init(&ctx->sh->rbtree, &ctx->sh->sentinel,
                    ngx_http_hits_rbtree_insert_value);

    ngx_queue_init(&ctx->sh->queue);

    len = sizeof(" in hits zone \"\"") + shm_zone->shm.name.len;

    ctx->shpool->log_ctx = ngx_slab_alloc(ctx->shpool, len);
    if (ctx->shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(ctx->shpool->log_ctx, " in hits zone \"%V\"%Z",
                &shm_zone->shm.name);

    /* running out of memory is expected: we evict instead */
    ctx->shpool->log_nomem = 0;

    return NGX_OK;
}


static void *
ngx_http_hits_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_hits_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_hits_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    /*
     * set by ngx_pcalloc():
     *
     *     conf->status = NULL;
     */

    conf->zone = NGX_CONF_UNSET_PTR;

    return conf;
}


static char *
ngx_http_hits_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_hits_loc_conf_t  *prev = parent;
    ngx_http_hits_loc_conf_t  *conf = child;

    ngx_conf_merge_ptr_value(conf->zone, prev->zone, NULL);

    return NGX_CONF_OK;
}


static char *
ngx_http_hits_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ssize_t               size;
    ngx_str_t            *value;
    ngx_shm_zone_t       *shm_zone;
    ngx_http_hits_ctx_t  *ctx;

    value = cf->args->elts;

    size = ngx_parse_size(&value[2]);

    if (size == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid zone size \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    if (size < (ssize_t) (8 * ngx_pagesize)) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "zone \"%V\" is too small", &value[1]);
        return NGX_CONF_ERROR;
    }

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_hits_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    shm_zone = ngx_shared_memory_add(cf, &value[1], size,
                                     &ngx_http_hits_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (shm_zone->data) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "duplicate zone \"%V\"", &value[1]);
        return NGX_CONF_ERROR;
    }

    shm_zone->init = ngx_http_hits_init_zone;
    shm_zone->data = ctx;

    return NGX_CONF_OK;
}


static char *
ngx_http_hits(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_hits_loc_conf_t  *hlcf = conf;

    ngx_str_t  *value;

    if (hlcf->zone != NGX_CONF_UNSET_PTR) {
        return "is duplicate";
    }

    value = cf->args->elts;

    if (ngx_strcmp(value[1].data, "off") == 0) {
        hlcf->zone = NULL;
        return NGX_CONF_OK;
    }

    hlcf->zone = ngx_shared_memory_add(cf, &value[1], 0,
                                       &ngx_http_hits_module);
    if (hlcf->zone == NULL) {
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}


static char *
ngx_http_hits_status(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_hits_loc_conf_t  *hlcf = conf;

    ngx_str_t                 *value;
    ngx_http_core_loc_conf_t  *clcf;

    if (hlcf->status) {
        return "is duplicate";
    }

    value = cf->args->elts;

    hlcf->status = ngx_shared_memory_add(cf, &value[1], 0,
                                         &ngx_http_hits_module);
    if (hlcf->status == NULL) {
        return NGX_CONF_ERROR;
    }

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_hits_status_handler;

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_hits_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_LOG_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_hits_log_handler;

    return NGX_OK;
}
