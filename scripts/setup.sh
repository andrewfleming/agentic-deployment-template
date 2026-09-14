#!/usr/bin/env bash
# Adds the agentic deployment template to an existing repository.
#
# Usage (run from the root of your target repo):
#   bash <(curl -fsSL https://raw.githubusercontent.com/whyisjake/agentic-deployment-template/main/scripts/setup.sh)
#
# Or clone and run locally:
#   bash /path/to/agentic-deployment-template/scripts/setup.sh
#
# Updating a repository that already has the template:
#   Pass --update. Without it every file that already exists is skipped, which
#   is right for a first install and useless for picking up a later fix.
#
#     bash /path/to/agentic-deployment-template/scripts/setup.sh --update
#
#   --update overwrites the files this template owns, and refuses to run while
#   .github/ or scripts/ has uncommitted changes, so git is always the undo.
#   Review the result with `git diff` before committing.
#
#   .github/LABELS.yml is never overwritten, because the documented way to
#   adopt it is to merge its entries into a file you already have. Overwriting
#   would silently delete labels that are yours.
#
#   Two files are meant to be edited per project: the allow list in
#   .github/actions/claude-run/action.yml and the sandbox in
#   .github/actions/codex-run/action.yml. An update replaces both. Re-apply
#   your changes afterwards; the summary reminds you if either one moved.
#
# Installing from a fork or a mirror:
#   Set TEMPLATE_REPO_URL to the raw base URL of the copy you want, and
#   TEMPLATE_DOCS_URL to its web URL. Both are optional.
#
#     TEMPLATE_REPO_URL=https://raw.githubusercontent.com/<owner>/<repo>/<ref> \
#       bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/scripts/setup.sh)
#
#   Setting TEMPLATE_REPO_URL always wins, even when the script is run from a
#   clone. If the copy you want has no anonymous raw URL — a private repo, or a
#   host with no raw endpoint — clone it and run this script from that clone
#   instead; local mode never touches the network.
#
# What this does:
#   - Adds .github/ISSUE_TEMPLATE/agent-ready.md       (alongside existing templates)
#   - Adds .github/PULL_REQUEST_TEMPLATE/agent-generated.md  (alongside existing templates)
#   - Adds .github/LABELS.yml  (or prints merge instructions if one already exists)
#   - Adds .github/workflows/  (all agent workflow files, skips any that already
#     exist, or replaces them with --update)
#   - Adds .github/agents/issue-screener.agent.md
#   - Adds scripts/validate-workflows.sh  (the workflow YAML + permission guard)
#   - Adds .github/actions/claude-run/       (the shared Claude invocation)
#   - Adds .github/actions/codex-run/        (the shared Codex invocation)
#   - Adds .github/actions/screen-issue/     (the shared issue structure check)
#   - Creates docs/ if it doesn't exist
#   - Sets the AGENT_PROVIDER repository variable, and reports on the secret
#   - Prints next steps
#
# Nothing is committed — you review and commit the changes yourself.
#
# AGENT PROVIDER:
#   AGENT_PROVIDER=claude  — choose the provider without being prompted
#   SKIP_AGENT_SETUP=1     — skip the provider section entirely
#
#   The provider's credential is never set here. Secrets are write-only and it
#   is your key, so the script reports whether it is present and tells you how
#   to add it.
#
# EXISTING TEMPLATES:
#   Issue templates coexist — GitHub shows all files in ISSUE_TEMPLATE/ as choices.
#   PR templates coexist   — GitHub shows all files in PULL_REQUEST_TEMPLATE/ as choices.
#   If you use a single flat pull_request_template.md, this script adds a named
#   PULL_REQUEST_TEMPLATE/ directory alongside it (both work at the same time).

set -euo pipefail

UPDATE_MODE="no"
for arg in "$@"; do
  case "$arg" in
    --update)
      UPDATE_MODE="yes"
      ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf '\033[0;31mUnknown option: %s\033[0m\n' "$arg" >&2
      printf 'Run with --help for usage.\n' >&2
      exit 1
      ;;
  esac
done

# Counters for the closing summary. In update mode the useful number is how
# many files actually changed, not how many were considered: a run that
# rewrites nothing should say so rather than printing fourteen lines that all
# look like work.
ADDED=0
UPDATED=0
UNCHANGED=0
SKIPPED=0
CUSTOMISED_FILE_CHANGED="no"

