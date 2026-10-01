#!/usr/bin/env bash
#
# Unify Onboarding — guided setup for new Components/Applications created
# from the cbci-integration Bitbucket template repos.
#
# WHAT THIS DOES, step by step:
#   1) Syncs a template's content into your destination repo, either by
#      direct push (diff-aware) or via a real Bitbucket pull request —
#      your choice each time.
#   2) Creates (or reuses) a Bitbucket integration SCOPED TO THAT SPECIFIC
#      destination repo, using that repo's own write token — fully
#      automatic, no manual UI step. This is what guarantees step 4 below
#      actually works: a single integration shared across every repo isn't
#      guaranteed real access to all of them.
#   3) For each Component: creates it in Unify (or reuses one that already
#      exists with that name, so re-running never duplicates), and lets you
#      configure the Environments it's linked to — pick from existing ones
#      by name, create new ones, or skip environments entirely. They're
#      optional, and selected per Component, not for the Application.
#      The Bitbucket repository name and the Unify Component/Application
#      name are asked as two SEPARATE questions and do NOT have to match
#      (press Enter on the second to keep them the same). Every prompt
#      re-asks on bad input rather than aborting the run.
#   4) Creates the Application the same way, linked to the Components
#      above — always with zero environments of its own; environments
#      live on its Components instead.
#   5) Registers each resource's real .cloudbees/workflows/*.yaml files as
#      Unify Automations, so they actually show up in the Workflows tab —
#      Component/Application creation alone is pure metadata and never
#      scans a linked repo's existing files on its own.
#   6) Discovers which Properties/Secrets a repo's real
#      .cloudbees/workflows/*.yaml files need, and sets them — either from
#      a values file you provide, or by prompting you for each one.
#
# SAFE TO RE-RUN: every create step checks for an existing object with the
# same name first and reuses it instead of erroring or duplicating.
#
# STANDALONE PROPERTIES MODE — one command, no re-run of the full flow:
#   ./unify-onboarding.sh --properties path/to/values.json
# For every Component/Application ALREADY CREATED in Unify (by a prior full
# run), this single command either:
#   - generates a real, editable JSON file at that path (if it doesn't exist
#     yet) with a placeholder for every discovered property/secret, one
#     section per resource — open it in any editor (Notepad, VS Code,
#     whatever), fill in real values, save; or
#   - applies the values already sitting in that file (if it exists) to
#     each matching resource in Unify.
# Never touches sync/Component/Application/Environment/workflow steps at
# all — just Properties, for whatever already exists.
#
# SETUP:
#   1. Create a file (e.g. onboarding.env) with:
#        UNIFY_PAT=<your Unify personal access token>
#        UNIFY_ORG_ID=<your Unify organization ID>
#        BITBUCKET_TOKEN=<workspace access token>          # if you have one
#        BITBUCKET_TOKEN_<TEMPLATE_NAME>=<read token>       # per-repo-token mode
#        BITBUCKET_TOKEN_DEST_<REPO_NAME>=<write token>     # per-repo-token mode
#   2. Load it and run:
#        set -a; source ./onboarding.env; set +a
#        export UNIFY_SCRIPTS_WORKDIR="$HOME/unify-onboarding-workdir"
#        ./unify-onboarding.sh --dry-run     # preview, no real changes
#        ./unify-onboarding.sh               # real run
#        ./unify-onboarding.sh --properties path/to/values.json   # Properties only
#
# Requires: bash, curl, jq, git.

set -euo pipefail

DRY_RUN="false"
PROPERTIES_ONLY_PATH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="true" ;;
    --properties) shift; PROPERTIES_ONLY_PATH="${1:-}" ;;
    --properties=*) PROPERTIES_ONLY_PATH="${1#--properties=}" ;;
  esac
  shift
done

UNIFY_BASE_URL="${UNIFY_BASE_URL:-https://api.cloudbees.io}"
BITBUCKET_API="https://api.bitbucket.org/2.0"
# TWO workspaces, deliberately separate. The template repos and the
# destination repos do not have to live in the same Bitbucket workspace —
# and for anyone outside the original engagement they usually don't. These
# used to be a single variable defaulting to "cbci-integration", which
# meant a customer who didn't know about the (undocumented) override
# silently ran every clone/push/PR/repo-create against CloudBees' own
# workspace, while setting it to their own workspace made the script look
# for the TEMPLATE repos in their workspace instead, where they don't
# exist. Neither could work.
#   TEMPLATE_WORKSPACE : where the template repos are read FROM
#   WORKSPACE          : where the customer's destination repos live
# WORKSPACE defaults to TEMPLATE_WORKSPACE so a setup where both are the
# same (the common case for a first-time engagement) keeps working with
# no changes.
TEMPLATE_WORKSPACE="${BITBUCKET_TEMPLATE_WORKSPACE:-cbci-integration}"
WORKSPACE="${BITBUCKET_WORKSPACE:-$TEMPLATE_WORKSPACE}"
ORG_ID="${UNIFY_ORG_ID:?Set UNIFY_ORG_ID before running}"
WORK_DIR="${UNIFY_SCRIPTS_WORKDIR:?Set UNIFY_SCRIPTS_WORKDIR to a persistent local directory before running}"
: "${UNIFY_PAT:?Set UNIFY_PAT before running}"
mkdir -p "$WORK_DIR"

# Overridable so the tool isn't locked to one engagement's template names:
#   export UNIFY_TEMPLATE_REPOS="my-component-template,my-app-template"
if [ -n "${UNIFY_TEMPLATE_REPOS:-}" ]; then
  IFS=', ' read -r -a TEMPLATE_REPOS <<< "$UNIFY_TEMPLATE_REPOS"
else
  TEMPLATE_REPOS=("unify-bitbucket-integration" "unify-bitbucket-integration-app2" "unify-bitbucket-integration-application")
fi

log() { echo "==> $*"; }
confirm() { local a; read -r -p "$1" a; [[ "$a" =~ ^[Yy] ]]; }
env_name() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'; }

get_secret() {
  local env_var="$1" prompt="$2" val="${!1:-}"
  if [ -n "$val" ]; then printf '%s' "$val"; return; fi
  read -r -s -p "${prompt} (or set \$${env_var} to skip this prompt): " val >&2; echo >&2
  printf '%s' "$val"
}

unify_get() {
  curl -sS --connect-timeout 10 --max-time 30 -H "Authorization: Bearer ${UNIFY_PAT}" "${UNIFY_BASE_URL}$1"
}
unify_write() {
  curl -sS --connect-timeout 10 --max-time 30 -X "$1" \
    -H "Authorization: Bearer ${UNIFY_PAT}" -H "Content-Type: application/json" -d "$3" \
    "${UNIFY_BASE_URL}$2"
}
bb_request() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS --connect-timeout 10 --max-time 30 -X "$method" -H "Authorization: Bearer ${BITBUCKET_TOKEN}" \
      -H "Content-Type: application/json" -d "$body" "${BITBUCKET_API}${path}"
  else
    curl -sS --connect-timeout 10 --max-time 30 -X "$method" -H "Authorization: Bearer ${BITBUCKET_TOKEN}" "${BITBUCKET_API}${path}"
  fi
}
# $1=repo slug, $2=token, $3=workspace (optional, defaults to the
# DESTINATION workspace). Template clones must pass $TEMPLATE_WORKSPACE.
repo_clone_url() { printf 'https://x-token-auth:%s@bitbucket.org/%s/%s.git' "$2" "${3:-$WORKSPACE}" "$1"; }

check_repo_access() {
  local ws_repo="$1" token="$2"
  local code; code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    -H "Authorization: Bearer ${token}" "${BITBUCKET_API}/repositories/${WORKSPACE}/${ws_repo}" 2>/dev/null) || code="000"
  [ "$code" = "200" ]
}

# ---------------------------------------------------------------------------
# Bitbucket integration lookup on the Unify side, with an auto-create
# fallback if none exists at all yet for this org.
# FIX (confirmed live, 2026-09-16): the create fallback used to be flagged
# EXPERIMENTAL/unconfirmed because it always failed with HTTP 400 "invalid
# endpoint provided, must have either parent_id or a contribution_id and
# contribution_type". That was NOT a backend restriction — the body was
# wrapped in {"endpoint": {...}}, but AddEndpoint's real schema
# (confirmed against the OpenAPI spec, and against a real working
# integration's own stored fields via GET) takes the flat object directly.
# Fixed and confirmed live: an unwrapped POST with this exact shape
# succeeds and returns a real, working integration.
# ---------------------------------------------------------------------------
print_manual_integration_instructions() {
  cat <<'EOF'
No Bitbucket integration was found for this organization, and automatic
creation failed. Create one manually instead:
  1. Open CloudBees Unify -> select the organization
  2. Configurations -> Integrations -> Create integration
  3. Choose "Bitbucket access token"
  4. Give it a name, paste your Bitbucket access token, click "Test
     integration" to confirm it authenticates, then Submit
Re-run this tool afterwards — it will detect the new integration automatically.
EOF
}

