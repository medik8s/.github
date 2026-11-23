// @ts-check

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  DAILY_START,
  DAILY_END,
  classifyCron,
  applyDailyAutoBlock,
  renderDailySection,
  renderWeeklyPage,
  renderAllJobsPage,
  discoverJobFiles,
  loadAllJobs,
  updateWiki,
} = require("../scripts/wiki-ci-status.cjs");

test("classifyCron distinguishes daily, weekly, and other", () => {
  assert.equal(classifyCron("0 4 * * *"), "daily");
  assert.equal(classifyCron("30 9 * * *"), "daily");
  assert.equal(classifyCron("0 4 * * 1"), "weekly");
  assert.equal(classifyCron("0 12 * * 3"), "weekly");
  assert.equal(classifyCron("0 12 1 * *"), "other");
  assert.equal(classifyCron("invalid"), "other");
});

test("applyDailyAutoBlock prepends when markers are missing", () => {
  const next = applyDailyAutoBlock(
    "# Manual\n\nKeep me.\n",
    "# Current CI Status\n\ndaily\n",
  );
  assert.match(next, new RegExp(`^${escapeRegex(DAILY_START)}`));
  assert.match(next, /# Current CI Status/);
  assert.match(next, /# Manual/);
  assert.match(next, /Keep me\./);
  assert.ok(next.indexOf(DAILY_START) < next.indexOf("# Manual"));
});

test("applyDailyAutoBlock replaces only the marked block", () => {
  const existing = [
    DAILY_START,
    "old daily",
    DAILY_END,
    "",
    "## Previous Versions",
    "",
    "keep",
    "",
  ].join("\n");
  const next = applyDailyAutoBlock(existing, "new daily\n");
  assert.match(next, /new daily/);
  assert.doesNotMatch(next, /old daily/);
  assert.match(next, /## Previous Versions/);
  assert.match(next, /\nkeep\n/);
});

test("renderers include expected headings and no badges on All Jobs", () => {
  /** @type {import('../scripts/wiki-ci-status.cjs').DiscoveredJob[]} */
  const jobs = [
    {
      name: "periodic-ci-openshift-rhwa-system-tests-main-5.0-upstream-e2e-far-daily-aws",
      type: "periodic",
      org: "openshift",
      repo: "rhwa-system-tests",
      component: "rhwa-system-tests",
      variant: "5.0-upstream",
      target: "e2e-far-daily-aws",
      cron: "0 4 * * *",
      scheduleClass: "daily",
      sourceFile: "x",
    },
    {
      name: "periodic-ci-medik8s-fence-agents-remediation-main-5.0-e2e-system-tests-far-fbc-upgrade",
      type: "periodic",
      org: "medik8s",
      repo: "fence-agents-remediation",
      component: "fence-agents-remediation",
      variant: "5.0",
      target: "e2e-system-tests-far-fbc-upgrade",
      cron: "30 9 * * *",
      scheduleClass: "daily",
      sourceFile: "x",
    },
    {
      name: "periodic-ci-openshift-rhwa-system-tests-main-5.0-konflux-e2e-far-aws",
      type: "periodic",
      org: "openshift",
      repo: "rhwa-system-tests",
      component: "rhwa-system-tests",
      variant: "5.0-konflux",
      target: "e2e-far-aws",
      cron: "0 16 * * 2",
      scheduleClass: "weekly",
      sourceFile: "x",
    },
    {
      name: "pull-ci-openshift-rhwa-system-tests-main-5.0-upstream-e2e-far-aws",
      type: "presubmit",
      org: "openshift",
      repo: "rhwa-system-tests",
      component: "rhwa-system-tests",
      variant: "5.0-upstream",
      target: "e2e-far-aws",
      optional: true,
      alwaysRun: false,
      sourceFile: "x",
    },
  ];

  const daily = renderDailySection(jobs);
  assert.match(daily, /Current CI Status/);
  assert.match(daily, /^## Version 5\.0$/m);
  assert.match(daily, /^### upstream$/m);
  assert.match(daily, /#### Operators/);
  assert.match(daily, /e2e-far-daily-aws/);
  assert.match(
    daily,
    /badge\.svg\?jobs=periodic-ci-openshift-rhwa-system-tests-main-5\.0-upstream-e2e-far-daily-aws/,
  );
  assert.match(
    daily,
    /job-history\/gs\/origin-ci-test\/logs\/periodic-ci-openshift-rhwa-system-tests-main-5\.0-upstream-e2e-far-daily-aws/,
  );
  assert.doesNotMatch(daily, /fbc-upgrade/);
  assert.doesNotMatch(daily, /konflux/);
  assert.doesNotMatch(daily, /## FAR/);

  const weekly = renderWeeklyPage(jobs);
  assert.match(weekly, /Weekly CI Status/);
  assert.match(weekly, /^## Version 5\.0$/m);
  assert.match(weekly, /^### konflux$/m);
  assert.match(weekly, /0 16 \* \* 2/);

  const allJobs = renderAllJobsPage(jobs);
  assert.match(allJobs, /All Jobs/);
  assert.match(allJobs, /^## PRs \(general\)$/m);
  assert.match(allJobs, /^## PRs \(by operator\)$/m);
  assert.match(allJobs, /^## Periodics$/m);
  assert.match(allJobs, /^## Other$/m);
  assert.match(allJobs, /presubmit/);
  assert.match(
    allJobs,
    /pull-ci-openshift-rhwa-system-tests-main-5\.0-upstream-e2e-far-aws/,
  );
  assert.doesNotMatch(allJobs, /job-history/);
  const generalIdx = allJobs.indexOf("## PRs (general)");
  const periodicsIdx = allJobs.indexOf("## Periodics");
  const pullIdx = allJobs.indexOf(
    "pull-ci-openshift-rhwa-system-tests-main-5.0-upstream-e2e-far-aws",
  );
  const farDailyIdx = allJobs.indexOf(
    "periodic-ci-openshift-rhwa-system-tests-main-5.0-upstream-e2e-far-daily-aws",
  );
  assert.ok(generalIdx < pullIdx && pullIdx < periodicsIdx);
  assert.ok(periodicsIdx < farDailyIdx);
});

test("version/variant helpers and WAO/interop buckets", () => {
  const {
    versionFromVariant,
    variantDisplayName,
    jobBucket,
    compareVersionsDesc,
  } = require("../scripts/wiki-ci-status.cjs");
  assert.equal(versionFromVariant("5.0-upstream"), "5.0");
  assert.equal(versionFromVariant("4.22-konflux"), "4.22");
  assert.equal(versionFromVariant("5.0"), "5.0");
  assert.equal(versionFromVariant(""), "(no version)");
  assert.equal(variantDisplayName("5.0", "5.0-upstream"), "upstream");
  assert.equal(variantDisplayName("5.0", "5.0"), "default");
  assert.ok(compareVersionsDesc("5.0", "4.22") < 0);

  assert.equal(
    jobBucket({
      name: "periodic-ci-medik8s-workload-availability-operator-wao-5.0-install-wao-nmo-daily-aws",
      component: "workload-availability-operator",
      target: "install-wao-nmo-daily-aws",
    }),
    "wao",
  );
  assert.equal(
    jobBucket({
      name: "periodic-ci-openshift-rhwa-system-tests-main-5.0-konflux-e2e-far-nhc-interop-aws",
      component: "rhwa-system-tests",
      target: "e2e-far-nhc-interop-aws",
    }),
    "interop",
  );
  assert.equal(
    jobBucket({
      name: "periodic-ci-openshift-rhwa-system-tests-main-5.0-upstream-e2e-far-daily-aws",
      component: "rhwa-system-tests",
      target: "e2e-far-daily-aws",
    }),
    "operators",
  );
});

const releaseRoot = process.env.RELEASE_DIR;
const releaseAvailable = Boolean(
  releaseRoot && fs.existsSync(String(releaseRoot)),
);

test(
  "discoverJobFiles finds rhwa and medik8s yaml when release fixture exists",
  {
    skip: releaseAvailable
      ? false
      : "set RELEASE_DIR to an openshift/release checkout",
  },
  () => {
    const files = discoverJobFiles(/** @type {string} */ (releaseRoot));
    assert.ok(files.some((file) => file.includes("rhwa-system-tests")));
    assert.ok(files.some((file) => file.includes("fence-agents-remediation")));
    assert.ok(
      !files.some((file) => /system-tests\/OWNERS$/.test(file)),
      "OWNERS-only dirs must not contribute files",
    );

    const jobs = loadAllJobs(/** @type {string} */ (releaseRoot));
    assert.ok(jobs.length > 0);
    assert.ok(jobs.some((job) => job.scheduleClass === "daily"));
    assert.ok(jobs.some((job) => job.scheduleClass === "weekly"));
    assert.ok(jobs.some((job) => job.type === "presubmit"));
  },
);

test("updateWiki is idempotent and skips unchanged files", () => {
  const wikiDir = fs.mkdtempSync(path.join(os.tmpdir(), "wiki-ci-"));
  try {
    fs.writeFileSync(
      path.join(wikiDir, "Home.md"),
      "## Previous Versions\n\nmanual\n",
      "utf8",
    );

    /** @type {import('../scripts/wiki-ci-status.cjs').DiscoveredJob[]} */
    const jobs = [
      {
        name: "periodic-ci-medik8s-workload-availability-operator-wao-5.0-install-wao-nmo-daily-aws",
        type: "periodic",
        org: "medik8s",
        repo: "workload-availability-operator",
        component: "workload-availability-operator",
        variant: "5.0",
        target: "install-wao-nmo-daily-aws",
        cron: "0 4 * * *",
        scheduleClass: "daily",
        sourceFile: "x",
      },
    ];

    const first = updateWiki(wikiDir, jobs);
    assert.deepEqual(first.changed.sort(), [
      "All-Jobs.md",
      "Home.md",
      "Weekly-CI-Status.md",
    ]);

    const home = fs.readFileSync(path.join(wikiDir, "Home.md"), "utf8");
    assert.match(home, new RegExp(escapeRegex(DAILY_START)));
    assert.match(home, /Previous Versions/);
    assert.match(home, /manual/);

    const second = updateWiki(wikiDir, jobs);
    assert.deepEqual(second.changed, []);
    assert.deepEqual(second.skipped.sort(), [
      "All-Jobs.md",
      "Home.md",
      "Weekly-CI-Status.md",
    ]);
  } finally {
    fs.rmSync(wikiDir, { recursive: true, force: true });
  }
});

/**
 * @param {string} value
 * @returns {string}
 */
function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
