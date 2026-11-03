// @ts-check

// Verify that a pull request description fills in the medik8s pull request
// template (.github/PULL_REQUEST_TEMPLATE.md).
//
// Required sections fail the check when they are empty or too thin. The test
// plan is advisory: an incomplete one asks CodeRabbit for a draft in a single
// sticky comment instead of failing the job.

// -----------------------------------------------------------------------------
// GitHub data types
// -----------------------------------------------------------------------------

/**
 * GitHub response shapes used by this script. Only consumed fields are listed;
 * these declarations require no runtime packages beyond github-script.
 *
 * @typedef {{owner: string, repo: string}} Repository
 */

/**
 * @typedef {Object} PullRequest
 * @property {number} number
 * @property {string | null} body
 * @property {{name: string}[]} labels
 * @property {{login: string}} user
 */

/**
 * @typedef {{id: number, body?: string | null}} IssueComment
 * @typedef {{pull_request?: PullRequest}} EventPayload
 * @typedef {{repo: Repository, eventName: string, payload: EventPayload}} WorkflowContext
 * @typedef {{status?: number}} ApiError
 */

/**
 * @typedef {Object} ActionsCore
 * @property {(message: string) => void} info
 * @property {(message: string) => void} notice
 * @property {(message: string) => void} warning
 * @property {(message: string) => void} setFailed
 */

/**
 * Parameters shared by the GitHub endpoints used below.
 * @typedef {Repository & {issue_number?: number, per_page?: number, body?: string}} ApiParams
 */

/**
 * @template T
 * @typedef {(params: ApiParams) => Promise<{data: T}>} Endpoint
 */

/**
 * The subset of github-script's authenticated Octokit client this module uses.
 * @typedef {Object} GitHubClient
 * @property {<T>(endpoint: Endpoint<T[]>, params: ApiParams) => Promise<T[]>} paginate
 * @property {{issues: {
 *   listComments: Endpoint<IssueComment[]>,
 *   createComment: Endpoint<unknown>
 * }}} rest
 */

// -----------------------------------------------------------------------------
// Template section rules
// -----------------------------------------------------------------------------

/**
 * Values derived from the workflow inputs that the section rules depend on.
 * @typedef {{minWords: number, jira: RegExp}} Rules
 */

/**
 * One section of the pull request template and the bar it has to clear.
 * @typedef {Object} SectionRule
 * @property {string} key Short identifier used in log output.
 * @property {string} title Section heading as written in the template.
 * @property {RegExp} heading Matches the normalized heading of this section.
 * @property {boolean} [advisory] Report but do not fail the check.
 * @property {(rules: Rules) => string} requirement Human-readable expectation.
 * @property {(text: string, rules: Rules) => boolean} satisfied Section test.
 */

/** Hidden marker that makes the CodeRabbit request a single sticky comment. */
const COMMENT_MARKER = "<!-- medik8s-pr-description-check -->";

const TEMPLATE_URL =
  "https://github.com/medik8s/.github/blob/main/.github/PULL_REQUEST_TEMPLATE.md";

/** Issue number, `org/repo#123`, and GitHub issue or pull request links. */
const GITHUB_ISSUE =
  /#\d+\b|https?:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:issues|pull)\/\d+\b/;

/**
 * Count whitespace-separated tokens that carry at least one alphanumeric
 * character, so that bullet markers and punctuation do not pad a section.
 * @param {string} text
 * @returns {number}
 */
const wordCount = (text) => (text.match(/\S*[A-Za-z0-9]\S*/g) ?? []).length;

/**
 * @param {string} text
 * @param {Rules} rules
 * @returns {boolean}
 */
const hasTracker = (text, rules) =>
  rules.jira.test(text) || GITHUB_ISSUE.test(text);