resolve_bitbucket_endpoint_id() {
  local resp found_id
  resp=$(unify_get "/v1/resources/${ORG_ID}/endpoints")
  found_id=$(echo "$resp" | jq -r '[.endpoints[]? | select(((.contributionId // "") | ascii_downcase | contains("bitbucket")))] | first | .id // empty')
  if [ -n "$found_id" ]; then
    echo "Found existing Bitbucket integration: $found_id" >&2
    printf '%s' "$found_id"; return
  fi

  echo "No Bitbucket integration found for this organization — creating one automatically." >&2
  local bb_token int_name
  bb_token="$(get_secret BITBUCKET_TOKEN "Bitbucket access token")"
  read -r -p "Name for the new integration: " int_name
  local create_resp new_id
  create_resp=$(unify_write POST "/v1/resources/${ORG_ID}/endpoints" \
    "$(jq -nc --arg org "$ORG_ID" --arg name "$int_name" --arg ws "$WORKSPACE" --arg token "$bb_token" \
      '{resourceId:$org, name:$name, description:"Created automatically by unify-onboarding.sh",
        contributionType:"cb.platform.endpoint-type", contributionId:"cb.bitbucket.bitbucket-cloud-token-endpoint-type",
        contributionTargets:["cb.platform.endpoint-types","cb.platform.scm.repository","scm"],
        properties: [{name:"workspace", string:$ws, isSecret:false}, {name:"token", string:$token, isSecret:true},
                     {name:"url", string:"https://bitbucket.org", isSecret:false}, {name:"provider", string:"bitbucket", isSecret:false}]}')")
  new_id=$(echo "$create_resp" | jq -r '.id // empty')
  if [ -z "$new_id" ]; then
    echo "Automatic creation failed: $create_resp" >&2
    print_manual_integration_instructions >&2
    return
  fi
  echo "Created integration: $new_id" >&2
  printf '%s' "$new_id"
}

# ---------------------------------------------------------------------------
# Mechanism A: direct push, diff-aware, safe to re-run.
# ---------------------------------------------------------------------------
push_direct() {
  # Prints the local checkout path on stdout (the caller captures this via
  # command substitution to know where Properties discovery should later
  # look) — everything else MUST go to stderr, INCLUDING git's own status
  # output. FIX (confirmed live): git commands like `checkout -B` and
  # `merge` write some of their own status lines (e.g. "branch 'x' set up
  # to track 'y'", "Updating abc..def") to STDOUT, not stderr — this
  # leaked straight into the captured path, corrupting it with git's own
  # chatter. All git work below is wrapped in a `{ ...; } >&2` group so
  # NOTHING it prints can reach the real stdout, regardless of which
  # stream any individual git subcommand happens to use.
  local template="$1" dest_slug="$2" template_token="$3" push_token="$4"
  local local_path="$WORK_DIR/$template"
  local up_to_date="false"
  log "Direct push: '$template' -> '$dest_slug'" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would clone/push $template -> $dest_slug" >&2
    printf '%s' "$local_path"; return
  fi
  local push_url; push_url=$(repo_clone_url "$dest_slug" "$push_token")
  {
    if [ -d "$local_path/.git" ]; then
      git -C "$local_path" remote set-url template "$(repo_clone_url "$template" "$template_token" "$TEMPLATE_WORKSPACE")"
      git -C "$local_path" fetch template main
    else
      git clone --branch main --single-branch "$(repo_clone_url "$template" "$template_token" "$TEMPLATE_WORKSPACE")" "$local_path"
      git -C "$local_path" remote rename origin template
    fi
    git -C "$local_path" checkout -B push template/main
    if git ls-remote --heads "$push_url" main 2>/dev/null | grep -q .; then
      git -C "$local_path" fetch "$push_url" main
      if git -C "$local_path" diff --quiet FETCH_HEAD template/main -- ; then
        up_to_date="true"
      else
        git -C "$local_path" merge --allow-unrelated-histories -X ours FETCH_HEAD -m "Merge existing destination content" || true
      fi
    fi
  } >&2
  if [ "$up_to_date" = "true" ]; then
    log "  '$dest_slug' already up to date with '$template' — nothing to push." >&2
  else
    git -C "$local_path" push "$push_url" push:main >&2
    log "  Pushed. Local checkout: $local_path" >&2
  fi
  printf '%s' "$local_path"
}

# ---------------------------------------------------------------------------
# Mechanism B: PR-based sync — clones both,
# copies template files over the target's working tree (never deletes
# target-only files), commits on a temp branch, opens a real Bitbucket PR,
# merges it fast-forward. Use when you want the sync itself to be
# reviewable/visible as a PR rather than a direct push.
# ---------------------------------------------------------------------------
sync_via_pr() {
  # Same stdout/stderr discipline as push_direct: prints the local path
  # that actually holds the synced content (target's own checkout — it
  # already has the template's files copied in before the PR is even
  # opened) on stdout; everything else goes to stderr, on every return path.
  local template="$1" target_slug="$2" template_token="$3" target_token="$4"
  log "PR-based sync: '$template' -> '$target_slug'" >&2
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would clone both, copy files, open a PR into ${target_slug}@main, and merge it" >&2
    printf '%s' "$WORK_DIR/pr-sync-${target_slug}/target"; return
  fi
  # FIX (confirmed live): a fixed, reused directory name here fails on
  # re-runs — `rm -rf` can't always remove a previous clone's .git/hooks/*
  # sample files (OS-level permission quirk on git's hook templates, hit
  # repeatedly elsewhere in this project), which then makes `git clone`
  # fail with "destination path already exists" — and because that
  # failure was never checked, execution silently continued and produced
  # a FALSE "already up to date" result on an empty, broken directory.
  # Using a fresh mktemp -d each call sidesteps the whole problem — these
  # clones are one-shot (open a PR and you're done), not meant to persist
  # across runs like push_direct's diff-tracking clone.
  local tmp; tmp=$(mktemp -d "${WORK_DIR}/pr-sync-${target_slug}.XXXXXX")
  if ! git clone --branch main --single-branch "$(repo_clone_url "$target_slug" "$target_token")" "$tmp/target" >&2; then
    echo "ERROR: failed to clone destination repo '$target_slug' — see git output above." >&2
    return 1
  fi
  if ! git clone --branch main --single-branch "$(repo_clone_url "$template" "$template_token" "$TEMPLATE_WORKSPACE")" "$tmp/template" >&2; then
    echo "ERROR: failed to clone template repo '$template' — see git output above." >&2
    return 1
  fi

  # FIX (confirmed live, same class as push_direct): git's own status
  # output (from checkout -b, commit, push) can land on stdout, not just
  # stderr — everything below is wrapped in `{ ...; } >&2` so none of it
  # can corrupt the final printed path.
  local branch_name="sync-from-${template}"
  {
    (cd "$tmp/template" && find . -path ./.git -prune -o -type f -print) | while read -r f; do
      mkdir -p "$tmp/target/$(dirname "$f")"
      cp "$tmp/template/$f" "$tmp/target/$f"
    done
    git -C "$tmp/target" checkout -b "$branch_name"
    git -C "$tmp/target" add -A
  } >&2
  if [ -z "$(git -C "$tmp/target" status --short)" ]; then
    log "  '$target_slug' already up to date with '$template' — no PR needed." >&2
    printf '%s' "$tmp/target"; return
  fi
  {
    git -C "$tmp/target" commit -m "Sync from template ${template}"
    git -C "$tmp/target" push "$(repo_clone_url "$target_slug" "$target_token")" "$branch_name"
  } >&2

  BITBUCKET_TOKEN="$target_token"
  local pr_resp pr_id
  pr_resp=$(bb_request POST "/repositories/${WORKSPACE}/${target_slug}/pullrequests" \
    "$(jq -nc --arg title "Sync from template ${template}" --arg branch "$branch_name" \
      '{title:$title, source:{branch:{name:$branch}}, destination:{branch:{name:"main"}}, close_source_branch:true}')")
  pr_id=$(echo "$pr_resp" | jq -r '.id // empty')
  if [ -z "$pr_id" ]; then
    echo "ERROR opening PR: $pr_resp" >&2
    printf '%s' "$tmp/target"; return 1
  fi
  bb_request POST "/repositories/${WORKSPACE}/${target_slug}/pullrequests/${pr_id}/merge" '{"merge_strategy":"fast_forward"}' > /dev/null
  log "  Synced via PR #${pr_id} (merged)." >&2
  printf '%s' "$tmp/target"
}

