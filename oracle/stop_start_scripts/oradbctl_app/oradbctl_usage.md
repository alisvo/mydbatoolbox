# oradbctl — install, Ansible and crontab usage

## Install

Run all of this as root.

**1. Place the script on a path the `oracle` user can reach**

```bash
install -o root -g root -m 0755 oradbctl /usr/local/bin/oradbctl
```

Mode `0755` matters: started as root the script re-execs itself as the Oracle software owner using its
own path, so that user needs read+execute on the file.

**2. Create the log and lock directories**

```bash
mkdir -p /var/log/oradbctl /var/tmp/oradbctl
chown oracle:oinstall /var/log/oradbctl /var/tmp/oradbctl
chmod 0750 /var/log/oradbctl /var/tmp/oradbctl
```

If `/var/log/oradbctl` is missing or not writable by `oracle`, logging silently falls back to `/tmp`
instead of failing — easy to miss, so don't skip this.

**3. Optional site defaults**

```bash
cat > /etc/sysconfig/oradbctl <<'EOF'
ORADBCTL_PARALLEL=4
ORADBCTL_STANDBY_OPEN=READ_ONLY      # MOUNT if the host is not ADG-licensed
ORADBCTL_STOP_TIMEOUT=600
ORADBCTL_ABORT_ON_TIMEOUT=1
ORADBCTL_LOG_KEEP_DAYS=30
EOF
```

**4. Check what oratab will drive**

```bash
grep -v '^#' /etc/oratab
```

Only entries flagged **Y** are touched; `+ASM*`, `-MGMTDB`, `*` and `N` entries are skipped.

**5. Verify**

```bash
oradbctl -V                      # oradbctl 1.1.2
oradbctl status
su - oracle -c 'oradbctl -V'     # must work as oracle too
```

`oradbctl status` on a healthy host:

```
SID              STATUS    ROLE               OPEN_MODE             APPLY
PRODDB           OPEN      PRIMARY            READ_WRITE            NO
DWHDB            OPEN      PRIMARY            READ_WRITE            NO
PRODSTB          OPEN      PHYSICAL_STANDBY   READ_ONLY_WITH_APPLY  YES
LISTENER         RUNNING
```

Both invocation paths do the same work as the `oracle` user: as root it drops privileges via `runuser`,
as `oracle` it runs directly.

## Upgrading

Overwrite the file — there is no state to migrate and the config, log and lock directories are compatible
across versions.

```bash
install -o root -g root -m 0755 oradbctl /usr/local/bin/oradbctl
oradbctl -V
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | all requested operations OK (including "already in the target state") |
| 1 | at least one database or listener operation failed |
| 2 | usage / config error, or `-d SID` matched nothing in oratab |

Concurrency: one `flock` per SID — an overlapping cron run skips that DB instead of colliding.

## Troubleshooting

**"SKIPPED - another oradbctl run holds the lock" when nothing else is running**

Fixed in 1.1.0. Cause: Oracle background processes are forked from `sqlplus` during `STARTUP` and keep
*every* inherited file descriptor for the life of the instance — including the per-SID lock descriptor.
The lock therefore stayed held by `ora_pmon_<SID>` & friends until the database was shut down, which
`oradbctl` could no longer do. Confirm on an affected host with:

```bash
ls -l /proc/$(pgrep -x ora_pmon_db1)/fd | grep oradbctl
```

1.1.0 closes fd 3 and fd 9 before exec'ing `sqlplus`/`lsnrctl`, so nothing leaks into Oracle any more,
and it also recognises a lock held *only* by `ora_*`/`tnslsnr` processes as stale and reclaims it —
so an already-affected host heals itself on the next run. A lock held by a real concurrent `oradbctl`
is still respected.

To clear it by hand instead: `rm -f /var/tmp/oradbctl/<SID>.lock`

The same fd hygiene is why the script is safe under Ansible and cron: a leaked descriptor on the job's
stdout pipe would keep the pipe open for the life of the instance and hang the calling task.

## Logging and retention

One file per day: `/var/log/oradbctl/oradbctl-YYYYMMDD.log` (content also goes to stdout unless `-q`).

The script cleans up after itself: at the start of every run it deletes its own log files older than
`ORADBCTL_LOG_KEEP_DAYS` (default **30**). The `find` is anchored to the exact
`oradbctl-YYYYMMDD.log` name pattern and `-maxdepth 1`, so nothing else in the directory can be touched.
Stale lock files unused for 30+ days are removed the same way.

```bash
# keep 3 months instead
echo 'ORADBCTL_LOG_KEEP_DAYS=90' >> /etc/sysconfig/oradbctl
```

If you'd rather manage it centrally, set `ORADBCTL_LOG_KEEP_DAYS=0` and drop in a logrotate rule:

```
# /etc/logrotate.d/oradbctl
/var/log/oradbctl/oradbctl-*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    su oracle oinstall
    create 0640 oracle oinstall
}
```

---

## Ansible

`--json` prints a single JSON object on **stdout**; all human logging goes to stderr, so parsing is safe.

```json
{"action":"stop","host":"dbsrv01","rc":0,"changed":true,
 "databases":[{"sid":"PRODDB","result":"changed","status":"DOWN","role":"-","open_mode":"-","apply":"-"}]}
