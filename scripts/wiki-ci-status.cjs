// @ts-check

/**
 * Discover Prow jobs from openshift/release and update the medik8s/.github wiki.
 *
 * Usage:
 *   node scripts/wiki-ci-status.cjs --release-dir DIR --wiki-dir DIR [--dry-run]
 */

const fs = require("node:fs");
const path = require("node:path");
const yaml = require("js-yaml");

/** @typedef {'periodic' | 'presubmit'} JobType */
/** @typedef {'daily' | 'weekly' | 'other'} ScheduleClass */

/**
 * @typedef {Object} DiscoveredJob
 * @property {string} name
 * @property {JobType} type
 * @property {string} org
 * @property {string} repo
 * @property {string} component
 * @property {string} variant
 * @property {string} [branch]
 * @property {string} [target]
 * @property {string} [cron]
 * @property {ScheduleClass} [scheduleClass]
 * @property {boolean} [optional]
 * @property {boolean} [alwaysRun]
 * @property {string} sourceFile
 */

const DAILY_START = "<!-- AUTO-GENERATED:DAILY-START -->";
const DAILY_END = "<!-- AUTO-GENERATED:DAILY-END -->";
const HISTORY_BASE =
  "https://prow.ci.openshift.org/job-history/gs/origin-ci-test/logs";
const VARIANT_LABEL = "ci-operator.openshift.io/variant";

/** @type {Record<string, string>} */
const COMPONENT_TITLES = {
  "fence-agents-remediation": "FAR — Fence Agents Remediation",
  "machine-deletion-remediation": "MDR — Machine Deletion Remediation",
  "node-healthcheck-operator": "NHC — Node Health Check",
  "node-maintenance-operator": "NMO — Node Maintenance Operator",
  "self-node-remediation": "SNR — Self Node Remediation",
  "storage-based-remediation": "SBR — Storage Based Remediation",
  "workload-availability-operator": "WAO — Workload Availability Operator",
  "customized-user-remediation": "CUR — Customized User Remediation",
  "must-gather": "Must Gather",
  common: "Common",
  "rhwa-system-tests": "RHWA System Tests",
};

/** Operator repos whose PR jobs go under "PRs by operator". */
const OPERATOR_COMPONENTS = new Set([
  "fence-agents-remediation",
  "machine-deletion-remediation",
  "node-healthcheck-operator",
  "node-maintenance-operator",
  "self-node-remediation",
  "storage-based-remediation",
  "workload-availability-operator",
  "customized-user-remediation",
]);

/** Shared / multi-operator repos whose PR jobs go under "PRs (general)". */
const GENERAL_PR_COMPONENTS = new Set([
  "rhwa-system-tests",
  "common",
  "must-gather",
]);

/** @typedef {'pr-general' | 'pr-operator' | 'periodics' | 'other'} AllJobsCategory */

/**
 * Classify a standard 5-field cron as daily, weekly, or other.
 * @param {string} cron
 * @returns {ScheduleClass}
 */
function classifyCron(cron) {
  const fields = String(cron).trim().split(/\s+/);
  if (fields.length < 5) {
    return "other";
  }

  const dayOfMonth = fields[2];
  const dayOfWeek = fields[4];
  const dowIsWildcard = dayOfWeek === "*";
  const domIsWildcard = dayOfMonth === "*";

  if (domIsWildcard && dowIsWildcard) {
    return "daily";
  }

  if (domIsWildcard && !dowIsWildcard) {
    return "weekly";
  }

  return "other";
}

/**
 * @param {string} releaseDir
 * @returns {string[]}
 */
