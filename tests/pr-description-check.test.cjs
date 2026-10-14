// @ts-check

/**
 * Reuse the script's consumed GitHub response types for realistic fixtures.
 * @typedef {import('../scripts/pr-description-check.cjs').PullRequest} PullRequest
 * @typedef {import('../scripts/pr-description-check.cjs').IssueComment} IssueComment
 * @typedef {import('../scripts/pr-description-check.cjs').ApiParams} ApiParams
 * @typedef {import('../scripts/pr-description-check.cjs').ApiError} ApiError
 * @typedef {import('../scripts/pr-description-check.cjs').EventPayload} EventPayload
 * @typedef {import('../scripts/pr-description-check.cjs').WorkflowContext} WorkflowContext
 * @typedef {import('../scripts/pr-description-check.cjs').GitHubClient} GitHubClient
 * @typedef {Object} SimulationOptions
 * @property {string | null} [body] Pull request description to evaluate.
 * @property {string[]} [labels] Labels applied to the pull request.
 * @property {IssueComment[]} [comments] Comments already on the pull request.
 * @property {Error & ApiError} [commentError] Error thrown by createComment.
 * @property {EventPayload} [payload] Webhook payload override.
 * @typedef {Object} Outcome
 * @property {string[]} comments Comment bodies posted by the script.
 * @property {string | undefined} failure Message passed to core.setFailed.
 * @property {string[]} notices Messages passed to core.notice.
 * @property {string[]} warnings Messages passed to core.warning.
 */

const { test } = require("node:test");
const assert = require("node:assert/strict");
const check = require("../scripts/pr-description-check.cjs");

process.env.MIN_WORDS = "15";
process.env.JIRA_PROJECTS = "RHWA,OCPBUGS";
process.env.SKIP_LABEL = "skip-pr-description-check";

const FIFTEEN_WORDS =
  "This change reconciles the remediation template so that the controller " +
  "stops requeueing unhealthy nodes forever.";

/**
 * Build a description from the four template sections.
 * @param {{why?: string, changes?: string, issues?: string, plan?: string}} sections
 * @returns {string}
 */
const body = ({ why = "", changes = "", issues = "", plan = "" }) =>
  [
    "#### Why we need this PR",
    "<!-- Outline the purpose of this PR. -->",
    why,
    "",
    "#### Changes made",
    changes,
    "",
    "#### Which issue(s) this PR fixes",
    issues,
    "",
    "#### Test plan",
    plan,
  ].join("\n");

/** A description where every section passes, for single-section variation. */
const complete = {
  why: "Fixes #42",
  changes: "Drop the duplicate watch.",
  issues: "Fixes #42",
  plan: FIFTEEN_WORDS,
};

/**
 * Run the production module against fixtures and record its observable effects.
 * @param {SimulationOptions} [options]
 * @returns {Promise<Outcome>}
 */
const simulate = async (options = {}) => {
  const {
    body: description = body(complete),
    labels = [],
    comments = [],
    commentError,
    payload,
  } = options;

  /** @type {string[]} */
  const posted = [];
  /** @type {Outcome} */
  const outcome = {
    comments: posted,
    failure: undefined,
    notices: [],
    warnings: [],
  };

  /** @type {GitHubClient} */
  const github = {
    paginate: async () =>
      /** @type {never[]} */ (/** @type {unknown} */ (comments)),
    rest: {
      issues: {
        listComments: async () => ({ data: comments }),
        createComment: async ({ body: posting }) => {
          if (commentError) {
            throw commentError;
          }

          posted.push(/** @type {string} */ (posting));
          return { data: {} };
        },
      },
    },
  };

  /** @type {WorkflowContext} */
  const context = {
    repo: { owner: "medik8s", repo: "self-node-remediation" },
    eventName: "pull_request",
    payload: payload ?? {
      pull_request: {
        number: 7,
        body: description,
        labels: labels.map((name) => ({ name })),
        user: { login: "contributor" },
      },
    },
  };

  await check({
    github,
    context,
    core: {
      info: () => {},
      notice: (message) => outcome.notices.push(message),
      warning: (message) => outcome.warnings.push(message),
      setFailed: (message) => {
        outcome.failure = message;
      },
    },
  });

  return outcome;
};

test("a complete description passes without commenting", async () => {
  const outcome = await simulate();
  assert.equal(outcome.failure, undefined);
  assert.deepEqual(outcome.comments, []);
  assert.deepEqual(outcome.warnings, []);
});