# ---------------------------------------------------------------------------
# Auto-create a destination Bitbucket repo (only possible with a workspace
# token, which has Admin scope).
# ---------------------------------------------------------------------------
create_bitbucket_repo() {
  local name="$1"
  BITBUCKET_TOKEN="$WORKSPACE_TOKEN"
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would create Bitbucket repo ${WORKSPACE}/${name}"
    return
  fi
  bb_request POST "/repositories/${WORKSPACE}/${name}" '{"scm":"git","is_private":true}' > /dev/null
  log "  Created Bitbucket repo ${WORKSPACE}/${name}"
}

# ---------------------------------------------------------------------------
# Input helpers — every one of these RE-PROMPTS on bad input instead of
# letting the run die. Before these existed, a simple typo was fatal: a
# mistyped repo name derived a token variable name that didn't exist (or,
# with a space in it, wasn't even a valid identifier) and `set -u` killed
# the whole script mid-run; a non-numeric count crashed the `for (( ))`
# arithmetic; an out-of-range menu choice silently linked a literal "null"
# ID. All prompts/messages go to stderr so these stay safe to call from
# inside command substitution.
# ---------------------------------------------------------------------------

# Every re-prompt loop below MUST detect end-of-input. `read` returns
# non-zero at EOF (stdin closed, or piped input exhausted) and leaves the
# variable empty — without this check the loop re-prompts forever against
# a dead stdin and the script hangs instead of finishing. Confirmed live:
# a piped test run spun indefinitely. Returning non-zero here aborts the
# run via `set -e` at the caller's assignment, which is the right outcome
# since an interactive prompt can't be answered with no input left.
read_or_eof() {
  local __var="$1" prompt="$2"
  if ! read -r -p "$prompt" "$__var" >&2; then
    echo "" >&2
    echo "  No more input available (end of input) — aborting rather than re-prompting forever." >&2
    return 1
  fi
}

# A whole number, defaulting to $2 when the customer just presses Enter.
prompt_count() {
  local prompt="$1" default="$2" val
  while true; do
    read_or_eof val "$prompt" || return 1
    if [ -z "$val" ]; then printf '%s' "$default"; return; fi
    case "$val" in
      *[!0-9]*) echo "  Please enter a whole number (digits only) — try again." >&2 ;;
      *) printf '%s' "$val"; return ;;
    esac
  done
}

# A template, chosen by number from TEMPLATE_REPOS.
prompt_template() {
  local label="$1" n="${#TEMPLATE_REPOS[@]}" idx
  while true; do
    read_or_eof idx "${label} - template number [1-${n}]: " || return 1
    case "$idx" in
      ''|*[!0-9]*) echo "  Please enter a number between 1 and ${n}." >&2; continue ;;
    esac
    if [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ]; then
      printf '%s' "${TEMPLATE_REPOS[$((idx-1))]}"; return
    fi
    echo "  Please enter a number between 1 and ${n}." >&2
  done
}

# Which destination repos we actually hold a write token for — shown as a
# hint when the customer types a repo name we have no token for. Prints only
# variable NAMES and the repo slug they imply, never any token value.
list_available_dest_tokens() {
  local vars; vars=$(env | sed -n 's/^\(BITBUCKET_TOKEN_DEST_[A-Z0-9_]*\)=.*/\1/p' | sort)
  [ -z "$vars" ] && return
  echo "  Destination repos you currently have a token for:" >&2
  local v slug
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    slug=$(printf '%s' "${v#BITBUCKET_TOKEN_DEST_}" | tr '[:upper:]_' '[:lower:]-')
    echo "    - ${slug}   (from \$${v})" >&2
  done <<< "$vars"
}

# Ask for the Bitbucket repository name AND the name to use in Unify, as
# two SEPARATE questions — they no longer have to match. The repo name
# drives everything Bitbucket-side (which token to use, what to clone/push,
# the scoped integration, the stored repositoryUrl); the Unify name is just
# what the Component/Application is called in Unify. Pressing Enter on the
# second question keeps them identical, which is still the common case.
# The repo name is validated against real Bitbucket before we accept it, so
# a typo costs one re-prompt instead of a crashed run.
# Prints "<repo_slug>|<unify_name>" on stdout; everything else to stderr.
prompt_repo_and_name() {
  local label="$1" slug name token
  while true; do
    read_or_eof slug "${label} - Bitbucket repository name (e.g. my-app): " || return 1
    if [ -z "$slug" ]; then
      echo "  A Bitbucket repository name is required." >&2; continue
    fi
    # Character check first, for EVERY mode: a name containing a space (the
    # real typo that killed a run — "unify application" instead of
    # "unify-application") produces an invalid shell variable name when the
    # token lookup is built from it, which is fatal under set -u.
    case "$slug" in
      *[!a-zA-Z0-9._-]*)
        echo "  '$slug' isn't a valid Bitbucket repository name — letters, numbers, dots, hyphens and underscores only (no spaces)." >&2
        continue ;;
    esac
    # Workspace-token mode legitimately allows a repo that doesn't exist yet
    # (it gets auto-created below), so there's nothing to verify there.
    # Everywhere else, confirm the repo really is reachable with its token —
    # including on --dry-run, since catching a typo during a preview run is
    # exactly what a preview is for, and the check is a read-only GET.
    if [ "$TOKEN_KIND" = "1" ]; then break; fi
    token=$(push_token_for_repo "$slug")
    if [ -z "$token" ]; then
      echo "  No Bitbucket token found for repo '${slug}' — expected \$BITBUCKET_TOKEN_DEST_$(env_name "$slug") to be set." >&2
      list_available_dest_tokens
      echo "  Check the spelling, or add that token to your environment file, then try again." >&2
      continue
    fi
    if ! check_repo_access "$slug" "$token"; then
      echo "  Couldn't reach 'https://bitbucket.org/${WORKSPACE}/${slug}' with that token." >&2
      echo "  Either the repository name is wrong or that token doesn't have access to it — try again." >&2
      continue
    fi
    break
  done
  read -r -p "${label} - name to use in Unify [press Enter to use '${slug}']: " name >&2
  [ -z "$name" ] && name="$slug"
  printf '%s|%s' "$slug" "$name"
}

# The Bitbucket repo slug behind an already-created Unify service, taken
# from the repositoryUrl Unify itself stores. Needed because a service's
# Unify name no longer implies its repo name — standalone Properties mode
# has nothing else to go on, since it runs with no memory of a prior run.
repo_slug_for_service() {
  local all_services="$1" name="$2"
  echo "$all_services" \
    | jq -r --arg n "$name" '.service[]? | select(.name == $n) | .repositoryUrl // ""' \
    | head -1 | sed -e 's#/*$##' -e 's#\.git$##' -e 's#.*/##'
}

# Ask once which Bitbucket token mode to use, and for a given template +
# destination pair, resolve which sync mechanism + tokens to use.
choose_bitbucket_mode() {
  echo ""
  echo "Bitbucket token type?"
  echo "  1) Workspace access token — works across the whole workspace, can create new repos"
  echo "  2) Repository access token(s) — one token per template (read) and per destination repo (write)"
  read -r -p "Which kind? [1/2]: " TOKEN_KIND
  if [ "$TOKEN_KIND" = "1" ]; then
    WORKSPACE_TOKEN="$(get_secret BITBUCKET_TOKEN "Workspace access token")"
  fi
}

