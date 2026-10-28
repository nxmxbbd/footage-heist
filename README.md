# footage-heist

**A heist movie for your old footage.** footage-heist moves old recordings, with their events, smart
detections and face groups, from one UniFi Protect console into the timeline of another, one camera at a
time. Experimental.

The setup is a classic: a new console on the shelf with a timeline that starts the day it was installed,
an old console full of footage the new one knows nothing about, and no official way to move the past
between them. You can buy a bigger vault from the vendor; what you cannot buy is a service that
drives your loot across town. So you do what any reasonable home-lab operator does: you plan a heist.

To be clear about the crime: this is the most legal heist imaginable. You own the vault. You have the key.
The getaway vehicle is a Linux box you also own, and the crew keeps meticulous receipts --- a database
ledger that decides every outcome, no exceptions. And yes, the security cameras are off during the job:
recording stops for a few minutes while the window runs, because the heist itself stops them. This crew
takes its own surveillance footage so seriously that it refuses to be recorded while handling it.

What goes in the bag, exactly: **only recordings and what hangs off them move** --- their events, smart
detections and labels, and the face and vehicle groups those detections point to. Cameras, settings, users
and everything else about your consoles stay exactly where they are --- the cameras move in on their own,
like adults; the crew only handles the tapes. The target console must have already adopted the camera
before its batch can run. This is a heist for footage, not a whole-console migration, and the crew has no
plan for one.

> **Unofficial.** This project is not affiliated with, endorsed by, sponsored by, or supported by Ubiquiti Inc.
> "UniFi", "UniFi Protect", "UNVR", "UDM" and related names are trademarks of Ubiquiti Inc. and are used here only
> to identify the products this tool is designed to work with.

## Read this before you run anything

- This tool writes directly into UniFi Protect's internal PostgreSQL database and recording storage during a short
  maintenance window in which Protect is stopped. That is not a supported operation. A bug, a power cut, or a Protect
  version that behaves differently can corrupt the database, lose recordings or face data, or leave the console in a
  state Ubiquiti support will not help with. Ubiquiti's limited warranty excludes damage caused by third-party software.
- Validated only for a UniFi Dream Machine SE as the source and a UNVR as the target, both on Protect 7.3.70. The
  generated import refuses any other target version, and `night.sh` refuses to start a window, unless the batch was
  generated with `--unvalidated-version X.Y.Z`. That option checks the schema only (the target's column lists must
  equal the staged ones), not behaviour: see "Version guard".
- Use it only on consoles you own or are authorized to administer, only after a backup you have restored
  successfully, and at your own risk.

## Privacy

Imported data includes face-recognition groups, with the names you gave them, and the face detections of the imported
recordings, which carry the name they matched and face-recognition data. Detections, thumbnails and recordings show
people, and importing extends how long all of this is kept. You are responsible for having a lawful basis for keeping
it and for any retention limits that apply to you (for example as a business under the GDPR or a similar law).

This version has no switch that leaves face data behind: removing it would mean rewriting Protect's records into a
shape that has not been validated on a console. If you may not keep this data, do not use this tool.

## What this project is

This crew enters through the front door. It contains no Ubiquiti code, firmware or binaries and does not
bypass any protection: it uses the SSH access that UniFi OS offers its administrators --- the owner's own
key, used the way the owner could use it by hand. Table and column names appear in the SQL only so that
the tool can interoperate with Protect. [MECHANISM.md](MECHANISM.md) lists the behaviour the tool guards
against and how to observe it on your own console. Provided "as is", without warranty of any kind; see
[LICENSE](LICENSE) (MIT).

## The crew and the plan

Three machines: the **source** console (where the recordings are --- the vault), the **target** console
(whose timeline receives them --- the safe house), and a Linux **controller** that runs this repository,
a disposable PostgreSQL container and the copy runner (the planner and the getaway driver; mostly
spreadsheets). One **batch** = one camera that the target has already adopted. One job at a time: this
crew does sequels, never double features.

