-- rows.sql (psql -v mac=<MAC>) --- one camera's non-free recordingFiles rows on the SOURCE console, oldest first.
-- Columns 1-4 (id|folder|file|size) are the copy list; the full row is the pre/post-copy snapshot.
select r.id, r.folder, r.file, r.size, r.type, r.channel, r.start, r."end", r.active, r.locked, r.free, r."compactionState", r."updatedAt"
from "recordingFiles" r join cameras c on c.id = r."cameraId" where c.mac = :'mac' and not r.free order by r.start
