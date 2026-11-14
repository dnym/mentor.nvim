# Tutorial: patching nginx with mentor.nvim

Imagine you have just joined a team that runs its own build of nginx. On
your first Monday, this lands in your inbox:

> We keep guessing which URLs get the most traffic, and grepping access logs
> on every box is slow. Can you add a small built-in module to our nginx
> that counts requests per URI and shows the counts at a status URL?
>
> - Counts are shared across all worker processes, not one set per worker.
> - Memory use is fixed: when the table is full, drop the URIs nobody has
>   asked for in a while.
> - Counts survive `nginx -s reload`.
> - The busiest URIs come first.
> - It is off unless built with `--with-http_hits_module`.
>
> No rush. Have it ready for review by the end of the week.

You know C, but you have never read nginx's source. This tutorial follows
you through that task from first question to working build, using every
part of Mentor along the way. By the end, this works:

```console
$ curl localhost:8088/hits
# hits zone "pages": 3 entries
5 /hot
4 /index.html
2 /missing
```

The module is small, but it touches the parts of nginx that are hard to
learn from the outside: request phases, module configuration, shared
memory, the slab allocator, red-black trees, and cross-process locking.
That makes it a good fit for Mentor, which helps you learn the code rather
than writing all of it for you:

| Step | Mode | What it is for here |
|---|---|---|
| Learn how nginx is put together | **Coach** (`:MentorChat`) | Questions about phases, shared memory zones, and data structures, answered from the real source |
| Write the boilerplate | **Implement** (`:MentorImplement`) | Configuration parsing, the module definition, the status page |
| Write the core logic | you | Lookup, insertion, eviction, and locking: the part worth learning |
| Catch mistakes | **Observer** (`:MentorObserve`) | Reviews your changes in the background while you type |
| Keep context | **Memory** (`:MentorMemory`) | Your learning goals and design decisions, across sessions |

Every message to send and every line of code to write is given below.
Model answers vary, so the tutorial describes what a good answer contains
rather than quoting one. If an answer misses the point, ask a follow-up:
that is how Coach is meant to be used.

A complete reference solution is in
[`tutorial/ngx_http_hits_module.c`](tutorial/ngx_http_hits_module.c), and
the test configuration is in [`tutorial/hits.conf`](tutorial/hits.conf).

## 0. Set up

### nginx

Clone nginx, check out the release used here, and create a branch for your
work:

```sh
git clone https://github.com/nginx/nginx.git
cd nginx
git checkout release-1.31.8
git switch -c hits-module
```

You need a C compiler, `make`, and the PCRE2 and zlib development headers
(`pcre2` and `zlib` on Arch; `libpcre2-dev` and `zlib1g-dev` on Debian and
Ubuntu). Check that a stock build works before you change anything, so
toolchain problems don't get mixed up with your own:

```sh
auto/configure --with-debug && make -j"$(nproc)"
objs/nginx -V
```

### Mentor

The defaults are tuned for short questions. This tutorial asks for whole
functions and lets the model read several nginx source files per answer,
so raise the budgets while you work through it:

```lua
require("mentor").setup({
  providers = {
    default = {
      endpoint = "http://127.0.0.1:8080/v1", -- your endpoint
      model = "your-model",
      -- api_key_env = "MENTOR_API_KEY", -- hosted providers: the variable holding your key (export it before starting Neovim)
      max_tokens = 8192, -- room for whole functions (and reasoning, if your model reasons)
      timeout_s = 300,
    },
  },
  limits = {
    interactive = { model_requests = 24, tool_calls = 40, elapsed_s = 600, est_tokens = 64000 },
    background = {
      model_requests = 16, tool_calls = 24, elapsed_s = 600, est_tokens = 48000,
      requests_per_hour_per_project = 120,
      est_tokens_per_day_per_project = 2000000, -- fine for a local model; mind your bill on a hosted one
    },
  },
  observer = {
    digest_file_bytes = 32768, -- the new module grows past the 2 KiB default
    digest_total_bytes = 32768,
  },
})
```

`est_tokens` must fit inside your model's context window. A local model
with a small context needs smaller values; reduce them and ask narrower
questions if Mentor reports that a request is too large.