REPO_URL_EXPLICIT="${TEMPLATE_REPO_URL:+yes}"
REPO_URL="${TEMPLATE_REPO_URL:-https://raw.githubusercontent.com/whyisjake/agentic-deployment-template/main}"
DOCS_URL="${TEMPLATE_DOCS_URL:-https://github.com/whyisjake/agentic-deployment-template}"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" || true

# Decide where files come from once, up front, instead of per file.
#
# fetch() used to try the local clone and fall back to REPO_URL whenever a file
# was not found there. That fallback is silent: a clone that is incomplete, or a
# TEMPLATE_DIR that resolved somewhere unexpected, downloads from the hardcoded
# URL instead and the run still reports success. Deciding once means the source
# is printed before anything is written, and a broken local clone fails loudly
# rather than quietly installing someone else's copy.
if [[ "$REPO_URL_EXPLICIT" == "yes" ]]; then
  SOURCE_MODE="remote"
elif [[ -n "$TEMPLATE_DIR" && -f "$TEMPLATE_DIR/.github/workflows/agent-ready-trigger.yml" ]]; then
  SOURCE_MODE="local"
else
  SOURCE_MODE="remote"
fi

if [[ "$SOURCE_MODE" == "local" ]]; then
  SOURCE_DESC="local clone at $TEMPLATE_DIR"
  LABELS_SOURCE="$TEMPLATE_DIR/.github/LABELS.yml"
else
  SOURCE_DESC="$REPO_URL"
  LABELS_SOURCE="$REPO_URL/.github/LABELS.yml"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

# Copy a file from the local clone, or download it — whichever mode was chosen
# above. No fallback between the two: if the chosen source cannot supply a file,
# that is an error worth stopping on.
fetch() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ "$SOURCE_MODE" == "local" ]]; then
    if [[ ! -f "$TEMPLATE_DIR/$src" ]]; then
      red "Error: $src is missing from the template clone at $TEMPLATE_DIR"
      red "       The clone looks incomplete. Re-clone it, or set TEMPLATE_REPO_URL to install from a URL."
      exit 1
    fi
    cp "$TEMPLATE_DIR/$src" "$dest"
  else
    if ! curl -fsSL "$REPO_URL/$src" -o "$dest"; then
      red "Error: could not download $src from $REPO_URL"
      red "       If that copy is private or has no raw URL, clone it and run this script from the clone."
      exit 1
    fi
  fi
}

# Install a file, or update one that is already there.
#
# The rule differs by mode, and the difference is the whole point of --update:
# an existing file is left alone on a first install and replaced on an update.
# In update mode the file is fetched to a temporary path first so an unchanged
# file can be reported as unchanged rather than rewritten, which keeps the
# summary honest and leaves mtimes alone.
place() {
  local src="$1" dest="$2"

  if [[ ! -f "$dest" ]]; then
    fetch "$src" "$dest"
    green "  added: $dest"
    ADDED=$((ADDED + 1))
    return
  fi

  if [[ "$UPDATE_MODE" != "yes" ]]; then
    yellow "  skipped (already exists): $dest"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  local tmp
  tmp="$(mktemp)"
  fetch "$src" "$tmp"

  if cmp -s "$tmp" "$dest"; then
    dim "  unchanged: $dest"
    UNCHANGED=$((UNCHANGED + 1))
    rm -f "$tmp"
    return
  fi

  cat "$tmp" > "$dest"
  rm -f "$tmp"
  green "  updated: $dest"
  UPDATED=$((UPDATED + 1))

  # The two files the template tells you to edit. Replacing them is correct
  # and also destroys local customisation, so the summary has to say so.
  case "$dest" in
    *"/claude-run/action.yml"|*"/codex-run/action.yml")
      CUSTOMISED_FILE_CHANGED="yes"
      ;;
  esac
}

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -d ".git" ]]; then
  red "Error: run this script from the root of a git repository."
  exit 1
fi

# Update mode overwrites files in place and keeps no backups, on the basis
# that the target is a git repository and git is a better undo than a pile of
# .bak files. That reasoning only holds while the relevant paths are clean, so
# this checks rather than assumes.
if [[ "$UPDATE_MODE" == "yes" ]]; then
  dirty="$(git status --porcelain -- .github scripts 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    red "Error: .github/ or scripts/ has uncommitted changes."
    echo ""
    printf '%s\n' "$dirty" | sed 's/^/      /'
    echo ""
    echo  "  --update overwrites these files and keeps no backups, because the"
    echo  "  intended way to undo it is git. That does not work if the changes"
    echo  "  were never committed."
    echo ""
    echo  "  Commit or stash them, then run this again."
    exit 1
  fi
