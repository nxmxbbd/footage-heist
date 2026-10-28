# MECHANISM.md --- what the guards are for

The behaviour below applies to UniFi Protect 7.3.70 (source: UniFi Dream Machine SE, target: UNVR). Each item states
the behaviour, how you can check it on your own console, and which part of the tool depends on it. Nothing here is a
statement about how Protect is implemented; it is what a console shows from the outside. Another Protect version may
behave differently: check every item before you run a window there (README "Version guard").

Commands run on the console as root. `psql` means
`psql -U postgres -p 5433 -h 127.0.0.1 -d unifi-protect` (Protect's own PostgreSQL 14 instance).

## 1. Stopping Protect stops its PostgreSQL

Behaviour: `systemctl stop unifi-protect` also stops `postgresql@14-protect`; Protect's database is unreachable until that
unit is started again. Starting `postgresql@14-protect` on its own does not start Protect.

Check: `systemctl show postgresql@14-protect -p PartOf` lists `unifi-protect.service`. During a maintenance stop,
`systemctl is-active postgresql@14-protect` reports `inactive`.

Tool: the window starts the PostgreSQL server unit itself after Protect is down, while a drop-in keeps Protect from
starting; recovery starts it too before it reads the ledger. The window never starts `postgresql-cluster@14-protect`
(a oneshot unit: `systemctl show postgresql-cluster@14-protect -p Type -p WantedBy`) directly; restarting `msr` pulls it
in, because `msr` lists it under `Wants=` (`systemctl show msr -p Wants`), exactly as any `msr` start on the console
does. `tool/unit-model.txt` records the dependencies; `test-window.sh` T18 fails if the window ever stops starting
PostgreSQL itself.

## 2. The media services follow Protect

Behaviour: when Protect stops, the recorder `msr` stops with it. While Protect stays down, `msp`, `mst` and `ms` are
stopped as well, within about two minutes. When Protect starts, it starts them again.

Check: `journalctl -u unifi-protect -u msr -u msp -u mst -u ms --since -10min` around a Protect stop shows the stop
times; `systemctl show unifi-protect -p Wants` lists the media services.

Tool: the window stops `msr`, `msp` and `mst` explicitly and checks that each is down before it links anything. Before
Protect starts, it restarts only `msr` and requires it to be a new process that stays up (same PID, no restarts) for
20 seconds; `msp`, `mst` and `ms` are left to Protect's own start. The model's `observed-stop` line simulates the stop
seen above, because no declared dependency explains it.

## 3. Protect deletes events older than the camera's earliest recording at startup

Behaviour: when Protect starts, it deletes a camera's events that ended before the earliest recording of that camera that
is still on disk, and logs a line containing `Startup purge completed`.

Check: before a restart, note `select count(*) from events where "cameraId" = '<id>'` and
`select min(start) from "recordingFiles" where "cameraId" = '<id>' and not free`; compare after the restart, and
`grep -h 'Startup purge completed' /srv/unifi-protect/logs/*.log`.

Tool: imported events are only safe once the camera's earliest recording includes the imported files. The window
therefore restarts `msr` with the imported files in place and proves it healthy before Protect starts; if `msr` is not
healthy after the commit, the import is rolled back automatically before Protect starts. The apply refuses imported
events that end before the camera's earliest rotating recording. `night.sh verify` shows the purge line.

## 4. Face samples older than a camera's earliest recording may expire after a restart

Behaviour: after a restart, Protect may expire stored face samples of a camera that are older than that camera's earliest
recording still on disk.

Check: count samples per camera in the face database before and after a restart:
`psql -U postgres -p 5433 -h 127.0.0.1 -d smart_detect_face -c 'select camera_id, count(*) from ui_face_db group by 1'`, or
`tool/face-check.sh snapshot` before and `tool/face-check.sh compare <snapshot.tsv>` after.

Tool: importing moves an imported camera's earliest recording back in time, which covers its older samples; cameras
not imported yet are not protected. `face-check.sh` takes the snapshot right before a window and compares right after
(only sample ids, cameras and timestamps; never embeddings or names).

## 5. Recording files: names, places, ownership

Behaviour: recordings live below `/srv/unifi-protect/video/YYYY/MM/DD/` as `<MAC>_<channel>_<type>_<start ms>.ubv`, owned
by user `ms`, group `unifi-streaming`, and each has a `recordingFiles` row (`folder`, `file`, `start`, `end`, `size`).

Check: `ls -l /srv/unifi-protect/video/$(date +%Y/%m/%d)/ | head` and
`select folder, file, start, "end", size from "recordingFiles" order by start desc limit 3`.

Tool: staged files get the same owner, group and mode before the window; the window hardlinks them into the same
layout (which needs the staging directory on the same mount: `stat -c %m` of both) and the apply inserts their rows.
Links are removed again only if the inode still matches the staged file and no row references the path.

Behaviour: a camera that has no native thumbnails file of its own on the target gets none after the import either: the
recorder continues the imported one. Its row's `end` moves forward to the present, while `size` (preallocated), `start`,
`file` and `folder` stay; the thumbnails imported in it are still served. Seen on a thumbnails file, starting about half
a day after its window; the tool treats a timelapse file the same way.

Check: `select type, file, "end", size, "updatedAt" from "recordingFiles" where "cameraId" = '<id>' and type <> 'rotating'
and not free` on consecutive days.

Tool: `verify.sql` reports such a row (thumbnails / timelapse, later `end`, every other column unchanged) as an `INFO`
line, any other change to an imported row as a FAIL. `rollback.sql` still refuses on it: the file now holds native data.

Behaviour: when Protect deletes a camera's oldest recording file to free space, it also updates the row of the next file
of the same type and channel: `start` becomes the deleted file's `end` (a few milliseconds later where the two
overlapped, the same value where they touched) and `updatedAt` changes, while `file`, `size`, `end` and the flags stay.
The file itself is not rewritten: its modification time and sha256 stay those of the day it was recorded. Seen on two
consecutive daily deletions in one camera's rotating channel-0 chain (once overlapping by 4 ms: `start` moved; once
touching: only `updatedAt` changed).

Check: `select id, file, start, "end", "updatedAt" from "recordingFiles" where "cameraId" = '<id>' and type = 'rotating'
and channel = 0 and not free order by start limit 3` before and after a deletion, and `sha256sum` of the second file.

Tool: the copy verify (`verify-staged.sh`, rows check in `verify-rows.py`) accepts exactly that change on a row whose
predecessor disappeared during the same copy, and then re-reads that file on the source against the ledger (a mismatch
is a FAIL); any other added or changed source row during a copy is a FAIL.

## 6. The services the window touches and their dependencies

Behaviour: the window's units and the dependency lists in `tool/unit-model.txt`.

Check: `systemctl show unifi-protect postgresql@14-protect msr msp mst ms -p Id -p LoadState -p Requires -p Requisite
-p BindsTo -p PartOf -p Wants -p Conflicts -p OnFailure -p ConflictedBy` (plus `Upholds`, `UpheldBy`, `PropagatesStopTo`,
`StopPropagatedFrom` and `OnSuccess` where systemd reports them), or `python3 tool/unit-graph.py query
tool/unit-model.txt` for the exact arguments.

Tool: `night.sh preflight` runs exactly that query on the target and compares the answer with the model; `prep`, `go`
and `rollback` refuse on any difference (README "Unit graph").
