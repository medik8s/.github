# Medik8s Team Expectations

This document sets baseline expectations for how the medik8s team works
together. It is a **starting point, not a rulebook**: we are a new team
building our process as we go, so everything here is a shared norm we've
agreed to start from — not an enforced procedure.

When a norm here stops matching how we actually work, we change the document.
We add process only when we feel the pain of not having it.

This document complements — and does not replace — three others:

- [`CONTRIBUTING.md`](../../CONTRIBUTING.md) — how to contribute (workflow, tooling, conventions)
- [`AGENTS.md`](../../AGENTS.md) — shared guidance for AI agents working in our repos
- [`CODE_OF_CONDUCT.md`](../../CODE_OF_CONDUCT.md) — the baseline for behavior; this document never overrides it

## What we're building

We maintain the medik8s operators (FAR, MDR, NHC, NMO, SNR, SBR, WAO, …) — workload
availability tooling for OpenShift. Our users depend on remediation working
end to end. That shapes our default:

- **Assume good intent.** We review code and designs, not people.

## Communication

We're a distributed team, so our default is **open, written, and
asynchronous**:

- Technical discussions happen in GitHub issues and PRs, where they're
  searchable and benefit the whole community. **When you must communicate
  something important, use multiple channels — we're a very distributed team.
  Repeat it in Slack, email, and team meetings until the point has landed;
  one post in one channel is not communication.**
- **Acknowledge, don't go silent.** When a question, review request, or issue
  is directed at you, a quick "seen, will get to this next week" is always an
  acceptable answer. Silence is the only real failure.
- **Ping, don't wait.** If you've requested a review and it's been quiet for a
  few days, politely pinging the reviewer is always okay — it's expected, not
  rude.
- **Decisions get written down.** Whatever we decide in a hallway conversation
  or call, someone writes it into the associated issue or PR so the rest of
  the team isn't left out.
- **In live meetings, bring people into your context.** Don't just read
  status ("working on JIRA 3533, it's fine"). Use the time to help others
  understand the work — what the problem is, why it's hard, what you're
  trying, what you've learned. Status fits in a written update; shared
  understanding doesn't.
- **All work is ultimately tracked in Jira.** Jira instructions are TBD —
  until they're written down here, ask in the team channel how to file and
  link work.

## Design docs

New or changed features require a design doc in
[designs](https://github.com/medik8s/.github/tree/main/designs) before
implementation starts. The design doc is where the team weighs in on the
approach — cost of finding a design problem in a doc is much lower than in a
PR. Keep it as light as the change warrants: a short doc for a small feature
beats no doc, and beats a giant doc too.

## Pull requests

We're starting with a few defaults that come from the tooling we already have
(branch protection, Prow, CI), and keeping everything else lightweight:

**As authors:**

- One concern per PR. Large refactors get split into layers that each build
  and pass tests on their own.
- Open early as a draft with `WIP` in the title while not ready, to save CI
  resources.
- Write a real description using the PR template: *what* changed and *why*,
  with a reference to the relevant issue.
- PRs that add or change functionality require a test — either an existing
  test or a new one — in
  [rhwa-system-tests](https://github.com/openshift/rhwa-system-tests).
  Identify the test by its test case ID as defined in the
  [test case guidelines](https://github.com/openshift/rhwa-system-tests/blob/main/docs/TESTCASES/AGENTS.md).
- Respond to every review comment — either address it or reply with your
  reasoning.
- Sign off with `git commit -s` (DCO is required).

**As reviewers:**

- Review each other's work promptly — we haven't set a hard turnaround; the
  norm is "reviews shouldn't be the bottleneck." If you can't get to something,
  say so and suggest an alternate reviewer.
- Review for correctness first, then design, then style. Nitpicks are marked
  `nit:` and don't block.
- Use `/ok-to-test` promptly for first-time contributors — they're blocked
  until someone does.
- If new commits land after your approval, re-review the delta.

## Quality

We have no assigned QE — quality is everyone's job and everyone's
responsibility. In practice that means:

- **You test what you ship.** The author is the first tester; don't push
  something to review that you haven't exercised yourself.
- **Tests are part of the work, not a follow-up.** A feature isn't done until
  it's covered in [rhwa-system-tests](https://github.com/openshift/rhwa-system-tests).
- **Everyone tests, everyone reports.** If you find a bug — in your code or
  someone else's — you file it or fix it. "Not my component" is not a thing.
- **Review with an eye for what could break.** Failure paths, edge cases, and
  what happens on a real cluster matter as much as the happy path.

## Priorities

- **Escalate early.** Blocked on a review, a decision, or another team? Raise
  it in the open (issue comment) before it becomes a deadline problem.

## What we're deliberately not doing (yet)

To keep this honest about being a new team, some things we may need later but
aren't committing to now:

- Retrospectives

If and when the absence of one of these hurts, we'll add it — here, by PR,
with the same review process as any other change.

## Changing these expectations

These expectations are ours. Propose changes via a PR to this file. When we
notice a norm has quietly changed, we write it down; when we notice a written
norm nobody follows, we delete it rather than pretend.