fi

# Which GitHub repository this run will write its variable to.
#
# Resolved once, printed, and passed to every gh call with --repo. A bare gh
# command resolves against the current directory's remotes on its own, and a
# clone with more than one remote takes whichever gh prefers rather than the
# one you have in mind. The case that hurts is a clone whose `origin` is a
# shared or production repository and whose personal copy sits on a second
# remote: the variable lands on the shared one, quietly, and a later check for
# the provider's secret then reads that same wrong repository and reports the
# secret missing when it is present on the right one.
#
# Override with TARGET_REPO=owner/name if the resolved value is not the one
# you want.
TARGET_REPO="${TARGET_REPO:-}"
if [[ -z "$TARGET_REPO" ]] && command -v gh >/dev/null 2>&1; then
  TARGET_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

bold ""
bold "Agentic Deployment Template — Setup"
echo  "Adding agent-ready workflow files to: $(basename "$(pwd)")"
echo  "Installing from: $SOURCE_DESC"
if [[ -n "$TARGET_REPO" ]]; then
  echo  "GitHub repository:  $TARGET_REPO"
  remote_count="$(git remote 2>/dev/null | grep -c . || true)"
  if [[ "${remote_count:-0}" -gt 1 ]]; then
    yellow "  This clone has $remote_count remotes. Settings will be written to $TARGET_REPO."
    dim    "  If that is the wrong one, re-run with TARGET_REPO=owner/name."
  fi
fi
echo  ""

# ── Issue template ────────────────────────────────────────────────────────────
# GitHub shows every file in ISSUE_TEMPLATE/ as a separate choice when opening
# an issue, so agent-ready.md coexists with bug_report.md, feature_request.md, etc.

if [[ -d ".github/ISSUE_TEMPLATE" ]]; then
  dim "  .github/ISSUE_TEMPLATE/ already exists — adding agent-ready.md alongside your existing templates"
fi

place ".github/ISSUE_TEMPLATE/agent-ready.md" ".github/ISSUE_TEMPLATE/agent-ready.md"

# ── PR template ───────────────────────────────────────────────────────────────
# GitHub supports multiple named PR templates in PULL_REQUEST_TEMPLATE/.
# If you have a flat .github/pull_request_template.md, both approaches work
# simultaneously — GitHub uses the named directory when it exists.

if [[ -f ".github/pull_request_template.md" ]]; then
  dim "  Found .github/pull_request_template.md — adding named PULL_REQUEST_TEMPLATE/ alongside it"
  dim "  (GitHub uses named templates when PULL_REQUEST_TEMPLATE/ exists; your existing template is unaffected)"
fi

place ".github/PULL_REQUEST_TEMPLATE/agent-generated.md" ".github/PULL_REQUEST_TEMPLATE/agent-generated.md"

# ── LABELS.yml ────────────────────────────────────────────────────────────────
# Never overwritten, not even by --update, and this is the one exception to
# that flag.
#
# Every other file here belongs to the template. This one is a file you are
# told to merge the template's entries into, so by the time an update runs it
# may hold labels that exist nowhere upstream. Replacing it would delete them
# with no warning and no way to tell what was lost.

if [[ -f ".github/LABELS.yml" ]]; then
  yellow "  skipped (never overwritten): .github/LABELS.yml"
  echo   "  → To add or refresh agent labels, merge these entries into your own file:"
  echo   "    $LABELS_SOURCE"
  SKIPPED=$((SKIPPED + 1))
else
  fetch ".github/LABELS.yml" ".github/LABELS.yml"
  green "  added: .github/LABELS.yml"
  ADDED=$((ADDED + 1))
fi

# ── Workflows ────────────────────────────────────────────────────────────────
# Each workflow file is independent — skipping an existing file leaves the
# rest unaffected.

