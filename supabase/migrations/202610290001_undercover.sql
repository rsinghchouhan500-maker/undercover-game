create extension if not exists pgcrypto with schema extensions;

create table if not exists public.uc_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{5}$'),
  host_id uuid not null,
  member_ids uuid[] not null default '{}',
  phase text not null default 'lobby' check (phase in ('lobby','clues','discussion','voting','result')),
  round_no integer not null default 0,
  state jsonb not null default '{"clues":[],"turn_order":[],"turn_index":0,"vote_round":0,"candidates":[]}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists uc_rooms_code_idx on public.uc_rooms(code);

create table if not exists public.uc_players (
  room_id uuid not null references public.uc_rooms(id) on delete cascade,
  user_id uuid not null,
  display_name text not null check (char_length(display_name) between 1 and 18),
  seat integer not null,
  connected boolean not null default true,
  alive boolean not null default true,
  score integer not null default 0,
  last_seen timestamptz not null default now(),
  primary key (room_id,user_id), unique(room_id,seat)
);
create table if not exists public.uc_secrets (
  room_id uuid not null references public.uc_rooms(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('undercover','group')),
  word text not null,
  primary key (room_id,user_id)
);
create table if not exists public.uc_votes (
  room_id uuid not null references public.uc_rooms(id) on delete cascade,
  round_no integer not null,
  vote_round integer not null,
  voter_id uuid not null,
  target_id uuid not null,
  primary key(room_id,round_no,vote_round,voter_id)
);

alter table public.uc_rooms enable row level security;
alter table public.uc_players enable row level security;
alter table public.uc_secrets enable row level security;
alter table public.uc_votes enable row level security;
drop policy if exists "room members can read room" on public.uc_rooms;
create policy "room members can read room" on public.uc_rooms for select to authenticated using (auth.uid() = any(member_ids));
drop policy if exists "room members can read player list" on public.uc_players;
create policy "room members can read player list" on public.uc_players for select to authenticated using (
  exists(select 1 from public.uc_rooms r where r.id = room_id and auth.uid() = any(r.member_ids))
);
-- No client policies are intentionally created for uc_secrets or uc_votes.
revoke all on public.uc_rooms, public.uc_players, public.uc_secrets, public.uc_votes from anon, authenticated;
grant select on public.uc_rooms, public.uc_players to authenticated;
grant all on public.uc_rooms, public.uc_players, public.uc_secrets, public.uc_votes to service_role;

create or replace function public.uc_snapshot(p_room uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r uc_rooms%rowtype; mine uc_secrets%rowtype; roster jsonb; secret_json jsonb; reveal jsonb;
        votes_cast int; self_voted boolean; self_vote_target uuid;
begin
  select * into r from uc_rooms where id=p_room;
  if not found or not (p_user = any(r.member_ids)) then raise exception 'Room not found'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.display_name,'seat',p.seat,'connected',p.connected,'alive',p.alive,'score',p.score) order by p.seat),'[]'::jsonb)
    into roster from uc_players p where p.room_id=p_room;
  select * into mine from uc_secrets where room_id=p_room and user_id=p_user;
  secret_json := case when found then jsonb_build_object('role',mine.role,'word',case when mine.role='group' then mine.word else null end) else null end;
  reveal := null;
  if r.phase='result' then
    select jsonb_build_object('word',min(s.word),'roles',jsonb_object_agg(s.user_id::text,s.role)) into reveal
      from uc_secrets s where s.room_id=p_room;
  end if;
  select count(*) into votes_cast from uc_votes v join uc_players p on p.room_id=v.room_id and p.user_id=v.voter_id
    where v.room_id=p_room and v.round_no=r.round_no and v.vote_round=coalesce((r.state->>'vote_round')::int,0) and p.alive and p.connected;
  select exists(select 1 from uc_votes where room_id=p_room and round_no=r.round_no and vote_round=coalesce((r.state->>'vote_round')::int,0) and voter_id=p_user) into self_voted;
  select target_id into self_vote_target from uc_votes where room_id=p_room and round_no=r.round_no and vote_round=coalesce((r.state->>'vote_round')::int,0) and voter_id=p_user;
  return jsonb_build_object('room',jsonb_build_object('id',r.id,'code',r.code,'host_id',r.host_id,'phase',r.phase,'round',r.round_no,'state',r.state),
    'players',roster,'self_secret',secret_json,'reveal',reveal,'self_id',p_user,'votes_cast',votes_cast,'self_voted',self_voted,'self_vote_target',self_vote_target);