/** @type {SectionRule[]} */
const SECTIONS = [
  {
    key: "why",
    title: "Why we need this PR",
    heading: /^why we need this pr/,
    requirement: ({ minWords }) =>
      `a Jira key (for example RHWA-4444), a GitHub issue reference ` +
      `(for example #123), or at least ${minWords} words of explanation`,
    satisfied: (text, rules) =>
      hasTracker(text, rules) || wordCount(text) >= rules.minWords,
  },
  {
    key: "changes",
    title: "Changes made",
    heading: /^changes made/,
    requirement: () => "a description of the changes, of any length",
    satisfied: (text) => wordCount(text) > 0,
  },
  {
    key: "issues",
    title: "Which issue(s) this PR fixes",
    heading: /^which issue/,
    requirement: () =>
      "a GitHub issue reference (for example `Fixes #123`) or a Jira key " +
      "(for example RHWA-4444)",
    satisfied: (text, rules) => hasTracker(text, rules),
  },
  {
    key: "test-plan",
    title: "Test plan",
    heading: /^test plan/,
    advisory: true,
    requirement: ({ minWords }) =>
      `at least ${minWords} words describing how the change was verified`,
    satisfied: (text, { minWords }) => wordCount(text) >= minWords,
  },
];

// -----------------------------------------------------------------------------
// Description parsing
// -----------------------------------------------------------------------------

