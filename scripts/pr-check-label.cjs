// @ts-check

// Maintain a PR label that reflects its current CI results.
// Event-triggered runs inspect affected PRs; scheduled runs inspect all open PRs.
// Each PR is checked again before and after labeling to catch new commits.

// -----------------------------------------------------------------------------
// GitHub data types
// -----------------------------------------------------------------------------

/**
 * GitHub response shapes used by this script. Only consumed fields are listed;
 * these declarations require no runtime packages beyond github-script.
 *
 * @typedef {{owner: string, repo: string}} Repository
 * @typedef {{number: number}} PullRequestRef
 */

/**
 * @typedef {Object} PullRequest
 * @property {number} number
 * @property {'open' | 'closed'} state
 * @property {{sha: string}} head
 * @property {string | null} merge_commit_sha
 * @property {{repo: {full_name: string}}} base
 * @property {{name: string}[]} labels
 */

/**
 * @typedef {Object} CheckRun
 * @property {string} name
 * @property {string} status
 * @property {string | null} conclusion
 * @property {{slug?: string} | null} [app]
 */

/**
 * @typedef {{context: string, state: 'pending' | 'success' | 'failure' | 'error'}} CommitStatus
 * @typedef {{name: string, passed: boolean}} CheckResult
 * @typedef {{status?: number}} ApiError
 */

// -----------------------------------------------------------------------------
// Workflow event and GitHub API types
// -----------------------------------------------------------------------------

/**
 * @typedef {{head_sha: string, pull_requests?: PullRequestRef[]}} CheckEvent
 */

/**
 * @typedef {Object} EventPayload
 * @property {PullRequest} [pull_request]
 * @property {CheckEvent} [workflow_run]
 * @property {CheckEvent} [check_run]
 * @property {CheckEvent} [check_suite]
 * @property {string} [sha]
 * @property {string} [action]
 */

/**
 * @typedef {{repo: Repository, eventName: string, payload: EventPayload}} WorkflowContext
 * @typedef {{info: (message: string) => void}} ActionsCore
 */

/**
 * Parameters shared by the GitHub endpoints used below.
 * @typedef {Repository & {
 *   ref?: string, commit_sha?: string, per_page?: number, filter?: string,
 *   state?: string, pull_number?: number, issue_number?: number,
 *   name?: string, labels?: string[], color?: string, description?: string
 * }} ApiParams
 */

/**
 * @template T
 * @typedef {(params: ApiParams) => Promise<{data: T}>} Endpoint
 */

/**
 * The subset of github-script's authenticated Octokit client this module uses.
 * Pagination unwraps both array responses and the check_runs response object.
 * @typedef {Object} GitHubClient
 * @property {<T>(endpoint: Endpoint<T[] | {check_runs: T[]}>, params: ApiParams) => Promise<T[]>} paginate
 * @property {{
 *   pulls: {list: Endpoint<PullRequest[]>, get: Endpoint<PullRequest>},
 *   checks: {listForRef: Endpoint<{check_runs: CheckRun[]}>},
 *   repos: {
 *     listPullRequestsAssociatedWithCommit: Endpoint<PullRequestRef[]>,
 *     listCommitStatusesForRef: Endpoint<CommitStatus[]>
 *   },
 *   issues: {
 *     removeLabel: Endpoint<unknown>, getLabel: Endpoint<unknown>,
 *     createLabel: Endpoint<unknown>, addLabels: Endpoint<unknown>
 *   }
 * }} rest
 */

// -----------------------------------------------------------------------------
// PR label reconciliation
// -----------------------------------------------------------------------------

/**
 * Reconcile the CI label for PRs affected by an event, or all open PRs on a scan.
 * @param {{github: GitHubClient, context: WorkflowContext, core: ActionsCore}} dependencies
 *   Objects injected by actions/github-script.
 * @returns {Promise<void>}
 */