function discoverJobFiles(releaseDir) {
  /** @type {string[]} */
  const files = [];
  const jobsRoot = path.join(releaseDir, "ci-operator", "jobs");

  const rhwaDir = path.join(jobsRoot, "openshift", "rhwa-system-tests");
  if (fs.existsSync(rhwaDir)) {
    for (const name of fs.readdirSync(rhwaDir)) {
      if (
        name.endsWith("-periodics.yaml") ||
        name.endsWith("-presubmits.yaml")
      ) {
        files.push(path.join(rhwaDir, name));
      }
    }
  }

  const medik8sRoot = path.join(jobsRoot, "medik8s");
  if (!fs.existsSync(medik8sRoot)) {
    return files.sort();
  }

  for (const component of fs.readdirSync(medik8sRoot, {
    withFileTypes: true,
  })) {
    if (!component.isDirectory()) {
      continue;
    }

    const componentDir = path.join(medik8sRoot, component.name);
    const yamlNames = fs
      .readdirSync(componentDir)
      .filter(
        (name) =>
          name.endsWith("-periodics.yaml") || name.endsWith("-presubmits.yaml"),
      );

    for (const name of yamlNames) {
      files.push(path.join(componentDir, name));
    }
  }

  return files.sort();
}

/**
 * @param {unknown} value
 * @returns {Record<string, string>}
 */
function asStringMap(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }

  /** @type {Record<string, string>} */
  const out = {};
  for (const [key, raw] of Object.entries(value)) {
    if (raw === undefined || raw === null) {
      continue;
    }

    out[key] = String(raw);
  }

  return out;
}

/**
 * @param {any} job
 * @returns {string}
 */
function extractTarget(job) {
  const containers = job?.spec?.containers;
  if (!Array.isArray(containers)) {
    return "";
  }

  for (const container of containers) {
    const args = container?.args;
    if (!Array.isArray(args)) {
      continue;
    }

    for (const arg of args) {
      if (typeof arg === "string" && arg.startsWith("--target=")) {
        return arg.slice("--target=".length);
      }
    }
  }

  return "";
}

/**
 * @param {string} sourceFile
 * @returns {{org: string, repo: string, component: string}}
 */
function identityFromPath(sourceFile) {
  const parts = sourceFile.split(path.sep);
  const jobsIdx = parts.lastIndexOf("jobs");
  if (jobsIdx < 0 || parts.length < jobsIdx + 3) {
    return { org: "unknown", repo: "unknown", component: "unknown" };
  }

  const org = parts[jobsIdx + 1];
  const repo = parts[jobsIdx + 2];

  return { org, repo, component: repo };
}

/**
 * @param {string} filePath
 * @returns {DiscoveredJob[]}
 */
function parseJobFile(filePath) {
  const doc = yaml.load(fs.readFileSync(filePath, "utf8"));
  if (!doc || typeof doc !== "object") {
    return [];
  }

  const { org, repo, component } = identityFromPath(filePath);
  /** @type {DiscoveredJob[]} */
  const jobs = [];

  if (Array.isArray(/** @type {any} */ (doc).periodics)) {
    for (const periodic of /** @type {any} */ (doc).periodics) {
      if (!periodic?.name) {
        continue;
      }

      const labels = asStringMap(periodic.labels);
      const cron = periodic.cron ? String(periodic.cron) : "";
      const scheduleClass = cron ? classifyCron(cron) : "other";
      const branch =
        Array.isArray(periodic.extra_refs) && periodic.extra_refs[0]?.base_ref
          ? String(periodic.extra_refs[0].base_ref)
          : undefined;

      if (scheduleClass === "other" && cron) {
        console.warn(
          `warning: periodic ${periodic.name} cron "${cron}" is neither daily nor weekly`,
        );
      }

      jobs.push({
        name: String(periodic.name),
        type: "periodic",
        org,
        repo,
        component,
        variant: labels[VARIANT_LABEL] || "",
        branch,
        target: extractTarget(periodic) || undefined,
        cron,
        scheduleClass,
        sourceFile: filePath,
      });
    }
  }

  const presubmits = /** @type {any} */ (doc).presubmits;
  if (presubmits && typeof presubmits === "object") {
    for (const [repoKey, entries] of Object.entries(presubmits)) {
      if (!Array.isArray(entries)) {
        continue;
      }

      const [entryOrg, entryRepo] = String(repoKey).split("/");
      for (const presubmit of entries) {
        if (!presubmit?.name) {
          continue;
        }

        const labels = asStringMap(presubmit.labels);
        jobs.push({
          name: String(presubmit.name),
          type: "presubmit",
          org: entryOrg || org,
          repo: entryRepo || repo,
          component: entryRepo || component,
          variant: labels[VARIANT_LABEL] || "",
          target: extractTarget(presubmit) || undefined,
          optional: Boolean(presubmit.optional),
          alwaysRun: Boolean(presubmit.always_run),
          sourceFile: filePath,
        });
      }
    }
  }

  return jobs;
}