How long a request takes depends on your provider and model. An Implement
proposal or an Observer pass reads several nginx files before it answers,
which can take minutes on a slow model. The background budgets above give
the Observer room to read the code around your change; with less, it still
reports on its last turn, but from less evidence. You can keep working
while either one runs.

Start Neovim inside the clone and check the setup:

```sh
nvim src/http/ngx_http_core_module.h
```

```vim
:checkhealth mentor
:MentorStatus
```

`:MentorStatus` should show the nginx clone as the project, with Git
detected and your provider configured. If your provider needs an API key,
`:checkhealth mentor` also tells you whether it found one.

## 1. Tell Mentor how you want to learn

Mentor keeps a memory of your learning goals and of the project's
decisions. Seed it first, so every later answer is pitched right:

```vim
:MentorChatAsk Please remember this about me: I'm comfortable with C, but new to the nginx codebase. Give me hints and questions first, and full answers only when I ask for them.
```

The chat buffer opens and the answer streams into it. Coach should save a
global memory entry; you will see a `[tool: memory_remember]` note in the
transcript. Check what it stored:

```vim
:MentorMemory
```

The entry is plain Markdown. You can edit it and `:w` to save; an entry you
edit becomes protected, so the assistant can no longer change it. Close the
view with `:q`.

> **Using the chat buffer.** Every message in this tutorial is given as a
> `:MentorChatAsk` command, so you can paste it. In the chat buffer itself,
> you can also type a new line starting with `> `, leave Insert mode, and
> press `<CR>` on that line to send it. Requests sent while one is running
> queue up. `:MentorStop` cancels the running one.

## 2. Find your way around

Ask where the feature belongs:

```vim
:MentorChatAsk I want to add a built-in nginx module that counts requests per URI across all worker processes and serves the counts at a status URL. Where in a request's life should the counting happen, and which existing modules are closest to what I need?
```

A good answer is grounded in files Coach actually opened. You will see
`read_file` and `search_content` notes in the transcript. It should
cover:

- **HTTP phases.** `ngx_http_phases` in `src/http/ngx_http_core_module.h`
  lists them. Counting belongs in `NGX_HTTP_LOG_PHASE`, which runs once per
  request, after the response, for the location that finally handled it.
- **Neighbours.** `ngx_http_limit_req_module.c` and
  `ngx_http_limit_conn_module.c` keep per-key state in shared memory.
  `ngx_http_stub_status_module.c` is a minimal module that serves a status
  page.

Then dig into the closest neighbour:

```vim
:MentorChatAsk Walk me through how ngx_http_limit_req_module keeps per-key state in shared memory. What are ngx_shm_zone_t, the slab pool, and the zone's init callback for, and what happens to the zone when nginx reloads its configuration?
```

What you want to come away with:

- A directive such as `limit_req_zone` calls `ngx_shared_memory_add()` while
  the configuration is parsed. The memory itself is mapped later, before
  the workers fork, so every worker sees the same bytes.
- The zone starts with an `ngx_slab_pool_t`. You allocate inside it with
  `ngx_slab_alloc()` / `ngx_slab_alloc_locked()`, and its `mutex` is the
  cross-process lock.
- `shm_zone->init` runs for every configuration cycle. On a reload it
  receives the previous cycle's context as `data` and reuses the existing
  tree, so state survives `nginx -s reload`.

## 3. Choose the data structures

This is the most valuable step to work through with Coach. Ask for hints,
not code:

```vim
:MentorChatAsk I need a map from URI to counter that lives in shared memory, plus a way to make room when the zone fills up. limit_req uses an rbtree plus a queue. Why that pair rather than ngx_hash_t? Hints only, please.
```

Try to answer the hints yourself before you ask for more. The reasoning
you should arrive at:

- `ngx_hash_t` is built once at configuration time and is read-only after
  that, so it cannot take new keys at runtime. `ngx_rbtree_t` can insert
  and delete in O(log n) with no rehashing, and it is intrusive: the node
  lives inside your own struct, so a single slab allocation holds the
  node, the counter, and the key.
- The tree is keyed by a 32-bit hash (`ngx_crc32_short`). Different URIs
  can share a hash, so equal hashes fall back to comparing the bytes
  (`ngx_memn2cmp`).
