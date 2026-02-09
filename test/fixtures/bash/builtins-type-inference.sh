#!/usr/bin/env bash
# Test: Type inference from command argument positions
# 
# nix-compile knows the types of common command flags.
# When you write `curl --connect-timeout "$TIMEOUT"`, 
# it infers TIMEOUT :: TInt without any annotation.

set -euo pipefail

# These should all infer to TInt from curl's schema
curl --connect-timeout "$CONNECT_TIMEOUT" \
     --max-time "$MAX_TIME" \
     --retry "$RETRY_COUNT" \
     --retry-delay "$RETRY_DELAY" \
     -o "$OUTPUT_FILE" \
     "$URL"

# wget: timeout flags are TInt, output is TPath
wget -t "$WGET_RETRIES" -T "$WGET_TIMEOUT" -O "$WGET_OUTPUT" "$DOWNLOAD_URL"

# ssh: port is TInt, identity file is TPath
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_HOST" "echo connected"

# find: depth limits are TInt
find "$SEARCH_PATH" -maxdepth "$MAX_DEPTH" -mindepth "$MIN_DEPTH" -name "$PATTERN"

# parallel: job count is TInt
parallel -j "$NUM_JOBS" --timeout "$JOB_TIMEOUT" ::: task1 task2 task3

# timeout: duration is TInt (positional!)
timeout "$TIMEOUT_SECONDS" long-running-command

# sleep: duration is TInt (positional!)
sleep "$SLEEP_SECONDS"

# nc: port is TInt (positional!)
nc -w "$NC_TIMEOUT" "$NC_HOST" "$NC_PORT"

# rsync: bandwidth and timeout are TInt
rsync --timeout "$RSYNC_TIMEOUT" --bwlimit "$BW_LIMIT" "$SRC" "$DEST"

# grep: line counts are TInt
grep -m "$MAX_MATCHES" -A "$AFTER_CONTEXT" -B "$BEFORE_CONTEXT" "$GREP_PATTERN" "$GREP_FILE"

# head/tail: line counts are TInt
head -n "$HEAD_LINES" "$HEAD_FILE"
tail -n "$TAIL_LINES" "$TAIL_FILE"

# xargs: parallelism is TInt
xargs -n "$XARGS_MAX" -P "$XARGS_PROCS" cmd

# nix: build parallelism is TInt
nix build --max-jobs "$NIX_JOBS" --cores "$NIX_CORES" .#package

# dd: count is TInt
dd if="$DD_INPUT" of="$DD_OUTPUT" count="$DD_COUNT" skip="$DD_SKIP"

echo "All done"