/**
 * @param {string} releaseDir
 * @returns {DiscoveredJob[]}
 */
function loadAllJobs(releaseDir) {
  /** @type {DiscoveredJob[]} */
  const jobs = [];
  for (const file of discoverJobFiles(releaseDir)) {
    jobs.push(...parseJobFile(file));
  }

  jobs.sort((a, b) => {
    const left = `${a.org}/${a.repo}\0${a.variant}\0${a.name}`;
    const right = `${b.org}/${b.repo}\0${b.variant}\0${b.name}`;

    return left.localeCompare(right);
  });

  return jobs;
}

/**
 * @param {DiscoveredJob} job
 * @returns {string}
 */
function jobHistoryUrl(job) {
  return `${HISTORY_BASE}/${job.name}`;
}

/**
 * @param {DiscoveredJob} job
 * @returns {string}
 */
function displayLabel(job) {
  if (job.target) {
    return job.target;
  }

  return job.name;
}

/**
 * @param {DiscoveredJob} job
 * @returns {string}
 */
function componentTitle(job) {
  return COMPONENT_TITLES[job.component] || job.component;
}

/** @typedef {'operators' | 'wao' | 'interop'} JobBucket */

/**
 * Extract the version prefix from a ci-operator variant (e.g. `5.0-upstream` → `5.0`).
 * @param {string} variant
 * @returns {string}
 */
function versionFromVariant(variant) {
  const match = String(variant || "").match(/^(\d+\.\d+)/);
  if (match) {
    return match[1];
  }

  return variant ? String(variant) : "(no version)";
}

/**
 * Short variant label under a version heading (`5.0-upstream` under `5.0` → `upstream`).
 * @param {string} version
 * @param {string} variant
 * @returns {string}
 */
function variantDisplayName(version, variant) {
  if (!variant || variant === "(no variant)") {
    return "default";
  }

  if (variant === version) {
    return "default";
  }

  const prefix = `${version}-`;
  if (variant.startsWith(prefix)) {
    return variant.slice(prefix.length);
  }

  return variant;
}

/**
 * Compare version strings like `5.0`, `4.22` (newest first).
 * @param {string} left
 * @param {string} right
 * @returns {number}
 */
function compareVersionsDesc(left, right) {
  const leftParts = left.split(".").map((part) => Number(part));
  const rightParts = right.split(".").map((part) => Number(part));
  if (
    leftParts.length >= 2 &&
    rightParts.length >= 2 &&
    leftParts.every((part) => Number.isFinite(part)) &&
    rightParts.every((part) => Number.isFinite(part))
  ) {
    if (leftParts[0] !== rightParts[0]) {
      return rightParts[0] - leftParts[0];
    }

    return rightParts[1] - leftParts[1];
  }

  return left.localeCompare(right);
}

/**
 * Split WAO and interop jobs out of the default operators table.
 * @param {{name: string, component: string, target?: string}} job
 * @returns {JobBucket}
 */
function jobBucket(job) {
  if (job.component === "workload-availability-operator") {
    return "wao";
  }

  const haystack = `${job.name} ${job.target || ""}`;
  if (/\binterop\b/i.test(haystack)) {
    return "interop";
  }

  if (/\bwao\b/i.test(haystack)) {
    return "wao";
  }

  return "operators";
}

/**
 * Operator label for a table row.
 * @param {DiscoveredJob} job
 * @returns {string}
 */