- An `ngx_queue_t` (an intrusive doubly linked list) records recency. A hit
  moves its node to the head of the queue. When allocation fails, the tail
  is the least recently used entry, which makes eviction O(1).

Follow up on the property your code will depend on:

```vim
:MentorChatAsk Every node is in both the rbtree and the queue. What invariant has to hold between the two, and which operations could break it?
```

The answer you want: every node is linked into **both** structures or
**neither**, at all times when the lock is not held. Insertion must add a
node to both. Eviction must unlink it from both **before** the memory goes
back to the slab pool. Remember this; it comes up again in step 7.

Now the concurrency question:

```vim
:MentorChatAsk Workers are separate processes. What do I need to lock in this design, for how long, and what must I avoid while holding the lock?
```

Expect: take `shpool->mutex` (an `ngx_shmtx_t`, a spinlock with a
semaphore fallback) around every access to the tree, the queue, and the
counters. Hold it briefly. Never block, do I/O, or return early while
holding it. Use the `_locked` slab functions inside the critical section,
because plain `ngx_slab_alloc()` takes the same mutex itself.

Record the design so later sessions start from it:

```vim
:MentorChatAsk Please remember a project decision: the hits module stores per-URI counters in a shared memory zone, as an rbtree keyed by crc32 of the URI (memcmp on collisions) plus an LRU queue; when the slab allocator runs out, it evicts from the queue tail. All access happens under shpool->mutex.
```

## 4. Wire the module into the build

nginx has no Makefile in Git. `auto/configure` generates one, plus
`objs/ngx_modules.c`, from shell scripts. A built-in module needs three
small edits, which you make by hand.

In `auto/options`, add a default next to the stub_status one:

```sh
# STUB
HTTP_STUB_STATUS=NO
HTTP_HITS=NO
```

add the option to the big `case` statement, after the stub_status line:

```sh
        --with-http_stub_status_module)  HTTP_STUB_STATUS=YES       ;;
        --with-http_hits_module)         HTTP_HITS=YES              ;;
```

and to the `--help` text:

```text
  --with-http_stub_status_module     enable ngx_http_stub_status_module
  --with-http_hits_module            enable ngx_http_hits_module
```

In `auto/modules`, after the `HTTP_STUB_STATUS` block and before the `fi`
that closes `if [ $HTTP = YES ]`, add:

```sh
    if [ $HTTP_HITS = YES ]; then
        ngx_module_name=ngx_http_hits_module
        ngx_module_incs=
        ngx_module_deps=
        ngx_module_srcs=src/http/modules/ngx_http_hits_module.c
        ngx_module_libs=
        ngx_module_link=$HTTP_HITS

        . auto/module
    fi
```

Order matters here. Modules listed later in `auto/modules` run their
phase handlers earlier. You can ask Coach why:

```vim
:MentorChatAsk How does the block I added to auto/modules end up in the nginx binary? Explain what auto/module does with ngx_module_name and ngx_module_srcs, and why the order of modules matters.
```

## 5. Create the file and write the types

Open the new file:

```vim
:edit src/http/modules/ngx_http_hits_module.c
```

Type the header, the types, and the placeholder comments below. The types
*are* the design from step 3, so write them yourself. Each placeholder
marks a part you will fill in later, either with Implement or by hand.

```c

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


/* IMPLEMENT: prototypes, directives, and module definition */


/* BY HAND: counting, lookup, insertion, eviction */


/* IMPLEMENT: status handler */


/* IMPLEMENT: zone init and location configuration */


/* IMPLEMENT: directive handlers and postconfiguration */
```

Save it with `:w`. Then check your understanding of the layout:

```vim
:MentorChatAsk In ngx_http_hits_node_t in the file I have open, why must node be the first member, and what does the u_char data[1] at the end buy me compared with an ngx_str_t?
```

The answer should cover two points. With `node` first, a
`ngx_rbtree_node_t *` from the tree can be cast straight to your struct.
The trailing array lets one slab allocation of
`offsetof(ngx_http_hits_node_t, data) + len` bytes hold the key inline, so
there is no second allocation and no pointer that would mean something
different in each process.

## 6. Generate the configuration code with Implement

Implement edits exactly the range you select. The model can read the
project, but it can only propose replacement text for that range. You see a
diff and decide.