1. **Copy** the camera's recording files from the source into a staging directory on the target's recording volume
   (outside Protect's video directory), hash-verified on both ends, rate-limited, resumable (`tool/copyq.py`). The
   loot is pre-positioned in the safe house's garage before anyone puts on a mask.
2. **Extract** the camera's rows (events, detections, groups, labels, recording files) from a dump of the source's
   database into a staging schema, with the static rewrites (camera id, AI processor id, paths) applied
   (`tool/extract.sh`).
3. **Generate** the load, apply, rollback and verify SQL for the batch (`tool/gen.py`). At generation time it proves
   that every reference to a face or vehicle group sits on the list of places the apply step rewrites.
4. **Test** against a fresh clone of the target's database: SQL scenarios (`tool/dryrun.sh`) and the window script
   against a simulated service graph with fault injection (`tool/test-window.sh`). Rehearsal in a fake vault, with
   things going wrong on purpose.
5. **Prepare** on the live target while Protect keeps running: push the batch, take database dumps and a Protect
   backup, load the staging schema, run the apply once inside a transaction that ends in ROLLBACK (`tool/night.sh`).
   A rehearsal on the real vault that rolls itself back --- a crime with takebacks.
6. **Window**: on the target, as a transient systemd unit that survives a lost SSH session: block Protect from
   starting, stop Protect and its media services, start PostgreSQL alone, hardlink the staged files into the video
   directory, run the apply in one transaction, restart the recorder and prove it healthy, start Protect. Recording
   stops for a few minutes. The loot itself is never carried in: the window only files paperwork (a hardlink) so the
   same bytes can also live in the video directory.
7. **Verify** (database checks, media exports and thumbnails through the Protect API, face samples) and **observe**
   daily for a few days. After the job, the crew cases its own work, every day, like people with trust issues.

The script that drives the window is called `night.sh`, because of course it is. And much of what comes
before step six (rollback SQL, dumps, a backup, a rehearsal) exists so that step six has a way back out:
this crew plans the exit before the entrance.

## Requirements

What the job insists on before the crew will take it:

- Source and target: UniFi OS consoles running Protect, with SSH enabled for the root account; the target's staging
  directory must be on the same mount as Protect's video directory (hardlinks) and have room for the batch.
- Controller: Linux with systemd, bash, Python 3, OpenSSH, `curl`, `ffprobe` (verify-media.sh) and Docker
  (`pgvector/pgvector:pg14` for the disposable database, `postgres:16-alpine` as the restore client).
- SSH keys: controller → source, controller → target (root), and source → target with ONE restricted key bound to the
  receiver (see "Copy channel").
- An AI processor on both consoles (`AI_SRC` / `AI_DST`): the validated setup has one, and consoles without one are not
  supported. Detections recorded by any other AI processor make the extract refuse the camera.

## Install

Assembling the crew. Seven steps, done once per site; none of them are optional, and step seven has
sub-clauses that deserve their own seat.

1. Clone this repository on the controller. Create `IMPORT_DIR` (mode 700).
2. Site configuration: copy [site.env.example](site.env.example) to `~/.config/footage-heist/site.env` (or set
   `IMPORT_SITE`), mode 600, and fill it in. Every tool reads it through `tool/siteconf.py`; nothing falls back to
   built-in host or path guesses. `python3 tool/siteconf.py show` prints the resolved values.
3. Credential files the site configuration points at (mode 600, never on a command line): the target's TLS public key
   pin (`sha256//...`, for `curl --pinnedpubkey`), a curl config with the integration API key header, and the JSON body
   for a local admin login.
4. Disposable database: `docker run -d --name <PG_CONTAINER> --network none --shm-size=1g
   -e POSTGRES_HOST_AUTH_METHOD=trust -v <IMPORT_DIR>:/in:ro pgvector/pgvector:pg14` (no network), then restore a dump of the source's
   `unifi-protect` database (taken with the source's own PostgreSQL 14 `pg_dump -Fc`) into a database named `src`.
5. Source console: put `tool/ubv-push.py` and `tool/source-run-push.sh` (as `run-push.sh`) into `SOURCE_WORKDIR`,
   together with the restricted key pair and the target's host key (`known_hosts`).
6. Target console: put `tool/ubv-recv.py` somewhere root-only and bind the restricted key to it in root's
   `authorized_keys`: `command="python3 <dir>/ubv-recv.py --base <TARGET_STAGING>",restrict ssh-ed25519 AAAA...`.
   Create `<TARGET_STAGING>` itself on the target's video volume (`install -d -m 700 <TARGET_STAGING>`): the copy
   runner checks free space there before the first file, and the receiver refuses a `--base` that does not exist. It
   creates `files/` and `state/` inside on first use.
7. Units: `install/render.sh <out_dir> [--top-user <user>]` renders the copy runner, the daily summary and the
   observation timer, the `copyq-top` wrapper and (optional) a sudoers drop-in from the templates in `systemd/` and
   `install/` with your site values. It installs nothing: review the files, copy the units to `/etc/systemd/system/`
   and the wrapper to `/usr/local/bin/copyq-top`, `visudo -c` the drop-in before placing it in `/etc/sudoers.d/`, then
   `systemctl daemon-reload` and enable the two timers. The drop-in lets that user run the wrapper as root, so with
   `--top-user` render.sh refuses unless everything that wrapper runs or reads as root is root-owned and writable by
   nobody else (mode, access and default ACLs): the tool path as given (every directory its resolution passes through,
   symlinks followed one hop at a time), everything under the tool directory (a symlink there: also the directory it
   leads to, or for a linked file the directory that file is in, where Python loads its siblings from), the site file,
   `IMPORT_DIR` with its `copyq/` state and the camera id map.

### Camera id map

`IDMAP` is a tab-separated file, one line per camera: MAC (12 hex digits) | name | model | camera id on the source |
camera id on the target | ISO 8601 time at which the target took the camera over. `tool/new-batch.sh` reads it and
cross-checks the source camera id against the restored source database.

## Per camera (the night's schedule)

One job, in order. The crew does not improvise midway.

```
tool/new-batch.sh <slug> <mac> [apply_timeout]       # <IMPORT_DIR>/<slug>/batch.env, own staging schema
tool/copyq.py add <slug> <mac> [--filter ...]        # queue the copy
tool/copyq.py resume                                  # start the runner unit; it works the queue in order
tool/copyq.py status                                  # or: copyq-top (live, read-only); wait for "copied"
tool/extract.sh <IMPORT_DIR>/<slug>                   # camera rows -> schema "stage" in the disposable DB
python3 tool/gen.py <IMPORT_DIR>/<slug>               # data + SQL; [--unvalidated-version X.Y.Z]
tool/night.sh <IMPORT_DIR>/<slug> clone-dump          # fresh read-only dump of the target DB for the tests
tool/dryrun.sh <IMPORT_DIR>/<slug>                    # SQL scenarios on the clone
tool/test-window.sh <IMPORT_DIR>/<slug>               # window script against the simulated services
tool/night.sh <IMPORT_DIR>/<slug> prep                # push, backups, staging schema (Protect keeps running)
tool/night.sh <IMPORT_DIR>/<slug> trial               # the real apply in a transaction that ends in ROLLBACK
tool/copyq.py ready <slug> "<note>"                   # prepared: notification with your note
tool/face-check.sh snapshot                           # target face samples, right before the window
tool/copyq.py pause                                   # no copy may write to the target's disks during a window
tool/night.sh <IMPORT_DIR>/<slug> go                  # THE WINDOW (preflight, version and unit graph guards first)
tool/night.sh <IMPORT_DIR>/<slug> status | verify
tool/verify-media.sh <IMPORT_DIR>/<slug>              # exports + thumbnails through the Protect API
tool/face-check.sh compare <snapshot.tsv>             # every face sample must have survived Protect's restart
tool/copyq.py imported <slug>; tool/copyq.py resume
tool/night.sh <IMPORT_DIR>/<slug> drop-staging        # after verify: drop the staging data tables
echo "<slug> <last day YYYY-MM-DD>" >> <IMPORT_DIR>/observe.list   # daily read-only checks until that day
```

`night.sh <batch> rollback` (`FORCE=1` to override native rows hanging off imported ones) and `recover` run as window
units too. `preflight` shows the target's state read-only (flags, services, version, unit graph, staged files, ledger).
`verify` reports a thumbnails / timelapse file the recorder continued (MECHANISM.md section 5) as an `INFO` line, every
other change to an imported recording row as a FAIL. `night.sh <batch> refresh-verify` brings an imported batch's
`sql/verify.sql` (the local file and the target's copy, which `verify` runs) to the current `gen.py`'s recording check
and changes nothing else; a batch not imported yet is regenerated and prepped instead.
Never edit a script while a run of it is executing (bash reads scripts incrementally).

## Safety design (what the window guarantees)

A heist is only as good as its exit plan, and this one was written by someone with trust issues. Every
line below is load-bearing prose, not a joke: these are the promises the window keeps when things go
wrong.

- One `recover()` decides every outcome from the import ledger (`<LEDGER_SCHEMA>.ledger` in the target's database),
  never from psql's exit code. It runs on normal end, failure, signal, script death and, through the unit's
  `ExecStopPost`, after SIGKILL.
- While a file named `.corrupted-db` exists in Protect's data directory the window stops or starts nothing (neither
  Protect nor its PostgreSQL) and leaves the decision to a human.
- Files are linked, never copied or moved, and removed again only if the inode still matches the staged file and no
  `recordingFiles` row references the path.
- The apply is one transaction; merges of face / vehicle groups are decided against the live database inside it.
  Group ids come in mixed shapes, so rewrites are exact-token and followed by a residual check.
- Rollback refuses if the recorder changed an imported recording row; native rows that hang off imported rows (any
  foreign key, read from `pg_constraint`) block it unless forced; groups still referenced or edited are kept.
- One window at a time: `night.sh` refuses while any batch's window unit runs or any batch sits in a state that needs
  a human, and while the copy runner writes to the target.

## Version guard

The crew has cased exactly one kind of vault and admits it.

`gen.py` writes a version check into the apply SQL: it refuses unless the target's Protect version is 7.3.70, the
version the behaviour in MECHANISM.md was observed on. `night.sh prep` and `go` compare the target's version with the
batch before anything stops.

`gen.py <batch> --unvalidated-version X.Y.Z` accepts exactly X.Y.Z instead (and is refused for 7.3.70 itself). The
apply still refuses a target whose column lists differ from the staged ones, but nothing checks that Protect X.Y.Z
behaves as MECHANISM.md describes: re-check every item there on your console first. The batch's manifest and the
ledger record the override. Even off-book jobs get written down: the bookkeeper is told everything.

## Unit graph

The building's wiring, memorized before the job and checked again at every door.

What a window stops or starts along with Protect is decided by systemd dependencies. `tool/unit-model.txt` holds the
dependencies of the units the window touches as the validated target reports them, plus behaviour that no declared
dependency explains (`observed-stop`). `tool/test-window.sh` simulates exactly this model, and `night.sh` compares the
target's `systemctl show` output with it: `prep`, `go` and `rollback` refuse on any difference, `recover` only warns
(it must be able to bring services back). After a firmware or Protect update that changes these units: review the
difference that `night.sh <batch> preflight` prints, update the model (or point `UNIT_MODEL` at your own copy), make
sure `test-window.sh` still passes against it, and only then run a window. `tool/unit-graph.py` does the parsing and
the comparison (`check`, `query`, `closure`); `lint` refuses a model with a property the fake does not simulate, and a
`ConflictedBy` that is not exactly the reverse of the window units' `Conflicts` (as systemd reports it).

## Copy channel

The route the loot rides. Two modes of transport, one of them only for people who trust their own LAN.

`ubv-push.py` runs on the source and sends each file through SSH to the forced-command receiver `ubv-recv.py` on the
target, which writes it below `<TARGET_STAGING>/files`; both ends compute sha256 and compare. `COPY_MODE=ssh`
(default) carries the data inside the SSH channel. `COPY_MODE=tcp` uses SSH as the control channel only and sends the
data over a one-shot plain TCP connection that the receiver opens per file, gated by a one-time token and the SSH
client's address: it is **not encrypted**, so use it only on a trusted LAN.

The copy runner (`copyq.py run`, the `<NAME_PREFIX>-copy` service) starts the push on the source as a transient unit
(`PUSH_UNIT`, one at a time, survives a lost controller), moves files that Protect deleted on the source meanwhile to
`<slug>.gone`, retries transport failures, stops on anything else, and verifies every finished camera
(`tool/verify-staged.sh`: no source row added or changed apart from the successor update that comes with a deletion
(MECHANISM.md 5; that file is then re-read on the source), every staged file re-read on the target, samples re-read on
the source). Footage the source threw out mid-job is not dragged back in; it is listed in `<slug>.gone` and
reported.

## Notifications

The lookout reports in, once per milestone, with a whistle you can key on.

`NOTIFY_CMD` is any executable; it is called once per event as `NOTIFY_CMD <event-key> <message>` with
`NOTIFY_EVENT=<event>` in the environment, and exit 0 means delivered. Retries and de-duplication are the hook's job;
the key is stable per event, so it can serve as an idempotency key.

| event | key | when |
|---|---|---|
| `copy-done` | `copy:done:<slug>` | a camera is copied and verified |
| `copy-error` | `copy:error:<slug>:<n>` | the copy queue stopped |
| `copy-ready` | `copy:ready:<slug>` | `copyq.py ready <slug> <note>` |
| `copy-summary` | `copy:summary:<YYYY-MM-DD>` | daily summary (timer) |
| `observe-fail` | `observe:fail:<slug>:<YYYY-MM-DD>` | a daily observation check found a problem |

Without `NOTIFY_CMD` events are only logged.

## Known unknowns

The part of the plan the crew will not pretend to know. Every item below is a real gap, not a footnote.

- Whether imported recordings and rows survive later Protect upgrades (schema migrations) has not been tested.
- Imported files are the oldest on the target's disk: when the target needs space, its retention deletes them first.
- After a restart Protect may expire face samples that are older than a camera's earliest recording still on disk
  (MECHANISM.md); `face-check.sh` detects it, it does not prevent it for cameras you have not imported.
- The ledger schema (`LEDGER_SCHEMA`) and each batch's remaining staging tables stay in Protect's database (rollback
  and verify need them); how a future Protect version treats them is unknown.
- The TCP copy mode is for a trusted LAN only (see "Copy channel").
- The unit graph check covers the units the window stops and starts. Units outside that set (the ones a Protect or
  recorder start pulls in) are seen only through their edges to window units (`Wants`, `ConflictedBy`, ...); their own
  dependencies and behaviour are neither compared nor simulated.
- The window's guard makes Protect's own start fail while the import runs; it does not stop something else on the
  console from starting Protect's dependencies (or retrying Protect) during the window. Whether UniFi OS ever does that
  is unknown; the tests do not inject such a start.

## Tests

Rehearsals, including the ones where the vault catches fire on purpose: the window script alone is put
through T0 to T19, most of them injected faults.

- `tool/dryrun.sh <batch>`: SQL scenarios against a fresh clone of the target database per scenario. Expected values
  come from the batch manifest and the clone; fixtures are picked from the batch's own data (missing fixture = SKIP,
  never PASS). Clone: `TARGET_DUMP` > `CLONE` in batch.env > newest `<batch>/<target label>-clone-*.dump`.
- `tool/test-window.sh <batch>`: the window script against a fake systemctl that follows `tool/unit-model.txt`, with
  fault injection (T0-T19). T18 removes the window's explicit PostgreSQL start and must fail, because stopping
  Protect stops its PostgreSQL: keep that property when changing the model or the fake. T19 checks the fake on a mutated model:
  a Conflicts stop, stops reaching further through `observed-stop` lines, a restart's stop-then-start order with
  try-restarts of its dependents, and the guard keeping a restarted dependent down. `WINDOW_SCRIPT=<file>` runs another version of the window
  script against the same fake.
- `tool/test-unit-graph.sh`: offline tests of the unit graph guard (samples, mutations, and `night.sh` with fake ssh
  against `*.invalid` hosts: graph refusals, the deployed-batch, site-configuration and session-name checks).
- `tool/test-transfer.sh`: the copy channel locally (receiver, sender in a private mount namespace, both modes), and
  the runner's verify cleanup.
- `tool/test-verify-media.sh`: verify-media.sh's verdict with fake ssh / curl / ffprobe (`*.invalid` hosts): failed
  or empty queries, the events count against the API, ffprobe's exit status and codec.
- `tool/test-verify-rows.sh`: the copy verify's rows check on synthetic rows, and verify-staged.sh with fake ssh / scp
  (`*.invalid` hosts): the successor update of a deleted file passes and its source file is re-read (a mismatch fails,
  a file deleted since is skipped); a row added, any other change and an unexplained missing row fail.
- `tool/test-verify-sql.sh`: the generated verify.sql on synthetic recording rows in a throw-away database of the
  controller's container: a continued thumbnails / timelapse file is INFO, any other change (a rotating file's end,
  size, an earlier or missing end, free, any other column) a FAIL, a vanished row fails the present check; the
  previous check failed on the continued file; `gen.py --refresh-verify` replaces exactly that check or refuses.
- `install/test-render.sh`: render.sh's `--top-user` guard in a sandbox under `/run` (needs root and an unprivileged
  account named `nobody`).
