# Unify Onboarding — Setup Guide

This tool automates onboarding new Components and an Application into CloudBees Unify from the `cbci-integration` Bitbucket template repos, so you don't have to click through the Unify UI by hand.

## What it does

1. **Syncs** each template's content into your destination repo — either a direct push (diff-aware) or via a real Bitbucket pull request, your choice per repo.
2. **Creates a Bitbucket integration scoped to that specific destination repo**, using that repo's own write token — fully automatic. This is what makes step 5 below actually work: a single integration shared across every repo isn't guaranteed real access to all of them, which was the original root cause of workflows never showing up.
3. **For each Component**: creates it in Unify (or reuses one that already exists with that name), then lets you configure which Environments it's linked to — pick from existing ones by name, create a new one, or **skip environments entirely**. **Environments are optional, and configured per Component, not for the Application.**
4. **Creates the Application**, linked to the Components above. The Application itself always has zero environments of its own — environments live on its Components.
5. **Registers real workflows**: for every Component and the Application, scans the synced repo's `.cloudbees/workflows/*.yaml` files and registers each one as a Unify Automation, so they actually show up in the **Workflows** tab. Creating a Component/Application is pure metadata — Unify never scans a linked repo's existing files on its own, so this step is what makes that actually happen.
6. **Properties**: scans each repo's real `.cloudbees/workflows/*.yaml` files to find which config values/secrets it needs, and sets them from a JSON file you fill in.

**Safe to re-run.** An existing Component/Application/integration is reused, not duplicated — and re-running only ever *adds* newly-selected links, it never removes a previously-linked Component/Environment just because a later run didn't mention it again.

## Platform support

This is a bash script — it runs the same way on **macOS, Linux, and Windows**, as long as you have a bash shell:

| Platform | How to run it |
|---|---|
| **macOS** | Works out of the box in Terminal. Install `jq` if missing: `brew install jq` |
| **Linux** | Works out of the box in your default shell. Install `jq` if missing: `sudo apt install jq` (Debian/Ubuntu) or `sudo yum install jq` (RHEL/CentOS) |
| **Windows** | Use **Git Bash** (installed automatically alongside Git for Windows — you already need `git` for this script, so you likely have it) or **WSL**. Plain `cmd.exe` or PowerShell will **not** work — this is a bash script, not a batch/PowerShell one. Inside Git Bash, install `jq` via `winget install jqlang.jq`, or download the Windows binary from [jqlang.org](https://jqlang.org/download/) and put it on your `PATH`. |

## Prerequisites

- `bash`, `curl`, `jq`, and `git` installed (see the platform table above for how to get `jq` if it's missing — the other three are almost always already present).
- A Unify Personal Access Token. Create it under **your name (top right) → User profile → Personal access tokens → Generate token**. PATs are *personal*, not org-scoped — they inherit your own permissions — so the only fields are Name, Description and Duration. **Change Duration from its 7-day default** to something that outlasts your engagement.
- Bitbucket access tokens — either one workspace-level token, or one *read* token per template plus one *write* token per destination repo (a repo must already exist in Bitbucket first).

## Setup

1. Create a file — call it `onboarding.env` — with your real values:

   ```bash
   UNIFY_PAT=<your Unify personal access token>
   UNIFY_ORG_ID=<your Unify organization ID>

   # Which Bitbucket workspace YOUR destination repos live in.
   BITBUCKET_WORKSPACE=<your-workspace>

   # Which workspace the TEMPLATE repos are read from.
   # Defaults to cbci-integration; only set this if the templates have been
   # copied somewhere else.
   # BITBUCKET_TEMPLATE_WORKSPACE=cbci-integration

   # Optional — override the template repo names (comma or space separated)
   # if you're not using the three defaults.
   # UNIFY_TEMPLATE_REPOS="my-component-template,my-app-template"

   # If using per-repo tokens (not a workspace token):
   BITBUCKET_TOKEN_UNIFY_BITBUCKET_INTEGRATION=<read token for template 1>
   BITBUCKET_TOKEN_UNIFY_BITBUCKET_INTEGRATION_APP2=<read token for template 2>
   BITBUCKET_TOKEN_UNIFY_BITBUCKET_INTEGRATION_APPLICATION=<read token for template 3>

   # One write token per destination repo, named after its repository name
   # (dashes -> underscores, everything uppercase), e.g. for "my-app":
   BITBUCKET_TOKEN_DEST_MY_APP=<write token>
   ```

   **The two workspaces are separate on purpose.** Templates are read from `BITBUCKET_TEMPLATE_WORKSPACE`; your repos are written to `BITBUCKET_WORKSPACE`. If you only set one, both default to the same value, which is fine when everything lives in one workspace.

2. Load it and set a persistent working directory (where template checkouts live between runs):

   ```bash
   set -a; source ./onboarding.env; set +a
   export UNIFY_SCRIPTS_WORKDIR="$HOME/unify-onboarding-workdir"
   ```

## Running it

```bash
./unify-onboarding.sh --dry-run   # preview only, no real changes
./unify-onboarding.sh             # real run
```

You'll be walked through, in order:
1. **Bitbucket token type** — workspace token, or per-repo tokens.
2. **For each Component**: template number, **Bitbucket repository name**, **name to use in Unify** (press Enter to reuse the repository name), sync mechanism (direct push or PR-based), then how many Environments to configure and which ones (existing, new, or none).
3. **For the Application**: the same questions — template, repository name, Unify name, sync mechanism. No environment step here.
4. **Properties**: whether to run it now, and a path to a JSON values file.

Every prompt re-asks on invalid input instead of stopping the run, so a typo costs you one re-entry, not a failed run. If you name a repository that doesn't exist (or that you have no token for), it tells you which repositories you *do* have tokens for.

## Before anything is written to a repository, you get asked

Syncing is the only step that writes to a real Bitbucket repository, and there's no undo — so it stops and shows you exactly what's about to happen first:

```
  ---------------------------------------------------------------
  About to modify a REAL Bitbucket repository:
      template : cbci-integration/unify-bitbucket-integration-application   (read from)
      repo     : cbci-integration/app-1   (written to)
      method   : pull request into main (opened AND merged automatically)
  Make sure the template above is the right one for this repo.
  ---------------------------------------------------------------
  Continue? [y/N]
```

**Check the template line.** Picking the wrong template number is the one mistake that's genuinely awkward to undo — it copies that template's workflow files into the repo permanently. Answer anything but `y` and the repository is left untouched. (This prompt is skipped under `--dry-run`, which writes nothing anyway.)

## One Component per repository

Unify allows only one active Component per repository URL. Pointing a second Component at a repo that already has one fails with `Another active component already exists for url: ...`, regardless of what you name it. That Component is skipped and the run carries on.

## Naming: the repository and the Unify name can differ

The **Bitbucket repository name** and the **Unify Component/Application name** are asked separately, so a repo called `acme-app1-svc` can be onboarded as a Component simply named `app-1`. Press Enter at the Unify-name prompt to keep them identical (the usual case).

Two things to know:
- Your **write token is looked up from the repository name** (`BITBUCKET_TOKEN_DEST_<REPO_NAME>`, uppercased with `-` → `_`), not the Unify name.
- In the **Properties JSON**, each section is keyed by the **Unify name**, because that's what identifies the resource in Unify.

## Environments are optional

At the "How many environments do you want to configure?" prompt, enter `0` — or just press Enter — to skip environments completely and move on. If you've already started picking and change your mind, choose `s` at the environment list to stop and continue to the next step.

## Properties: how the values file works

Point the script at a JSON file path. If that file **doesn't exist yet**, it gets generated automatically — one section per resource, each field a placeholder like `<ENTER_VALUE_FOR_JENKINS_BASE_URL>`:

```json
{
  "app-1": {
    "SONAR_HOST_URL": "<ENTER_VALUE_FOR_SONAR_HOST_URL>",
    "SONAR_PROJECT_KEY": "<ENTER_VALUE_FOR_SONAR_PROJECT_KEY>"
  },
  "app-2": {
    "SONAR_PROJECT_KEY": "<ENTER_VALUE_FOR_SONAR_PROJECT_KEY>"
  }
}
```

Open it, replace the placeholders with real values (each resource has its own section — nothing is shared between them, since values genuinely differ per resource), save it, then **run the script again pointing at the same path** to actually apply them. Any placeholder left untouched is treated as "not provided" and just prompts you interactively instead of ever being pushed to Unify as if it were real.

## Verifying it worked

- **Bitbucket**: open the destination repo, confirm the template's files are there.
- **Unify UI**: open the Application from the list, click the "⋮" menu on its row → Edit, to see its linked Components. Open a Component/Application's **Workflows** tab to confirm the real workflow files show up there. Open its **Properties** tab to see the values you set (secrets show masked, never in plaintext).
