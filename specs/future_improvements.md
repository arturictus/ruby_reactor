# Future improvements for review

## Guard

I want to add another hook feature to the step: `guard`
A guard concept is to execute after validations and before run.
example:

```ruby
class SendEmail < RubyReactor::Step
  input :email, :string, format?: /\A[^@\s]+@[^@\s]+\z/

  def guard
    fail!("Prevent spamming") if EmailService.sent_today?(inputs[:email])
    success! # optional
  end

  def run
    # do the work
  end
end
```    
## Fenced context writes

**Status:** proposal, not scheduled. Follows from 005 (step coordination remediation), R-18 and
R-19 in `specs/005-step-coordination-remediation/research.md`.

### The rule

A context is written by one process only: the controlled execution that owns it.

- Async children (`async_step`, `async_reactor`, map elements) never write their parent. The
  parent holds only the link written at dispatch; each child keeps its own record, and the
  dashboard rebuilds its view from the links. 005 made this true for `async_step` (R-18).
- Today the rule is a convention: any code with a storage adapter can `SET` any context. This
  proposal makes it a guarantee that the storage enforces.

### Why a convention is not enough

Holding the lock at some point is not the same as owning the data when the write lands:

| Failure | What happens today |
|---|---|
| **Paused holder**: a worker holding the `async:<root id>` lock stalls (GC, network, a long rollback wait) past `context_lock_ttl`. The lock expires, a redelivery takes it and makes progress, then the first worker wakes. | The first worker's next `store_context` is a plain `SET`. It overwrites the newer state. Its auto-extender fails silently. Nothing stops the write. |
| **Stale read**: `Worker#perform` loads the context *before* `resume_execution` takes the context lock. | A previous holder can write between that read and the lock. The new holder then runs on the older snapshot and saves over the newer one. |
| **Writer outside any execution**: a path writes with no lock at all. | It overwrites whatever the live execution saved. 005 fixed two of these (`StepWorker#save_root`, the map collector's post-resume save); others remain (below). |

The first two are the textbook reasons distributed locks need fencing. A lock that only *excludes*
is not enough. The storage must also *reject writes from anyone who no longer holds the lock*.

### Remaining writers outside a controlled execution

Found while auditing for 005 R-19:

| Writer | Where | Today |
|---|---|---|
| `Worker.record_retries_exhausted` | backend's retries-exhausted hook | Plain read-modify-write, no lock. Marks the context failed even if a redelivery is live. |
| `Worker#escalate_snooze` | after the executor returned | Runs after the executor released the context lock. |
| `Worker#handle_deserialization_failure` | before any executor | Writes a failed payload with no lock. |
| Map collector, failure branch | `Map::Helpers#resume_parent_execution` | Holds `map_collect:<map_id>`, never the parent's `async:` lock. |
| `Reactor.cancel`, `Reactor.undo` | any process (app code, console) | `find` → mutate → `save_context`: a blind write racing a live worker. |
| `Reactor#continue` (interrupt resume) | web request / app code | Writes the payload before `resume_execution` takes the lock. |
| Synchronous `Reactor.run` / `Executor#execute` | caller's process | Never takes the context lock, so its saves are unfenced. |

Writers that already belong to the owning execution:
- `Executor#save_context` and `#checkpoint!` on the worker path;
- `RetryManager#requeue_job`;
- `StepExecutor#checkpoint_root!`;
- `MapStep#prepare_async_execution`.

Two writers only *create* a row that nothing has read yet:
- `Reactor#save_context` at enqueue;
- `AsyncReactorStep#save`, the child's first row.

### Proposal

Four parts. Parts 1 and 2 are the mechanism; parts 3 and 4 route the remaining writers through it.

#### 1. Ownership-checked, versioned writes (the fence)

- Every context row gets a version: a small key next to the blob,
  `reactor:<Class>:context:<id>:v`, with the same TTL as the blob.
- Every write goes through one Lua script. The script takes:
  - the lock key it claims to hold (`lock:async:<root id>`, or the map element's
    `lock:map_element:<map>:<index>`);
  - the owner token of that lock: the per-execution UUID `Executor#acquire_context_lock`
    already generates;
  - the version the writer loaded.
- The script writes only if **the lock is held by that token** *and* **the stored version equals
  the loaded one**. It then bumps the version.
- It returns `ok`, `lost_lock` or `stale`:

```lua
-- KEYS: context_key, version_key, lock_key   ARGV: blob, ttl, owner, expected_version
if redis.call('hget', KEYS[3], 'owner') ~= ARGV[3] then return 'lost_lock' end
local current = tonumber(redis.call('get', KEYS[2]) or '0')
if current ~= tonumber(ARGV[4]) then return 'stale' end
redis.call('set', KEYS[1], ARGV[1], 'EX', ARGV[2])
redis.call('set', KEYS[2], current + 1, 'EX', ARGV[2])
return 'ok'
```

Why both checks:
- The **owner check** stops a paused holder from writing at all, even before anyone else has
  written.
- The **version check** catches a stale read by the current holder, and any path this proposal
  missed.

The lock and the data live in the same Redis, and the check runs atomically inside it, so the
owner comparison does the job of a fencing token. There are no clock or ordering assumptions.
If locks and contexts ever move to different stores, switch to classic monotonic fencing tokens
(`INCR` on acquire, highest-token-wins at the store).

**Creating a row** uses the same script with `expected_version = 0` and no lock check: a
create-only `SET NX` equivalent. It covers `Reactor#save_context` at enqueue and an
`async_reactor` child's first row.

#### 2. Lock, then load

- A worker takes the context lock **before** it reads the context. The restructure:
  `Worker#perform` acquires `async:<root id>`, then retrieves and deserializes, then hands
  the token and the loaded version to `Executor`. Today `resume_execution` acquires the lock
  mid-way.
- A synchronous `Reactor.run` takes the same lock for its whole run. It is one `SET NX` and a
  release; today it takes none.
- Composed children already run inside the root's lock and write through the root. They reuse
  the root's token.

#### 3. External actors send requests, not writes

Operator actions must not write a live context. Make them requests the owning execution
consumes, the same pattern as async children writing their own records:

- **`Reactor.cancel` / `.undo`**:
  - write a `cancel_requested` key, `reactor:<Class>:context:<id>:cancel`;
  - the owning execution checks it at each step boundary and cancels or undoes itself, under its
    own lock;
  - if no execution is live (the context lock is free), `cancel` takes the lock itself and
    applies the request directly: lock, load, fenced write.
- **`Reactor#continue`**: take the lock first (bounded wait, because it is a user action), load,
  store the payload, resume. If the lock is held, return "busy — retry" instead of racing.
- **Worker bookkeeping** (`record_retries_exhausted`, `escalate_snooze`, deserialization
  failure):
  - take the context lock with `wait: 0`;
  - if another process holds it, that process owns the outcome, so log and skip;
  - move `escalate_snooze` inside the executor's lock scope instead of after it.
- **Map collector**: take the parent's `async:` lock for both branches. The success branch passes
  the token into `resume_execution`, which must accept an already-held lock (re-entrant by owner).

#### 4. What a rejected write does

A write that comes back `lost_lock` or `stale` raises `Error::ContextOwnershipLost`:
- The executor stops at once. It saves nothing else, runs no further steps, and releases only
  holds it still owns (every release is already owner-checked).
- It logs one structured line: `event="ruby_reactor.context.ownership_lost"`, with the context
  id, the lock key and the expected and actual version.
- The worker does **not** snooze or retry the job. The current owner is responsible for the run.
- A rejection is a correctness signal, not an error to hide. Expose it in the log and in the
  `:failed_reactor` middleware event, but never mark the context failed: its owner decides the
  outcome.

### Constraints and open questions

- **Redis Cluster**: the script touches three keys, which must share a hash slot. Tag them with
  the root id: `lock:async:{<root>}`, `reactor:<Class>:context:{<root>}`, and the version key. The
  ordered lock already does this. Changing the key format needs a migration or a dual-read window.
- **Composed children's own rows**: `Executor#save_context` of a composed child also stores the
  child under its own id. That is a second key in a different slot. Either tag it with the root
  id too, or drop these rows. They are an observability path: the root blob already embeds the
  child.
- **Inline test mode**: `Sidekiq::Testing.inline!` re-enters the worker inside a frame that holds
  the lock, which is why `acquire_context_lock` is skipped there today. The fence needs the same
  exemption, or re-entrancy by owner token.
- **Redis failover**: replication is asynchronous, so a failover can lose an acknowledged lock
  or write. This proposal gives single-primary guarantees, the same as today's locks. Stronger
  guarantees mean `WAIT`/`WAITAOF` on the lock write, or a different store. Document; don't solve
  here.
- **Other records**: Step Result Records and map element results have the same shape:
  - the dispatcher creates the record;
  - the unit's job updates it under its liveness lock;
  - it could be fenced the same way.

  Nothing races there today, because the liveness lock drops concurrent duplicates. Decide
  whether to fence them now or later.

### Rollout

- **SemVer**: MINOR, behind `config.fenced_context_writes` (default `false`) for one release.
  Existing contexts have no version key, which is read as `0`.
- A rolling deploy mixes old workers (plain `SET`, no version bump) with new ones, so the new
  workers would see spurious `stale` results. Enable the flag only after every worker runs the new
  version. Flip the default in the next MAJOR.
- **Cost**: one `EVAL` in place of one `SET` per save; checkpoints already save once per step.
  One extra `SET NX` and release per synchronous run.

### Test plan

All against real Redis, per the constitution.

1. **Paused holder**:
   - take the lock with a short TTL and let it expire;
   - a second owner takes it and writes;
   - the first owner's write returns `lost_lock`, and the stored blob is the second owner's.
2. **Stale read**:
   - load at version N;
   - another writer (holding the lock through a handover) bumps the version to N+1;
   - the write returns `stale`.
3. **Lock, then load**: a redelivery that races a finishing holder always runs on the holder's
   final state. This is the same repro shape as 005 P4.
4. **One spec per writer** in the tables above, showing it goes through the fence, or takes the
   lock and skips when it is held.
5. **Cancel of a live run**: the request is consumed at the next step boundary. The running
   execution's saves are never overwritten by the canceller.
6. **Cluster slot co-location**, if Redis Cluster is supported: every key a script touches
   hashes to one slot.

### Size

- Storage adapter: one new script and a versioned `retrieve_context`.
- Executor and `Worker`: lock, then load, and pass the token.
- Six writer paths rerouted, plus the cancel/undo request key.
- Docs: `locks_and_semaphores.md`, `background_and_async.md`, and the README's "Durability &
  Recovery" section.