test("an untouched template fails on every required section", async () => {
  const outcome = await simulate({ body: body({}) });
  assert.match(/** @type {string} */ (outcome.failure), /Why we need this PR/);
  assert.match(/** @type {string} */ (outcome.failure), /Changes made/);
  assert.match(/** @type {string} */ (outcome.failure), /Which issue/);
  // The test plan is advisory and must not appear among the failures.
  assert.doesNotMatch(/** @type {string} */ (outcome.failure), /Test plan/);
});

test("a missing section fails the same way as an empty one", async () => {
  const outcome = await simulate({ body: "Just a sentence, no headings." });
  assert.match(
    /** @type {string} */ (outcome.failure),
    /`#### Why we need this PR` is missing/,
  );
});

test("the why section accepts a Jira key, an issue, or enough words", async () => {
  for (const why of [
    "rhwa-4444",
    "OCPBUGS-1234",
    "Fixes #42",
    "https://github.com/medik8s/self-node-remediation/issues/42",
    FIFTEEN_WORDS,
  ]) {
    const outcome = await simulate({ body: body({ ...complete, why }) });
    assert.equal(outcome.failure, undefined, `rejected: ${why}`);
  }

  const outcome = await simulate({
    body: body({ ...complete, why: "bugfix" }),
  });
  assert.match(/** @type {string} */ (outcome.failure), /Why we need this PR/);
});

test("an unlisted Jira project is not an issue reference", async () => {
  const outcome = await simulate({
    body: body({ ...complete, why: "NOTAPROJECT-1", issues: "NOTAPROJECT-1" }),
  });
  assert.match(/** @type {string} */ (outcome.failure), /Which issue/);
});

test("the changes section accepts any text but not emptiness", async () => {
  const brief = await simulate({
    body: body({ ...complete, changes: "typo" }),
  });
  assert.equal(brief.failure, undefined);

  const bare = await simulate({ body: body({ ...complete, changes: "- -" }) });
  assert.match(/** @type {string} */ (bare.failure), /Changes made/);
});

test("the issue section requires a reference, not prose", async () => {
  const prose = await simulate({
    body: body({ ...complete, issues: `No issue. ${FIFTEEN_WORDS}` }),
  });
  assert.match(/** @type {string} */ (prose.failure), /Which issue/);

  const jira = await simulate({
    body: body({ ...complete, issues: "Fixes RHWA-4444" }),
  });
  assert.equal(jira.failure, undefined);
});

test("a thin test plan asks CodeRabbit but does not fail", async () => {
  const outcome = await simulate({
    body: body({ ...complete, plan: "tested locally" }),
  });
  assert.equal(outcome.failure, undefined);
  assert.equal(outcome.comments.length, 1);
  assert.match(outcome.comments[0], /@coderabbitai/);
  assert.match(outcome.comments[0], /@contributor/);
  assert.equal(outcome.warnings.length, 1);
});

test("the CodeRabbit request is posted only once per pull request", async () => {
  const outcome = await simulate({
    body: body({ ...complete, plan: "" }),
    comments: [
      { id: 1, body: "unrelated review comment" },
      {
        id: 2,
        body: "<!-- medik8s-pr-description-check -->\n@coderabbitai ...",
      },
    ],
  });
  assert.deepEqual(outcome.comments, []);
});

test("a read-only fork token degrades to a notice", async () => {
  const outcome = await simulate({
    body: body({ ...complete, plan: "" }),
    commentError: Object.assign(Error("Resource not accessible"), {
      status: 403,
    }),
  });
  assert.equal(outcome.failure, undefined);
  assert.match(outcome.notices.join("\n"), /read-only token/);

  await assert.rejects(
    simulate({
      body: body({ ...complete, plan: "" }),
      commentError: Object.assign(Error("Server error"), { status: 500 }),
    }),
    /Server error/,
  );
});

test("the skip label bypasses the check entirely", async () => {
  const outcome = await simulate({
    body: body({}),
    labels: ["skip-pr-description-check"],
  });
  assert.equal(outcome.failure, undefined);
  assert.deepEqual(outcome.comments, []);
  assert.match(outcome.notices.join("\n"), /skip-pr-description-check/);
});

test("a non-pull-request event is ignored", async () => {
  const outcome = await simulate({ payload: {} });
  assert.equal(outcome.failure, undefined);
  assert.deepEqual(outcome.comments, []);
});

test("template guidance comments do not count as content", async () => {
  const outcome = await simulate({
    body: [
      "#### Why we need this PR",
      "<!--",
      `Outline the purpose of this PR. ${FIFTEEN_WORDS} ${FIFTEEN_WORDS}`,
      "-->",
      "",
      "#### Changes made",
      "<!-- Outline the specific changes made. -->",
    ].join("\n"),
  });
  assert.match(/** @type {string} */ (outcome.failure), /Why we need this PR/);
  assert.match(/** @type {string} */ (outcome.failure), /Changes made/);
});