end $$;

create or replace function public.uc_begin_round(p_room uuid)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare word text; undercover_id uuid; order_ids uuid[];
begin
  select array_agg(user_id order by seat) into order_ids from uc_players where room_id=p_room and connected;
  if coalesce(array_length(order_ids,1),0) < 4 or array_length(order_ids,1)>10 then raise exception 'A game needs 4 to 10 players'; end if;
  word := (array['telescope','waterfall','pancake','volcano','library','airplane','pineapple','snowman','lighthouse','keyboard','submarine','campfire','octopus','skateboard','rainbow','spaceship','popcorn','toothbrush','cactus','treasure','bicycle','moonlight','sandwich','penguin','fireworks','sunglasses','butterfly','milkshake','jigsaw','thermometer','backpack','cinnamon','parachute','chocolate','footprint','hourglass','toaster','mermaid','hammock','snowflake'])[1 + floor(random()*40)::int];
  select user_id into undercover_id from uc_players where room_id=p_room and connected order by random() limit 1;
  delete from uc_secrets where room_id=p_room;
  insert into uc_secrets(room_id,user_id,role,word) select p_room,user_id,case when user_id=undercover_id then 'undercover' else 'group' end,word from uc_players where room_id=p_room and connected;
  update uc_players set alive=connected where room_id=p_room;
  update uc_rooms set phase='clues',round_no=round_no+1,updated_at=now(),state=jsonb_build_object('clues','[]'::jsonb,'turn_order',to_jsonb(order_ids),'turn_index',0,'vote_round',0,'candidates','[]'::jsonb,'result',null) where id=p_room;
  delete from uc_votes where room_id=p_room;
end $$;

create or replace function public.uc_continue_round(p_room uuid)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare order_ids uuid[];
begin
  select array_agg(user_id order by seat) into order_ids from uc_players where room_id=p_room and connected and alive;
  if coalesce(array_length(order_ids,1),0)=0 then raise exception 'No connected players remain'; end if;
  update uc_rooms set phase='clues',round_no=round_no+1,updated_at=now(),state=jsonb_build_object('clues','[]'::jsonb,'turn_order',to_jsonb(order_ids),'turn_index',0,'vote_round',0,'candidates','[]'::jsonb,'result',null) where id=p_room;
  delete from uc_votes where room_id=p_room;
end $$;

create or replace function public.uc_resolve_votes(p_room uuid)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r uc_rooms%rowtype; candidates uuid[]; tied uuid[]; v_round int; vote_count int; expected_count int; target uuid;
begin
  select * into r from uc_rooms where id=p_room;
  if r.phase<>'voting' then return; end if;
  v_round:=coalesce((r.state->>'vote_round')::int,1);
  candidates:=array(select p.user_id from uc_players p where p.room_id=p_room and p.alive and p.user_id=any(array(select jsonb_array_elements_text(r.state->'candidates')::uuid)) order by p.seat);
  update uc_rooms set state=r.state||jsonb_build_object('candidates',to_jsonb(candidates)) where id=p_room;
  select count(*) into expected_count from uc_players where room_id=p_room and alive and connected;
  select count(*) into vote_count from uc_votes v where v.room_id=p_room and v.round_no=r.round_no and v.vote_round=v_round and v.voter_id in (select user_id from uc_players where room_id=p_room and alive and connected);
  if expected_count=0 or vote_count<expected_count then return; end if;
  select array_agg(q.target_id order by q.target_id) into tied from (
    select v.target_id,count(*) n from uc_votes v join uc_players p on p.room_id=v.room_id and p.user_id=v.target_id
    where v.room_id=p_room and v.round_no=r.round_no and v.vote_round=v_round and p.alive
      and v.voter_id in (select user_id from uc_players where room_id=p_room and alive and connected)
    group by v.target_id
  ) q where q.n=(select max(z.n) from (
    select count(*) n from uc_votes v join uc_players p on p.room_id=v.room_id and p.user_id=v.target_id
    where v.room_id=p_room and v.round_no=r.round_no and v.vote_round=v_round and p.alive
      and v.voter_id in (select user_id from uc_players where room_id=p_room and alive and connected)
    group by v.target_id
  ) z);
  if coalesce(array_length(tied,1),0)=0 then return; end if;
  if array_length(tied,1)>1 and v_round=1 then
    update uc_rooms set state=r.state||jsonb_build_object('vote_round',2,'candidates',to_jsonb(tied)),updated_at=now() where id=p_room;
  elsif array_length(tied,1)>1 then
    perform uc_finish_round(p_room,'none',null);
  else
    target:=tied[1];
    update uc_players set alive=false where room_id=p_room and user_id=target;
    if (select role from uc_secrets where room_id=p_room and user_id=target)='undercover' then perform uc_finish_round(p_room,'group',target);
    elsif (select count(*) from uc_players where room_id=p_room and alive)<=2 then perform uc_finish_round(p_room,'undercover',target);
    else perform uc_continue_round(p_room); end if;
  end if;
