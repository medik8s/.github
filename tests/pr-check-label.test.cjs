// @ts-check

/**
 * Reuse the script's consumed GitHub response types for realistic fixtures.
 * @typedef {import('../scripts/pr-check-label.cjs').PullRequest} PullRequest
 * @typedef {import('../scripts/pr-check-label.cjs').PullRequestRef} PullRequestRef
 * @typedef {import('../scripts/pr-check-label.cjs').CheckRun} CheckRun
 * @typedef {import('../scripts/pr-check-label.cjs').CommitStatus} CommitStatus
 * @typedef {import('../scripts/pr-check-label.cjs').ApiParams} ApiParams
 * @typedef {import('../scripts/pr-check-label.cjs').ApiError} ApiError
 * @typedef {import('../scripts/pr-check-label.cjs').EventPayload} EventPayload
 * @typedef {import('../scripts/pr-check-label.cjs').WorkflowContext} WorkflowContext
 * @typedef {import('../scripts/pr-check-label.cjs').GitHubClient} GitHubClient
 * @typedef {'removeLabel' | 'getLabel' | 'createLabel' | 'addLabels'} IssueMethod
 * @typedef {ApiParams & {method: IssueMethod}} RecordedCall
 * @typedef {Object} SimulationOptions
 * @property {PullRequest[]} [pulls] PRs available to the mock API.
 * @property {PullRequest[]} [snapshots] Successive responses for PR reads.
 * @property {PullRequestRef[]} [associated] PRs associated with an event SHA.
 * @property {Record<string, CheckRun[]>} [runs] Check runs keyed by commit SHA.
 * @property {Record<string, CommitStatus[]>} [statuses] Status history keyed by SHA.
 * @property {Partial<Record<IssueMethod, Error & ApiError>>} [errors] Write errors by API method.
 * @property {Error & ApiError} [readError] Error thrown by check/status reads.
 * @property {string} [eventName] GitHub event name.
 * @property {EventPayload} [payload] Webhook payload to evaluate.
 */

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const evaluate = require("../scripts/pr-check-label.cjs");
process.env.LABEL_NAME = "all-checks-passed";
process.env.IGNORED_CHECKS = '["tide"]';

/**
 * Read the top-level permissions block used by our label workflow files.
 * @param {string} filename
 * @returns {Record<string, string>}
 */
function workflowPermissions(filename) {
  const source = readFileSync(
    join(__dirname, "../.github/workflows", filename),
    "utf8",
  );
  const block = source.match(/^permissions:\n((?: {2}[^\n]*\n)+)/m);

  assert.ok(block, `${filename} must declare token permissions`);

  return Object.fromEntries(
    block[1]
      .trim()
      .split("\n")
      .map((line) => line.trim().split(/:\s*/)),
  );
}

test("both label workflows grant PR write access and repository label access", () => {
  for (const filename of ["auto-label-pr.yaml", "pr-check-label.yaml"]) {
    const permissions = workflowPermissions(filename);

    assert.equal(permissions["pull-requests"], "write", filename);
    assert.equal(permissions.issues, "write", filename);
  }
});

test("the caller grants every permission requested by the reusable workflow", () => {
  const caller = workflowPermissions("auto-label-pr.yaml");
  const shared = workflowPermissions("pr-check-label.yaml");
  /** @type {Record<string, number>} */
  const access = { none: 0, read: 1, write: 2 };

  for (const [permission, level] of Object.entries(shared)) {
    assert.ok(
      access[caller[permission] || "none"] >= access[level],
      `caller must grant ${permission}: ${level}`,
    );
  }
});

/** @param {number} [number=1] @returns {PullRequest} */
const pr = (number = 1) => ({
  number,
  state: "open",
  head: { sha: "head" },
  merge_commit_sha: "merge",
  base: { repo: { full_name: "medik8s/example" } },
  labels: [],
});
/**
 * @param {string} [name='unit-test']
 * @param {string | null} [conclusion='success']
 * @param {string} [status='completed']
 * @returns {CheckRun}
 */
const run = (
  name = "unit-test",
  conclusion = "success",
  status = "completed",
) => ({
  name,
  conclusion,
  status,
  app: { slug: "github-actions" },
});
/**
 * @param {CommitStatus['state']} [state='success']
 * @param {string} [context='prow/unit']
 * @returns {CommitStatus}
 */
const status = (state = "success", context = "prow/unit") => ({
  context,
  state,
});

/**
 * Run the production module against API fixtures and record label operations.
 * @param {SimulationOptions} [options={}]
 * @returns {Promise<RecordedCall[]>}
 */
