#!/bin/bash
# Orchestrates an AgentTier review-sandbox for one pull request.
# Runs on the self-hosted runner (itself an AgentTier sandbox, in-cluster).
#
# Talks to the Router REST API to: create a Claude Code sandbox, launch the
# review in the background (fire-and-poll, because the exec API has a short
# read timeout), collect the findings, upsert a summary comment on the PR, and
# delete the sandbox. Exits non-zero if any HIGH-severity finding survived.
#
# The sandbox deliberately does NOT receive GH_TOKEN — the review is read-only
# and every GitHub write happens here on the runner.
#
# Required env:
#   ROUTER_URL     in-cluster Router base URL
#   REPO           owner/name
#   PR_NUMBER      pull request number
#   BASE_REF       target branch of the PR
#   HEAD_SHA       head commit of the PR
#   GH_TOKEN       token with pull-requests write (comment only)
set -uo pipefail

: "${ROUTER_URL:?}"; : "${REPO:?}"; : "${PR_NUMBER:?}"; : "${GH_TOKEN:?}"
export BASE_REF="${BASE_REF:-main}"
export HEAD_SHA="${HEAD_SHA:-}"
SBX="sec-review-pr-${PR_NUMBER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AGENT_REVIEW="${SCRIPT_DIR}/agent-security-review.sh"
INSTRUCTIONS="${REPO_ROOT}/.claude/skills/security-review/SKILL.md"
WORK="$(mktemp -d)"

[ -f "$INSTRUCTIONS" ] || { echo "missing audit instructions: $INSTRUCTIONS"; exit 1; }