module.exports = async ({ github, context, core }) => {
  // --- Read the label configuration ---

  const repo = context.repo;
  const labelName = /** @type {string} */ (process.env.LABEL_NAME);

  /** @type {unknown} */
  const parsedIgnoredChecks = JSON.parse(
    /** @type {string} */ (process.env.IGNORED_CHECKS),
  );

  if (
    !Array.isArray(parsedIgnoredChecks) ||
    parsedIgnoredChecks.some((name) => typeof name !== "string")
  ) {
    throw new Error("ignored-checks must be a JSON array of strings");
  }

  const ignoredChecks = new Set(/** @type {string[]} */ (parsedIgnoredChecks));

  // --- Find the PRs affected by this event ---

  const eventPayload = context.payload;

  const eventSha =
    eventPayload.pull_request?.head.sha ||
    eventPayload.workflow_run?.head_sha ||
    eventPayload.check_run?.head_sha ||
    eventPayload.check_suite?.head_sha ||
    eventPayload.sha;

  const eventPulls = eventPayload.pull_request
    ? [eventPayload.pull_request]
    : eventPayload.workflow_run?.pull_requests ||
      eventPayload.check_run?.pull_requests ||
      eventPayload.check_suite?.pull_requests ||
      [];

  // Start with the PRs included in the webhook payload. These are PRs whose
  // labels may need updating; we still verify each PR's current commit below.
  let candidates = eventPulls;

  // If the event identifies a commit but provides no PRs, ask GitHub which PRs
  // are associated with that commit. Status events and some fork PR events
  // need this lookup. paginate retrieves every page of associated PRs.
  if (!candidates.length && eventSha) {
    candidates = await github.paginate(
      github.rest.repos.listPullRequestsAssociatedWithCommit,
      {
        ...repo,
        commit_sha: eventSha,
        per_page: 100,
      },
    );
  }

  // If neither the payload nor the commit lookup identifies any PRs, fetch all
  // open PRs as a fallback. For a commit event, the loop below skips PRs whose
  // current head or test merge commit does not match eventSha.
  // Scheduled and manual runs have no eventSha, so they evaluate all open PRs.
  if (!candidates.length) {
    candidates = await github.paginate(github.rest.pulls.list, {
      ...repo,
      state: "open",
      per_page: 100,
    });
  }

  // --- Check filtering and label removal helpers ---

  /** @param {CheckRun} run @returns {boolean} */
  const isLabelCheck = (run) =>
    run.app?.slug === "github-actions" &&
    ["Update CI label", "label-on-success"].some(
      (name) => run.name === name || run.name.endsWith(` / ${name}`),
    );

  /** @param {number} number @returns {Promise<void>} */
  const removeLabel = async (number) => {
    try {
      await github.rest.issues.removeLabel({
        ...repo,
        issue_number: number,
        name: labelName,
      });
    } catch (error) {
      if (/** @type {ApiError} */ (error).status !== 404) {
        throw error;
      }
    }
  };

  // --- Evaluate each PR once ---

  for (const number of new Set(candidates.map((pr) => pr.number))) {
    // Ignore PRs from other repositories and events for older commits.

    const { data: pr } = await github.rest.pulls.get({
      ...repo,
      pull_number: number,
    });

    if (
      pr.base.repo.full_name.toLowerCase() !==
      `${repo.owner}/${repo.repo}`.toLowerCase()
    ) {
      core.info(
        `PR #${number}: skipping because base repository ${pr.base.repo.full_name} does not match ${repo.owner}/${repo.repo}`,
      );

      continue;
    }

    if (
      eventSha &&
      eventSha !== pr.head.sha &&
      eventSha !== pr.merge_commit_sha
    ) {
      core.info(
        `PR #${number}: skipping event for commit ${eventSha}; current head is ${pr.head.sha} and test merge commit is ${pr.merge_commit_sha}`,
      );

      continue;
    }

    // A closed PR or a new commit immediately clears the previous CI label.

    if (
      pr.state !== "open" ||
      (context.eventName === "pull_request_target" &&
        eventPayload.action === "synchronize")
    ) {
      const reason =
        pr.state !== "open" ? "the PR is closed" : "a new commit was pushed";
      core.info(`PR #${number}: clearing "${labelName}" because ${reason}`);

      await removeLabel(number);

      continue;
    }

    // --- Collect CI results from the head and test merge commits ---

    /** @type {CheckResult[]} */
    const checks = [];

    // pull_request workflows may report on the test merge commit.
    const refs = /** @type {string[]} */ ([
      ...new Set([pr.head.sha, pr.merge_commit_sha].filter(Boolean)),
    ]);

    for (const ref of refs) {
      /** @type {CheckRun[]} */
      let runs;

      /** @type {CommitStatus[]} */
      let statuses;

      try {
        [runs, statuses] = await Promise.all([
          github.paginate(github.rest.checks.listForRef, {
            ...repo,
            ref,
            filter: "latest",
            per_page: 100,
          }),
          github.paginate(github.rest.repos.listCommitStatusesForRef, {
            ...repo,
            ref,
            per_page: 100,
          }),
        ]);
      } catch (error) {
        // A test merge commit may not exist yet for a conflicting PR.
        if (
          /** @type {ApiError} */ (error).status !== 404 ||
          ref === pr.head.sha
        ) {
          throw error;
        }

        continue;
      }

      // GitHub check runs: keep CI checks and exclude our own labeling job.

      for (const run of runs) {
        if (!ignoredChecks.has(run.name) && !isLabelCheck(run)) {
          checks.push({
            name: run.name,
            passed: run.status === "completed" && run.conclusion === "success",
          });
        }
      }

      // Legacy CI statuses: keep only the latest result for each context.
      // Status history is newest first: a successful retest replaces
      // its previous failure rather than being counted alongside it.

      /** @type {Map<string, CommitStatus>} */
      const latestStatuses = new Map();

      for (const status of statuses) {
        if (!latestStatuses.has(status.context)) {
          latestStatuses.set(status.context, status);
        }
      }

      for (const status of latestStatuses.values()) {
        if (!ignoredChecks.has(status.context)) {
          checks.push({
            name: status.context,
            passed: status.state === "success",
          });
        }
      }
    }

    // --- Decide whether every reported CI check passed ---

    const allPassed =
      checks.length > 0 && checks.every((check) => check.passed);

    core.info(
      `PR #${number}: ${checks.length} reported checks, all passed: ${allPassed}`,
    );

    for (const check of checks) {
      core.info(`  ${check.name}: ${check.passed ? "passed" : "not passed"}`);
    }

    // --- Verify that the PR still matches the checks we evaluated ---

    // Re-read before changing the label in case a new commit arrived.
    const { data: current } = await github.rest.pulls.get({
      ...repo,
      pull_number: number,
    });

    if (
      current.state !== "open" ||
      current.head.sha !== pr.head.sha ||
      current.merge_commit_sha !== pr.merge_commit_sha
    ) {
      await removeLabel(number);

      continue;
    }

    // --- Remove the label while checks are pending or unsuccessful ---

    const hasLabel = current.labels.some((label) => label.name === labelName);

    if (!allPassed) {
      if (hasLabel) {
        await removeLabel(number);
      }

      continue;
    }

    if (hasLabel) {
      continue;
    }

    // --- Create the repository label if it does not exist yet ---

    try {
      await github.rest.issues.getLabel({ ...repo, name: labelName });
    } catch (error) {
      if (/** @type {ApiError} */ (error).status !== 404) {
        throw error;
      }

      try {
        await github.rest.issues.createLabel({
          ...repo,
          name: labelName,
          color: "0e8a16",
          description: "All reported CI checks have passed",
        });
      } catch (createError) {
        // Another PR evaluation may have created it concurrently.
        if (/** @type {ApiError} */ (createError).status !== 422) {
          throw createError;
        }

        await github.rest.issues.getLabel({ ...repo, name: labelName });
      }
    }

    // --- Add the label and check once more for new commits ---

    await github.rest.issues.addLabels({
      ...repo,
      issue_number: number,
      labels: [labelName],
    });

    // Clean up if the head changed while the label was being added.
    const { data: after } = await github.rest.pulls.get({
      ...repo,
      pull_number: number,
    });

    if (
      after.state !== "open" ||
      after.head.sha !== pr.head.sha ||
      after.merge_commit_sha !== pr.merge_commit_sha
    ) {
      await removeLabel(number);
    }
  }
};