async function simulate(options = {}) {
  /** @type {RecordedCall[]} */
  const calls = [];
  const pulls = options.pulls || [pr()];
  /** @type {Map<number, number>} */
  const reads = new Map();
  const rest = {
    pulls: {
      list: "pulls.list",
      /** @param {{pull_number: number}} params */
      get: async ({ pull_number }) => {
        const count = reads.get(pull_number) || 0;
        reads.set(pull_number, count + 1);
        const original = pulls.find((pull) => pull.number === pull_number);
        return { data: options.snapshots?.[count] || original };
      },
    },
    checks: { listForRef: "checks.listForRef" },
    repos: {
      listPullRequestsAssociatedWithCommit: "repos.associated",
      listCommitStatusesForRef: "repos.statuses",
    },
    issues: Object.fromEntries(
      /** @type {IssueMethod[]} */ ([
        "removeLabel",
        "getLabel",
        "createLabel",
        "addLabels",
      ]).map((method) => [
        method,
        /** @param {ApiParams} args */
        async (args) => {
          calls.push({ method, ...args });
          if (options.errors?.[method]) throw options.errors[method];
          return { data: {} };
        },
      ]),
    ),
  };
  const github = {
    rest,
    /**
     * Mock pagination uses method-name tokens in place of Octokit functions.
     * @param {string} method
     * @param {ApiParams} args
     * @returns {Promise<(PullRequestRef | CheckRun | CommitStatus)[]>}
     */
    paginate: async (method, args) => {
      assert.equal(args.per_page, 100);
      if (method === "pulls.list") return pulls;
      if (method === "repos.associated") return options.associated || [];
      if (options.readError) throw options.readError;
      if (method === "checks.listForRef") {
        assert.equal(args.filter, "latest");
        return options.runs?.[/** @type {string} */ (args.ref)] || [];
      }
      if (method === "repos.statuses")
        return options.statuses?.[/** @type {string} */ (args.ref)] || [];
      throw Error(`Unexpected API: ${method}`);
    },
  };
  /** @type {WorkflowContext} */
  const context = {
    repo: { owner: "medik8s", repo: "example" },
    eventName: options.eventName || "workflow_run",
    payload: options.payload || {
      workflow_run: { head_sha: "head", pull_requests: [{ number: 1 }] },
    },
  };
  // The mock implements the consumed API with string tokens for pagination.
  await evaluate({
    github: /** @type {GitHubClient} */ (/** @type {unknown} */ (github)),
    context,
    core: { info() {} },
  });
  return calls;
}

test("adds label only when head and merge checks and latest statuses pass", async () => {
  const calls = await simulate({
    runs: { head: [run()], merge: [run("e2e")] },
    statuses: { head: [status()] },
  });
  assert.deepEqual(
    calls.map((call) => call.method),
    ["getLabel", "addLabels"],
  );
  assert.deepEqual(calls[1].labels, ["all-checks-passed"]);
});

for (const [name, check] of /** @type {[string, CheckRun][]} */ ([
  ["pending", run("unit", null, "in_progress")],
  ["queued", run("unit", null, "queued")],
  ...[
    "failure",
    "cancelled",
    "timed_out",
    "neutral",
    "skipped",
    "action_required",
    "stale",
  ].map((value) => [value, run("unit", value)]),
])) {
  test(`removes an existing label for a ${name} check`, async () => {
    const labeled = { ...pr(), labels: [{ name: "all-checks-passed" }] };
    const calls = await simulate({
      pulls: [labeled],
      runs: { head: [run()], merge: [check] },
    });
    assert.deepEqual(
      calls.map((call) => call.method),
      ["removeLabel"],
    );
  });
}

test("successful legacy retest replaces old failure", async () => {
  const calls = await simulate({
    statuses: { head: [status("success"), status("failure")] },
  });
  assert.equal(/** @type {RecordedCall} */ (calls.at(-1)).method, "addLabels");
});

test("latest pending legacy status removes the label", async () => {
  const calls = await simulate({
    pulls: [{ ...pr(), labels: [{ name: "all-checks-passed" }] }],
    statuses: { head: [status("pending"), status("success")] },
  });
  assert.equal(
    /** @type {RecordedCall} */ (calls.at(-1)).method,
    "removeLabel",
  );
});

test("ignores tide and own checks, but requires at least one real check", async () => {
  const own = [
    run("label / Update CI label", null, "in_progress"),
    run("label-on-success", "failure"),
  ];
  const statuses = { head: [status("pending", "tide")] };
  assert.deepEqual(await simulate({ runs: { head: own }, statuses }), []);
  assert.equal(
    /** @type {RecordedCall} */ (
      (await simulate({ runs: { head: [...own, run()] }, statuses })).at(-1)
    ).method,
    "addLabels",
  );
});