function rowTitle(job) {
  if (job.component === "rhwa-system-tests") {
    const target = job.target || "";
    /** @type {[RegExp, string][]} */
    const patterns = [
      [/\bfar\b/i, COMPONENT_TITLES["fence-agents-remediation"]],
      [/\bmdr\b/i, COMPONENT_TITLES["machine-deletion-remediation"]],
      [/\bnhc\b/i, COMPONENT_TITLES["node-healthcheck-operator"]],
      [/\bnmo\b/i, COMPONENT_TITLES["node-maintenance-operator"]],
      [/\bsnr\b/i, COMPONENT_TITLES["self-node-remediation"]],
      [/\bsbr\b/i, COMPONENT_TITLES["storage-based-remediation"]],
      [/\bwao\b/i, COMPONENT_TITLES["workload-availability-operator"]],
      [/\bcur\b/i, COMPONENT_TITLES["customized-user-remediation"]],
    ];

    for (const [pattern, title] of patterns) {
      if (pattern.test(target)) {
        return title;
      }
    }

    return COMPONENT_TITLES["rhwa-system-tests"];
  }

  return componentTitle(job);
}

/**
 * @param {DiscoveredJob[]} jobs
 */
function sortJobs(jobs) {
  jobs.sort((left, right) => {
    const byOperator = rowTitle(left).localeCompare(rowTitle(right));
    if (byOperator !== 0) {
      return byOperator;
    }

    return left.name.localeCompare(right.name);
  });
}

/**
 * Group jobs as version → variant → jobs.
 * @param {DiscoveredJob[]} jobs
 * @param {(job: DiscoveredJob) => boolean} [predicate]
 * @returns {Map<string, Map<string, DiscoveredJob[]>>}
 */
function groupByVersionVariant(jobs, predicate = () => true) {
  /** @type {Map<string, Map<string, DiscoveredJob[]>>} */
  const grouped = new Map();

  for (const job of jobs) {
    if (!predicate(job)) {
      continue;
    }

    const variantKey = job.variant || "(no variant)";
    const versionKey = versionFromVariant(variantKey);
    if (!grouped.has(versionKey)) {
      grouped.set(versionKey, new Map());
    }

    const variants = /** @type {Map<string, DiscoveredJob[]>} */ (
      grouped.get(versionKey)
    );
    if (!variants.has(variantKey)) {
      variants.set(variantKey, []);
    }

    /** @type {DiscoveredJob[]} */ (variants.get(variantKey)).push(job);
  }

  /** @type {Map<string, Map<string, DiscoveredJob[]>>} */
  const ordered = new Map();
  const versions = [...grouped.keys()].sort(compareVersionsDesc);
  for (const version of versions) {
    const variants = /** @type {Map<string, DiscoveredJob[]>} */ (
      grouped.get(version)
    );
    /** @type {Map<string, DiscoveredJob[]>} */
    const orderedVariants = new Map();
    for (const variant of [...variants.keys()].sort()) {
      const variantJobs = /** @type {DiscoveredJob[]} */ (
        variants.get(variant)
      );
      sortJobs(variantJobs);
      orderedVariants.set(variant, variantJobs);
    }

    ordered.set(version, orderedVariants);
  }

  return ordered;
}

/**
 * @param {DiscoveredJob[]} jobs
 * @returns {{operators: DiscoveredJob[], wao: DiscoveredJob[], interop: DiscoveredJob[]}}
 */
function splitBuckets(jobs) {
  /** @type {{operators: DiscoveredJob[], wao: DiscoveredJob[], interop: DiscoveredJob[]}} */
  const buckets = { operators: [], wao: [], interop: [] };
  for (const job of jobs) {
    buckets[jobBucket(job)].push(job);
  }

  sortJobs(buckets.operators);
  sortJobs(buckets.wao);
  sortJobs(buckets.interop);

  return buckets;
}

/**
 * @param {DiscoveredJob[]} jobs
 * @param {{includeCron?: boolean, linkStatus?: boolean, detailed?: boolean}} options
 * @returns {string[]}
 */