/** Markdown ATX heading, with optional indentation and closing hashes. */
const HEADING = /^[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$/;

/**
 * Reduce a heading to a stable form so that casing, trailing colons, and
 * repeated spaces do not hide a section.
 * @param {string} heading
 * @returns {string}
 */
const normalizeHeading = (heading) =>
  heading
    .replace(/[*_`]/g, "")
    .replace(/\s+/g, " ")
    .replace(/[\s:]+$/, "")
    .trim()
    .toLowerCase();

/**
 * Split a pull request body into its template sections, dropping the HTML
 * comments that the template uses for author guidance. Sections that the
 * author left untouched therefore read as empty.
 * @param {string} body
 * @returns {{heading: string, text: string}[]}
 */
const parseSections = (body) => {
  const withoutComments = body
    .replace(/<!--[\s\S]*?-->/g, "\n")
    .replace(/\r\n?/g, "\n");

  /** @type {{heading: string, lines: string[]}[]} */
  const sections = [];

  for (const line of withoutComments.split("\n")) {
    const heading = HEADING.exec(line);

    if (heading) {
      sections.push({ heading: normalizeHeading(heading[2]), lines: [] });
      continue;
    }

    sections.at(-1)?.lines.push(line);
  }

  return sections.map(({ heading, lines }) => ({
    heading,
    text: lines.join("\n").trim(),
  }));
};

// -----------------------------------------------------------------------------
// Workflow input parsing
// -----------------------------------------------------------------------------

/**
 * @returns {Rules}
 */
const readRules = () => {
  const minWords = Number(process.env.MIN_WORDS);

  if (!Number.isInteger(minWords) || minWords < 1) {
    throw new Error("min-words must be a positive integer");
  }

  const projects = (process.env.JIRA_PROJECTS ?? "")
    .split(/[,\s]+/)
    .filter(Boolean)
    .map((project) => project.replace(/[^A-Za-z0-9]/g, ""));

  if (projects.length === 0) {
    throw new Error("jira-projects must list at least one project key");
  }

  return {
    minWords,
    jira: new RegExp(`\\b(?:${projects.join("|")})-\\d+\\b`, "i"),
  };
};

// -----------------------------------------------------------------------------
// CodeRabbit test plan request
// -----------------------------------------------------------------------------

/**
 * Ask CodeRabbit to draft a test plan, once per pull request. A fork's
 * `pull_request` token is read only, so a rejected write degrades to a notice
 * rather than failing an advisory check.
 * @param {{github: GitHubClient, core: ActionsCore, repo: Repository,
 *   pullRequest: PullRequest, requirement: string}} dependencies
 * @returns {Promise<void>}
 */
const requestTestPlan = async ({
  github,
  core,
  repo,
  pullRequest,
  requirement,
}) => {
  const comments = await github.paginate(github.rest.issues.listComments, {
    ...repo,
    issue_number: pullRequest.number,
    per_page: 100,
  });

  if (comments.some((comment) => comment.body?.includes(COMMENT_MARKER))) {
    core.info("CodeRabbit test plan request already posted; not repeating it.");
    return;
  }

  const body = [
    COMMENT_MARKER,
    `@coderabbitai please draft a test plan for this pull request: the unit ` +
      `and e2e tests that cover these changes, the manual steps a reviewer ` +
      `can follow to verify them, and the OpenShift e2e job worth running ` +
      `(for example \`/test 4.20-openshift-e2e\`).`,
    "",
    `@${pullRequest.user.login} the \`#### Test plan\` section of the ` +
      `[pull request template](${TEMPLATE_URL}) needs ` +
      `${requirement}. Copy CodeRabbit's draft into the pull ` +
      `request description, edit it to match what you actually ran, and ` +
      `update the description. This is a suggestion and does not block the ` +
      `pull request.`,
  ].join("\n");

  try {
    await github.rest.issues.createComment({
      ...repo,
      issue_number: pullRequest.number,
      body,
    });
    core.info("Asked CodeRabbit to draft a test plan.");
  } catch (error) {
    if (/** @type {ApiError} */ (error).status !== 403) {
      throw error;
    }

    core.notice(
      "Cannot comment on this pull request, so CodeRabbit was not asked for " +
        "a test plan. Fork pull requests get a read-only token; ask " +
        "CodeRabbit directly with `@coderabbitai draft a test plan`.",
    );
  }
};

// -----------------------------------------------------------------------------
// Pull request description check
// -----------------------------------------------------------------------------

/**
 * Check the pull request description against the medik8s template.
 * @param {{github: GitHubClient, context: WorkflowContext, core: ActionsCore}} dependencies
 *   Objects injected by actions/github-script.
 * @returns {Promise<void>}
 */
module.exports = async ({ github, context, core }) => {
  // --- Read the event and the configuration ---

  const pullRequest = context.payload.pull_request;

  if (!pullRequest) {
    core.info("No pull request in the event payload; nothing to check.");
    return;
  }

  const rules = readRules();
  const skipLabel = /** @type {string} */ (process.env.SKIP_LABEL);

  if (pullRequest.labels.some((label) => label.name === skipLabel)) {
    core.notice(
      `Description check skipped: the \`${skipLabel}\` label is applied.`,
    );
    return;
  }

  // --- Evaluate each template section ---

  const sections = parseSections(pullRequest.body ?? "");

  /** @type {{rule: SectionRule, found: boolean, ok: boolean}[]} */
  const results = SECTIONS.map((rule) => {
    const section = sections.find(({ heading }) => rule.heading.test(heading));

    return {
      rule,
      found: section !== undefined,
      ok: section !== undefined && rule.satisfied(section.text, rules),
    };
  });

  for (const { rule, ok } of results) {
    if (ok) {
      core.info(`${rule.title}: ok`);
    }
  }

  // --- Ask CodeRabbit for a test plan when that section is thin ---

  const testPlan = results.find(({ rule }) => rule.key === "test-plan");

  if (testPlan && !testPlan.ok) {
    core.warning(
      `${testPlan.rule.title}: needs ${testPlan.rule.requirement(rules)}. ` +
        "Asking CodeRabbit for a draft; this does not fail the check.",
    );

    await requestTestPlan({
      github,
      core,
      repo: context.repo,
      pullRequest,
      requirement: testPlan.rule.requirement(rules),
    });
  }

  // --- Fail on the required sections ---

  const failures = results.filter(({ rule, ok }) => !ok && !rule.advisory);

  if (failures.length === 0) {
    core.info("The pull request description follows the medik8s template.");
    return;
  }

  const report = failures.map(
    ({ rule, found }) =>
      `- \`#### ${rule.title}\` ${found ? "needs" : "is missing; add it with"} ` +
      rule.requirement(rules),
  );

  core.setFailed(
    [
      `The pull request description does not follow the [medik8s template](${TEMPLATE_URL}):`,
      ...report,
      "",
      "Update the description, then re-run this check. Maintainers can " +
        `bypass it with the \`${skipLabel}\` label.`,
    ].join("\n"),
  );
};