```

`result` is one of `ok` (no change needed), `changed`, `failed`, `skipped` (locked by another run).

### Deploy + operate role snippet

```yaml
- name: Deploy oradbctl
  hosts: oracle_db
  become: true
  tasks:
    - name: Install oradbctl
      ansible.builtin.copy:
        src: files/oradbctl
        dest: /usr/local/bin/oradbctl
        owner: root
        group: root
        mode: '0755'

    - name: Site defaults
      ansible.builtin.copy:
        dest: /etc/sysconfig/oradbctl
        mode: '0644'
        content: |
          ORADBCTL_PARALLEL=4
          ORADBCTL_STANDBY_OPEN=READ_ONLY

    - name: Runtime directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: oracle
        group: oinstall
        mode: '0750'
      loop:
        - /var/log/oradbctl
        - /var/tmp/oradbctl
```

### Stop all databases before patching

```yaml
- name: Stop all Oracle databases
  ansible.builtin.command:
    argv: [/usr/local/bin/oradbctl, stop, --json, -q]
  become: true
  register: ora_stop
  changed_when: (ora_stop.stdout | from_json).changed
  failed_when: ora_stop.rc != 0
  # rc 1 = something did not stop -> the play stops here on purpose

- name: Show per-database outcome
  ansible.builtin.debug:
    msg: "{{ (ora_stop.stdout | from_json).databases }}"
```

### Start again afterwards

```yaml
- name: Start Oracle databases and listeners
  ansible.builtin.command:
    argv: [/usr/local/bin/oradbctl, start, --json, -q]
  become: true
  register: ora_start
  changed_when: (ora_start.stdout | from_json).changed
  failed_when: ora_start.rc != 0

- name: Assert every database reached the expected state
  ansible.builtin.assert:
    that:
      - item.result != 'failed'
      - item.status in ['OPEN', 'MOUNTED']
    fail_msg: "{{ item.sid }} ended as {{ item.status }} ({{ item.result }})"
  loop: "{{ (ora_start.stdout | from_json).databases }}"
  loop_control:
    label: "{{ item.sid }}"
```

### Single database (e.g. bounce one DB after a parameter change)

```yaml
- name: Restart PRODDB only, leave the listener alone
  ansible.builtin.command:
    argv: [/usr/local/bin/oradbctl, restart, -d, PRODDB, --no-listener, --json, -q]
  become: true
  register: r
  changed_when: (r.stdout | from_json).changed
```

### Read-only health check (never reports changed)

```yaml
- name: Collect Oracle status
  ansible.builtin.command:
    argv: [/usr/local/bin/oradbctl, status, --json, -q]
  become: true
  register: ora_status
  changed_when: false

- name: Fail if any standby stopped applying redo
  ansible.builtin.fail:
    msg: "Redo apply is down on {{ item.sid }}"
  when:
    - item.role == 'PHYSICAL_STANDBY'
    - item.apply != 'YES'
  loop: "{{ (ora_status.stdout | from_json).databases }}"
  loop_control:
    label: "{{ item.sid }}"