sync_repo() {
  # Prints the local checkout path that actually holds the synced content
  # on stdout (the caller needs this for accurate Properties discovery
  # later — direct-push and PR-based sync use DIFFERENT local paths, so
  # this must reflect whichever mechanism actually ran, not a guess).
  local template="$1" dest_slug="$2"
  local template_token push_token repo_exists="true"

  if [ "$TOKEN_KIND" = "1" ]; then
    template_token="$WORKSPACE_TOKEN"; push_token="$WORKSPACE_TOKEN"
    if [ "$DRY_RUN" != "true" ] && ! check_repo_access "$dest_slug" "$WORKSPACE_TOKEN"; then
      repo_exists="false"
    fi
  else
    local read_var="BITBUCKET_TOKEN_$(env_name "$template")"
    local write_var="BITBUCKET_TOKEN_DEST_$(env_name "$dest_slug")"
    # ":-" defaults, never bare "${!var}" — a missing token variable used to
    # abort the whole run with a bare "unbound variable" under set -u.
    template_token="${!read_var:-}"; push_token="${!write_var:-}"
    if [ -z "$template_token" ]; then
      echo "ERROR: no read token for template '$template' (expected \$${read_var}) — skipping this resource." >&2
      return 1
    fi
    if [ -z "$push_token" ]; then
      echo "ERROR: no write token for repo '$dest_slug' (expected \$${write_var}) — skipping this resource." >&2
      return 1
    fi
  fi

  if [ "$repo_exists" = "false" ]; then
    create_bitbucket_repo "$dest_slug" >&2
    push_direct "$template" "$dest_slug" "$template_token" "$push_token"
    return
  fi

  read -r -p "Sync mechanism for '$dest_slug'? [1] Direct push (diff-aware, default)  [2] Sync via Pull Request: " mech >&2
  local mech_label="direct push to main"
  [ "$mech" = "2" ] && mech_label="pull request into main (opened AND merged automatically)"

  # CONFIRMATION GATE. This is the only step in the whole script that
  # WRITES to a real Bitbucket repository, and there is no undo.
  # Added after a real incident (2026-09-17): the Application template was
  # synced into the 'app-1' repo because of one wrong menu number, the PR
  # was auto-merged 8 seconds later, and 16 files that didn't belong there
  # became permanent — then got registered as Unify workflows on top.
  # Nothing before this point has touched anything, so state the exact
  # template -> repo pair and require an explicit yes.
  # Skipped under --dry-run, which writes nothing by definition.
  if [ "$DRY_RUN" != "true" ]; then
    echo "" >&2
    echo "  ---------------------------------------------------------------" >&2
    echo "  About to modify a REAL Bitbucket repository:" >&2
    echo "      template : ${TEMPLATE_WORKSPACE}/${template}   (read from)" >&2
    echo "      repo     : ${WORKSPACE}/${dest_slug}   (written to)" >&2
    echo "      method   : $mech_label" >&2
    echo "  Make sure the template above is the right one for this repo." >&2
    echo "  ---------------------------------------------------------------" >&2
    if ! confirm "  Continue? [y/N] "; then
      echo "  Skipped — '${WORKSPACE}/${dest_slug}' was NOT modified." >&2
      return 1
    fi
  fi

  if [ "$mech" = "2" ]; then
    sync_via_pr "$template" "$dest_slug" "$template_token" "$push_token"
  else
    push_direct "$template" "$dest_slug" "$template_token" "$push_token"
  fi
}

# ---------------------------------------------------------------------------
# The write token for a given destination repo — same lookup sync_repo()
# already does internally, exposed here so main() can also use it to create
# that repo's own scoped Bitbucket integration.
# ---------------------------------------------------------------------------
push_token_for_repo() {
  local dest_slug="$1"
  if [ "$TOKEN_KIND" = "1" ]; then
    printf '%s' "$WORKSPACE_TOKEN"
  else
    local write_var="BITBUCKET_TOKEN_DEST_$(env_name "$dest_slug")"
    # ":-" default (not a bare "${!write_var}") so a missing token variable
    # returns empty instead of crashing with "unbound variable" under set -u
    # — callers check for empty and warn clearly instead.
    printf '%s' "${!write_var:-}"
  fi
}

# ---------------------------------------------------------------------------
# Clone (or refresh) a resource's OWN destination repo — used by standalone
# Properties mode to discover .cloudbees/workflows/*.yaml property/secret
# names without needing anything from a prior sync/create run in memory.
# ---------------------------------------------------------------------------
fetch_repo_for_properties() {
  local slug="$1" token="$2"
  local repo_path="${WORK_DIR}/properties-only-${slug}"
  if [ -d "${repo_path}/.git" ]; then
    { git -C "$repo_path" fetch origin main && git -C "$repo_path" reset --hard origin/main; } >&2
  else
    git clone --branch main --single-branch "$(repo_clone_url "$slug" "$token")" "$repo_path" >&2
  fi
  printf '%s' "$repo_path"
}

# ---------------------------------------------------------------------------
# STANDALONE Properties mode — ./unify-onboarding.sh --properties <path>.
# One command, no re-run of sync/Component/Application/Environment/workflow
# steps. Works against whatever Components/Applications ALREADY EXIST in
# Unify (created by a prior full run):
#   - path doesn't exist yet -> discovers every existing service in this
#     org, clones each one's own repo to find its real property/secret
#     names, and writes a real, editable placeholder template to that path.
#   - path exists -> applies the values already in it, same as the
#     Properties step inside the full flow.
# ---------------------------------------------------------------------------
apply_properties_only() {
  local json_path="$1"
  if [ -z "$json_path" ]; then
    echo "ERROR: --properties requires a file path, e.g. --properties ./values.json" >&2
    exit 1
  fi
  case "$json_path" in "~"|"~/"*) json_path="${HOME}${json_path#\~}" ;; esac

  choose_bitbucket_mode

  local all_services; all_services=$(unify_get "/v1/organizations/${ORG_ID}/services")
  local known_slugs; known_slugs=$(echo "$all_services" | jq -r '.service[]?.name')
  if [ -z "$known_slugs" ]; then
    echo "ERROR: no Components/Applications found in this org yet — run the full onboarding flow first to create some." >&2
    exit 1
  fi

  if [ ! -f "$json_path" ]; then
    log "No file at '$json_path' yet — discovering every existing Component/Application to build a template."
    # Each section is keyed by the resource's UNIFY name, but the repo to
    # clone (and therefore the token to use) comes from that service's own
    # stored repositoryUrl — the two can legitimately differ now, so the
    # Unify name can't be used to guess either one.
    local slug_path_pairs=() slug repo_slug token repo_path
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      repo_slug=$(repo_slug_for_service "$all_services" "$slug")
      if [ -z "$repo_slug" ]; then
        echo "  WARNING: '$slug' has no repository URL in Unify — skipping (won't appear in the generated template)." >&2
        continue
      fi
      token=$(push_token_for_repo "$repo_slug")
      if [ -z "$token" ]; then
        echo "  WARNING: no Bitbucket token available for repo '$repo_slug' (resource '$slug') — skipping (won't appear in the generated template)." >&2
        continue
      fi
      log "  Fetching '$slug' (repo '$repo_slug')..."
      repo_path=$(fetch_repo_for_properties "$repo_slug" "$token")
      slug_path_pairs+=("$slug" "$repo_path")
    done <<< "$known_slugs"

    if [ "${#slug_path_pairs[@]}" -eq 0 ]; then
      echo "ERROR: couldn't fetch any resource's repo — no template generated. Check your Bitbucket tokens in .env." >&2
      exit 1
    fi
    local ncount; ncount=$(ensure_properties_template "$json_path" "${slug_path_pairs[@]}")
    echo ""
    echo "Created a template at '$json_path' with $ncount entries."
    echo "Open it in any editor, fill in real values, save it, then run this exact same command again:"
    echo "  ./unify-onboarding.sh --properties \"$json_path\""
    return
  fi

  export PROPERTIES_VALUES_FILE="$json_path"
  local file_slugs; file_slugs=$(jq -r 'keys[]' "$json_path")
  # FIX (same bug class as set_properties()'s stdin-shift bug, see project
  # memory): must read slugs into an array FIRST, not loop directly against
  # a here-string (`done <<< "$file_slugs"`) — set_properties() below calls
  # confirm(), which does its own `read`. A here-string redirects the WHOLE
  # loop body's stdin, so confirm()'s nested read would silently consume
  # the NEXT slug name as if it were the user's y/N answer instead of ever
  # prompting — confirmed live: this caused every overwrite to silently
  # "decline" with no visible prompt, and ate app-2/unify-application's
  # names in the process, so the loop quietly stopped after only app-1.
  local slug_arr=() slug
  while IFS= read -r slug; do [ -n "$slug" ] && slug_arr+=("$slug"); done <<< "$file_slugs"
  local service_id repo_slug token repo_path
  for slug in "${slug_arr[@]}"; do
    service_id=$(echo "$all_services" | jq -r --arg n "$slug" '.service[]? | select(.name == $n) | .id' | head -1)
    if [ -z "$service_id" ]; then
      echo "WARNING: no existing Component/Application named '$slug' found in Unify — skipping." >&2
      continue
    fi
    repo_slug=$(repo_slug_for_service "$all_services" "$slug")
    if [ -z "$repo_slug" ]; then
      echo "WARNING: '$slug' has no repository URL in Unify — skipping." >&2
      continue
    fi
    token=$(push_token_for_repo "$repo_slug")
    if [ -z "$token" ]; then
      echo "WARNING: no Bitbucket token available for repo '$repo_slug' (resource '$slug') — skipping." >&2
      continue
    fi
    log "Fetching '$slug' (repo '$repo_slug') to discover its real Properties/Secrets..."
    repo_path=$(fetch_repo_for_properties "$repo_slug" "$token")
    log "Properties for $slug"
    set_properties "$service_id" "$repo_path" "$slug"
  done
  log "Done."
}