function renderJobTable(jobs, options) {
  if (jobs.length === 0) {
    return [];
  }

  const includeCron = Boolean(options.includeCron);
  const linkStatus = options.linkStatus !== false;
  const detailed = Boolean(options.detailed);
  /** @type {string[]} */
  const lines = [];

  if (detailed) {
    if (includeCron) {
      lines.push("| Operator | Name | Type | Cron | Optional | Always run |");
      lines.push("| --- | --- | --- | --- | --- | --- |");
      for (const job of jobs) {
        const cron = job.type === "periodic" ? job.cron || "" : "";
        const optional =
          job.type === "presubmit" ? String(Boolean(job.optional)) : "";
        const alwaysRun =
          job.type === "presubmit" ? String(Boolean(job.alwaysRun)) : "";
        lines.push(
          `| ${rowTitle(job)} | \`${job.name}\` | ${job.type} | \`${cron}\` | ${optional} | ${alwaysRun} |`,
        );
      }
    } else {
      lines.push("| Operator | Name | Type | Optional | Always run |");
      lines.push("| --- | --- | --- | --- | --- |");
      for (const job of jobs) {
        const optional =
          job.type === "presubmit" ? String(Boolean(job.optional)) : "";
        const alwaysRun =
          job.type === "presubmit" ? String(Boolean(job.alwaysRun)) : "";
        lines.push(
          `| ${rowTitle(job)} | \`${job.name}\` | ${job.type} | ${optional} | ${alwaysRun} |`,
        );
      }
    }
  } else if (includeCron) {
    lines.push("| Operator | Cron | Status |");
    lines.push("| --- | --- | --- |");
    for (const job of jobs) {
      const label = displayLabel(job);
      const status = linkStatus ? `[${label}](${jobHistoryUrl(job)})` : label;
      lines.push(`| ${rowTitle(job)} | \`${job.cron || ""}\` | ${status} |`);
    }
  } else {
    lines.push("| Operator | Status |");
    lines.push("| --- | --- |");
    for (const job of jobs) {
      const label = displayLabel(job);
      const status = linkStatus ? `[${label}](${jobHistoryUrl(job)})` : label;
      lines.push(`| ${rowTitle(job)} | ${status} |`);
    }
  }

  return lines;
}

/**
 * @param {number} level
 * @param {string} text
 * @returns {string}
 */
function markdownHeading(level, text) {
  const safeLevel = Math.min(Math.max(level, 1), 6);

  return `${"#".repeat(safeLevel)} ${text}`;
}

/**
 * Render version → variant → Operators / WAO / Interop tables.
 * @param {Map<string, Map<string, DiscoveredJob[]>>} grouped
 * @param {{includeCron?: boolean, linkStatus?: boolean, detailed?: boolean, headingLevel?: number}} [options]
 * @returns {string}
 */
function renderGroupedTables(grouped, options = {}) {
  const headingLevel =
    typeof options.headingLevel === "number" ? options.headingLevel : 2;
  /** @type {string[]} */
  const parts = [];

  for (const [version, variants] of grouped) {
    parts.push(markdownHeading(headingLevel, `Version ${version}`));
    parts.push("");

    for (const [variant, jobs] of variants) {
      const label = variantDisplayName(version, variant);
      parts.push(markdownHeading(headingLevel + 1, label));
      parts.push("");
      parts.push(`\`${variant}\``);
      parts.push("");

      const buckets = splitBuckets(jobs);
      /** @type {[string, DiscoveredJob[]][]} */
      const sections = [
        ["Operators", buckets.operators],
        ["WAO", buckets.wao],
        ["Interop", buckets.interop],
      ];

      for (const [title, sectionJobs] of sections) {
        if (sectionJobs.length === 0) {
          continue;
        }

        parts.push(markdownHeading(headingLevel + 2, title));
        parts.push("");
        parts.push(...renderJobTable(sectionJobs, options));
        parts.push("");
      }
    }
  }

  return parts.join("\n").trim() + "\n";
}