api() { curl -s -m 30 "$@"; }
status() { api "$ROUTER_URL/api/v1/sandboxes/$SBX" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")'; }

echo "::group::Create sandbox ${SBX}"
api -X POST "$ROUTER_URL/api/v1/sandboxes" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${SBX}\",\"templateRef\":{\"name\":\"claude-code-bedrock\",\"kind\":\"ClusterSandboxTemplate\"}}"
echo
for i in $(seq 1 45); do
  st="$(status)"; echo "status=${st}"
  [ "$st" = "Running" ] && break
  sleep 4
done
echo "::endgroup::"
[ "$(status)" = "Running" ] || { echo "sandbox did not reach Running"; exit 1; }

# Build the launch payload (writes the trusted audit instructions + the review
# script via base64, then backgrounds the review with a completion sentinel).
python3 - "$AGENT_REVIEW" "$INSTRUCTIONS" > "$WORK/launch.json" <<'PY'
import base64, json, os, sys
b64f = lambda p: base64.b64encode(open(p, 'rb').read()).decode()
script_b64 = b64f(sys.argv[1])
instr_b64 = b64f(sys.argv[2])
launch = (
    f"export REPO='{os.environ['REPO']}'; export PR_NUMBER='{os.environ['PR_NUMBER']}'; "
    f"export BASE_REF='{os.environ['BASE_REF']}'; export HEAD_SHA='{os.environ['HEAD_SHA']}'; "
    f"echo '{instr_b64}' | base64 -d > /workspace/audit-instructions.md; "
    f"echo '{script_b64}' | base64 -d > /workspace/agent-security-review.sh; "
    f"rm -f /workspace/review.done /workspace/review.log /workspace/findings.b64; "
    f"setsid bash -c 'bash /workspace/agent-security-review.sh > /workspace/review.log 2>&1; "
    f"echo EXIT=$? > /workspace/review.done' >/dev/null 2>&1 </dev/null & echo LAUNCHED"
)
json.dump({"command": launch, "timeout": 15}, sys.stdout)
PY

cat > "$WORK/poll.json" <<'EOF'
{"command":"if [ -f /workspace/review.done ]; then echo DONE; cat /workspace/review.done; echo ----LOG----; tail -c 6000 /workspace/review.log; else echo RUNNING; fi","timeout":15}
EOF

cat > "$WORK/collect.json" <<'EOF'
{"command":"cat /workspace/findings.b64 2>/dev/null","timeout":15}
EOF

echo "::group::Launch Claude Code security review"
api -X POST "$ROUTER_URL/api/v1/sandboxes/$SBX/exec" -H 'Content-Type: application/json' --data @"$WORK/launch.json"
echo

RESULT=""
for i in $(seq 1 60); do
  sleep 10
  out="$(api -X POST "$ROUTER_URL/api/v1/sandboxes/$SBX/exec" -H 'Content-Type: application/json' --data @"$WORK/poll.json")"
  if printf '%s' "$out" | grep -q '"stdout":"DONE'; then
    RESULT="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["stdout"])')"
    break
  fi
  echo "  ...reviewer still working (${i})"
done
echo "::endgroup::"

echo "=== security-review output ==="
printf '%s\n' "$RESULT"

# Collect the findings payload (base64 avoids JSON-in-JSON escaping issues).
FINDINGS='[]'
REVIEW_OK=0
if printf '%s' "$RESULT" | grep -q 'REVIEW_OK'; then
  REVIEW_OK=1
  cout="$(api -X POST "$ROUTER_URL/api/v1/sandboxes/$SBX/exec" -H 'Content-Type: application/json' --data @"$WORK/collect.json")"
  decoded="$(printf '%s' "$cout" | python3 -c '
import base64, json, sys
try:
    b64 = json.load(sys.stdin).get("stdout", "").strip()
    findings = json.loads(base64.b64decode(b64).decode())
    if isinstance(findings, list):
        print(json.dumps(findings))
except Exception:
    pass' 2>/dev/null)"
  [ -n "$decoded" ] && FINDINGS="$decoded"
fi

echo "::group::Delete sandbox ${SBX}"
api -X DELETE "$ROUTER_URL/api/v1/sandboxes/$SBX" >/dev/null && echo "deleted ${SBX}"
echo "::endgroup::"

if [ "$REVIEW_OK" -ne 1 ]; then
  rm -rf "$WORK"
  echo "ERROR: the review did not complete successfully"
  exit 1
fi

# Render the summary comment and report the HIGH count on the last line.
MARKER='<!-- agenttier-security-review -->'
printf '%s' "$FINDINGS" > "$WORK/findings.json"
HIGH="$(FINDINGS_FILE="$WORK/findings.json" MARKER="$MARKER" REPO="$REPO" HEAD_SHA="$HEAD_SHA" \
  python3 - "$WORK/comment.json" <<'PY'
import json, os, sys

findings = json.load(open(os.environ['FINDINGS_FILE']))
high = [f for f in findings if f.get('severity') == 'HIGH']
medium = [f for f in findings if f.get('severity') == 'MEDIUM']
sha = os.environ.get('HEAD_SHA', '')[:7]

lines = [os.environ['MARKER'], '## 🛡️ Claude Code security review', '']
if not findings:
    lines += [f'No security issues found in the changes at `{sha}`.', '']
else:
    lines += [
        f'Reviewed the changes at `{sha}` and found '
        f'**{len(high)} HIGH** and **{len(medium)} MEDIUM** severity issue(s).',
        '',
    ]
    LIMIT = 20
    for f in (high + medium)[:LIMIT]:
        loc = '%s:%s' % (f.get('file', 'unknown'), f.get('line', '?'))
        lines.append('### %s — `%s`' % (f.get('severity', '?'), loc))
        lines.append('')
        lines.append('- **Category:** `%s`' % f.get('category', 'security_issue'))
        lines.append('- **Description:** %s' % f.get('description', '(none)'))
        if f.get('exploit_scenario'):
            lines.append('- **Exploit scenario:** %s' % f['exploit_scenario'])
        if f.get('recommendation'):
            lines.append('- **Recommendation:** %s' % f['recommendation'])
        lines.append('')
    if len(findings) > LIMIT:
        lines.append('_%d further finding(s) omitted._' % (len(findings) - LIMIT))
        lines.append('')

lines.append('<sub>Generated by Claude Code in an AgentTier sandbox. '
             'Findings are advisory — confirm before acting.</sub>')

json.dump({'body': '\n'.join(lines)}, open(sys.argv[1], 'w'))
print(len(high))
PY
)"

# Upsert: edit our previous comment if there is one, otherwise post a new one.
EXISTING="$(api -H "Authorization: token $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
  | MARKER="$MARKER" python3 -c '
import json, os, sys
try:
    for c in json.load(sys.stdin):
        if os.environ["MARKER"] in (c.get("body") or ""):
            print(c["id"]); break
except Exception:
    pass' 2>/dev/null)"

if [ -n "$EXISTING" ]; then
  api -X PATCH "https://api.github.com/repos/$REPO/issues/comments/$EXISTING" \
    -H "Authorization: token $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
    --data @"$WORK/comment.json" >/dev/null \
    && echo "Updated review comment on PR #$PR_NUMBER"
else
  api -X POST "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments" \
    -H "Authorization: token $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
    --data @"$WORK/comment.json" >/dev/null \
    && echo "Posted review comment on PR #$PR_NUMBER"
fi

rm -rf "$WORK"

# Comment first, fail second, so reviewers always see the findings.
# A count we can't read is treated as a failure, not as a pass.
case "$HIGH" in
  ''|*[!0-9]*) echo "ERROR: unreadable HIGH count ('${HIGH}')"; exit 1 ;;
  0) echo "No HIGH-severity findings." ;;
  *) echo "FAILING: ${HIGH} HIGH-severity finding(s)"; exit 1 ;;
esac
