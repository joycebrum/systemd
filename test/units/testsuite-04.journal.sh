#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

# Rotation/flush test, see https://github.com/systemd/systemd/issues/19895
journalctl --relinquish-var
[[ "$(systemd-detect-virt -v)" == "qemu" ]] && ITERATIONS=10 || ITERATIONS=50
for ((i = 0; i < ITERATIONS; i++)); do
    dd if=/dev/urandom bs=1M count=1 | base64 | systemd-cat
done
journalctl --rotate
journalctl --flush
journalctl --sync
journalctl --rotate --vacuum-size=8M

# Reset the ratelimit buckets for the subsequent tests below.
systemctl restart systemd-journald

# Test stdout stream
write_and_match() {
    local input="${1:?}"
    local expected="${2?}"
    local id
    shift 2

    id="$(systemd-id128 new)"
    echo -ne "$input" | systemd-cat -t "$id" "$@"
    journalctl --sync
    diff <(echo -ne "$expected") <(journalctl -b -o cat -t "$id")
}
# Skip empty lines
write_and_match "\n\n\n" "" --level-prefix false
write_and_match "<5>\n<6>\n<7>\n" "" --level-prefix true
# Remove trailing spaces
write_and_match "Trailing spaces \t \n" "Trailing spaces\n" --level-prefix false
write_and_match "<5>Trailing spaces \t \n" "Trailing spaces\n" --level-prefix true
# Don't remove leading spaces
write_and_match " \t Leading spaces\n" " \t Leading spaces\n" --level-prefix false
write_and_match "<5> \t Leading spaces\n" " \t Leading spaces\n" --level-prefix true

# --output-fields restricts output
ID="$(systemd-id128 new)"
echo -ne "foo" | systemd-cat -t "$ID" --level-prefix false
journalctl --sync
journalctl -b -o export --output-fields=MESSAGE,FOO --output-fields=PRIORITY,MESSAGE -t "$ID" >/tmp/output
[[ $(wc -l </tmp/output) -eq 9 ]]
grep -q '^__CURSOR=' /tmp/output
grep -q '^MESSAGE=foo$' /tmp/output
grep -q '^PRIORITY=6$' /tmp/output
(! grep '^FOO=' /tmp/output)
(! grep '^SYSLOG_FACILITY=' /tmp/output)

# '-b all' negates earlier use of -b (-b and -m are otherwise exclusive)
journalctl -b -1 -b all -m >/dev/null

# -b always behaves like -b0
journalctl -q -b-1 -b0 | head -1 >/tmp/expected
journalctl -q -b-1 -b | head -1 >/tmp/output
diff /tmp/expected /tmp/output
# ... even when another option follows (both of these should fail due to -m)
{ journalctl -ball -b0 -m 2>&1 || :; } | head -1 >/tmp/expected
{ journalctl -ball -b  -m 2>&1 || :; } | head -1 >/tmp/output
diff /tmp/expected /tmp/output

# https://github.com/systemd/systemd/issues/13708
ID=$(systemd-id128 new)
systemd-cat -t "$ID" bash -c 'echo parent; (echo child) & wait' &
PID=$!
wait $PID
journalctl --sync
# We can drop this grep when https://github.com/systemd/systemd/issues/13937
# has a fix.
journalctl -b -o export -t "$ID" --output-fields=_PID | grep '^_PID=' >/tmp/output
[[ $(wc -l </tmp/output) -eq 2 ]]
grep -q "^_PID=$PID" /tmp/output
grep -vq "^_PID=$PID" /tmp/output

# https://github.com/systemd/systemd/issues/15654
ID=$(systemd-id128 new)
printf "This will\nusually fail\nand be truncated\n" >/tmp/expected
systemd-cat -t "$ID" /bin/sh -c 'env echo -n "This will";echo;env echo -n "usually fail";echo;env echo -n "and be truncated";echo;'
journalctl --sync
journalctl -b -o cat -t "$ID" >/tmp/output
diff /tmp/expected /tmp/output
[[ $(journalctl -b -o cat -t "$ID" --output-fields=_TRANSPORT | grep -Pc "^stdout$") -eq 3 ]]
[[ $(journalctl -b -o cat -t "$ID" --output-fields=_LINE_BREAK | grep -Pc "^pid-change$") -eq 3 ]]
[[ $(journalctl -b -o cat -t "$ID" --output-fields=_PID | sort -u | grep -c "^.*$") -eq 3 ]]
[[ $(journalctl -b -o cat -t "$ID" --output-fields=MESSAGE | grep -Pc "^(This will|usually fail|and be truncated)$") -eq 3 ]]

# test that LogLevelMax can also suppress logging about services, not only by services
systemctl start silent-success
journalctl --sync
[[ -z "$(journalctl -b -q -u silent-success.service)" ]]

# Exercise the matching machinery
SYSTEMD_LOG_LEVEL=debug journalctl -b -n 1 /dev/null /dev/zero /dev/null /dev/null /dev/null
journalctl -b -n 1 /bin/true /bin/false
journalctl -b -n 1 /bin/true + /bin/false
journalctl -b -n 1 -r --unit "systemd*"