/**
 * @param {DiscoveredJob} job
 * @returns {AllJobsCategory}
 */
function allJobsCategory(job) {
  if (job.type === "periodic") {
    return "periodics";
  }

  if (job.type === "presubmit") {
    if (OPERATOR_COMPONENTS.has(job.component)) {
      return "pr-operator";
    }

    if (GENERAL_PR_COMPONENTS.has(job.component)) {
      return "pr-general";
    }
  }

  return "other";
}

/**
 * Home only lists explicit *-daily-* periodics (not every job with a daily cron).
 * @param {DiscoveredJob} job
 * @returns {boolean}
 */
function isHomeDailyJob(job) {
  if (job.type !== "periodic" || job.scheduleClass !== "daily") {
    return false;
  }

  const haystack = `${job.name} ${job.target || ""}`;

  return /\bdaily\b/i.test(haystack);
}

/**
 * @param {DiscoveredJob[]} jobs
 * @returns {string}
 */
function renderDailySection(jobs) {
  const grouped = groupByVersionVariant(jobs, isHomeDailyJob);
  /** @type {string[]} */
  const parts = [
    "# Current CI Status",
    "",
    "Only explicit `*-daily-*` periodics from `openshift/release`, grouped by **version → variant**. Default table is Operators; WAO and Interop are always separate. Updated automatically.",
    "",
  ];

  if (grouped.size === 0) {
    parts.push("_No daily periodics found._");
    parts.push("");
  } else {
    parts.push(renderGroupedTables(grouped, { linkStatus: true }).trimEnd());
    parts.push("");
  }

  return parts.join("\n");
}

/**
 * @param {DiscoveredJob[]} jobs
 * @returns {string}
 */
function renderWeeklyPage(jobs) {
  const grouped = groupByVersionVariant(
    jobs,
    (job) => job.type === "periodic" && job.scheduleClass === "weekly",
  );
  /** @type {string[]} */
  const parts = [
    "<!-- AUTO-GENERATED: Do not edit; overwritten by the wiki-ci-status workflow. -->",
    "# Weekly CI Status",
    "",
    "Weekly periodics from `openshift/release`, grouped by **version → variant**. Default table is Operators; WAO and Interop are always separate. Updated automatically.",
    "",
  ];

  if (grouped.size === 0) {
    parts.push("_No weekly periodics found._");
    parts.push("");
  } else {
    parts.push(
      renderGroupedTables(grouped, {
        includeCron: true,
        linkStatus: true,
      }).trimEnd(),
    );
    parts.push("");
  }

  return parts.join("\n");
}

/**
 * @param {DiscoveredJob[]} jobs
 * @returns {Map<string, DiscoveredJob[]>}
 */
function groupPresubmitsByOperator(jobs) {
  /** @type {Map<string, DiscoveredJob[]>} */
  const grouped = new Map();
  for (const job of jobs) {
    const key = job.component;
    if (!grouped.has(key)) {
      grouped.set(key, []);
    }

    /** @type {DiscoveredJob[]} */ (grouped.get(key)).push(job);
  }

  /** @type {Map<string, DiscoveredJob[]>} */
  const ordered = new Map();
  const components = [...grouped.keys()].sort((left, right) => {
    const leftTitle = COMPONENT_TITLES[left] || left;
    const rightTitle = COMPONENT_TITLES[right] || right;

    return leftTitle.localeCompare(rightTitle);
  });

  for (const component of components) {
    const componentJobs = /** @type {DiscoveredJob[]} */ (
      grouped.get(component)
    );
    sortJobs(componentJobs);
    ordered.set(component, componentJobs);
  }

  return ordered;
}

/**
 * @param {DiscoveredJob[]} jobs
 * @returns {string}
 */
