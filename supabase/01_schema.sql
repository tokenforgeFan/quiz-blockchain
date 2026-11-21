-- =====================================================================
-- Chaîne des Quiz — base Supabase (comptes, correction serveur, classements)
-- À coller tel quel dans Supabase → SQL Editor → Run.
-- Ensuite, exécuter 02_questions.sql (les 160 questions).
-- =====================================================================

create extension if not exists citext;

-- ---------- Profils (pseudo public) ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  pseudo     citext not null unique
             check (char_length(pseudo) between 3 and 20 and pseudo ~ '^[A-Za-z0-9_\-\.]+$'),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profils lisibles" on public.profiles;
create policy "profils lisibles" on public.profiles for select using (true);
drop policy if exists "créer son profil" on public.profiles;
create policy "créer son profil" on public.profiles for insert with check (auth.uid() = id);
drop policy if exists "modifier son profil" on public.profiles;
create policy "modifier son profil" on public.profiles for update using (auth.uid() = id);

-- ---------- Blocs et questions (bonnes réponses invisibles des joueurs) ----------
create table if not exists public.levels (
  id     text primary key,          -- s1, s2, ...
  ord    int  not null,
  title  text not null,
  src    text
);
create table if not exists public.questions (
  level_id    text not null references public.levels(id) on delete cascade,
  idx         int  not null,        -- 0..19
  prompt      text not null,
  options     jsonb not null,       -- ["A","B","C","D"]
  answer      int  not null,        -- indice de la bonne option (SECRET)
  explanation text not null,
  primary key (level_id, idx)
);
alter table public.levels    enable row level security;
alter table public.questions enable row level security;
drop policy if exists "blocs lisibles" on public.levels;
create policy "blocs lisibles" on public.levels for select using (true);
-- Aucune policy sur questions : personne ne lit la table directement.

-- Questions sans la réponse, pour l'affichage
create or replace function public.get_questions(p_level text)
returns table(idx int, prompt text, options jsonb)
language sql stable security definer set search_path = public as $$
  select q.idx, q.prompt, q.options from questions q
  where q.level_id = p_level order by q.idx;
$$;

-- ---------- Tentatives ----------
create table if not exists public.attempts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  level_id    text not null references public.levels(id),
  score       numeric(4,1) not null,   -- barème : +1 / −0,5 / 0, plancher 0
  correct     int not null,
  wrong       int not null,
  skipped     int not null,
  passed      boolean not null,
  created_at  timestamptz not null default now()
);
create index if not exists attempts_user_level on public.attempts(user_id, level_id);
create index if not exists attempts_created on public.attempts(created_at);
alter table public.attempts enable row level security;
drop policy if exists "voir ses tentatives" on public.attempts;
create policy "voir ses tentatives" on public.attempts for select using (auth.uid() = user_id);
-- Pas d'insert direct : seul submit_quiz écrit ici.

