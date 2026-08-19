---
name: sdd-init
description: >-
  First run of the SDD/TDD loop in a repo. Detects the stacks, writes this repo's
  seam profile so the probe recognises its real test levels, and generates a
  repo-local language skill saying how a test at each seam is actually written
  here — file layout, naming, framework, and the exact command that runs ONE
  test. Run once per repo, and again when the test setup changes.
---

# /sdd-init — make the process fit this repo

Usage: `/sdd-init` or `/sdd-init <scope-path>` (a package, in a monorepo)

Entry condition: the plugin is installed and nobody has configured it here.
Exit condition: `.claude/sdd-tdd/seams.json` exists and the probe reports the
levels this repo really tests, and `.claude/skills/sdd-lang-<stack>/SKILL.md`
says how to write a test at each of them.

## Why this exists

The plugin is a **process** — task → spec → enumerated use cases → red, green,
refactored — and it holds no language knowledge on purpose. The same loop runs
over a Flutter app, a .NET API and a TS worker, so anything ecosystem-specific
baked into the plugin is wrong in some repo that installed it. That's not
theoretical: the seam probe used to carry a hardcoded marker table, and a C#
project with a full xunit suite probed as *no test suite at all*, which pushed
every use case to `manual` and left the loop with nothing to drive.

So the split is: **the process ships in the plugin, the language lives in the
repo.** This skill writes the repo's half.

`SDD=${CLAUDE_PLUGIN_ROOT}/scripts` and `TPL=${CLAUDE_PLUGIN_ROOT}/templates`
below.

## What I write

| Path | Owner | Why |
|---|---|---|
| `.claude/sdd-tdd/seams.json` | `init-scaffold.sh` | the seam names (= the `Level` vocabulary) and the marker that recognises each one |
| `.claude/sdd-tdd-loop.json` | `init-scaffold.sh` | only when there's a business wiki to point at |
| `.claude/skills/sdd-lang-<stack>/SKILL.md` | **me, by hand** | how a test is written here, per seam, including the single-test command |

Not written here: the task store (`task.sh` creates it on first use) and
`tracks/` (`scaffold-track.sh` owns it, per track). Two writers of one file is
how a store gets reset.

## Sequence

### 1. Detect, don't assume

`$SDD/detect-stack.sh [scope]`. It reports the manifests present and which
shipped starter profile matches each. Read its output as a *starting point*: it
answers "what is built here", never "how is it tested here".

Then look, for real:
- the test directories and a handful of actual test files in each
- the manifest's test dependencies (`*.csproj` PackageReferences, `package.json`
  devDependencies, `pubspec.yaml` dev_dependencies, `pyproject.toml`, the Gradle
  build) — the framework and assertion library come from here, named and versioned
- the CI config, which is usually the only place the real test command is written
  down without wishful thinking

In a monorepo, do this per package. The probe's scope argument exists because a
repo-wide answer ("some package somewhere has goldens") is worse than useless.

### 2. Choose the seams — the honest ones only

`$SDD/init-scaffold.sh --list-profiles` shows the shipped starters and the seams
each one names. Start from the matching one and **cut it down**: a seam this repo
never writes is a `Level` intake would be allowed to promise, and a promise at a
level nobody has ever written is discovered at implementation time, which is the
whole failure this plugin is built to prevent.

- One stack → copy that profile, delete the seams that don't apply (e.g. `widget`
  in a repo with no UI).
- Several stacks → merge into **one** file: seam names are shared, `globs` and
  `marker` are unioned (one `unit` seam whose globs cover `*.cs` and `*.ts`, whose
  marker matches xunit attributes *or* `it(`).
- Nothing matched → write the file from the shape in `seam-profile.sh`'s header.
  Every marker is "what a test at this level unavoidably contains", and
  `testFilePattern` is "which files are test files at all".

Write your candidate to a scratch path first, then:

```
$SDD/init-scaffold.sh --profile <name|scratch-path> [--wiki auto]
```

It validates before writing, refuses to clobber an existing profile without
`--force`, and prints what resolved.

### 3. Prove the profile against the repo

`$SDD/probe-test-seams.sh <scope>` for each package that matters.

**This is the acceptance test for step 2, and it's not optional.** A seam this
repo demonstrably writes that reports `available=no` means the marker or the
`testFilePattern` is wrong — the repo is not in question. Fix the profile and
re-probe until the report matches what you saw with your own eyes in step 1.

Say the numbers out loud in your report (`unit=41 integration=6 golden=0`).
"The profile is written" and "the profile is right" are different claims.

### 4. Write the repo-local language skill

Start from `$TPL/lang-skill.template.md`, write to
`.claude/skills/sdd-lang-<stack>/SKILL.md`, one file per stack if a repo has more
than one. `$SDD/lang-guide.sh` is what the loop uses to find it, so the path
matters.

Fill it in **from files you opened**, and cite the path for every convention.
The parts that carry their weight:

- **The command that runs ONE test.** The red and green observations are the
  evidence this plugin produces, and a suite-wide run is not that evidence — a
  test that never ran in isolation can be green because something else set the
  state up. Get the exact invocation, with its filter syntax.
- **Run it once, before writing it down.** An unrun command in that table is a
  guess wearing a fact's clothes, and `/sdd-implement` will trust it. Say which
  command you actually executed and what it printed.
- **Per seam:** where the file goes, how it's named, the framework idiom, one
  real example path, and what a genuine red looks like there (a failing assert,
  not a compile error and not a skip).
- **What this repo does not have**, and what introducing it would cost.
- **Gaps** — every claim you could not verify against a file, stated plainly. An
  admitted gap is cheap; a plausible invention is not.

### 5. Report, and name the next step

- the profile path, its seams, and the probe numbers per package
- the language skill path, and which commands you verified by running
- anything you could not answer from the repo — those are questions for the human
  now, not guesses for the loop later
- next step: `/sdd-task new "<title>"`, then `/sdd-spec`

## Re-running

Safe and expected — after a framework change, a new test project, or the first
time a seam gets introduced. It reports what already exists and changes nothing
unless you pass `--force`. When re-running because something changed, re-probe
first and say what drifted, rather than overwriting a profile someone tuned.

## Don't outsource the shell

Every script here works without a TTY: it prints `[no-tty] proceeding: <action>`
and continues. **Never ask the user to run one for you.** And never ask the user
what the test command is before you've looked for it — the manifests and the CI
config answer that in most repos, and a question you could have answered by
reading is a question that wastes the human's attention.