```

### Notes

* `become: true` is enough — the script drops privileges itself, no `become_user: oracle` needed.
* Prefer `argv:` over a shell string; no shell quoting issues, no `warn` noise.
* For long stops raise the Ansible timeout: add `async: 1800` / `poll: 30`, or use `-t 300 --abort`.
* Add `-P 4` on consolidated hosts to work on 4 databases at a time.

---

## Crontab

Install under **root**'s crontab (the script drops to `oracle`) or under `oracle`'s — both work.
Cron has a bare environment; `oradbctl` sets `ORACLE_HOME`/`ORACLE_SID`/`PATH`/`LD_LIBRARY_PATH`
per database itself, so no profile sourcing is required.

```cron
# /etc/cron.d/oradbctl        (root crontab format: user field required)
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=dba-team@sunexpress.com

# --- boot ----------------------------------------------------------------
# start everything after a server reboot (listener first, then all Y databases)
@reboot          root  sleep 60; /usr/local/bin/oradbctl start -P 4 -q

# --- nightly bounce of the test host -------------------------------------
# stop 22:00, start 22:30
0  22 * * *      root  /usr/local/bin/oradbctl stop  -P 4 -q
30 22 * * *      root  /usr/local/bin/oradbctl start -P 4 -q

# --- weekend shutdown of non-prod ----------------------------------------
0  20 * * 5      root  /usr/local/bin/oradbctl stop  -d DEVDB,TESTDB -q
0  06 * * 1      root  /usr/local/bin/oradbctl start -d DEVDB,TESTDB -q

# --- self healing: restart anything that is down, every 15 min -----------
# 'start' is idempotent - running databases are left untouched
*/15 * * * *     root  /usr/local/bin/oradbctl start -q --no-listener

# --- standby apply watchdog ---------------------------------------------
*/10 * * * *     root  /usr/local/bin/oradbctl status --json -q | grep -q '"role":"PHYSICAL_STANDBY","open_mode":"[^"]*","apply":"NO"' && /usr/local/bin/oradbctl start -d PRODSTB -q
```

Personal crontab of `oracle` (`crontab -e -u oracle`) — same lines without the user field:

```cron
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=dba-team@sunexpress.com

@reboot        sleep 60; /usr/local/bin/oradbctl start -P 4 -q
0 22 * * *     /usr/local/bin/oradbctl stop -q
30 22 * * *    /usr/local/bin/oradbctl start -q
```

### Cron tips

* `-q` silences stdout so cron only mails you on a real problem — the daily log file still gets everything.
  Drop `-q` if you want the full transcript by mail.
* Non-zero exit already triggers the cron mail; no extra wrapper needed.
* Overlapping runs are safe: the per-SID `flock` makes the second run skip that database (exit 0) instead of
  issuing a second `shutdown`.
* `@reboot` + `sleep 60` gives the network and storage time to settle. If you use systemd instead of `@reboot`,
  a `Type=oneshot` / `RemainAfterExit=yes` unit calling `oradbctl start` and `oradbctl stop` is enough.

---

## Environment variables (all optional)

| Variable | Default | Purpose |
|---|---|---|
| `ORADBCTL_CFG` | `/etc/sysconfig/oradbctl` | config file path |
| `ORADBCTL_ORATAB` | `/etc/oratab` | oratab path |
| `ORADBCTL_LOG_DIR` | `/var/log/oradbctl` | log directory |
| `ORADBCTL_LOG_KEEP_DAYS` | `30` | delete own logs older than N days; `0` = never (use logrotate) |
| `ORADBCTL_LOCK_DIR` | `/var/tmp/oradbctl` | lock directory |
| `ORADBCTL_STANDBY_OPEN` | `READ_ONLY` | `READ_ONLY` (ADG) or `MOUNT` |
| `ORADBCTL_START_TIMEOUT` | `900` | seconds per startup step |
| `ORADBCTL_STOP_TIMEOUT` | `600` | seconds for `shutdown immediate` |
| `ORADBCTL_ABORT_ON_TIMEOUT` | `1` | `shutdown abort` if immediate hangs |
| `ORADBCTL_WITH_LISTENER` | `1` | manage listeners |
| `ORADBCTL_PARALLEL` | `1` | databases handled concurrently |
| `ORADBCTL_OWNER` | auto-detected | Oracle software owner |
| `ORADBCTL_LISTENERS` | auto from `listener.ora` | explicit listener list, comma separated |

> **License note:** `ORADBCTL_STANDBY_OPEN=READ_ONLY` opens physical standbys read-only **with** redo apply
> running — that is Active Data Guard and requires the ADG option. Set it to `MOUNT` on hosts without it.