-- Correction côté serveur.
-- p_answers : tableau JSON de 20 éléments, l'indice d'origine de l'option choisie, ou null si « passer ».
create or replace function public.submit_quiz(p_level text, p_answers jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_ok int := 0; v_ko int := 0; v_skip int := 0;
  v_score numeric; v_passed boolean; v_prev_passed boolean;
  v_detail jsonb := '[]'::jsonb;
  q record; v_choice jsonb;
  v_n int;
begin
  if v_uid is null then raise exception 'non connecté'; end if;
  if not exists (select 1 from profiles where id = v_uid) then raise exception 'pseudo manquant'; end if;
  select count(*) into v_n from questions where level_id = p_level;
  if v_n = 0 then raise exception 'bloc inconnu'; end if;
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> v_n then
    raise exception 'réponses invalides';
  end if;
  -- Bloc verrouillé ? (il faut avoir miné le bloc précédent)
  if exists (select 1 from levels l where l.id = p_level and l.ord > 1)
     and not exists (select 1 from attempts a join levels l on l.id = a.level_id
                     where a.user_id = v_uid and a.passed
                       and l.ord = (select ord - 1 from levels where id = p_level)) then
    raise exception 'bloc verrouillé';
  end if;
  -- Anti-spam : 20 s minimum entre deux envois
  if exists (select 1 from attempts where user_id = v_uid and created_at > now() - interval '20 seconds') then
    raise exception 'trop rapide, réessaie dans quelques secondes';
  end if;

  for q in select * from questions where level_id = p_level order by idx loop
    v_choice := p_answers -> q.idx;
    if v_choice is null or jsonb_typeof(v_choice) = 'null' then
      v_skip := v_skip + 1;
    elsif (v_choice #>> '{}')::int = q.answer then
      v_ok := v_ok + 1;
    else
      v_ko := v_ko + 1;
    end if;
    v_detail := v_detail || jsonb_build_object(
      'idx', q.idx, 'answer', q.answer, 'explanation', q.explanation,
      'ok', (v_choice is not null and jsonb_typeof(v_choice) <> 'null' and (v_choice #>> '{}')::int = q.answer));
  end loop;

  v_score  := greatest(0, v_ok - 0.5 * v_ko);
  v_passed := v_score >= 15;
  insert into attempts(user_id, level_id, score, correct, wrong, skipped, passed)
  values (v_uid, p_level, v_score, v_ok, v_ko, v_skip, v_passed);

  return jsonb_build_object('score', v_score, 'correct', v_ok, 'wrong', v_ko,
                            'skipped', v_skip, 'passed', v_passed, 'detail', v_detail);
end $$;

-- ---------- Classements ----------
-- Général : somme des meilleurs scores par bloc (max 20 × nb de blocs)
create or replace view public.leaderboard_general with (security_invoker = false) as
select p.pseudo, sum(b.best) as total, count(*) filter (where b.passed) as blocs_mines,
       max(b.last_at) as derniere_partie
from (select user_id, level_id, max(score) as best, bool_or(passed) as passed, max(created_at) as last_at
      from attempts group by user_id, level_id) b
join profiles p on p.id = b.user_id
group by p.pseudo;

-- Par bloc
create or replace view public.leaderboard_level with (security_invoker = false) as
select a.level_id, p.pseudo, max(a.score) as best, min(a.created_at) filter (where a.passed) as mine_le
from attempts a join profiles p on p.id = a.user_id
group by a.level_id, p.pseudo;

-- Semaine en cours (lundi 00:00, heure de Paris)
create or replace view public.leaderboard_week with (security_invoker = false) as
select p.pseudo, sum(b.best) as total, count(*) as blocs_joues
from (select user_id, level_id, max(score) as best from attempts
      where created_at >= (date_trunc('week', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris')
      group by user_id, level_id) b
join profiles p on p.id = b.user_id
group by p.pseudo;

-- Badges (calculés)
create or replace view public.player_badges with (security_invoker = false) as
select p.pseudo,
  (select count(distinct level_id) from attempts a where a.user_id = p.id and a.passed) as blocs_mines,
  (select count(*) from levels) as blocs_total,
  exists (select 1 from attempts a where a.user_id = p.id and a.score = 20) as sans_faute,
  exists (select 1 from attempts a where a.user_id = p.id and a.passed and a.wrong = 0 and a.skipped = 0) as parfait,
  (select count(*) from attempts a where a.user_id = p.id) as parties
from profiles p;

grant select on public.leaderboard_general, public.leaderboard_level,
                public.leaderboard_week, public.player_badges to anon, authenticated;
grant execute on function public.get_questions(text) to anon, authenticated;
grant execute on function public.submit_quiz(text, jsonb) to authenticated;

-- ---------- Arcade (scores déclarés par le jeu, classement séparé) ----------
create table if not exists public.arcade_scores (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  session_id text not null,
  note       numeric(4,1) not null check (note between 0 and 20),
  updated_at timestamptz not null default now(),
  primary key (user_id, session_id)
);
alter table public.arcade_scores enable row level security;

create or replace function public.submit_arcade(p_session text, p_note numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'non connecté'; end if;
  if p_note < 0 or p_note > 20 then raise exception 'note invalide'; end if;
  insert into arcade_scores(user_id, session_id, note) values (auth.uid(), p_session, p_note)
  on conflict (user_id, session_id) do update
    set note = greatest(arcade_scores.note, excluded.note), updated_at = now();
end $$;
grant execute on function public.submit_arcade(text, numeric) to authenticated;

create or replace view public.leaderboard_arcade with (security_invoker = false) as
select p.pseudo, sum(s.note) as total, count(*) as sessions
from arcade_scores s join profiles p on p.id = s.user_id group by p.pseudo;
grant select on public.leaderboard_arcade to anon, authenticated;

-- ---------- RGPD : supprimer son compte ----------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'non connecté'; end if;
  delete from auth.users where id = auth.uid();   -- cascade : profil, tentatives, arcade
end $$;
grant execute on function public.delete_my_account() to authenticated;