systemd-run --user -M "testuser@.host" /bin/echo hello
journalctl --sync
journalctl -b -n 1 -r --user-unit "*"

(! journalctl -b /dev/lets-hope-this-doesnt-exist)
(! journalctl -b /dev/null /dev/zero /dev/this-also-shouldnt-exist)
(! journalctl -b --unit "this-unit-should-not-exist*")

# Facilities & priorities
journalctl --facility help
journalctl --facility kern -n 1
journalctl --facility syslog --priority 0..3 -n 1
journalctl --facility syslog --priority 3..0 -n 1
journalctl --facility user --priority 0..0 -n 1
journalctl --facility daemon --priority warning -n 1
journalctl --facility daemon --priority warning..info -n 1
journalctl --facility daemon --priority notice..crit -n 1
journalctl --facility daemon --priority 5..crit -n 1

(! journalctl --facility hopefully-an-unknown-facility)
(! journalctl --priority hello-world)
(! journalctl --priority 0..128)
(! journalctl --priority 0..systemd)

# Other options
journalctl --disk-usage
journalctl --dmesg -n 1
journalctl --fields
journalctl --list-boots
journalctl --update-catalog
journalctl --list-catalog

# Add new tests before here, the journald restarts below
# may make tests flappy.

# Don't lose streams on restart
systemctl start forever-print-hola
sleep 3
systemctl restart systemd-journald
sleep 3
systemctl stop forever-print-hola
[[ ! -f "/tmp/i-lose-my-logs" ]]

# https://github.com/systemd/systemd/issues/4408
rm -f /tmp/i-lose-my-logs
systemctl start forever-print-hola
sleep 3
systemctl kill --signal=SIGKILL systemd-journald
sleep 3
[[ ! -f "/tmp/i-lose-my-logs" ]]
systemctl stop forever-print-hola

set +o pipefail
# https://github.com/systemd/systemd/issues/15528
journalctl --follow --file=/var/log/journal/*/* | head -n1 | grep .
# https://github.com/systemd/systemd/issues/24565
journalctl --follow --merge | head -n1 | grep .
set -o pipefail

# https://github.com/systemd/systemd/issues/26746
rm -f /tmp/issue-26746-log /tmp/issue-26746-cursor
ID="$(systemd-id128 new)"
journalctl -t "$ID" --follow --cursor-file=/tmp/issue-26746-cursor | tee /tmp/issue-26746-log &
systemd-cat -t "$ID" /bin/sh -c 'echo hogehoge'
# shellcheck disable=SC2016
timeout 10 bash -c 'while ! [[ -f /tmp/issue-26746-log && "$(cat /tmp/issue-26746-log)" =~ hogehoge ]]; do sleep .5; done'
pkill -TERM journalctl
timeout 10 bash -c 'while ! test -f /tmp/issue-26746-cursor; do sleep .5; done'
CURSOR_FROM_FILE="$(cat /tmp/issue-26746-cursor)"
CURSOR_FROM_JOURNAL="$(journalctl -t "$ID" --output=export MESSAGE=hogehoge | sed -n -e '/__CURSOR=/ { s/__CURSOR=//; p }')"
test "$CURSOR_FROM_FILE" = "$CURSOR_FROM_JOURNAL"

# Check that the seqnum field at least superficially works
systemd-cat echo "ya"
journalctl --sync
SEQNUM1=$(journalctl -o export -n 1 | grep -Ea "^__SEQNUM=" | cut -d= -f2)
systemd-cat echo "yo"
journalctl --sync
SEQNUM2=$(journalctl -o export -n 1 | grep -Ea "^__SEQNUM=" | cut -d= -f2)
test "$SEQNUM2" -gt "$SEQNUM1"

# Test for journals without RTC
# See: https://github.com/systemd/systemd/issues/662
JOURNAL_DIR="$(mktemp -d)"
while read -r file; do
    filename="${file##*/}"
    unzstd "$file" -o "$JOURNAL_DIR/${filename%*.zst}"
done < <(find /test-journals/no-rtc -name "*.zst")

journalctl --directory="$JOURNAL_DIR" --list-boots --output=json >/tmp/lb1
diff -u /tmp/lb1 - <<'EOF'
[{"index":-3,"boot_id":"5ea5fc4f82a14186b5332a788ef9435e","first_entry":1666569600994371,"last_entry":1666584266223608},{"index":-2,"boot_id":"bea6864f21ad4c9594c04a99d89948b0","first_entry":1666584266731785,"last_entry":1666584347230411},{"index":-1,"boot_id":"4c708e1fd0744336be16f3931aa861fb","first_entry":1666584348378271,"last_entry":1666584354649355},{"index":0,"boot_id":"35e8501129134edd9df5267c49f744a4","first_entry":1666584356661527,"last_entry":1666584438086856}]
EOF
rm -rf "$JOURNAL_DIR" /tmp/lb1