function renderAllJobsPage(jobs) {
  /** @type {Record<AllJobsCategory, DiscoveredJob[]>} */
  const categories = {
    "pr-general": [],
    "pr-operator": [],
    periodics: [],
    other: [],
  };

  for (const job of jobs) {
    categories[allJobsCategory(job)].push(job);
  }

  const tableOptions = {
    includeCron: true,
    linkStatus: false,
    detailed: true,
    headingLevel: 3,
  };

  /** @type {string[]} */
  const parts = [
    "<!-- AUTO-GENERATED: Do not edit; overwritten by the wiki-ci-status workflow. -->",
    "# All Jobs",
    "",
    "Every periodic and presubmit for `openshift/rhwa-system-tests` and `medik8s/*` job folders in `openshift/release`. No badges.",
    "",
    "1. [PRs (general)](#prs-general)",
    "2. [PRs (by operator)](#prs-by-operator)",
    "3. [Periodics](#periodics)",
    "4. [Other](#other)",
    "",
  ];

  parts.push("## PRs (general)");
  parts.push("");
  parts.push(
    "Presubmits for shared repos (`openshift/rhwa-system-tests`, `medik8s/common`, `medik8s/must-gather`).",
  );
  parts.push("");
  if (categories["pr-general"].length === 0) {
    parts.push("_None._");
    parts.push("");
  } else {
    parts.push(
      renderGroupedTables(
        groupByVersionVariant(categories["pr-general"]),
        tableOptions,
      ).trimEnd(),
    );
    parts.push("");
  }

  parts.push("## PRs (by operator)");
  parts.push("");
  parts.push("Presubmits defined under each operator repository.");
  parts.push("");
  if (categories["pr-operator"].length === 0) {
    parts.push("_None._");
    parts.push("");
  } else {
    for (const [component, componentJobs] of groupPresubmitsByOperator(
      categories["pr-operator"],
    )) {
      parts.push(`### ${COMPONENT_TITLES[component] || component}`);
      parts.push("");
      parts.push(`\`${componentJobs[0].org}/${componentJobs[0].repo}\``);
      parts.push("");
      parts.push(
        renderGroupedTables(groupByVersionVariant(componentJobs), {
          ...tableOptions,
          headingLevel: 4,
        }).trimEnd(),
      );
      parts.push("");
    }
  }

  parts.push("## Periodics");
  parts.push("");
  if (categories.periodics.length === 0) {
    parts.push("_None._");
    parts.push("");
  } else {
    parts.push(
      renderGroupedTables(
        groupByVersionVariant(categories.periodics),
        tableOptions,
      ).trimEnd(),
    );
    parts.push("");
  }

  parts.push("## Other");
  parts.push("");
  if (categories.other.length === 0) {
    parts.push("_None._");
    parts.push("");
  } else {
    parts.push(
      renderGroupedTables(
        groupByVersionVariant(categories.other),
        tableOptions,
      ).trimEnd(),
    );
    parts.push("");
  }

  return parts.join("\n");
}

/**
 * Insert or replace the Home auto-generated daily block.
 * @param {string} pageContent
 * @param {string} sectionBody content between markers (no markers)
 * @returns {string}
 */
function applyDailyAutoBlock(pageContent, sectionBody) {
  const normalizedBody = sectionBody.replace(/\s+$/, "") + "\n";
  const block = `${DAILY_START}\n${normalizedBody}${DAILY_END}`;
  const startIdx = pageContent.indexOf(DAILY_START);
  const endIdx = pageContent.indexOf(DAILY_END);

  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    const rest = pageContent.replace(/^\uFEFF/, "").replace(/^\n+/, "");

    return rest ? `${block}\n\n${rest}` : `${block}\n`;
  }

  const after = pageContent.slice(endIdx + DAILY_END.length).replace(/^\n/, "");

  return `${pageContent.slice(0, startIdx)}${block}${after ? `\n${after}` : "\n"}`;
}

/**
 * @param {string} wikiDir
 * @param {DiscoveredJob[]} jobs
 * @param {{dryRun?: boolean}} [options]
 * @returns {{changed: string[], skipped: string[]}}
 */
