-- extract.sql --- select + statically transform one camera's history from a restored SOURCE Protect DB
-- into schema "stage" of the same database. Runs on the controller's disposable Postgres (db: src), never on a device.
-- psql vars: cam (source camera id), ucam (target camera id), cut (ms: the moment the target took the camera over),
-- ai_src, ai_dst (AI processor ids on source / target)
-- Dynamic decisions (face-group merge by externalId, label lids) are NOT made here: apply.sql makes them
-- inside the stop window against the live target, because the target keeps creating groups / labels until then.
\set ON_ERROR_STOP on
begin;
select set_config('extract.cam', :'cam', false), set_config('extract.ucam', :'ucam', false);
drop schema if exists stage cascade;
create schema stage;

-- events: detection types only (allowlist); system / sensor / admin events stay behind (no children, and
-- they point at source users / sensors that do not exist on the target)
create table stage.events as
  select e.* from public.events e
  where e."cameraId" = :'cam'
    and e.type in ('smartDetectZone', 'motion', 'smartDetectLine', 'smartAudioDetect')
    and e."deletedAt" is null and e."end" is not null and e.start < :cut;
do $$ begin
  if exists (select 1 from stage.events where "userId" is not null or "partitionId" is not null) then
    raise exception 'detection event with userId/partitionId --- unexpected, review before nulling';
  end if;
end $$;
update stage.events set "cameraId" = :'ucam', metadata = replace(metadata::text, :'cam', :'ucam')::json;

-- recording files (rotating / thumbnails / timelapse), never free slots; source thumbnails may live on /ssd1
create table stage."recordingFiles" as
  select * from public."recordingFiles" where "cameraId" = :'cam' and not free;
update stage."recordingFiles"
  set "cameraId" = :'ucam', folder = regexp_replace(folder, '^/ssd1/', '/srv/'), active = false;
do $$ begin
  if exists (select 1 from stage."recordingFiles" where folder !~ '^/srv/unifi-protect/video/[0-9]{4}/[0-9]{2}/[0-9]{2}$') then
    raise exception 'unexpected recordingFiles folder';
  end if;
  if exists (select 1 from public.detections d join stage."recordingFiles" r on r.id = d."recordingFileId")
     or exists (select 1 from public.partitions p join stage."recordingFiles" r on r.id = p."recordingFileId")
     or exists (select 1 from public."savedRecordingFiles" s join stage."recordingFiles" r on r.id = s."recordingFileId") then
    raise exception 'recordingFiles children (detections / partitions / savedRecordingFiles) present --- not handled';
  end if;
end $$;

-- smart-detect objects + areas (group ids kept as source ids; mapped in apply)
create table stage."smartDetectObjects" as
  select * from public."smartDetectObjects" where "eventId" in (select id from stage.events);
update stage."smartDetectObjects" set "cameraId" = :'ucam';
create table stage."smartDetectObjectAreas" as
  select * from public."smartDetectObjectAreas" where "smartDetectObjectId" in (select id from stage."smartDetectObjects");
-- enhanced images of the objects (seen: type face; no camera column, at most one per object)
create table stage."enhancedImages" as
  select * from public."enhancedImages" where "smartDetectObjectId" in (select id from stage."smartDetectObjects");

-- face / vehicle groups referenced by the objects (inserted or merged in apply)
create table stage."smartDetectObjectGroups" as
  select * from public."smartDetectObjectGroups"
  where id in (select "smartDetectObjectGroupId" from stage."smartDetectObjects");

-- heatmaps, tracks, RAM detections
create table stage.heatmaps as select * from public.heatmaps where "eventId" in (select id from stage.events);
update stage.heatmaps set "cameraId" = :'ucam';
create table stage."smartDetectTracks" as select * from public."smartDetectTracks" where "eventId" in (select id from stage.events);
update stage."smartDetectTracks" set "cameraId" = :'ucam';
create table stage."ramDetections" as select * from public."ramDetections" where "eventId" in (select id from stage.events);
-- a detection by another AI processor than AI_SRC has no mapping here: refuse instead of inventing a NULL (a NULL in
-- the source stays NULL)
select set_config('extract.ai_src', :'ai_src', false) as _ai_src_set \gset
do $$ begin
  if exists (select 1 from stage."ramDetections" where "aiprocessorId" is not null
             and "aiprocessorId"::text <> current_setting('extract.ai_src')) then
    raise exception 'ramDetections by an AI processor other than AI_SRC --- not handled';
  end if;
end $$;
update stage."ramDetections"
  set "cameraId" = :'ucam',
      "aiprocessorId" = case when "aiprocessorId" = :'ai_src' then :'ai_dst' else null end;
do $$ begin
  if exists (select 1 from stage."ramDetections" where "smartDetectObjectId" is not null
             and "smartDetectObjectId" not in (select id from stage."smartDetectObjects")) then
    raise exception 'ramDetections point at objects outside the batch';
  end if;
end $$;