test("empty checks remove a stale label", async () => {
  const calls = await simulate({
    pulls: [{ ...pr(), labels: [{ name: "all-checks-passed" }] }],
  });
  assert.equal(
    /** @type {RecordedCall} */ (calls.at(-1)).method,
    "removeLabel",
  );
});

test("does not ignore another app with a matching check name", async () => {
  const external = {
    ...run("Update CI label", "failure"),
    app: { slug: "external-ci" },
  };
  assert.deepEqual(await simulate({ runs: { head: [run(), external] } }), []);
});

test("fork payload with no PRs falls back to open PRs", async () => {
  const calls = await simulate({
    payload: { workflow_run: { head_sha: "head", pull_requests: [] } },
    runs: { merge: [run()] },
  });
  assert.equal(/** @type {RecordedCall} */ (calls.at(-1)).method, "addLabels");
});

test("updates every PR associated with a status event", async () => {
  const calls = await simulate({
    eventName: "status",
    payload: { sha: "head" },
    pulls: [pr(1), pr(2)],
    associated: [pr(1), pr(2)],
    statuses: { head: [status()] },
  });
  assert.deepEqual(
    calls
      .filter((call) => call.method === "addLabels")
      .map((call) => call.issue_number),
    [1, 2],
  );
});

test("ignores events for an old head", async () => {
  assert.deepEqual(
    await simulate({
      payload: {
        check_run: { head_sha: "old", pull_requests: [{ number: 1 }] },
      },
      runs: { head: [run()] },
    }),
    [],
  );
});

test("new commit clears the label even before checks register", async () => {
  const calls = await simulate({
    eventName: "pull_request_target",
    payload: { action: "synchronize", pull_request: pr() },
    runs: { head: [run()] },
  });
  assert.deepEqual(
    calls.map((call) => call.method),
    ["removeLabel"],
  );
});

test("closed PR clears the label", async () => {
  /** @type {PullRequest} */
  const closed = { ...pr(), state: "closed" };
  const calls = await simulate({
    eventName: "pull_request_target",
    payload: { action: "closed", pull_request: closed },
    pulls: [closed],
  });
  assert.equal(
    /** @type {RecordedCall} */ (calls.at(-1)).method,
    "removeLabel",
  );
});

test("head changing during evaluation prevents addition", async () => {
  const calls = await simulate({
    runs: { head: [run()] },
    snapshots: [pr(), { ...pr(), head: { sha: "new" } }],
  });
  assert.deepEqual(
    calls.map((call) => call.method),
    ["removeLabel"],
  );
});

test("head changing during addition cleans up the label", async () => {
  const calls = await simulate({
    runs: { head: [run()] },
    snapshots: [pr(), pr(), { ...pr(), head: { sha: "new" } }],
  });
  assert.deepEqual(
    calls.map((call) => call.method),
    ["getLabel", "addLabels", "removeLabel"],
  );
});

test("scheduled reconciliation updates all open PRs", async () => {
  const calls = await simulate({
    eventName: "schedule",
    payload: {},
    pulls: [pr(1), pr(2)],
    runs: { head: [run()] },
  });
  assert.equal(calls.filter((call) => call.method === "addLabels").length, 2);
});

test("a failure beyond the first page prevents a label", async () => {
  const many = Array.from({ length: 150 }, (_, index) => run(`job-${index}`));
  many.push(run("last-job", "failure"));
  assert.deepEqual(await simulate({ runs: { head: many } }), []);
});

test("already present label needs no writes", async () => {
  const calls = await simulate({
    pulls: [{ ...pr(), labels: [{ name: "all-checks-passed" }] }],
    runs: { head: [run()] },
  });
  assert.deepEqual(calls, []);
});

test("API read failures prevent adding the label", async () => {
  await assert.rejects(
    simulate({ readError: Object.assign(Error("Forbidden"), { status: 403 }) }),
    /Forbidden/,
  );
});

test("missing label is created; unexpected permission errors fail", async () => {
  const missing = Object.assign(Error("Not found"), { status: 404 });
  const calls = await simulate({
    runs: { head: [run()] },
    errors: { getLabel: missing },
  });
  assert.deepEqual(
    calls.map((call) => call.method),
    ["getLabel", "createLabel", "addLabels"],
  );
  await assert.rejects(
    simulate({
      runs: { head: [run()] },
      errors: { getLabel: Object.assign(Error("Forbidden"), { status: 403 }) },
    }),
    /Forbidden/,
  );
});