function updateWiki(wikiDir, jobs, options = {}) {
  const dryRun = Boolean(options.dryRun);
  const homePath = path.join(wikiDir, "Home.md");
  const weeklyPath = path.join(wikiDir, "Weekly-CI-Status.md");
  const allJobsPath = path.join(wikiDir, "All-Jobs.md");

  const homeExisting = fs.existsSync(homePath)
    ? fs.readFileSync(homePath, "utf8")
    : "";
  const homeNext = applyDailyAutoBlock(homeExisting, renderDailySection(jobs));
  const weeklyNext = renderWeeklyPage(jobs);
  const allJobsNext = renderAllJobsPage(jobs);

  /** @type {{path: string, next: string}[]} */
  const targets = [
    { path: homePath, next: homeNext },
    { path: weeklyPath, next: weeklyNext },
    { path: allJobsPath, next: allJobsNext },
  ];

  /** @type {string[]} */
  const changed = [];
  /** @type {string[]} */
  const skipped = [];

  for (const target of targets) {
    const previous = fs.existsSync(target.path)
      ? fs.readFileSync(target.path, "utf8")
      : null;
    if (previous === target.next) {
      skipped.push(path.basename(target.path));
      continue;
    }

    changed.push(path.basename(target.path));
    if (!dryRun) {
      fs.writeFileSync(target.path, target.next, "utf8");
    }
  }

  return { changed, skipped };
}

/**
 * @param {string[]} argv
 * @returns {{releaseDir: string, wikiDir: string, dryRun: boolean}}
 */
function parseArgs(argv) {
  /** @type {Record<string, string | boolean>} */
  const args = { dryRun: false };
  for (let idx = 0; idx < argv.length; idx += 1) {
    const arg = argv[idx];
    if (arg === "--release-dir") {
      args.releaseDir = argv[++idx];
    } else if (arg === "--wiki-dir") {
      args.wikiDir = argv[++idx];
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (args.help) {
    console.log(
      "Usage: node scripts/wiki-ci-status.cjs --release-dir DIR --wiki-dir DIR [--dry-run]",
    );
    process.exit(0);
  }

  if (typeof args.releaseDir !== "string" || !args.releaseDir) {
    throw new Error("--release-dir is required");
  }

  if (typeof args.wikiDir !== "string" || !args.wikiDir) {
    throw new Error("--wiki-dir is required");
  }

  return {
    releaseDir: path.resolve(args.releaseDir),
    wikiDir: path.resolve(args.wikiDir),
    dryRun: Boolean(args.dryRun),
  };
}

/**
 * @param {string[]} argv
 * @returns {void}
 */
function main(argv = process.argv.slice(2)) {
  const { releaseDir, wikiDir, dryRun } = parseArgs(argv);
  if (!fs.existsSync(releaseDir)) {
    throw new Error(`release dir not found: ${releaseDir}`);
  }

  if (!fs.existsSync(wikiDir)) {
    throw new Error(`wiki dir not found: ${wikiDir}`);
  }

  const jobs = loadAllJobs(releaseDir);
  console.log(`discovered ${jobs.length} jobs from ${releaseDir}`);

  const { changed, skipped } = updateWiki(wikiDir, jobs, { dryRun });
  if (changed.length === 0) {
    console.log("no wiki changes");
  } else if (dryRun) {
    console.log(`dry-run; would update: ${changed.join(", ")}`);
  } else {
    console.log(`updated: ${changed.join(", ")}`);
  }

  if (skipped.length > 0) {
    console.log(`unchanged: ${skipped.join(", ")}`);
  }
}

module.exports = {
  DAILY_START,
  DAILY_END,
  HISTORY_BASE,
  classifyCron,
  isHomeDailyJob,
  allJobsCategory,
  versionFromVariant,
  variantDisplayName,
  jobBucket,
  compareVersionsDesc,
  groupByVersionVariant,
  discoverJobFiles,
  parseJobFile,
  loadAllJobs,
  renderDailySection,
  renderWeeklyPage,
  renderAllJobsPage,
  applyDailyAutoBlock,
  updateWiki,
  parseArgs,
  main,
};

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