# ---------------------------------------------------------------------------
# Create-or-reuse a Component/Application by name.
# FIX (confirmed against the real API): POST /v1/organizations/{org}/services
# — NOT /v1/resources/{org}/services (HTTP 501). Response nests id under
# .service.id, not a bare .id.
# ---------------------------------------------------------------------------
ensure_service() {
  local name="$1" repo_url="$2" service_type="$3" endpoint_id="$4" comp_ids_json="$5" env_ids_json="$6"
  local all_services existing
  all_services=$(unify_get "/v1/organizations/${ORG_ID}/services")
  existing=$(echo "$all_services" | jq -c --arg n "$name" '.service[]? | select(.name == $n)' | head -1)
  if [ -n "$existing" ]; then
    local existing_id; existing_id=$(echo "$existing" | jq -r '.id')
    # FIX #1 (confirmed live): merely returning the existing ID here
    # silently ignored whatever NEW comp_ids_json/env_ids_json the caller
    # just asked for — links never updated on re-run.
    # FIX #2 (confirmed live, found via deliberate multi-run testing):
    # the first fix above REPLACED linkedComponentIds/linkedEnvironmentIds
    # wholesale — meaning re-running with a DIFFERENT subset of
    # components/environments silently DROPPED any previously-linked one
    # not mentioned in that particular run (confirmed: re-running with
    # only "app-1" as a Component silently unlinked "app-2" from an
    # Application that already had both). MERGE (union) with whatever the
    # object already has instead of overwriting — a run should be able to
    # ADD links, never silently REMOVE one just by omission.
    local merged_comps merged_envs
    merged_comps=$(jq -nc --argjson a "$(echo "$existing" | jq -c '.linkedComponentIds // []')" --argjson b "$comp_ids_json" '($a + $b) | unique')
    merged_envs=$(jq -nc --argjson a "$(echo "$existing" | jq -c '.linkedEnvironmentIds // []')" --argjson b "$env_ids_json" '($a + $b) | unique')
    log "$service_type '$name' already exists (id=$existing_id) — reusing it, merging in any newly-linked components/environments." >&2
    if [ "$DRY_RUN" != "true" ]; then
      unify_write PUT "/v1/organizations/${ORG_ID}/services/${existing_id}" \
        "$(jq -nc --arg id "$existing_id" --arg name "$name" --arg url "$repo_url" --arg ep "$endpoint_id" \
            --arg org "$ORG_ID" --arg stype "$service_type" --argjson comps "$merged_comps" --argjson envs "$merged_envs" \
          '{service: {id:$id, name:$name, repositoryUrl:$url, endpointId:$ep, organizationId:$org, serviceType:$stype,
            linkedComponentIds:$comps, linkedEnvironmentIds:$envs}}')" > /dev/null
    fi
    printf '%s' "$existing_id"; return
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would create $service_type '$name' -> $repo_url" >&2
    printf '<dry-run>'; return
  fi
  local resp new_id
  resp=$(unify_write POST "/v1/organizations/${ORG_ID}/services" \
    "$(jq -nc --arg name "$name" --arg url "$repo_url" --arg ep "$endpoint_id" --arg org "$ORG_ID" --arg stype "$service_type" \
        --argjson comps "$comp_ids_json" --argjson envs "$env_ids_json" \
      '{service: {name:$name, repositoryUrl:$url, endpointId:$ep, organizationId:$org, serviceType:$stype,
        linkedComponentIds:$comps, linkedEnvironmentIds:$envs}}')")
  new_id=$(echo "$resp" | jq -r '.service.id // empty')
  [ -z "$new_id" ] && { echo "ERROR creating $service_type '$name': $resp" >&2; return 1; }
  log "Created $service_type '$name' (id=$new_id)" >&2
  printf '%s' "$new_id"
}