Put the cursor on the line `/* IMPLEMENT: zone init and location
configuration */`, press `V` to select it, then type `:` (Neovim fills in
`'<,'>`) and the rest of the command:

```vim
:'<,'>MentorImplement Replace this line with three functions in nginx style, modeled on ngx_http_limit_req_module.c: ngx_http_hits_init_zone (the shm_zone init callback: on reload reuse the old context's sh and shpool; if shm.exists, take sh from shpool->data; otherwise slab-allocate the ngx_http_hits_shctx_t, store it in shpool->data, init the rbtree with ngx_http_hits_rbtree_insert_value and the queue, set log_ctx to ' in hits zone "NAME"' and log_nomem to 0), ngx_http_hits_create_loc_conf (status NULL, zone NGX_CONF_UNSET_PTR), and ngx_http_hits_merge_loc_conf (merge zone with default NULL).
```

A side window shows the model's progress and tool calls. When it finishes,
a diff opens. Review it against this checklist:

- `ngx_http_hits_init_zone` has three paths: `octx` (reload: copy `sh` and
  `shpool`), `shm.exists` (take `sh` from `shpool->data`), and fresh
  (allocate, `ngx_rbtree_init`, `ngx_queue_init`, `log_ctx`,
  `log_nomem = 0`).
- Every allocation is checked against `NULL`.
- `create_loc_conf` uses `ngx_pcalloc` and sets
  `zone = NGX_CONF_UNSET_PTR`; `merge_loc_conf` uses
  `ngx_conf_merge_ptr_value(conf->zone, prev->zone, NULL)`.

If it looks right:

```vim
:MentorImplementAccept
```

If the side window says `Stopped without producing a proposal: tool call
limit ... reached`, the model spent its budget exploring. Run the same
command again, and name the files it should read in the instruction. That
is why the status-page instruction in step 8 says "read only ...".

The change lands as a single undo step, so one `u` takes it back. If the
proposal is wrong, run `:MentorImplementReject` and try again with a more
specific instruction. You can also accept it and fix the details by hand.
If you edit the buffer before you accept, even an edit you undo, the
proposal is invalidated, because it no longer matches the text it was made
for.

`:w`, then select the line `/* IMPLEMENT: directive handlers and
postconfiguration */` the same way:

```vim
:'<,'>MentorImplement Replace this line with four functions in nginx style: ngx_http_hits_zone parses "hits_zone NAME SIZE" (ngx_parse_size, minimum 8 * ngx_pagesize, allocate an ngx_http_hits_ctx_t, ngx_shared_memory_add with &ngx_http_hits_module, reject a duplicate zone, set init to ngx_http_hits_init_zone); ngx_http_hits parses "hits NAME" or "hits off" into zone (duplicate check against NGX_CONF_UNSET_PTR, off means NULL, otherwise ngx_shared_memory_add with size 0); ngx_http_hits_status parses "hits_status NAME" into status and sets the core location handler to ngx_http_hits_status_handler; ngx_http_hits_init registers ngx_http_hits_log_handler in NGX_HTTP_LOG_PHASE.
```

Checklist:

- `hits_zone` reports `invalid zone size` and `zone ... is too small`
  errors with `ngx_conf_log_error`. It rejects a zone whose `shm_zone->data`
  is already set, then sets `shm_zone->init` and `shm_zone->data`.
- `hits` and `hits_status` call `ngx_shared_memory_add(cf, &value[1], 0,
  &ngx_http_hits_module)`. Size 0 means "a reference to a zone declared
  elsewhere". If the zone is never declared, nginx refuses to start with
  `zero size shared memory zone`.
- `hits_status` gets the core location configuration with
  `ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module)` and sets its
  `handler`.
- `ngx_http_hits_init` pushes onto
  `cmcf->phases[NGX_HTTP_LOG_PHASE].handlers`.

Accept, `:w`, and make a checkpoint commit. The commit also keeps the next
step's diff small, so the Observer can focus on your hand-written code:

```sh
git add auto/options auto/modules src/http/modules/ngx_http_hits_module.c
git commit -m "hits: build wiring, types, configuration handlers"
```

(Run it from a terminal, or prefix it with `:!` inside Neovim.)

## 7. Write the core by hand, with the Observer watching