WORKFLOW_FILES=(
  ".github/workflows/agent-ready-trigger.yml"
  ".github/workflows/plan-approval-gate.yml"
  ".github/workflows/setup-labels.yml"
  ".github/workflows/auto-label-agent-ready.yml"
  ".github/workflows/issue-screener.yml"
  ".github/workflows/validate-workflows.yml"
  ".github/workflows/claude-pr-feedback.yml"
  ".github/workflows/codex-pr-feedback.yml"
)

for file in "${WORKFLOW_FILES[@]}"; do
  place "$file" "$file"
done

# ── Agent file ────────────────────────────────────────────────────────────────

place ".github/agents/issue-screener.agent.md" ".github/agents/issue-screener.agent.md"

# ── Composite actions ─────────────────────────────────────────────────────────
# The workflows call ./.github/actions/claude-run and ./.github/actions/codex-run
# rather than the upstream actions directly, so the permission mode, allow list
# and sandbox have one definition each.
# A repo that gets the workflows without these directories has workflows
# referencing an action that does not exist, and every agent run fails at
# startup — so this is not optional and is installed even if it already exists
# in some other form.
#
# Both providers' actions are installed regardless of AGENT_PROVIDER. An unused
# composite action costs nothing; a missing one costs a failed run at the moment
# someone switches provider, which is the worst time to discover it.

for action in claude-run codex-run screen-issue; do
  place ".github/actions/$action/action.yml" ".github/actions/$action/action.yml"
done

# ── Scripts ───────────────────────────────────────────────────────────────────
# validate-workflows.sh installs alongside the workflows because both halves of
# the guard depend on it: the agent is told to run it before opening a PR, and
# validate-workflows.yml runs it in CI. Installing the workflow without the
# script would leave the guard broken in the one repo that needs it.

place "scripts/validate-workflows.sh" "scripts/validate-workflows.sh"
chmod +x "scripts/validate-workflows.sh"

# ── docs/ directory ───────────────────────────────────────────────────────────

if [[ ! -d "docs" ]]; then
  mkdir -p docs
  green "  created: docs/"
fi

# ── Agent provider ────────────────────────────────────────────────────────────
# Copying the files in is not enough to make the agent run. The workflows read
# AGENT_PROVIDER from repository variables and the provider's key from
# repository secrets. With neither set, labels sync and CI goes green, so the
# repo looks configured — but labelling an issue agent-ready does nothing, and
# the first sign of that is an issue that never gets a PR.
#
# So the variable gets set here, and the secret — which this script cannot set,
# because secrets are write-only and it is not our credential — gets named.

# Which secret each provider needs. Empty means the provider has no single
# credential we can check for: you wire those up yourself.
secret_for_provider() {
  case "$1" in
    claude)       printf '%s' "CLAUDE_CODE_OAUTH_TOKEN" ;;
    openai-codex) printf '%s' "OPENAI_API_KEY" ;;
    *)            printf '%s' "" ;;
  esac
}

PROVIDER_NEXT_STEP="Set AGENT_PROVIDER and your provider's secret — see the README."

echo ""
bold "Agent provider"

if [[ -n "${SKIP_AGENT_SETUP:-}" ]]; then
  dim "  SKIP_AGENT_SETUP is set — leaving AGENT_PROVIDER alone."
elif [[ "$UPDATE_MODE" == "yes" ]]; then
  # An update must never ask this question.
  #
  # The provider was chosen when the template was installed. The prompt below
  # defaults to claude on an empty return, so asking again during an update
  # puts a working openai-codex repository one keystroke away from being
  # switched to a provider it holds no credentials for. Nothing about
  # refreshing files justifies that risk.
  current=""
  if [[ -n "$TARGET_REPO" ]] && command -v gh >/dev/null 2>&1; then
    current="$(gh variable list --repo "$TARGET_REPO" 2>/dev/null | awk '$1 == "AGENT_PROVIDER" { print $2 }')"
  fi
  if [[ -n "$current" ]]; then
    dim "  Leaving AGENT_PROVIDER as it is: $current"
  else
    dim "  Leaving AGENT_PROVIDER alone (not set on $TARGET_REPO, or not readable from here)."
  fi