# ---------------------------------------------------------------------------
# Register a resource's real .cloudbees/workflows/*.yaml files as Unify
# Automations against its default branch (main), so they actually show up
# in the Workflows tab. FIX (confirmed live): creating a Component/
# Application is pure metadata — Unify never scans a linked repo's existing
# files on its own, no matter how endpointId is set. This API
# (CreateAutomation) is the only mechanism that registers a workflow, and
# it CAN write a real commit/branch/PR back to the actual repo if the
# content being registered differs from what's already on that branch —
# but since sync_repo() already pushed/merged this exact content moments
# earlier, it's always identical here, so this registers with zero
# repo-side write (confirmed live: an equivalent manual test showed an
# empty "Files changed" diff on the resulting PR). Requires endpointId to
# have REAL Bitbucket access to this specific repo — without it, every
# call below fails with "no access to this repository" (also confirmed
# live); that's reported clearly per file rather than aborting the run.
# Staged vs. standard workflow detection: there's no reliable marker in the
# YAML content itself (checked live — both kinds share `kind: workflow`),
# so this relies on the `staged-pipeline*` filename convention used by
# these templates. A future template with different naming would need this
# heuristic updated.
# ---------------------------------------------------------------------------
register_workflows() {
  local service_id="$1" repo_path="$2" resource_name="$3"
  local wf_dir="${repo_path}/.cloudbees/workflows"
  [ -d "$wf_dir" ] || { log "No .cloudbees/workflows for '$resource_name' — skipping workflow registration."; return; }
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would register workflow(s) in $wf_dir for '$resource_name'" >&2
    return
  fi
  log "Registering workflows for '$resource_name'..."
  local f base staged payload resp name ok=0 fail=0 auth_failed="false"
  local failed_names=()
  for f in "$wf_dir"/*.yaml "$wf_dir"/*.yml; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    staged="false"
    case "$base" in staged-pipeline*) staged="true" ;; esac
    payload=$(jq -n --rawfile content "$f" --arg fileName ".cloudbees/workflows/${base}" \
      --arg commitMessage "Register existing workflow ${base} via Unify" --argjson staged "$staged" \
      '{fileName:$fileName, yamlContent:$content, branchName:"main", commitMessage:$commitMessage, createNewBranch:false, createPullRequest:false, isStagedWorkflow:$staged}')
    resp=$(unify_write POST "/v1/organizations/${ORG_ID}/services/${service_id}/automations" "$payload")
    name=$(echo "$resp" | jq -r '.automations[0].name // empty')
    if [ -z "$name" ]; then
      # One retry — transient HTTP 503s observed in practice when firing
      # many of these calls back-to-back.
      sleep 2
      resp=$(unify_write POST "/v1/organizations/${ORG_ID}/services/${service_id}/automations" "$payload")
      name=$(echo "$resp" | jq -r '.automations[0].name // empty')
    fi
    if [ -n "$name" ]; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      failed_names+=("$base")
      local msg; msg=$(echo "$resp" | jq -r '.message // "unknown error"' 2>/dev/null)
      echo "    WARNING: failed to register '$base': $msg" >&2
      # An auth failure is NOT a per-file problem — every remaining call
      # will fail the same way, so stop instead of grinding through the
      # rest and burying the real cause in a wall of warnings. (This
      # happened for real: a Unify PAT stopped being authorized part-way
      # through a run, and the old blanket "integration lacks access"
      # message below sent the diagnosis in completely the wrong
      # direction.)
      case "$msg" in
        *"not authorized"*|*"Unauthorized"*|*"unauthenticated"*|*"Unauthenticated"*)
          echo "    STOPPING: your Unify credentials are being rejected (not a problem with this file)." >&2
          echo "    Check that \$UNIFY_PAT is still valid and has access to this organization, then re-run." >&2
          auth_failed="true"
          break ;;
      esac
    fi
  done
  if [ "$auth_failed" = "true" ]; then
    log "  Registered $ok workflow(s) for '$resource_name' before Unify rejected the credentials — the rest were NOT registered. Fix \$UNIFY_PAT and re-run (re-running is safe)."
  elif [ "$fail" -gt 0 ]; then
    log "  Registered $ok workflow(s) for '$resource_name'; $fail failed (${failed_names[*]}) — if the errors above mention repository access, the integration in use doesn't have real access to this repo."
  else
    log "  Registered $ok workflow(s) for '$resource_name'."
  fi
}

# ---------------------------------------------------------------------------
# Create a new Environment.
# FIX (confirmed live, 2026-09-16): this previously always failed with
# HTTP 400 "invalid endpoint provided, must have either parent_id or a
# contribution_id and contribution_type" — wrongly concluded at the time to
# be a genuine backend/permission restriction and escalated to CloudBees as
# such. It was NOT a backend limitation: the request body was wrapped in
# {"endpoint": {...}}, but the real
# OpenAPI spec (EndpointService_AddEndpoint) defines the body as the flat
# api.endpoint.Endpoint object itself — no envelope. Verified against a
# real, working environment's own stored fields via GET before fixing this
# (contributionId/contributionType/contributionTargets below match exactly
# what an existing manually-created environment actually has), then
# confirmed live: an unwrapped POST with this exact shape succeeds and
# returns a real id.
# ---------------------------------------------------------------------------
create_environment() {
  local name="$1"
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would create environment '$name'" >&2
    printf '<dry-run>'; return
  fi
  local resp new_id
  resp=$(unify_write POST "/v1/resources/${ORG_ID}/endpoints" \
    "$(jq -nc --arg org "$ORG_ID" --arg name "$name" \
      '{resourceId:$org, name:$name, contributionId:"cb.configuration.basic-environment",
        contributionType:"cb.platform.environment", contributionTargets:["cb.configuration.environments"],
        properties: [{name:"approvers", isSecret:false}]}')")
  new_id=$(echo "$resp" | jq -r '.id // empty')
  [ -z "$new_id" ] && echo "  API error creating environment '$name': $resp" >&2
  printf '%s' "$new_id"
}

# ---------------------------------------------------------------------------
# Create-or-reuse a Bitbucket integration SCOPED TO ONE SPECIFIC destination
# repo, using that repo's own write token. This is what actually fixes
# "workflows don't populate in Unify" (confirmed live, 2026-09-16): a
# Component/Application whose endpointId points at an integration lacking
# real access to that specific repo will forever show empty Workflows/
# Properties discovery, with no error at creation time — the failure only
# surfaces later, deep in register_workflows()/CreateAutomation, as "no
# access to this repository". Giving every resource its OWN scoped
# integration (rather than sharing one generic one across all repos) avoids
# that entirely. Same unwrapped-body fix as create_environment() above —
# this call hit the identical false "backend restriction" symptom before
# being fixed.
# ---------------------------------------------------------------------------
ensure_bitbucket_integration_for_repo() {
  local dest_slug="$1" token="$2"
  local int_name="${dest_slug}-scoped-integration"
  local existing_id
  existing_id=$(unify_get "/v1/resources/${ORG_ID}/endpoints" \
    | jq -r --arg n "$int_name" '.endpoints[]? | select(.name == $n) | .id' | head -1)
  if [ -n "$existing_id" ]; then
    log "  Bitbucket integration '$int_name' already exists (id=$existing_id) — reusing it." >&2
    printf '%s' "$existing_id"; return
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would create Bitbucket integration '$int_name'" >&2
    printf '<dry-run>'; return
  fi
  local resp new_id
  resp=$(unify_write POST "/v1/resources/${ORG_ID}/endpoints" \
    "$(jq -nc --arg org "$ORG_ID" --arg name "$int_name" --arg ws "$WORKSPACE" --arg token "$token" \
      '{resourceId:$org, name:$name, description:("Scoped access to " + $name),
        contributionType:"cb.platform.endpoint-type", contributionId:"cb.bitbucket.bitbucket-cloud-token-endpoint-type",
        contributionTargets:["cb.platform.endpoint-types","cb.platform.scm.repository","scm"],
        properties:[{name:"workspace",string:$ws,isSecret:false}, {name:"token",string:$token,isSecret:true},
                    {name:"url",string:"https://bitbucket.org",isSecret:false}, {name:"provider",string:"bitbucket",isSecret:false}]}')")
  new_id=$(echo "$resp" | jq -r '.id // empty')
  if [ -z "$new_id" ]; then
    echo "  ERROR creating Bitbucket integration '$int_name': $resp — falling back to the shared integration for this resource." >&2
    return 1
  fi
  log "  Created Bitbucket integration '$int_name' (id=$new_id)." >&2
  printf '%s' "$new_id"
}

# ---------------------------------------------------------------------------
# Interactively configure N environments: for each one, the customer picks
# from a NUMBERED LIST of existing environments, or creates a new one by
# name. No typing names blind, no silent skipping — every choice is
# explicit. This never touches the Unify UI; the whole thing runs from the
# terminal.
# ---------------------------------------------------------------------------
configure_environments() {
  # IMPORTANT: this function's stdout is captured via command substitution
  # by its caller (env_ids_json=$(configure_environments)) to get the final
  # JSON array. Every informational echo/log line below MUST go to stderr
  # (>&2) — otherwise it silently leaks into that captured value instead of
  # being shown on screen, corrupting the JSON (confirmed live: this was a
  # real bug here — every prompt/message vanished from the terminal and
  # only didn't crash the run because the caller happened to short-circuit
  # before ever using the corrupted value).
  #
  # Called ONCE PER COMPONENT (per explicit user decision, 2026-09-16):
  # environments are selected at Component-creation time, not for the
  # Application — the Application is created with linkedEnvironmentIds
  # hardcoded to [] instead. $1 is the resource name, used only to make
  # the prompt clear about which resource this is for.
  local resource_name="$1"
  # FIX (confirmed live): a transient network/API hiccup can make this GET
  # return something jq can't parse, which previously crashed with a
  # cryptic "integer expression expected" error deep in the loop below.
  # Validate up front and fall back to "no existing environments" (still
  # usable — you can create new ones) instead of crashing the whole run.
  local existing_envs
  existing_envs=$(unify_get "/v1/resources/${ORG_ID}/endpoints" \
    | jq -c '[.endpoints[]? | select(.contributionType == "cb.platform.environment") | {id, name}]' 2>/dev/null)
  if ! echo "$existing_envs" | jq -e . > /dev/null 2>&1; then
    echo "  WARNING: could not fetch the existing environment list (network/API issue) — you can still create new ones below." >&2
    existing_envs='[]'
  fi
  local existing_count; existing_count=$(echo "$existing_envs" | jq 'length')

  echo "" >&2
  # Environments are OPTIONAL: 0 (or just pressing Enter) skips this step
  # entirely and moves straight on to the next one, and 's' bails out
  # mid-way through if the customer changes their mind after seeing the
  # list. Nothing here is mandatory.
  local nenv
  nenv=$(prompt_count "How many environments do you want to configure for '$resource_name'? (0 = none, or just press Enter to skip) " 0)
  if [ "$nenv" -eq 0 ]; then
    log "  No environments configured for '$resource_name' — moving on to the next step." >&2
    echo '[]'; return
  fi
  local ids=() e
  for ((e = 1; e <= nenv; e++)); do
    echo "" >&2
    echo "Environment #$e of $nenv:" >&2
    local choice=""
    if [ "$existing_count" -gt 0 ]; then
      while true; do
        echo "  Existing environments on this org:" >&2
        echo "$existing_envs" | jq -r 'to_entries[] | "    \(.key + 1)) \(.value.name)"' >&2
        echo "    0) None of these — create a NEW environment" >&2
        echo "    s) Skip — no (more) environments, continue to the next step" >&2
        read_or_eof choice "  Choose a number, or 's' to skip: " || return 1
        case "$choice" in
          s|S|skip|SKIP) choice="s"; break ;;
          0) break ;;
          ''|*[!0-9]*) echo "  Please pick a number from the list, 0 to create a new one, or 's' to skip." >&2 ;;
          *)
            # Out-of-range used to pass straight through: jq returned null
            # for the index and a literal "null" got linked as an
            # environment ID. Validated here instead.
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$existing_count" ]; then break; fi
            echo "  '$choice' isn't on the list — pick 1-${existing_count}, 0 to create a new one, or 's' to skip." >&2 ;;
        esac
      done
    else
      echo "  No existing environments found on this org." >&2
      # Previously this FORCED the create-new path with no way out, so a
      # customer who didn't want an environment was stuck having to name
      # one. Now it's a real choice.
      if confirm "  Create a new environment now? [y/N] "; then choice="0"; else choice="s"; fi
    fi

    if [ "$choice" = "s" ]; then
      log "  Skipping any further environment configuration for '$resource_name'." >&2
      break
    elif [ "$choice" = "0" ]; then
      read -r -p "  Name for the new environment: " new_name
      local new_id; new_id=$(create_environment "$new_name")
      if [ -n "$new_id" ] && [ "$new_id" != "<dry-run>" ]; then
        ids+=("$new_id")
        log "  Created environment '$new_name'." >&2
      elif [ "$new_id" != "<dry-run>" ]; then
        # FIX (confirmed live): environment creation can fail (confirmed:
        # a real HTTP 400 from the API even with a payload matching an
        # existing, working environment exactly — an open question that
        # was never resolved here) — this used to
        # fail SILENTLY, with no indication at all that '$new_name' never
        # got added. Always say so explicitly instead.
        echo "  ERROR: failed to create environment '$new_name' — it will NOT be linked. See any API error above." >&2
      fi
    else
      local idx=$((choice - 1))
      local chosen_id chosen_name
      chosen_id=$(echo "$existing_envs" | jq -r --argjson i "$idx" '.[$i].id')
      chosen_name=$(echo "$existing_envs" | jq -r --argjson i "$idx" '.[$i].name')
      ids+=("$chosen_id")
      log "  Using existing environment '$chosen_name'." >&2
    fi
  done
  # FIX (confirmed live): referencing "${ids[@]}" when the array has ZERO
  # elements triggers "unbound variable" under `set -u` in this bash
  # version (3.2, macOS's stock bash) — a known old-bash limitation, fixed
  # in bash 4.4+ but not here. Guard explicitly instead of relying on the
  # expansion being safe.
  if [ "${#ids[@]}" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "${ids[@]}" | jq -R . | jq -sc .
  fi
}

# ---------------------------------------------------------------------------
# Discover which vars/secrets a repo's real .cloudbees/workflows/*.yaml
# files reference. Prints {"vars": [...], "secrets": [...]} — shared by
# set_properties() and the template-JSON generator below, so both always
# agree on exactly what a repo needs.
# ---------------------------------------------------------------------------
discover_property_names() {
  local workflows_dir="$1"
  if [ ! -d "$workflows_dir" ]; then echo '{"vars":[],"secrets":[]}'; return; fi
  local vars secrets
  vars=$(grep -h -v '^\s*#' "$workflows_dir"/*.yaml 2>/dev/null | grep -oE '\$\{\{[[:space:]]*vars\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}\}' | sed -E 's/.*vars\.([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u)
  secrets=$(grep -h -v '^\s*#' "$workflows_dir"/*.yaml 2>/dev/null | grep -oE '\$\{\{[[:space:]]*secrets\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}\}' | sed -E 's/.*secrets\.([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u)
  jq -nc --arg v "$vars" --arg s "$secrets" \
    '{vars: ($v | split("\n") | map(select(length > 0))), secrets: ($s | split("\n") | map(select(length > 0)))}'
}

# ---------------------------------------------------------------------------
# The placeholder value written into every generated template field. Using
# an obvious, self-documenting dummy (rather than "") makes it visually
# unambiguous in the file which fields still need real values — and
# because it encodes the field's own name, is_placeholder_value() below
# can regenerate and compare it exactly to detect "customer left this
# untouched" without needing any separate tracking.
placeholder_value() { printf '<ENTER_VALUE_FOR_%s>' "$1"; }
is_placeholder_value() { [ "$2" = "$(placeholder_value "$1")" ]; }

# ---------------------------------------------------------------------------
# Generate a template JSON file — one section per resource, each with ITS
# OWN complete set of discovered properties/secrets:
#   {
#     "<resource-slug>": {"NAME": "<ENTER_VALUE_FOR_NAME>", ...},
#     "<other-resource-slug>": {"NAME": "<ENTER_VALUE_FOR_NAME>", ...}
#   }
# No shared/fallback section — values genuinely differ per resource every
# time (per explicit user decision), so each resource's values are always
# entered independently, even for names that happen to also appear
# elsewhere. Prints the total number of (resource, name) entries generated.
# ---------------------------------------------------------------------------
ensure_properties_template() {
  local json_path="$1"; shift
  local result='{}' total=0
  while [ "$#" -gt 0 ]; do
    local slug="$1" p="$2"; shift 2
    local disc names count
    disc=$(discover_property_names "${p}/.cloudbees/workflows")
    names=$(echo "$disc" | jq -c '.vars + .secrets | unique')
    count=$(echo "$names" | jq 'length')
    total=$((total + count))
    result=$(echo "$result" | jq --arg s "$slug" --argjson names "$names" \
      '. + {($s): ([$names[] | {(.): ("<ENTER_VALUE_FOR_" + . + ">")}] | add // {})}')
  done
  echo "$result" > "$json_path"
  echo "$total"
}

# ---------------------------------------------------------------------------
# Discover + set Properties/Secrets from real .cloudbees/workflows.
# ---------------------------------------------------------------------------
set_properties() {
  local resource_id="$1" repo_path="$2" resource_slug="$3"
  local workflows_dir="${repo_path}/.cloudbees/workflows"
  if [ ! -d "$workflows_dir" ]; then log "No .cloudbees/workflows at $workflows_dir — skipping Properties."; return; fi

  local discovered var_names secret_names
  discovered=$(discover_property_names "$workflows_dir")
  var_names=$(echo "$discovered" | jq -r '.vars[]')
  secret_names=$(echo "$discovered" | jq -r '.secrets[]')

  log "Discovered for $resource_id:"
  echo "$var_names" | sed 's/^/    vars./'
  echo "$secret_names" | sed 's/^/    secrets./'
  if [ "$DRY_RUN" = "true" ]; then echo "  [dry-run] would prompt for and set the above." >&2; return; fi

  local values_file="${PROPERTIES_VALUES_FILE:-}" desired="[]" name val
  lookup_or_prompt() {
    local n="$1" is_secret="$2"
    if [ -n "$values_file" ] && [ -f "$values_file" ]; then
      # No shared fallback — values genuinely differ per resource every
      # time, so only THIS resource's own section is checked. A value
      # still equal to its generated placeholder (i.e. the customer never
      # actually edited it) is treated as not-provided, never applied as
      # if it were real.
      local placeholder; placeholder=$(placeholder_value "$n")
      local from_file
      from_file=$(jq -r --arg s "$resource_slug" --arg n "$n" --arg ph "$placeholder" \
        '((.[$s][$n] // "") as $r | if ($r | length) > 0 and $r != $ph then $r else "" end)' "$values_file")
      [ -n "$from_file" ] && { printf '%s' "$from_file"; return; }
    fi
    if [ "$is_secret" = "true" ]; then read -r -s -p "  $n (Secret, hidden) = " val >&2; echo >&2
    else read -r -p "  $n (Property) = " val >&2; fi
    printf '%s' "$val"
  }
  # FIX (confirmed live): must read names into arrays FIRST, not loop with
  # `while read <<< "$var_names"` directly — a here-string redirects the
  # WHOLE loop's stdin, and the nested `read -p` inside lookup_or_prompt()
  # (called via command substitution, which inherits that same stdin)
  # ends up consuming the NEXT variable NAME as if it were the typed
  # value, shifting every answer off by one. This is a well-known bash
  # trap with this exact pattern — reading into arrays first (no stdin
  # redirection on the loop)
  # avoids it entirely.
  local var_names_arr=() secret_names_arr=()
  while IFS= read -r name; do [ -n "$name" ] && var_names_arr+=("$name"); done <<< "$var_names"
  while IFS= read -r name; do [ -n "$name" ] && secret_names_arr+=("$name"); done <<< "$secret_names"

  for name in "${var_names_arr[@]}"; do
    val=$(lookup_or_prompt "$name" "false")
    desired=$(echo "$desired" | jq --arg n "$name" --arg v "$val" '. + [{name:$n, string:$v, isSecret:false}]')
  done
  for name in "${secret_names_arr[@]}"; do
    val=$(lookup_or_prompt "$name" "true")
    desired=$(echo "$desired" | jq --arg n "$name" --arg v "$val" '. + [{name:$n, string:$v, isSecret:true}]')
  done

  local count; count=$(echo "$desired" | jq 'length')
  [ "$count" -eq 0 ] && { log "Nothing to set for $resource_id."; return; }

  local existing; existing=$(unify_get "/v1/resources/${resource_id}/properties" | jq '[.properties[]? | {(.name): .}] | add // {}')
  local to_create="[]" to_update="[]" i
  for ((i = 0; i < count; i++)); do
    local prop pname current
    prop=$(echo "$desired" | jq -c ".[$i]"); pname=$(echo "$prop" | jq -r '.name')
    current=$(echo "$existing" | jq -c --arg n "$pname" '.[$n] // empty')
    if [ -z "$current" ]; then
      to_create=$(echo "$to_create" | jq --argjson p "$prop" '. + [$p]')
    else
      local cur_val new_val; cur_val=$(echo "$current" | jq -r '.string // ""'); new_val=$(echo "$prop" | jq -r '.string // ""')
      if [ "$cur_val" != "$new_val" ]; then
        echo "  '$pname' already has a different value — current: $cur_val, new: $new_val"
        confirm "  Overwrite '$pname'? [y/N] " && to_update=$(echo "$to_update" | jq --argjson p "$prop" '. + [$p]')
      fi
    fi
  done
  if [ "$(echo "$to_create" | jq 'length')" -gt 0 ]; then
    unify_write POST "/v1/resources/${resource_id}/properties" "$(jq -nc --arg rid "$resource_id" --argjson props "$to_create" '{resourceId:$rid, properties:$props}')" > /dev/null
    log "  Created $(echo "$to_create" | jq 'length') propert(y/ies)."
  fi
  local ucount; ucount=$(echo "$to_update" | jq 'length')
  for ((i = 0; i < ucount; i++)); do
    local prop pname; prop=$(echo "$to_update" | jq -c ".[$i]"); pname=$(echo "$prop" | jq -r '.name')
    unify_write PUT "/v1/resources/${resource_id}/properties/${pname}" "$(jq -nc --arg rid "$resource_id" --argjson p "$prop" '{property: ($p + {resourceId:$rid})}')" > /dev/null
  done
  [ "$ucount" -gt 0 ] && log "  Updated $ucount propert(y/ies)."
}

# ---------------------------------------------------------------------------
# Interactive main flow
# ---------------------------------------------------------------------------
main() {
  echo "Templates available:"
  local i=1; for t in "${TEMPLATE_REPOS[@]}"; do echo "  $i) $t"; i=$((i+1)); done

  log "Resolving a Bitbucket integration on org $ORG_ID..."
  local endpoint_id; endpoint_id=$(resolve_bitbucket_endpoint_id)
  [ -z "$endpoint_id" ] && { echo "No Bitbucket integration available — see instructions above." >&2; exit 1; }
  log "Using Bitbucket integration: $endpoint_id"

  choose_bitbucket_mode

  # In-memory only (not a file) — a persisted path-tracking file grew an
  # unbounded number of duplicate entries across repeated runs during
  # testing, causing Properties to silently re-run multiple times per
  # resource. This is scoped to a single invocation, which is all it needs.
  declare -a comp_ids=() slugs=() paths=()

  local ncomp; ncomp=$(prompt_count "How many Components to onboard? " 0)
  for ((c = 1; c <= ncomp; c++)); do
    echo ""
    local template; template=$(prompt_template "  Component #$c")
    # The Bitbucket repo name and the Unify Component name are asked
    # separately now — they're allowed to differ. $dest_slug drives
    # everything Bitbucket-side (token lookup, clone/push, the scoped
    # integration, the stored repositoryUrl); $unify_name is only what the
    # Component is called in Unify.
    local rn; rn=$(prompt_repo_and_name "  Component #$c")
    local dest_slug="${rn%%|*}" unify_name="${rn##*|}"
    local repo_path
    if ! repo_path=$(sync_repo "$template" "$dest_slug"); then
      # Covers both a real sync failure and the customer declining the
      # confirmation gate, so keep this wording neutral rather than
      # calling it an error.
      echo "  Skipping Component #$c ('$unify_name') — its repo was not synced (see the message above)." >&2
      continue
    fi
    # Give this Component its OWN scoped Bitbucket integration (root fix
    # for workflows not populating — a shared integration isn't guaranteed
    # real access to every repo it's pointed at). Falls back to the shared
    # $endpoint_id if scoped creation fails for any reason.
    local comp_endpoint_id="$endpoint_id"
    local scoped_id; scoped_id=$(ensure_bitbucket_integration_for_repo "$dest_slug" "$(push_token_for_repo "$dest_slug")") || true
    [ -n "$scoped_id" ] && [ "$scoped_id" != "<dry-run>" ] && comp_endpoint_id="$scoped_id"
    # Environments are selected HERE, per Component (per explicit user
    # decision, 2026-09-16) — NOT for the Application below, which always
    # gets linkedEnvironmentIds=[] now. Entirely optional; can be skipped.
    local comp_env_ids_json; comp_env_ids_json=$(configure_environments "$unify_name")
    # A refused create (e.g. Unify allows only ONE active Component per
    # repository URL — "Another active component already exists for url:
    # ...") used to abort the entire run at this point under set -e. Skip
    # just this Component and carry on instead.
    local cid
    if ! cid=$(ensure_service "$unify_name" "https://bitbucket.org/${WORKSPACE}/${dest_slug}" "COMPONENT" "$comp_endpoint_id" "[]" "$comp_env_ids_json"); then
      echo "  Skipping Component #$c ('$unify_name') — see the error above. Nothing else was changed for it." >&2
      continue
    fi
    comp_ids+=("$cid")
    slugs+=("$unify_name"); paths+=("$repo_path")
    register_workflows "$cid" "$repo_path" "$unify_name"
  done

  echo ""
  local atemplate; atemplate=$(prompt_template "Now the Application")
  local arn; arn=$(prompt_repo_and_name "Application")
  local adest_slug="${arn%%|*}" aunify_name="${arn##*|}"
  local arepo_path
  if ! arepo_path=$(sync_repo "$atemplate" "$adest_slug"); then
    echo "Stopping: the Application's repo was not synced (see the message above), so the Application was not created." >&2
    echo "Any Components created above are unaffected and already saved. Re-running is safe." >&2
    exit 1
  fi

  local app_endpoint_id="$endpoint_id"
  local app_scoped_id; app_scoped_id=$(ensure_bitbucket_integration_for_repo "$adest_slug" "$(push_token_for_repo "$adest_slug")") || true
  [ -n "$app_scoped_id" ] && [ "$app_scoped_id" != "<dry-run>" ] && app_endpoint_id="$app_scoped_id"

  # Application no longer gets an environment-selection step at all (per
  # explicit user decision, 2026-09-16) — always linked to zero
  # environments directly; environments live on its Components instead.
  local comp_ids_json="[]"
  [ "${#comp_ids[@]}" -gt 0 ] && comp_ids_json=$(printf '%s\n' "${comp_ids[@]}" | jq -R . | jq -sc .)
  local app_id
  if ! app_id=$(ensure_service "$aunify_name" "https://bitbucket.org/${WORKSPACE}/${adest_slug}" "APPLICATION" "$app_endpoint_id" "$comp_ids_json" "[]"); then
    echo "ERROR: couldn't create/update the Application '$aunify_name' — see the error above." >&2
    echo "       Any Components created above are unaffected and already saved." >&2
    exit 1
  fi
  slugs+=("$aunify_name"); paths+=("$arepo_path")
  register_workflows "$app_id" "$arepo_path" "$aunify_name"

  echo ""
  # "${arr[*]:-}" not "${arr[*]}" — an EMPTY array is now genuinely
  # reachable (0 Components is a valid answer), and bash 3.2 treats a bare
  # empty-array expansion as an unbound variable under set -u.
  log "Summary: components=${comp_ids[*]:-none}, application=$app_id"
  echo ""

  if confirm "Run the Properties step now for everything created above? [y/N] "; then
    read -r -p "Path to a JSON file for property/secret values: " props_json_path
    # FIX (confirmed live): bash only expands a leading ~ when it's typed
    # directly in a command — NOT when it's sitting inside a variable that
    # came from `read`. Without this, a path like "~/foo.json" stays a
    # literal string containing the "~" character, and every file
    # operation below fails with "No such file or directory".
    case "$props_json_path" in
      "~"|"~/"*) props_json_path="${HOME}${props_json_path#\~}" ;;
    esac
    if [ ! -f "$props_json_path" ]; then
      local slug_path_pairs=() k
      for ((k = 0; k < ${#slugs[@]}; k++)); do slug_path_pairs+=("${slugs[$k]}" "${paths[$k]}"); done
      local ncount; ncount=$(ensure_properties_template "$props_json_path" "${slug_path_pairs[@]}")
      echo ""
      echo "No file found at '$props_json_path' — created a template there with $ncount entries across these resources: ${slugs[*]:-none}"
      echo "Each resource has its own section with its own placeholder values (<ENTER_VALUE_FOR_...>) — fill in the real"
      echo "value for each field under its resource's section."
      echo "Open it, fill in the real values, save it, then run this script again with the same path to actually apply them."
    else
      export PROPERTIES_VALUES_FILE="$props_json_path"
      local k
      for ((k = 0; k < ${#slugs[@]}; k++)); do
        log "Properties for ${slugs[$k]}"
        local rid; rid=$(unify_get "/v1/organizations/${ORG_ID}/services" | jq -r --arg n "${slugs[$k]}" '.service[]? | select(.name == $n) | .id')
        set_properties "$rid" "${paths[$k]}" "${slugs[$k]}"
      done
    fi
  fi
  log "Done."
}

if [ -n "$PROPERTIES_ONLY_PATH" ]; then
  apply_properties_only "$PROPERTIES_ONLY_PATH"
else
  main "$@"
fi