Turn on background review for this project:

```vim
:MentorObserve enable
```

From now on, a short while after you stop typing or save, the Observer
sends a size-capped summary of your changes against `HEAD` to the model and
records its findings. It never interrupts Insert mode, and it notifies you
at most once a minute.

Replace `/* BY HAND: counting, lookup, insertion, eviction */` with the
code below. Type it rather than paste it if you can: this is the part of
the module that does the real work. **Type it exactly as shown.** It
contains one deliberate mistake for the Observer to find. If you spot it,
leave it in for now.

```c
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

    ngx_slab_free_locked(ctx->shpool, hn);
}
```

Some things to notice while you type:

- **The hot path.** A hit is a lookup, an increment, and a move to the
  queue head, all under the lock. Nothing in it allocates.
- **Lookup and insert agree.** `ngx_http_hits_lookup` and
  `ngx_http_hits_rbtree_insert_value` must order equal hashes the same way
  (`ngx_memn2cmp`, smaller to the left), or lookups would search the wrong
  subtree. The generic `ngx_rbtree_insert()` calls your `insert_value` to
  find the leaf, then rebalances.
- **Every exit unlocks.** Each `return` after `ngx_shmtx_lock` is preceded
  by `ngx_shmtx_unlock`.

Save with `:w` and keep working; you don't need to wait for the Observer.
A pass reads the surrounding nginx code before it reports, so depending on
your model it can take a while. If you edit the file while a pass is
running, its findings come back marked stale and the next pass starts
over, so leave the file alone for a while if you want to see the result.
When a notification arrives, or whenever you like, open the findings:

```vim
:MentorObservations
```

Keys in that list: `<CR>` asks Coach to explain the finding under the
cursor, `d` dismisses it, `u` / `x` rate it useful / not useful, `s`
snoozes its category, `m` mutes it, `R` rechecks whether findings are
stale, and `q` closes the list. If nothing has shown up after a minute,
trigger a pass by hand:

```vim
:MentorObserve review
```

You are looking for a **correctness** finding about
`ngx_http_hits_evict`. Press `<CR>` on it, and Coach will explain it in the
chat. If the Observer found something else, read that too: it might be
right. If it missed the eviction bug, ask Coach directly, using the
invariant from step 3:

```vim
:MentorChatAsk Check ngx_http_hits_evict in the file I have open against the invariant that every node is in both the rbtree and the queue or in neither. Is anything wrong? Hints first.
```

<details>
<summary>The mistake, and the fix</summary>

`ngx_http_hits_evict` unlinks the node from the queue and frees it, but
leaves it in the red-black tree. The tree now points into freed slab
memory. The next allocation reuses those bytes, and a lookup or insert then
walks through a node that is no longer a node. In a test you will see
workers crash with signal 11, or one worker spin at 100% CPU while holding
the mutex, so that every other worker blocks too.

Fix it by removing the node from the tree before you free it:

```c
    ngx_queue_remove(q);
    ngx_rbtree_delete(&ctx->sh->rbtree, &hn->node);

    ngx_slab_free_locked(ctx->shpool, hn);
```

</details>

Fix the bug and save. The finding refers to code that has now changed, so
the list marks it stale (press `R` in `:MentorObservations` to recheck).
Dismiss it with `d`, and rate it with `u` or `x` to record whether it
helped.

## 8. Generate the status page

First, a design question:

```vim
:MentorChatAsk For the status page I want all entries sorted by count, highest first. nginx has ngx_sort and ngx_qsort. Which one fits here, and why? Should I sort while holding the zone lock?
```

Expect: `ngx_sort` is an insertion sort. It is stable and fine for a
handful of elements, but O(n²), and a zone can hold thousands of entries.
`ngx_qsort` is the C library `qsort`. Don't sort under the lock. Copy a
snapshot into memory from the request pool, unlock, then sort the copy.
The copy must include the URI bytes, not just a pointer into the shared
zone, because another worker can evict and reuse that entry the moment you
unlock.

Select the line `/* IMPLEMENT: status handler */` and run:

```vim
:'<,'>MentorImplement Replace this line with ngx_http_hits_status_handler and its comparator ngx_http_hits_cmp. Allow only GET and HEAD and discard the request body. Under the zone mutex, copy every node's count and URI from the LRU queue into an array of ngx_http_hits_entry_t allocated from r->pool, then unlock. Sort with ngx_qsort, highest count first, ties by URI. Reply text/plain: a first line '# hits zone "NAME": N entries', then one "COUNT URI" line per entry. The types are already in this file; for sending the response, read only src/http/modules/ngx_http_stub_status_module.c and do it the same way.
```

Checklist:

- Every return between `ngx_shmtx_lock` and `ngx_shmtx_unlock` unlocks
  first. This is the classic bug in this function, and the Observer is
  watching for it too.
- The URI bytes are copied (`ngx_pnalloc` + `ngx_memcpy`), not just the
  pointer.
- The output buffer is sized from the snapshot. For example, each line
  needs `NGX_INT_T_LEN + 2 + uri.len` bytes, plus the header line. The
  buffer must never be empty, because nginx logs a `zero size buf` alert
  for that. The header line guarantees it isn't.
- The comparator has the `int ngx_libc_cdecl (const void *, const void *)`
  signature that `qsort` expects, and it returns -1/1, not a difference of
  unsigned counts. A difference could overflow.
- The response sets `content_type`, `content_length_n`, `last_buf`, calls
  `ngx_http_send_header`, and returns early for `HEAD` (`r->header_only`).

Accept and `:w`.

## 9. Generate the module definition

The last placeholder is pure boilerplate derived from everything below it,
so let Implement write it, now that the rest of the file exists. Select the
line `/* IMPLEMENT: prototypes, directives, and module definition */`:

```vim
:'<,'>MentorImplement Replace this line with the forward declarations of every static function defined below in this file, then the ngx_http_hits_commands array (hits_zone: http main only, TAKE2; hits: http, server and location, TAKE1, location conf offset; hits_status: location only, TAKE1, location conf offset), the ngx_http_module_t context (postconfiguration ngx_http_hits_init, create and merge location conf), and the ngx_module_t ngx_http_hits_module definition.
```

Checklist:

- There is one prototype for each static function in the file. The
  compiler will tell you if one is missing or mismatched.
- `hits_zone` uses `NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE2` with offset `0`.
  `hits` uses `NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1`
  with `NGX_HTTP_LOC_CONF_OFFSET`. `hits_status` uses
  `NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1` with `NGX_HTTP_LOC_CONF_OFFSET`. The
  array ends with `ngx_null_command`.
- `ngx_http_hits_module` is **not** `static`: `objs/ngx_modules.c` refers
  to it by name. It starts with `NGX_MODULE_V1`, ends with
  `NGX_MODULE_V1_PADDING`, and has type `NGX_HTTP_MODULE`.

Accept and `:w`.

## 10. Build

```sh
auto/configure --with-debug --with-http_hits_module
make -j"$(nproc)"
```

`grep hits objs/ngx_modules.c` should show the module in both lists.
nginx builds with `-Werror`, so every warning stops the build. If it
fails, give Coach the error. It can read the file and the nginx headers,
but it cannot run the compiler, so paste the first error:

```vim
:MentorChatAsk The build fails with this error, what does it mean? <paste the first error line here>
```

Typical first-build errors: a prototype that doesn't match its definition,
an unused variable left over from a proposal, or a comparator declared
without `ngx_libc_cdecl`. Fix them by hand, or select the offending function
and use `:MentorImplement` with an instruction like
`Fix this compile error: <error>`.

## 11. Run and test

Set up a scratch prefix inside the clone. nginx's `.gitignore` already
ignores `tmp/`, so the Observer won't review it:

```sh
mkdir -p tmp/hits/html tmp/hits/logs
echo hello > tmp/hits/html/index.html
cp /path/to/mentor.nvim/docs/tutorial/hits.conf tmp/hits/hits.conf
```

or create `tmp/hits/hits.conf` yourself:

```nginx
worker_processes  4;
daemon            on;
pid               nginx.pid;
error_log         error.log info;

events {}

http {
    access_log  off;

    hits_zone  pages  32k;

    server {
        listen  127.0.0.1:8088;
        root    html;

        hits  pages;

        location / {
        }

        location = /hits {
            hits         off;
            hits_status  pages;
        }
    }
}
```