- After a tool change: regenerate an existing batch with `gen.py` and compare the output with the previous version's,
  then run both suites on it.

## FAQ

**Is this a whole-console migration tool?** No. Only recordings and what hangs off them move: their events, smart
detections and labels, and the face and vehicle groups those detections point to. Cameras, settings, users and
everything else stay on the console they are already on, and the target must have already adopted the camera before
its batch runs.

**Does the vendor support this?** No, and it is not their job to: this is an unofficial tool that writes into
Protect's database and storage during a maintenance window. Read "Read this before you run anything" before you even
think about a date for the job.

**Why does recording have to stop?** Writing into Protect's internal database and storage only makes sense while
Protect is stopped; nothing in this repository is clever enough to do it live. Yes --- the heist turns the security
cameras off itself. A few minutes of not recording is part of the price of moving the recordings.

**Can two cameras go at once?** No. One batch is one camera, and `night.sh` refuses while any batch's window unit
runs. The crew does sequels, not double features.

**Can I take just the recordings and leave the face data behind?** No. This version has no switch that leaves face
data behind; see "Privacy". If you may not keep that data, this crew is not for hire.

**Is there an undo?** Yes: `night.sh <batch> rollback`, run as a window unit, with the refusals listed under
"Safety design". The exit was planned before the entrance.

**Will the imported recordings survive the next Protect upgrade?** Unknown; that has not been tested. See
"Known unknowns" --- that section is there for a reason.

---

footage-heist: the perfect crime, in the sense that it isn't one.