else
  provider="${AGENT_PROVIDER:-}"

  if [[ -z "$provider" ]]; then
    if [[ -t 0 ]]; then
      echo "  Which agent should run agent-ready issues?"
      echo "    1) claude        — implemented; needs the Claude GitHub App as well"
      echo "    2) openai-codex  — implemented; needs OPENAI_API_KEY, no app to install"
      echo "    3) copilot       — NOT IMPLEMENTED: a stub you must write yourself"
      echo "    4) custom        — repository_dispatch only; you write the listener"
      choice=""
      read -r -p "  Choice [1]: " choice || true
      case "${choice:-1}" in
        1|""|claude)      provider="claude" ;;
        2|openai-codex)   provider="openai-codex" ;;
        3|copilot)        provider="copilot" ;;
        4|custom)         provider="custom" ;;
        *) red "  Not one of the four choices: $choice"; exit 1 ;;
      esac
    else
      provider="claude"
      dim "  No terminal to prompt on — using claude. Set AGENT_PROVIDER to choose another."
    fi
  fi

  case "$provider" in
    claude|openai-codex|copilot|custom) ;;
    *) red "  AGENT_PROVIDER must be one of: claude, openai-codex, copilot, custom (got: $provider)"; exit 1 ;;
  esac

  # Set the repository variable. Needs gh, and a repo that exists on the remote —
  # a fresh local repo that has never been pushed has nothing to set it on.
  #
  # `gh repo view` is the probe rather than `gh auth status`: auth status
  # aggregates every configured host and exits non-zero when any one of them
  # fails, so a second host being unreachable — an enterprise host off VPN, say —
  # makes it report "not logged in" for a repo whose own host is fine. Asking
  # about this repo answers the question that actually matters.
  variable_set="no"
  if ! command -v gh >/dev/null 2>&1; then
    yellow "  gh CLI not found — AGENT_PROVIDER not set"
  elif [[ -z "$TARGET_REPO" ]]; then
    yellow "  gh cannot see a GitHub repo here — AGENT_PROVIDER not set"
    dim   "  (the repo may not be pushed yet, or gh may not be logged in to its host: gh auth login)"
  elif gh variable set AGENT_PROVIDER --body "$provider" --repo "$TARGET_REPO" >/dev/null 2>&1; then
    green "  set: AGENT_PROVIDER=$provider  (on $TARGET_REPO)"
    variable_set="yes"
  else
    yellow "  could not set AGENT_PROVIDER — your gh token may lack permission on $TARGET_REPO"
  fi

  if [[ "$variable_set" == "no" ]]; then
    echo "  → Set it by hand: Settings → Secrets and variables → Actions → Variables → New"
    echo "    AGENT_PROVIDER = $provider"
  fi

  # Say plainly when the chosen provider does not do anything yet.
  #
  # claude and openai-codex are implemented. copilot is a stub job that echoes
  # and exits; custom dispatches a repository_dispatch event and needs a listener
  # that does not exist yet. Either way the repo installs cleanly, syncs its
  # labels, goes green, and then produces nothing the first time someone labels
  # an issue.
  #
  # This is one of two places that says so — the stub job itself also comments on
  # the issue and fails, which is the signal that reaches someone who never ran
  # this script.
  case "$provider" in
    copilot)
      echo ""
      red   "  '$provider' is not implemented — its job is a stub."
      echo  "  trigger-$provider in .github/workflows/agent-ready-trigger.yml echoes a"
      echo  "  message and exits without running an agent or opening a pull request."
      echo  "  Labelling an issue agent-ready under this provider will not produce a PR"
      echo  "  until you write that job yourself."
      echo  "  For a working agent, re-run with: AGENT_PROVIDER=claude bash scripts/setup.sh"
      echo ""
      PROVIDER_NEXT_STEP="Provider is $provider, which is a stub — implement trigger-$provider, or switch to claude."
      ;;
    openai-codex)
      echo ""
      green "  'openai-codex' is implemented."
      echo  "  trigger-openai-codex runs openai/codex-action through"
      echo  "  .github/actions/codex-run, with the same complexity routing as claude."
      echo  "  Unlike claude there is no GitHub App to install — the OPENAI_API_KEY"
      echo  "  secret is the whole credential."
      echo  "  Worth knowing: pull requests it opens use the workflow token, so they"
      echo  "  arrive without CI runs on them."
      echo ""
      ;;
    custom)
      echo ""
      yellow "  'custom' dispatches; it does not implement."
      echo   "  trigger-custom fires a repository_dispatch 'agent-ready' event carrying the"
      echo   "  issue payload. Nothing consumes it until you add a listener workflow in THIS"
      echo   "  repository — repository_dispatch is not cross-repo."
      echo   "  For a working agent without writing one, re-run with: AGENT_PROVIDER=claude"
      echo ""
      PROVIDER_NEXT_STEP="Provider is custom — add a listener workflow for the repository_dispatch 'agent-ready' event."
      ;;
  esac

  # Report on the secret. Never set it.
  secret="$(secret_for_provider "$provider")"
  # Both providers that name a secret — claude and openai-codex — are
  # implemented, so both get a real check. The stub providers name no secret and
  # fall through to the branch below.
  if [[ -z "$secret" ]]; then
    dim "  Provider '$provider' has no single required secret — its credentials are yours to wire up."
  else
    if [[ "$variable_set" == "yes" ]] && gh secret list --repo "$TARGET_REPO" 2>/dev/null | awk '{print $1}' | grep -qx "$secret"; then
      green "  found: $secret is already set"
      PROVIDER_NEXT_STEP="Provider is $provider and $secret is set — you are ready to label an issue."
    else
      red   "  missing: $secret"
      echo  "  Until it is set, labelling an issue agent-ready will not start the agent."
      echo  "  It is your credential and secrets are write-only, so this script cannot add it."
      echo  "  Add it with:  gh secret set $secret"
      echo  "  or at:        Settings → Secrets and variables → Actions → Secrets"
      PROVIDER_NEXT_STEP="Add the $secret secret — the agent cannot run without it."
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
#
# An update and a first install need different closing advice. After an update
# the labels are already synced, the provider is already chosen and the app is
# already installed, so printing the install checklist again is noise that
# hides the one thing worth reading: what changed.