end $$;

create or replace function public.uc_finish_round(p_room uuid,p_winner text,p_eliminated uuid default null)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r uc_rooms%rowtype; roles jsonb; winning_ids uuid[]; word text; st jsonb;
begin
  select * into r from uc_rooms where id=p_room;
  select jsonb_object_agg(user_id::text,role),min(s.word) into roles,word from uc_secrets s where room_id=p_room;
  if p_winner='group' then select array_agg(user_id) into winning_ids from uc_players p join uc_secrets s using(room_id,user_id) where p.room_id=p_room and s.role='group';
  elsif p_winner='undercover' then select array_agg(user_id) into winning_ids from uc_players p join uc_secrets s using(room_id,user_id) where p.room_id=p_room and s.role='undercover';
  else winning_ids := '{}'::uuid[]; end if;
  update uc_players set score=score+1 where room_id=p_room and user_id=any(coalesce(winning_ids,'{}'::uuid[]));
  st := r.state || jsonb_build_object('result',jsonb_build_object('winner',p_winner,'eliminated_id',p_eliminated,'word',word,'roles',roles));
  update uc_rooms set phase='result',state=st,updated_at=now() where id=p_room;
end $$;

create or replace function public.run_undercover_action(p_user uuid,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r uc_rooms%rowtype; target_room uuid; new_id uuid; code_value text; display_value text; player_count int; me uc_players%rowtype;
        st jsonb; turn_ids uuid[]; current_idx int; current_id uuid; target_id uuid; clue_value text; v_round int; candidates uuid[]; counts record; tied uuid[]; voter_count int; expected_count int; winner text;
begin
  if p_action='create' then
    display_value := trim(regexp_replace(coalesce(p_data->>'name',''),'\s+',' ','g'));
    if char_length(display_value)<1 or char_length(display_value)>18 then raise exception 'Choose a name from 1 to 18 characters'; end if;
    if exists(select 1 from uc_players where user_id=p_user and connected) then raise exception 'You are already in a room'; end if;
    loop code_value := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',1+floor(random()*32)::int,1),'') from generate_series(1,5)); exit when not exists(select 1 from uc_rooms where code=code_value); end loop;
    insert into uc_rooms(code,host_id,member_ids) values(code_value,p_user,array[p_user]) returning id into target_room;
    insert into uc_players(room_id,user_id,display_name,seat) values(target_room,p_user,display_value,1);
    return uc_snapshot(target_room,p_user);
  end if;
  if p_action='join' then
    display_value := trim(regexp_replace(coalesce(p_data->>'name',''),'\s+',' ','g'));
    code_value := upper(regexp_replace(coalesce(p_data->>'code',''),'[^A-Za-z0-9]','','g'));
    if char_length(display_value)<1 or char_length(display_value)>18 then raise exception 'Choose a name from 1 to 18 characters'; end if;
    select id into target_room from uc_rooms where code=code_value for update;
    if not found then raise exception 'We could not find that room code'; end if;
    if (select phase from uc_rooms where id=target_room)='lobby' then
      delete from uc_players where room_id=target_room and user_id<>p_user and not connected and last_seen < now()-interval '70 seconds';
      update uc_rooms set member_ids=coalesce(array(select m from unnest(member_ids) m where exists(select 1 from uc_players p where p.room_id=target_room and p.user_id=m)),'{}'::uuid[]) where id=target_room;
    end if;
    if exists(select 1 from uc_players where room_id=target_room and user_id=p_user) then update uc_players set connected=true,last_seen=now() where room_id=target_room and user_id=p_user; return uc_snapshot(target_room,p_user); end if;
    select count(*) into player_count from uc_players where room_id=target_room;
    if player_count>=10 then raise exception 'This room is full (10 players maximum)'; end if;
    if (select phase from uc_rooms where id=target_room)<>'lobby' then raise exception 'This round is already in progress'; end if;
    if exists(select 1 from uc_players where user_id=p_user and connected) then raise exception 'You are already in a room'; end if;
    insert into uc_players(room_id,user_id,display_name,seat) values(target_room,p_user,display_value,coalesce((select max(seat)+1 from uc_players where room_id=target_room),1));
    update uc_rooms set member_ids=array_append(member_ids,p_user),
      host_id=case when exists(select 1 from uc_players p where p.room_id=target_room and p.user_id=uc_rooms.host_id and p.connected) then host_id
        else coalesce((select p.user_id from uc_players p where p.room_id=target_room and p.connected order by p.seat limit 1),p_user) end,
      updated_at=now() where id=target_room;
    return uc_snapshot(target_room,p_user);
  end if;

  target_room := nullif(p_data->>'room_id','')::uuid;
  if target_room is null then raise exception 'Room not found'; end if;
  select * into r from uc_rooms where id=target_room for update;
  if not found or not (p_user=any(r.member_ids)) then raise exception 'Room not found'; end if;
  select * into me from uc_players where room_id=target_room and user_id=p_user for update;
  st := r.state;

  if p_action='heartbeat' then
    update uc_players set connected=true,last_seen=now() where room_id=target_room and user_id=p_user;
    update uc_players set connected=false where room_id=target_room and connected and last_seen < now()-interval '70 seconds';
    if exists(select 1 from uc_players where room_id=target_room and user_id=r.host_id and not connected) then
      select user_id into new_id from uc_players where room_id=target_room and connected order by seat limit 1;
      if new_id is not null then update uc_rooms set host_id=new_id,updated_at=now() where id=target_room; end if;
    end if;
    if r.phase='clues' then
      turn_ids := array(select jsonb_array_elements_text(st->'turn_order')::uuid);
      current_idx := coalesce((st->>'turn_index')::int,0);
      while current_idx < coalesce(array_length(turn_ids,1),0) loop
        current_id := turn_ids[current_idx+1];
        exit when exists(select 1 from uc_players where room_id=target_room and user_id=current_id and connected and alive);
        current_idx := current_idx+1;
      end loop;
      if current_idx <> coalesce((st->>'turn_index')::int,0) then st := st || jsonb_build_object('turn_index',current_idx); update uc_rooms set state=st where id=target_room; end if;
      if current_idx>=coalesce(array_length(turn_ids,1),0) then update uc_rooms set phase='discussion',updated_at=now() where id=target_room; end if;
    end if;
    if r.phase='voting' then perform uc_resolve_votes(target_room); end if;
    update uc_rooms set updated_at=now() where id=target_room;
    return uc_snapshot(target_room,p_user);
  elsif p_action='leave' then
    update uc_players set connected=false,alive=false,last_seen=now() where room_id=target_room and user_id=p_user;
    if r.host_id=p_user then select user_id into new_id from uc_players where room_id=target_room and user_id<>p_user and connected order by seat limit 1; if new_id is not null then update uc_rooms set host_id=new_id where id=target_room; end if; end if;
    if r.phase in ('clues','discussion','voting') and (select role from uc_secrets where room_id=target_room and user_id=p_user)='undercover' then perform uc_finish_round(target_room,'group',p_user);
    elsif r.phase in ('clues','discussion','voting') and (select count(*) from uc_players where room_id=target_room and alive)<=2 and exists(select 1 from uc_players p join uc_secrets s using(room_id,user_id) where p.room_id=target_room and p.alive and s.role='undercover') then perform uc_finish_round(target_room,'undercover',p_user);
    elsif r.phase='clues' then turn_ids:=array(select jsonb_array_elements_text(st->'turn_order')::uuid);current_idx:=coalesce((st->>'turn_index')::int,0);if turn_ids[current_idx+1]=p_user then st:=st||jsonb_build_object('turn_index',current_idx+1);update uc_rooms set state=st where id=target_room; end if;
    end if;
    if r.phase='voting' then perform uc_resolve_votes(target_room); end if;
    return uc_snapshot(target_room,p_user);
  elsif p_action='start' then
    if r.host_id<>p_user then raise exception 'Only the host can start the game'; end if;
    if r.phase<>'lobby' then raise exception 'This room is not in the lobby'; end if;
    perform uc_begin_round(target_room);
  elsif p_action='rematch' then
    if r.host_id<>p_user then raise exception 'Only the host can start a rematch'; end if;
    if r.phase<>'result' then raise exception 'The round is still in progress'; end if;
    perform uc_begin_round(target_room);
  elsif p_action='clue' then
    if r.phase<>'clues' then raise exception 'Clue time is over'; end if;
    turn_ids:=array(select jsonb_array_elements_text(st->'turn_order')::uuid);current_idx:=coalesce((st->>'turn_index')::int,0);
    if turn_ids[current_idx+1] is distinct from p_user then raise exception 'Wait for your turn to give a clue'; end if;
    clue_value:=trim(regexp_replace(coalesce(p_data->>'clue',''),'\s+',' ','g'));
    if char_length(clue_value)<1 or char_length(clue_value)>40 then raise exception 'Use a clue from 1 to 40 characters'; end if;
    st:=st||jsonb_build_object('clues',coalesce(st->'clues','[]'::jsonb)||jsonb_build_array(jsonb_build_object('player_id',p_user,'text',clue_value)),'turn_index',current_idx+1);
    update uc_rooms set state=st,phase=case when current_idx+1>=array_length(turn_ids,1) then 'discussion' else 'clues' end,updated_at=now() where id=target_room;
  elsif p_action='begin_vote' then
    if r.host_id<>p_user then raise exception 'Only the host can start the vote'; end if;
    if r.phase<>'discussion' then raise exception 'Discussion is not ready yet'; end if;
    candidates:=array(select user_id from uc_players where room_id=target_room and alive order by seat);
    if array_length(candidates,1)<2 then raise exception 'At least two connected players are needed to vote'; end if;
    update uc_rooms set phase='voting',state=st||jsonb_build_object('vote_round',1,'candidates',to_jsonb(candidates)),updated_at=now() where id=target_room;
  elsif p_action='vote' then
    if r.phase<>'voting' then raise exception 'Voting is closed'; end if;
    if not me.alive or not me.connected then raise exception 'Only connected players still in the round can vote'; end if;
    target_id:=nullif(p_data->>'target_id','')::uuid;
    candidates:=array(select jsonb_array_elements_text(st->'candidates')::uuid);
    if not (target_id=any(candidates)) then raise exception 'Choose an eligible player'; end if;
    v_round:=coalesce((st->>'vote_round')::int,1);
    insert into uc_votes(room_id,round_no,vote_round,voter_id,target_id) values(target_room,r.round_no,v_round,p_user,target_id)
      on conflict(room_id,round_no,vote_round,voter_id) do update set target_id=excluded.target_id;
    select count(*) into expected_count from uc_players where room_id=target_room and alive and connected;
    select count(*) into voter_count from uc_votes where room_id=target_room and round_no=r.round_no and vote_round=v_round;
    perform uc_resolve_votes(target_room);
  else raise exception 'Unknown game action';
  end if;
  select * into r from uc_rooms where id=target_room;
  return uc_snapshot(target_room,p_user);
end $$;
revoke all on function public.run_undercover_action(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.run_undercover_action(uuid,text,jsonb) to service_role;
revoke all on function public.uc_snapshot(uuid,uuid) from public, anon, authenticated;
revoke all on function public.uc_begin_round(uuid) from public, anon, authenticated;
revoke all on function public.uc_finish_round(uuid,text,uuid) from public, anon, authenticated;
revoke all on function public.uc_continue_round(uuid) from public, anon, authenticated;
revoke all on function public.uc_resolve_votes(uuid) from public, anon, authenticated;

alter publication supabase_realtime add table public.uc_rooms;
