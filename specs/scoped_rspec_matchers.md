# Scoping the RSpec matchers to `type: :reactor`

## Goal

`RubyReactor::RSpec.configure(config)` should add **nothing** to a host app's
example groups unless they opt in with `type: :reactor`. Helpers already work
that way. The 19 matchers do not — they are global the moment
`ruby_reactor/rspec` is required, and moving them behind the tag needs a
one-line-per-matcher change plus a migration.

## Current state

[lib/ruby_reactor/rspec.rb:20-42](../lib/ruby_reactor/rspec.rb#L20-L42):

| Piece | Scoped to `type: :reactor`? |
| --- | --- |
| `Helpers` (`test_reactor`) | yes — `config.include …, REACTOR_METADATA` |
| `SidekiqHelpers` (`drain_async_jobs`, `pending_async_jobs`) | yes |
| `before(:each)` setup (fake mode, storage wipe, snooze reset) | yes |
| `Matchers` (19 matchers) | **no** |
| `StorageReset.install!`, `StepExecutor.prepend` | no — load-time monkeypatches, out of scope for this doc |

## Why the `config.include` line does nothing today

[matchers.rb](../lib/ruby_reactor/rspec/matchers.rb) declares every matcher as:

```ruby
module Matchers
  ::RSpec::Matchers.define :be_success do
    ...
  end
end
```

`define` is [`RSpec::Matchers::DSL#define`](https://github.com/rspec/rspec-expectations/blob/main/lib/rspec/matchers/dsl.rb),
and its entire body is a `define_method` **on the receiver**:

```ruby
def define(name, &declarations)
  warn_about_block_args(name, declarations)
  define_method name do |*expected, &block_arg|
    RSpec::Matchers::DSL::Matcher.new(name, declarations, self, *expected, &block_arg)
  end
end
alias_method :matcher, :define
```

The receiver is `::RSpec::Matchers`, which RSpec includes into *every* example
group. So the matcher methods land in the global spec namespace at require
time, and `RubyReactor::RSpec::Matchers` ends up an empty module — the
`config.include RubyReactor::RSpec::Matchers` line in
[rspec.rb:32](../lib/ruby_reactor/rspec.rb#L32) includes nothing. Adding
`REACTOR_METADATA` to that line scopes nothing either.

## The change

Extend the DSL into **our** module, so `define_method` targets
`RubyReactor::RSpec::Matchers`:

```ruby
module RubyReactor
  module RSpec
    module Matchers
      extend ::RSpec::Matchers::DSL   # <- add

      matcher :be_success do          # <- was ::RSpec::Matchers.define
        ...
      end
    end
  end
end
```

Then gate the include:

```ruby
config.include RubyReactor::RSpec::Matchers, REACTOR_METADATA
```

Mechanically: one `extend` line, 19 `::RSpec::Matchers.define` →
`matcher` rewrites (`sed` handles it), one changed line in `rspec.rb`, and the
comment at [rspec.rb:29-30](../lib/ruby_reactor/rspec.rb#L29-L30) — which
currently explains why matchers *can't* be scoped — deleted.

Nothing inside the matcher bodies changes. `Matchers.coordination_adapter`
([matchers.rb:260](../lib/ruby_reactor/rspec/matchers.rb#L260)) is called with
an explicit receiver and resolves lexically at match time, so it is unaffected.

### Verified

A probe against this repo's `spec_helper`, with one matcher declared each way:

```
UNTAGGED scoped: expected :nope to respond to `probe_scoped?`   # not included -> falls through
UNTAGGED global: GLOBAL-MATCHER-RAN: expected :ok, got :nope    # still global
TAGGED   scoped: SCOPED-MATCHER-RAN: expected :ok, got :nope    # real matcher, chains and all
```

Note the first line: scoping a matcher out does **not** produce a
`NoMethodError`. See below.

## The trap: `be_*` / `have_*` fall through to a predicate matcher

All 19 matcher names start with `be_` or `have_`, which is exactly the prefix
RSpec's dynamic predicate matchers claim. Once a matcher is no longer in scope,
`expect(x).to be_success` stops meaning "RubyReactor's `be_success`" and starts
meaning "call `x.success?`". Two consequences:

1. **`respond_to?(:be_success)` is not a scoping test.** It returns `true` in
   any example group for any `be_*`/`have_*` name, because
   `RSpec::Matchers#respond_to_missing?` claims the whole prefix. Test scoping
   by running an expectation and reading the failure message (as the probe
   above does), not by probing `respond_to?`.
2. **Some call sites degrade silently rather than breaking.** `TestSubject` and
   the result objects define `success?`, `failure?`, `paused?`, `halted?` and
   `skipped?` ([test_subject.rb:388-405](../lib/ruby_reactor/rspec/test_subject.rb#L388-L405),
   [ruby_reactor.rb:50-62](../lib/ruby_reactor.rb#L50-L62)), so an untagged
   `expect(result).to be_success` keeps passing via the predicate — with a
   generic failure message instead of the rich one in
   [matchers.rb:14-23](../lib/ruby_reactor/rspec/matchers.rb#L14-L23), and
   without the `ensure_executed!` nudge the real matcher does. Anything with a
   chain (`have_run_step(:x).returning(y)`, `be_halted.because(:period)`,
   `be_locked.by(owner)`) or a non-predicate name fails loudly instead.

So the migration cost is not "find the red specs" — a suite can go green while
quietly asserting something weaker. Grep for the matcher names rather than
trusting a passing run.

## Migration

In this repo, 34 spec files use these matchers; 24 of them are not tagged
`type: :reactor`. Most only need the tag added to the `RSpec.describe` line, the
same edit made for `test_reactor` in `0a3ebdab`. Order of work:

1. Rewrite `matchers.rb` to the DSL-extend form, leave the include ungated —
   suite must stay green (proves the rewrite alone changes nothing).
2. Gate the include, run the suite, tag the files that fail.
3. Grep the 24 untagged files for matcher names and tag the rest by hand —
   step 2 will not catch the silent-degradation cases above.
4. Update [documentation/testing.md](../documentation/testing.md#L17-L35),
   whose Setup section currently says matchers are available everywhere, and
   the comment at [rspec.rb:29-30](../lib/ruby_reactor/rspec.rb#L29-L30).

## Breaking change

Downstream suites calling these matchers in untagged groups are affected, with
the same silent-degradation caveat: a user's suite may stay green while
asserting less. This warrants a `BREAKING CHANGE:` footer and a release note
that names the fallback behavior explicitly, not just "matchers are now
scoped".

## Alternative considered

Keep matchers global, on the grounds that `be_success` / `have_run_step` are
already ambiguous with RSpec's predicate matchers and that a host app gains
little from gating them. This costs nothing and breaks nobody — worth taking if
the namespace complaint is theoretical rather than something a host app has
actually hit.
