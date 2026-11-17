#!/usr/bin/env bash
# sessionbridge.sh - SessionBridge client: submit jobs, read results.
#
# Usage:
#   sessionbridge.sh submit <job.json> [--wait [seconds]]
#   sessionbridge.sh wait   <job-id> [seconds]
#   sessionbridge.sh status <job-id>
#   sessionbridge.sh output <job-id>
#
# Transport (environment variables):
#   SB_DIR    Local bridge root (the folder holding inbox/ and outbox/).
#             Use when the client runs on the same machine as the runner,
#             or when that folder is mounted/synced locally.
#   SB_HOST   ssh/scp target for the runner machine, e.g. user@laptop
#   SB_REMOTE Bridge root on the runner machine (required with SB_HOST)
#   SB_TASK   Scheduled-task name on the runner machine (default SessionBridge);
#             with SB_HOST the client fires it over ssh after submitting.
#
# Requires: bash and python3 (any 3.x) on the client machine; scp/ssh only
# for the SB_HOST transport.
#
# Exit codes for submit --wait and wait:
#   0 = job completed, 1 = job failed/rejected/timed-out/interrupted,
#   2 = waited the full time with no final status (a wait timeout, not a failure)
set -uo pipefail

: "${SB_TASK:=SessionBridge}"
CMD="${1:?usage: sessionbridge.sh submit|wait|status|output ...}"

fetch() { # fetch <remote-relative-path> <local-dest>
  if [ -n "${SB_DIR:-}" ]; then
    cp "$SB_DIR/$1" "$2" 2>/dev/null
  else
    scp -q ${SB_SSH_OPTS:-} "$SB_HOST:$SB_REMOTE/$1" "$2" 2>/dev/null
  fi
}
put() { # put <local-src> <remote-relative-path>
  if [ -n "${SB_DIR:-}" ]; then
    cp "$1" "$SB_DIR/$2"
  else
    scp -q ${SB_SSH_OPTS:-} "$1" "$SB_HOST:$SB_REMOTE/$2"
  fi
}
fire() {
  if [ -z "${SB_DIR:-}" ] && [ -n "${SB_HOST:-}" ]; then
    ssh ${SB_SSH_OPTS:-} "$SB_HOST" "powershell -NoProfile -Command \"Start-ScheduledTask -TaskName $SB_TASK\"" >/dev/null 2>&1 || true
  fi
}
job_state() { # job_state <status.json-file> <not-before-epoch> -> state or "stale"
  # The runner writes startedAt with 7 fractional digits; datetime.fromisoformat
  # before Python 3.11 accepts at most 6, so truncate the fraction first -
  # otherwise every status reads as unparseable on older python3 (e.g. stock
  # macOS) and wait polls to a false timeout.
  python3 -c 'import json,sys,datetime,re; d=json.load(open(sys.argv[1])); st=(d.get("startedAt") or "").replace("Z","+00:00"); st=re.sub(r"(\.\d{6})\d+", r"\1", st); ep=datetime.datetime.fromisoformat(st).timestamp() if st else 0; print((d.get("state") or "") if ep >= int(sys.argv[2])-10 else "stale")' "$1" "$2" 2>/dev/null
}

do_wait() { # do_wait <job-id> <wait-sec> <not-before-epoch>
  local id="$1" wait_sec="$2" since="$3" elapsed=0 tmp state
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  fire
  while [ "$elapsed" -lt "$wait_sec" ]; do
    if fetch "outbox/$id.status.json" "$tmp/status.json"; then
      state="$(job_state "$tmp/status.json" "$since")"
      if [ -n "$state" ] && [ "$state" != "running" ] && [ "$state" != "stale" ]; then
        cat "$tmp/status.json"; echo
        fetch "outbox/$id.out.txt" "$tmp/out.txt" && { echo "--- output ---"; cat "$tmp/out.txt"; }
        [ "$state" = "completed" ] && return 0 || return 1
      fi
    fi
    sleep 5; elapsed=$((elapsed + 5))
    if [ $((elapsed % 60)) -eq 0 ]; then fire; fi
  done
  echo "no final status after ${wait_sec}s (exit 2 = wait timeout, not a job failure)" >&2
  return 2
}

case "$CMD" in
  submit)
    JOB_FILE="${2:?usage: sessionbridge.sh submit <job.json> [--wait [seconds]]}"
    # Mode is a required, explicit job field (runner 0.3.0): refuse here,
    # with a clear message, rather than submitting a job the runner would
    # only reject.
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); m=d.get("mode"); sys.exit(0 if isinstance(m,str) and m.strip() else 1)' "$JOB_FILE" || { echo "job file has no explicit 'mode' - every job must declare its mode (see the adapter file for the modes it defines); refusing to submit" >&2; exit 1; }
    ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$JOB_FILE")" || exit 1
    SINCE="$(date -u +%s)"
    put "$JOB_FILE" "inbox/$ID.json" || { echo "submit failed: cannot write to the bridge inbox" >&2; exit 1; }
    echo "submitted job $ID"
    fire
    if [ "${3:-}" = "--wait" ]; then do_wait "$ID" "${4:-1200}" "$SINCE"; exit $?; fi
    ;;
  wait)
    do_wait "${2:?job id required}" "${3:-1200}" "0"; exit $?
    ;;
  status)
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fetch "outbox/${2:?job id required}.status.json" "$TMP/status.json" && cat "$TMP/status.json" || { echo "no status found for job $2" >&2; exit 1; }
    ;;
  output)
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fetch "outbox/${2:?job id required}.out.txt" "$TMP/out.txt" && cat "$TMP/out.txt" || { echo "no output found for job $2" >&2; exit 1; }
    ;;
  *) echo "unknown command: $CMD (use submit|wait|status|output)" >&2; exit 64 ;;
esac