The zone is deliberately tiny: 32k is the smallest size the module accepts
(8 pages), so you can watch eviction happen. Four workers make the
shared-memory part real, because requests land on different processes.

Check the configuration, then start the server from the clone's root:

```sh
objs/nginx -p "$PWD/tmp/hits" -c hits.conf -t
objs/nginx -p "$PWD/tmp/hits" -c hits.conf
```

`-p` sets the prefix, so every relative path in the configuration resolves
inside `tmp/hits`, and nothing needs to be installed.

**Counting and sorting:**

```sh
for i in 1 2 3; do curl -s -o /dev/null localhost:8088/; done
curl -s -o /dev/null localhost:8088/index.html
curl -s -o /dev/null "localhost:8088/missing?x=1"
curl -s -o /dev/null localhost:8088/missing
curl -s localhost:8088/hits
```

```text
# hits zone "pages": 2 entries
4 /index.html
2 /missing
```

Two things to notice. Requests for `/` were counted as `/index.html`, and
the query string is not part of the key. Ask Coach why:

```vim
:MentorChatAsk My hits module counts requests for / under /index.html. Why, given that I read r->uri in a NGX_HTTP_LOG_PHASE handler? Which module changes the URI?
```

(The index module performs an internal redirect, and the log phase runs
once, for the final URI.)

**Method handling:**

```sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8088/hits   # 405
curl -sI localhost:8088/hits | head -1                                 # HTTP/1.1 200 OK
```

**Eviction under concurrency.** This sends 3000 distinct URIs from 8
parallel clients into a zone that holds about 190 of them:

```sh
seq 1 3000 | xargs -P 8 -I{} curl -s -m 2 -o /dev/null localhost:8088/page-{}
curl -s localhost:8088/hits | head -3
grep -c "exited on signal" tmp/hits/error.log
```

Expect a header like `# hits zone "pages": 191 entries`, only recent
`/page-...` URIs (the oldest were evicted, `/index.html` included), and
`0` crashed workers. If you skipped the fix in step 7, this is where it
shows: requests time out, `error.log` reports `worker process ... exited
on signal 11`, and `top` shows a worker stuck at 100% CPU.

**Survival across reloads:**

```sh
for i in 1 2 3 4 5; do curl -s -o /dev/null localhost:8088/hot; done
objs/nginx -p "$PWD/tmp/hits" -c hits.conf -s reload
sleep 1
curl -s localhost:8088/hits | head -2
```

`5 /hot` should still be at the top: the reload path in
`ngx_http_hits_init_zone` reused the existing tree.

Stop the server when you are done:

```sh
objs/nginx -p "$PWD/tmp/hits" -c hits.conf -s stop
```

## 12. Wrap up

That covers everything on your lead's list: counts shared across workers,
fixed memory with least-recently-used eviction, counts that survive a
reload, busiest URIs first, and a `--with-http_hits_module` build option.
Time to tidy up and ask for review.

- `:MentorMemory` shows what Mentor kept: your learning preferences and the
  module's design decision. In your next session on this clone, Coach
  starts from them.
- `:MentorStatus` shows interactive and background usage separately, so
  you can see what the Observer cost.
- `:MentorObserve disable` turns background review off for the project.
  `:MentorObserve pause` turns it off for this Neovim session only.
- `:MentorChatClear` clears the transcript and leaves memory alone.
- Commit your work:
  `git commit -am "hits: counting, eviction, status page"`.

### Exercises

Try these with Coach in hints-first mode, Implement for the boilerplate,
and the Observer left on:

1. **Top N.** Let `hits_status pages 10;` limit the report. When the zone
   holds n entries, how does a bounded heap (O(n log k)) compare with
   sorting everything (O(n log n))? Does it matter at this size?
2. **A variable.** Expose the current URI's count as `$hits_count`, so
   that `add_header X-Hits $hits_count;` works. Look at how
   `ngx_http_limit_req_module` registers `$limit_req_status`.
3. **Per-status counts.** Count `2xx`, `4xx`, and `5xx` responses separately
   per URI. What happens to the node layout, and to memory per entry?
4. **Approximate counting.** Replace exact counters with a count-min sketch
   in a fixed-size shared array. What do you gain, and what can no longer
   be reported?