-- transcriptions of the events (seen on smartAudioDetect events); a row on another camera than the batch camera has no
-- mapping here: refuse instead of moving it to the target camera (a NULL in the source stays NULL)
create table stage.transcriptions as select * from public.transcriptions where "eventId" in (select id from stage.events);
do $$ begin
  if exists (select 1 from stage.transcriptions where "cameraId" <> current_setting('extract.cam')) then
    raise exception 'transcriptions on another camera than the batch camera --- not handled';
  end if;
end $$;
update stage.transcriptions set "cameraId" = :'ucam' where "cameraId" = :'cam';

-- detection labels: lids -> names (camera id rewritten); lids are resolved on the target in apply
create table stage."detectionLabels" as
  select d.*,
         case when d.labels is null then null   -- keep '{}' as '{}' (array_agg over nothing is NULL)
              else coalesce((select array_agg(replace(l.name, :'cam', :'ucam') order by u.ord)
                               from unnest(d.labels) with ordinality u(lid, ord) join public.labels l on l.lid = u.lid), '{}'::text[]) end as label_names
  from public."detectionLabels" d where d."eventId" in (select id from stage.events);
-- dangling lids: the source's labels row is gone (seen: "group:<id>" of a face group the source already deleted) ->
-- the name is unrecoverable and pointed at nothing on the source either: dropped from label_names, recorded here
create table stage.dropped_lids as
  select d.id as "detectionLabelId", d."eventId", u.lid from stage."detectionLabels" d cross join lateral unnest(d.labels) u(lid)
  where not exists (select 1 from public.labels l where l.lid = u.lid);
do $$ begin
  if exists (select 1 from stage."detectionLabels" d
             where coalesce(array_length(d.labels, 1), 0) - coalesce(array_length(d.label_names, 1), 0)
                   <> (select count(*) from stage.dropped_lids x where x."detectionLabelId" = d.id)) then
    raise exception 'detectionLabels lost labels other than dangling lids';
  end if;
end $$;
create table stage.labels as
  select distinct on (n.name) n.name, l.id, l."lastSeen", l."createdAt", l."updatedAt"
  from public.labels l
  join lateral (select replace(l.name, :'cam', :'ucam') as name) n on true
  where l.lid in (select unnest(labels) from public."detectionLabels" where "eventId" in (select id from stage.events))
  order by n.name, l."lastSeen" desc nulls last;

-- tables deliberately not imported must have nothing for this batch (else: stop and decide)
do $$ declare n bigint; begin
  select count(*) into n from public."smartDetectSessionObjects" where "smartDetectObjectId" in (select id from stage."smartDetectObjects");
  if n > 0 then raise exception 'smartDetectSessionObjects: % rows, not handled', n; end if;
  select count(*) into n from public."smartDetectSessions" where "eventId" in (select id from stage.events);
  if n > 0 then raise exception 'smartDetectSessions: % rows, not handled', n; end if;
  select count(*) into n from public."favoriteEvents" where "eventId" in (select id from stage.events);
  if n > 0 then raise exception 'favoriteEvents: % rows, not handled', n; end if;
  select count(*) into n from public.thumbnails where "eventId" in (select id from stage.events);
  if n > 0 then raise exception 'thumbnails: % rows, not handled', n; end if;
  select count(*) into n from public."packageThumbnails" where "eventId" in (select id from stage.events);
  if n > 0 then raise exception 'packageThumbnails: % rows, not handled', n; end if;
end $$;

-- the source camera id must not survive anywhere in the staged rows
do $$ declare t text; n bigint; begin
  foreach t in array array['events','recordingFiles','smartDetectObjects','smartDetectObjectAreas','enhancedImages',
                           'smartDetectObjectGroups','heatmaps','smartDetectTracks','ramDetections','transcriptions',
                           'detectionLabels','labels'] loop
    execute format('select count(*) from stage.%I x where to_jsonb(x)::text like %L', t, '%' || current_setting('extract.cam') || '%') into n;
    if n > 0 then raise exception 'old camera id still present in stage.% (% rows)', t, n; end if;
  end loop;
end $$;
commit;

select 'events' t, count(*) from stage.events union all select 'recordingFiles', count(*) from stage."recordingFiles"
union all select 'smartDetectObjects', count(*) from stage."smartDetectObjects" union all select 'smartDetectObjectAreas', count(*) from stage."smartDetectObjectAreas"
union all select 'enhancedImages', count(*) from stage."enhancedImages"
union all select 'smartDetectObjectGroups', count(*) from stage."smartDetectObjectGroups" union all select 'heatmaps', count(*) from stage.heatmaps
union all select 'smartDetectTracks', count(*) from stage."smartDetectTracks" union all select 'ramDetections', count(*) from stage."ramDetections"
union all select 'transcriptions', count(*) from stage.transcriptions
union all select 'detectionLabels', count(*) from stage."detectionLabels" union all select 'labels', count(*) from stage.labels;
select 'dropped dangling lids', count(*) || ' (rows ' || count(distinct "detectionLabelId") || ', events ' || count(distinct "eventId") || ')' from stage.dropped_lids;