if [[ "$UPDATE_MODE" == "yes" ]]; then
  echo ""
  if [[ "$UPDATED" -eq 0 ]]; then
    bold "Already up to date."
    echo ""
    echo "  $UNCHANGED file(s) checked, none changed."
    echo ""
    echo "  Full docs: $DOCS_URL"
    echo ""
    exit 0
  fi

  bold "Updated $UPDATED file(s). $UNCHANGED unchanged."
  echo ""

  if [[ "$CUSTOMISED_FILE_CHANGED" == "yes" ]]; then
    yellow "  One of the files you are meant to customise was replaced."
    echo   "  The allow list in .github/actions/claude-run/action.yml and the"
    echo   "  sandbox in .github/actions/codex-run/action.yml hold per-project"
    echo   "  settings, such as the test command your agent is permitted to run."
    echo   "  Check the diff and re-apply anything of yours that went missing."
    echo ""
  fi

  echo "  1. Read what changed before you keep it:"
  echo "     git diff"
  echo ""
  echo "  2. Commit and push:"
  echo "     git add .github/ scripts/"
  echo "     git commit -m 'chore: update agentic deployment template'"
  echo "     git push"
  echo ""
  echo "  3. Push to your DEFAULT branch, not just a feature branch."
  echo "     Workflows triggered by issues and comments always run the copy on"
  echo "     the default branch, so a change parked on a branch does nothing."
  echo ""
  echo "  Full docs: $DOCS_URL"
  echo ""
  exit 0
fi

echo ""
bold "Done. Next steps:"
echo ""
echo "  1. Review added files:"
echo "     git status"
echo ""
echo "  2. Commit:"
echo "     git add .github/ docs/"
echo "     git commit -m 'chore: add agentic deployment template'"
echo "     git push"
echo ""
echo "  3. Sync labels (run once after pushing):"
echo "     Actions → Setup Labels → Run workflow"
echo ""
echo "  4. Agent provider:"
echo "     $PROVIDER_NEXT_STEP"
echo ""

# Only the claude provider needs the app. Printing this under openai-codex
# sends people to install something their setup never uses, and quietly
# implies their agent is misconfigured when it is not.
if [[ "${provider:-claude}" == "claude" ]]; then
  echo "  5. Install the Claude GitHub App (needed as these workflows are written):"
  echo "     Easiest: run /install-github-app from Claude Code — it does the app"
  echo "     and the secret together, and you may have done it already."
  echo "     Otherwise: https://github.com/apps/claude -> Configure -> this repo"
  echo ""
  echo "     Without it, runs fail in ~29 seconds on a 401 at the app token"
  echo "     exchange, even though labels sync and the workflow fires."
  echo ""
fi

echo "  Full docs: $DOCS_URL"
echo ""
